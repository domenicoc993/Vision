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
        isOrphan: Bool = false
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
    }

    public var duration: CMTime {
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
