import Foundation
import AVFoundation

public struct TimelineClip: Identifiable, Hashable {
    public let id: UUID
    public let mediaItem: MediaItem
    public var sourceIn: CMTime
    public var sourceOut: CMTime
    public var timelineStart: CMTime
    public var trackIndex: Int
    public var mediaType: AVMediaType
    public var orientation: ClipOrientation
    public var linkGroupId: UUID?
    public var isOrphan: Bool
    public var speed: Double // 1.0 = normale, 0.5 = slow motion 50%, 2.0 = 200%
    public var cageIndex: Int? // Indice della gabbia ritmata occupata
    public var span: Int // Numero di gabbie occupate (default 1)

    public init(
        id: UUID = UUID(),
        mediaItem: MediaItem,
        sourceIn: CMTime = .zero,
        sourceOut: CMTime? = nil,
        timelineStart: CMTime = .zero,
        trackIndex: Int = 0,
        mediaType: AVMediaType = .video,
        orientation: ClipOrientation? = nil,
        linkGroupId: UUID? = nil,
        isOrphan: Bool = false,
        speed: Double = 1.0,
        cageIndex: Int? = nil,
        span: Int = 1
    ) {
        self.id = id
        self.mediaItem = mediaItem
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut ?? mediaItem.duration
        self.timelineStart = timelineStart
        self.trackIndex = trackIndex
        self.mediaType = mediaType
        self.orientation = orientation ?? mediaItem.orientation
        self.linkGroupId = linkGroupId
        self.isOrphan = isOrphan
        self.speed = speed
        self.cageIndex = cageIndex
        self.span = max(1, span)
    }

    public var duration: CMTime {
        let raw = CMTimeSubtract(sourceOut, sourceIn)
        if speed > 0 && speed != 1.0 {
            // Durata sulla timeline dilatata o compressa in base alla velocità
            let sec = CMTimeGetSeconds(raw) / speed
            return CMTime(seconds: sec, preferredTimescale: 600)
        }
        return raw
    }

    public var sourceDuration: CMTime {
        CMTimeSubtract(sourceOut, sourceIn)
    }

    public var timelineEnd: CMTime {
        CMTimeAdd(timelineStart, duration)
    }

    public var sourceTimeRange: CMTimeRange {
        CMTimeRange(start: sourceIn, duration: duration)
    }

    public var timelineTimeRange: CMTimeRange {
        CMTimeRange(start: timelineStart, duration: duration)
    }
}
