import Foundation
import CoreMedia
import AVFoundation

public enum BeatIntervalMode: String, CaseIterable, Codable {
    case oneBeat = "1 Battito (Veloce / Dinamico)"
    case twoBeats = "2 Battiti (Standard / Pop)"
    case fourBeats = "4 Battiti (1 Battuta / Disteso)"
    case dynamicTransients = "Momenti Forti (Picchi & Esplosioni)"
    case adaptiveDirector = "Regia Adattiva (Ritmo + Picchi)"

    public var shortTitle: String {
        switch self {
        case .oneBeat: return "1 Beat"
        case .twoBeats: return "2 Beat"
        case .fourBeats: return "4 Beat"
        case .dynamicTransients: return "Momenti Forti"
        case .adaptiveDirector: return "Regia Adattiva"
        }
    }
}

public struct RhythmicCage: Identifiable, Hashable, Codable {
    public let id: UUID
    public var index: Int
    public var startSeconds: Double
    public var durationSeconds: Double
    public var assignedClipId: UUID?
    public var span: Int // Default 1 (occupa 1 gabbia), se 2 occupa 2 gabbie consecutive

    public init(
        id: UUID = UUID(),
        index: Int,
        startSeconds: Double,
        durationSeconds: Double,
        assignedClipId: UUID? = nil,
        span: Int = 1
    ) {
        self.id = id
        self.index = index
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.assignedClipId = assignedClipId
        self.span = max(1, span)
    }

    public var endSeconds: Double {
        startSeconds + durationSeconds
    }

    public var startTime: CMTime {
        CMTime(seconds: startSeconds, preferredTimescale: 600)
    }

    public var durationTime: CMTime {
        CMTime(seconds: durationSeconds, preferredTimescale: 600)
    }

    public var endTime: CMTime {
        CMTime(seconds: endSeconds, preferredTimescale: 600)
    }

    public var timeRange: CMTimeRange {
        CMTimeRange(start: startTime, duration: durationTime)
    }
}
