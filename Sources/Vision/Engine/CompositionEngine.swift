import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import Metal

public final class VisionLUTInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public struct ClipTransformSegment {
        public let start: CMTime
        public let end: CMTime
        public let transform: CGAffineTransform
    }

    public struct TrackLayer {
        public let trackID: CMPersistentTrackID
        public let segments: [ClipTransformSegment]
    }

    public let timeRange: CMTimeRange
    public let enablePostProcessing: Bool = false
    public let containsTweening: Bool = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public let trackLayers: [TrackLayer] // Ordered bottom-most track to top-most track

    public init(timeRange: CMTimeRange, trackLayers: [TrackLayer]) {
        self.timeRange = timeRange
        self.trackLayers = trackLayers
        self.requiredSourceTrackIDs = trackLayers.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

public final class VisionLUTCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let sharedCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private static let renderColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func cancelAllPendingVideoCompositionRequests() {}

    public func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = asyncVideoCompositionRequest.videoCompositionInstruction as? VisionLUTInstruction else {
                asyncVideoCompositionRequest.finishCancelledRequest()
                return
            }

            guard let dstBuffer = asyncVideoCompositionRequest.renderContext.newPixelBuffer() else {
                asyncVideoCompositionRequest.finish(with: NSError(domain: "VisionLUTCompositor", code: -1))
                return
            }

            let renderSize = asyncVideoCompositionRequest.renderContext.size
            let renderRect = CGRect(origin: .zero, size: renderSize)
            let compTime = asyncVideoCompositionRequest.compositionTime

            var composited = CIImage(color: CIColor.black).cropped(to: renderRect)

            for layer in instruction.trackLayers {
                guard let seg = layer.segments.first(where: {
                    CMTimeCompare(compTime, $0.start) >= 0 && CMTimeCompare(compTime, $0.end) < 0
                }) ?? layer.segments.first(where: {
                    CMTimeCompare(compTime, $0.start) >= 0 && CMTimeCompare(compTime, $0.end) <= 0
                }) else {
                    continue
                }

                guard let srcBuffer = asyncVideoCompositionRequest.sourceFrame(byTrackID: layer.trackID) else {
                    continue
                }

                let srcImg = CIImage(cvPixelBuffer: srcBuffer)
                let srcExtent = srcImg.extent
                let toTopLeft = CGAffineTransform(translationX: 0, y: srcExtent.height).scaledBy(x: 1, y: -1)
                let backToBottomLeft = CGAffineTransform(translationX: 0, y: renderSize.height).scaledBy(x: 1, y: -1)
                let ciTransform = toTopLeft.concatenating(seg.transform).concatenating(backToBottomLeft)
                let transformed = srcImg.transformed(by: ciTransform)
                composited = transformed.composited(over: composited)
            }

            if let lutParams = LUTEngine.shared.currentLUTParameters() {
                composited = LUTEngine.apply(lutParams, to: composited)
            }

            composited = composited.cropped(to: renderRect)
            Self.sharedCIContext.render(composited, to: dstBuffer, bounds: renderRect, colorSpace: Self.renderColorSpace)
            asyncVideoCompositionRequest.finish(withComposedVideoFrame: dstBuffer)
        }
    }
}

public final class CompositionEngine {
    public static let shared = CompositionEngine()

    public struct CachedAssetMetadata {
        public let asset: AVURLAsset
        public let videoTrack: AVAssetTrack?
        public let naturalSize: CGSize
        public let preferredTransform: CGAffineTransform
        public let audioTracks: [AVAssetTrack]
    }

    private var metadataCache: [URL: CachedAssetMetadata] = [:]
    private let cacheLock = NSLock()

    public init() {}

