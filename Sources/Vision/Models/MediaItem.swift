import Foundation
import AppKit
import AVFoundation

public struct MediaItem: Identifiable, Hashable {
    public let id: UUID
    public var url: URL
    public var name: String
    public var originalFileName: String
    public var fileSizeBytes: Int64?
    public let duration: CMTime
    public let resolution: CGSize
    public let frameRate: Float
    public let hasVideo: Bool
    public let hasAudio: Bool
    public let videoCodec: String
    public let audioTrackCount: Int
    public var orientation: ClipOrientation
    public var thumbnail: NSImage?
    public var proxyURL: URL?
    public var beatAnalysis: SavedBeatAnalysis?

    public var matchFileName: String {
        originalFileName.isEmpty ? url.lastPathComponent : originalFileName
    }

    public var isMediaAvailableOnDisk: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public static func measureFileSizeBytes(at url: URL) -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
           vals.isRegularFile == true,
           let sz = vals.fileSize {
            return Int64(sz)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let num = attrs[.size] as? NSNumber {
            return num.int64Value
        }
        return nil
    }

    public var hasProxy: Bool {
        guard let p = proxyURL else { return false }
        return FileManager.default.fileExists(atPath: p.path)
    }

    public var effectiveURL: URL {
        if EditorProject.shared.isProxyPlaybackEnabled && hasProxy, let p = proxyURL {
            return p
        }
        return url
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        originalFileName: String? = nil,
        fileSizeBytes: Int64? = nil,
        duration: CMTime,
        resolution: CGSize,
        frameRate: Float,
        hasVideo: Bool,
        hasAudio: Bool,
        videoCodec: String = "Sconosciuto",
        audioTrackCount: Int = 0,
        orientation: ClipOrientation = .normal,
        thumbnail: NSImage? = nil,
        proxyURL: URL? = nil,
        beatAnalysis: SavedBeatAnalysis? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        let diskName = originalFileName ?? ""
        self.originalFileName = diskName.isEmpty ? url.lastPathComponent : diskName
        self.fileSizeBytes = fileSizeBytes
        self.duration = duration
        self.resolution = resolution
        self.frameRate = frameRate
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.videoCodec = videoCodec
        self.audioTrackCount = audioTrackCount
        self.orientation = orientation
        self.thumbnail = thumbnail
        self.proxyURL = proxyURL
        self.beatAnalysis = beatAnalysis
    }

    public static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func load(from url: URL) async throws -> MediaItem {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        
        var videoSize = CGSize.zero
        var nominalFPS: Float = 24.0
        var hasVideo = false
        var hasAudio = false
        var detectedCodec = "Nessuno"
        var audioTracksFound = 0
        
        for track in tracks {
            if track.mediaType == .video {
                hasVideo = true
                videoSize = try await track.load(.naturalSize)
                nominalFPS = try await track.load(.nominalFrameRate)
                
                if let fds = try? await track.load(.formatDescriptions), let first = fds.first {
                    let subType = CMFormatDescriptionGetMediaSubType(first)
                    detectedCodec = fourCCToString(subType)
                }
            } else if track.mediaType == .audio {
                hasAudio = true
                audioTracksFound += 1
                if !hasVideo, detectedCodec == "Nessuno",
                   let fds = try? await track.load(.formatDescriptions), let first = fds.first {
                    let subType = CMFormatDescriptionGetMediaSubType(first)
                    detectedCodec = fourCCToString(subType)
                }
            }
        }

        // Generate lightweight thumbnail and prime bounded disk/RAM cache
        var thumbImage: NSImage? = nil
        if hasVideo {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 280, height: 160)
            let captureTime = CMTimeMultiplyByFloat64(duration, multiplier: 0.1) // 10% into clip
            if let cgImg = try? await gen.image(at: captureTime).image {
                thumbImage = NSImage(cgImage: cgImg, size: NSSize(width: CGFloat(cgImg.width), height: CGFloat(cgImg.height)))
                if let t = thumbImage {
                    ThumbnailCache.shared.store(t, for: url)
                }
            }
        }

        let byteSize = Self.measureFileSizeBytes(at: url)
        let item = MediaItem(
            url: url,
            name: url.lastPathComponent,
            originalFileName: url.lastPathComponent,
            fileSizeBytes: byteSize,
            duration: duration,
            resolution: videoSize,
            frameRate: nominalFPS > 0 ? nominalFPS : 24.0,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            videoCodec: detectedCodec,
            audioTrackCount: audioTracksFound,
            orientation: .normal,
            thumbnail: thumbImage
        )

        let durSec = String(format: "%.2fs", CMTimeGetSeconds(duration))
        DebugLogger.shared.log("Clip analizzata: '\(item.name)' [\(Int(videoSize.width))x\(Int(videoSize.height)) @ \(String(format: "%.1f", nominalFPS))fps, Codec: \(detectedCodec), Durata: \(durSec), Tracce Audio: \(audioTracksFound)]", level: .info)

        return item
    }

    private static func fourCCToString(_ code: FourCharCode) -> String {
        let bytes: [CChar] = [
            CChar((code >> 24) & 0xff),
            CChar((code >> 16) & 0xff),
            CChar((code >> 8) & 0xff),
            CChar(code & 0xff),
            0
        ]
        let str = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        switch str {
        case "hvc1", "hev1": return "HEVC / H.265 (10-bit)"
        case "avc1": return "H.264 / AVC"
        case "apch": return "Apple ProRes 422 HQ"
        case "apcn": return "Apple ProRes 422"
        case "apcs": return "Apple ProRes 422 LT"
        case "apco": return "Apple ProRes 422 Proxy"
        case "ap4h": return "Apple ProRes 4444"
        case "lpcm": return "Audio PCM / WAV"
        case ".mp3": return "Audio MP3"
        case "aac ", "aach", "aacp", "aace": return "Audio AAC"
        case "flac": return "Audio FLAC"
        case "alac": return "Apple Lossless (ALAC)"
        case "opus": return "Audio Opus"
        default: return str.isEmpty ? "Sconosciuto" : str
        }
    }

    public var formattedDuration: String {
        let seconds = CMTimeGetSeconds(duration)
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frames = Int((seconds.truncatingRemainder(dividingBy: 1.0)) * Double(frameRate))
        return String(format: "%02d:%02d:%02d", mins, secs, frames)
    }
}
