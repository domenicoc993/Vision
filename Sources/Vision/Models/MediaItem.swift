import Foundation
import AppKit
import AVFoundation

public struct MediaItem: Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let duration: CMTime
    public let resolution: CGSize
    public let frameRate: Float
    public let hasVideo: Bool
    public let hasAudio: Bool
    public let videoCodec: String
    public let audioTrackCount: Int
    public var orientation: ClipOrientation
    public var thumbnail: NSImage?

    public init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        duration: CMTime,
        resolution: CGSize,
        frameRate: Float,
        hasVideo: Bool,
        hasAudio: Bool,
        videoCodec: String = "Sconosciuto",
        audioTrackCount: Int = 0,
        orientation: ClipOrientation = .normal,
        thumbnail: NSImage? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.duration = duration
        self.resolution = resolution
        self.frameRate = frameRate
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.videoCodec = videoCodec
        self.audioTrackCount = audioTrackCount
        self.orientation = orientation
        self.thumbnail = thumbnail
    }

    public static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func load(from url: URL) async throws -> MediaItem {
        let asset = AVURLAsset(url: url)
        
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
            }
        }

        // Generate thumbnail for preview grid
        var thumbImage: NSImage? = nil
        if hasVideo {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 240)
            let captureTime = CMTimeMultiplyByFloat64(duration, multiplier: 0.1) // 10% into clip
            if let cgImg = try? await gen.image(at: captureTime).image {
                thumbImage = NSImage(cgImage: cgImg, size: NSSize(width: 160, height: 120))
            }
        }

        let item = MediaItem(
            url: url,
            name: url.lastPathComponent,
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