    private func getCachedMetadata(for url: URL) -> CachedAssetMetadata? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return metadataCache[url]
    }

    private func setCachedMetadata(_ metadata: CachedAssetMetadata, for url: URL) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        metadataCache[url] = metadata
    }

    /// Preloads and caches track metadata in memory to guarantee 0ms rebuild latency during trimming and editing
    public func preloadMetadata(for url: URL) async {
        _ = try? await getMetadata(for: url)
    }

    private func getMetadata(for url: URL) async throws -> CachedAssetMetadata {
        if let cached = getCachedMetadata(for: url) {
            return cached
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = vTracks.first

        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        if let vt = videoTrack {
            naturalSize = try await vt.load(.naturalSize)
            preferredTransform = try await vt.load(.preferredTransform)
        } else {
            naturalSize = .zero
            preferredTransform = .identity
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let metadata = CachedAssetMetadata(
            asset: asset,
            videoTrack: videoTrack,
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            audioTracks: audioTracks
        )

        setCachedMetadata(metadata, for: url)
        return metadata
    }

    public func buildComposition(from model: TimelineModel) async throws -> (AVComposition, AVVideoComposition?, AVAudioMix?) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let composition = AVMutableComposition()
        
        let renderSize = model.format.size
        let frameRate: Float = model.format.fps

        var compVideoTracks: [Int: AVMutableCompositionTrack] = [:]
        var clipTransforms: [Int: [(start: CMTime, end: CMTime, transform: CGAffineTransform)]] = [:]
        var audioMixParameters: [AVMutableAudioMixInputParameters] = []
        var totalClipsCount = 0
        var urlExistsCache: [URL: Bool] = [:]

        func fileExistsCached(_ url: URL) -> Bool {
            if let cached = urlExistsCache[url] { return cached }
            let exists = FileManager.default.fileExists(atPath: url.path)
            urlExistsCache[url] = exists
            return exists
        }

        // 1. Populate Video Tracks that have clips and are enabled
        for track in model.videoTracks {
            guard track.isEnabled else { continue }
            guard !track.clips.isEmpty else { continue }
            
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            compVideoTracks[track.id] = compTrack
            clipTransforms[track.id] = []

            for clip in track.clips {
                guard !clip.isOrphan else { continue }
                let effURL = clip.mediaItem.effectiveURL
                guard fileExistsCached(effURL) else {
                    DebugLogger.shared.log("Media offline per '\(clip.mediaItem.name)' in V\(track.id + 1)", level: .warning)
                    continue
                }
                totalClipsCount += 1
                do {
                    let metadata = try await getMetadata(for: effURL)
                    if let videoTrack = metadata.videoTrack {
                        try compTrack.insertTimeRange(
                            clip.sourceTimeRange,
                            of: videoTrack,
                            at: clip.timelineStart
                        )

                        if clip.speed != 1.0 && clip.speed > 0 {
                            let insertedRange = CMTimeRange(start: clip.timelineStart, duration: clip.sourceDuration)
                            compTrack.scaleTimeRange(insertedRange, toDuration: clip.duration)
                        }

                        // Calculate frame transform for orientation and aspect-fit into project resolution
                        let transform = makeTransform(
                            naturalSize: metadata.naturalSize,
                            preferredTransform: metadata.preferredTransform,
                            orientationAngle: clip.orientation.radians,
                            renderSize: renderSize
                        )
                        clipTransforms[track.id]?.append((start: clip.timelineStart, end: clip.timelineEnd, transform: transform))
                    }
                } catch {
                    DebugLogger.shared.log("ERRORE inserimento video '\(clip.mediaItem.name)': \(error)", level: .error)
                }
            }
        }

        // 2. Populate Audio Tracks that have clips and are enabled (mute check), reusing channel tracks per TimelineTrack
        //    so 65 clips x 4 channels uses only 4 composition tracks instead of 260 parallel pipelines.
        for track in model.audioTracks {
            guard track.isEnabled else { continue }
            guard !track.clips.isEmpty else { continue }

            var trackAudioChannels: [AVMutableCompositionTrack] = []
            var spilloverAudioTracks: [AVMutableCompositionTrack] = []

            for clip in track.clips {
                guard !clip.isOrphan else { continue }
                let effURL = clip.mediaItem.effectiveURL
                guard fileExistsCached(effURL) else {
                    DebugLogger.shared.log("Media offline per '\(clip.mediaItem.name)' in A\(track.id + 1)", level: .warning)
                    continue
                }
                do {
                    let metadata = try await getMetadata(for: effURL)
                    for (chIdx, srcAudioTrack) in metadata.audioTracks.enumerated() {
                        let compAudioTrack: AVMutableCompositionTrack
                        if chIdx < trackAudioChannels.count {
                            compAudioTrack = trackAudioChannels[chIdx]
                        } else if let newTrack = composition.addMutableTrack(
                            withMediaType: .audio,
                            preferredTrackID: kCMPersistentTrackID_Invalid
                        ) {
                            trackAudioChannels.append(newTrack)
                            compAudioTrack = newTrack
                        } else {
                            continue
                        }

                        do {
                            try compAudioTrack.insertTimeRange(
                                clip.sourceTimeRange,
                                of: srcAudioTrack,
                                at: clip.timelineStart
                            )
                            if clip.speed != 1.0 && clip.speed > 0 {
                                let insertedRange = CMTimeRange(start: clip.timelineStart, duration: clip.sourceDuration)
                                compAudioTrack.scaleTimeRange(insertedRange, toDuration: clip.duration)
                            }
                        } catch {
                            // Overlapping clip fallback on dedicated spillover track
                            if let spill = composition.addMutableTrack(
                                withMediaType: .audio,
                                preferredTrackID: kCMPersistentTrackID_Invalid
                            ) {
                                try spill.insertTimeRange(
                                    clip.sourceTimeRange,
                                    of: srcAudioTrack,
                                    at: clip.timelineStart
                                )
                                if clip.speed != 1.0 && clip.speed > 0 {
                                    let insertedRange = CMTimeRange(start: clip.timelineStart, duration: clip.sourceDuration)
                                    spill.scaleTimeRange(insertedRange, toDuration: clip.duration)
                                }
                                spilloverAudioTracks.append(spill)
                            }
                        }
                    }
                } catch {
                    DebugLogger.shared.log("ERRORE inserimento audio '\(clip.mediaItem.name)': \(error)", level: .error)
                }
            }

            for chTrack in trackAudioChannels + spilloverAudioTracks {
                let inputParam = AVMutableAudioMixInputParameters(track: chTrack)
                inputParam.setVolume(1.0, at: .zero)
                audioMixParameters.append(inputParam)
            }
        }

        // Build Audio Mix if active
        var audioMix: AVMutableAudioMix? = nil
        if !audioMixParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioMixParameters
            audioMix = mix
        }

        // 3. Build Video Composition if we have active video tracks
        // composition.duration is synchronous and instant in memory!
        let totalDuration = composition.duration
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        var videoComposition: AVVideoComposition? = nil
        if CMTimeCompare(totalDuration, .zero) > 0 && !compVideoTracks.isEmpty {
            let vComp = AVMutableVideoComposition()
            vComp.renderSize = renderSize
            vComp.frameDuration = CMTime(value: 1, timescale: Int32(frameRate > 0 ? frameRate : 30))

            if LUTEngine.shared.currentLUTParameters() != nil {
                var layers: [VisionLUTInstruction.TrackLayer] = []
                for track in model.videoTracks where track.isEnabled {
                    if let compTrack = compVideoTracks[track.id] {
                        let segs = (clipTransforms[track.id] ?? []).map {
                            VisionLUTInstruction.ClipTransformSegment(start: $0.start, end: $0.end, transform: $0.transform)
                        }
                        layers.append(VisionLUTInstruction.TrackLayer(trackID: compTrack.trackID, segments: segs))
                    }
                }
                vComp.customVideoCompositorClass = VisionLUTCompositor.self
                vComp.instructions = [VisionLUTInstruction(timeRange: CMTimeRange(start: .zero, duration: totalDuration), trackLayers: layers)]
            } else {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: totalDuration)

                var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
                for track in model.videoTracks.reversed() {
                    if track.isEnabled, let compTrack = compVideoTracks[track.id] {
                        let layerInst = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
                        if let transforms = clipTransforms[track.id] {
                            for item in transforms {
                                layerInst.setTransform(item.transform, at: item.start)
                            }
                        }
                        layerInstructions.append(layerInst)
                    }
                }
                instruction.layerInstructions = layerInstructions
                vComp.instructions = [instruction]
            }
            videoComposition = vComp
        }

        DebugLogger.shared.log("Composizione rigenerata in \(elapsedMs)ms (\(totalClipsCount) clip su timeline)", level: .playback)

        return (composition, videoComposition, audioMix)
    }

    private func makeTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        orientationAngle: Double,
        renderSize: CGSize
    ) -> CGAffineTransform {
        var t = preferredTransform
        if orientationAngle != 0 {
            let rot = CGAffineTransform(rotationAngle: CGFloat(orientationAngle))
            t = t.concatenating(rot)
        }

        let rect = CGRect(origin: .zero, size: naturalSize).applying(t)
        let normalize = CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y)
        t = t.concatenating(normalize)

        let orientedSize = rect.size
        let scaleX = renderSize.width / max(1, orientedSize.width)
        let scaleY = renderSize.height / max(1, orientedSize.height)
        let scale = min(scaleX, scaleY)

        let scaledTransform = CGAffineTransform(scaleX: scale, y: scale)
        t = t.concatenating(scaledTransform)

        let finalW = orientedSize.width * scale
        let finalH = orientedSize.height * scale
        let tx = (renderSize.width - finalW) / 2.0
        let ty = (renderSize.height - finalH) / 2.0
        let center = CGAffineTransform(translationX: tx, y: ty)
        t = t.concatenating(center)

        return t
    }

    @MainActor
    public func createPlayerItem(from model: TimelineModel) async throws -> AVPlayerItem? {
        guard CMTimeCompare(model.totalDuration, .zero) > 0 else {
            return nil
        }
        let (composition, videoComp, audioMix) = try await buildComposition(from: model)
        guard CMTimeCompare(composition.duration, .zero) > 0 else {
            return nil
        }
        let item = AVPlayerItem(asset: composition)
        if let videoComp = videoComp {
            item.videoComposition = videoComp
        }
        if let audioMix = audioMix {
            item.audioMix = audioMix
        }
        return item
    }
}
