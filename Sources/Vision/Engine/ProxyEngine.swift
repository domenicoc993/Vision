import Foundation
import AVFoundation
import AppKit
import VideoToolbox

public enum ProxyCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264 (Bilanciato & Compatibile)"
    case hevc = "H.265 / HEVC (Massima Efficienza)"

    public var id: String { rawValue }

    public var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    public var fileExtension: String {
        return "mp4"
    }
}

public enum ProxyScale: Double, CaseIterable, Identifiable {
    case half = 0.5
    case quarter = 0.25
    case eighth = 0.125

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .half: return "1/2 dell'originale (50%)"
        case .quarter: return "1/4 dell'originale (25%)"
        case .eighth: return "1/8 dell'originale (12.5%)"
        }
    }
}

public final class ProxyEngine: @unchecked Sendable {
    public static let shared = ProxyEngine()

    private var isCancelled = false

    public func cancel() {
        isCancelled = true
    }

    public func generateProxy(
        for item: MediaItem,
        codec: ProxyCodec,
        scale: ProxyScale,
        destinationFolder: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> URL {
        isCancelled = false

        let sourceURL = item.url
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let totalDurationSec = max(0.1, CMTimeGetSeconds(duration))

        // Ensure directory exists
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let outputFileName = "\(baseName)_proxy_\(Int(scale.rawValue * 100))pct.\(codec.fileExtension)"
        let outputURL = destinationFolder.appendingPathComponent(outputFileName)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Compute scaled dimensions (even numbers)
        var targetWidth = Int(item.resolution.width * scale.rawValue)
        var targetHeight = Int(item.resolution.height * scale.rawValue)
        if targetWidth % 2 != 0 { targetWidth += 1 }
        if targetHeight % 2 != 0 { targetHeight += 1 }
        targetWidth = max(160, targetWidth)
        targetHeight = max(120, targetHeight)

        // Bitrate calculation tailored for smooth proxy playback
        let pixelCount = targetWidth * targetHeight
        let videoBitrate: Int
        if pixelCount >= 1920 * 1080 {
            videoBitrate = codec == .hevc ? 4_000_000 : 6_000_000
        } else if pixelCount >= 1280 * 720 {
            videoBitrate = codec == .hevc ? 2_000_000 : 3_000_000
        } else {
            videoBitrate = codec == .hevc ? 1_000_000 : 1_500_000
        }

        // Setup AVAssetReader
        let reader = try AVAssetReader(asset: asset)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw NSError(domain: "ProxyEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "Nessuna traccia video trovata."])
        }

        let readerVideoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        readerVideoOutput.alwaysCopiesSampleData = false
        if reader.canAdd(readerVideoOutput) {
            reader.add(readerVideoOutput)
        }

        // Setup Audio reader if available
        var readerAudioOutput: AVAssetReaderTrackOutput? = nil
        if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
            let audioOut = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            audioOut.alwaysCopiesSampleData = false
            if reader.canAdd(audioOut) {
                reader.add(audioOut)
                readerAudioOutput = audioOut
            }
        }

        // Setup AVAssetWriter
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Video Writer Input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: codec == .hevc ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : (AVVideoProfileLevelH264HighAutoLevel as String)
            ]
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerVideoInput.expectsMediaDataInRealTime = false
        if let transform = try? await videoTrack.load(.preferredTransform) {
            writerVideoInput.transform = transform
        }
        if writer.canAdd(writerVideoInput) {
            writer.add(writerVideoInput)
        }

        // Audio Writer Input
        var writerAudioInput: AVAssetWriterInput? = nil
        if readerAudioOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                writerAudioInput = aInput
            }
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Processing queue
        let queue = DispatchQueue(label: "com.vision.proxy.writer", qos: .userInitiated)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            // 1. Process Video
            group.enter()
            writerVideoInput.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self = self else { return }
                while writerVideoInput.isReadyForMoreMediaData {
                    if self.isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        group.leave()
                        return
                    }

                    if let sample = readerVideoOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let progress = min(1.0, CMTimeGetSeconds(pts) / totalDurationSec)
                        DispatchQueue.main.async { progressHandler(progress) }

                        if !writerVideoInput.append(sample) {
                            reader.cancelReading()
                            writerVideoInput.markAsFinished()
                            group.leave()
                            return
                        }
                    } else {
                        writerVideoInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }

            // 2. Process Audio
            if let aOut = readerAudioOutput, let aIn = writerAudioInput {
                group.enter()
                aIn.requestMediaDataWhenReady(on: queue) { [weak self] in
                    guard let self = self else { return }
                    while aIn.isReadyForMoreMediaData {
                        if self.isCancelled {
                            reader.cancelReading()
                            writer.cancelWriting()
                            group.leave()
                            return
                        }

                        if let sample = aOut.copyNextSampleBuffer() {
                            if !aIn.append(sample) {
                                aIn.markAsFinished()
                                group.leave()
                                return
                            }
                        } else {
                            aIn.markAsFinished()
                            group.leave()
                            break
                        }
                    }
                }
            }

            group.notify(queue: queue) {
                if reader.status == .failed, let error = reader.error {
                    continuation.resume(throwing: error)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        DispatchQueue.main.async { progressHandler(1.0) }
                        continuation.resume()
                    } else if let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        return outputURL
    }
}
