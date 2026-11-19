import Foundation
import AVFoundation

public struct TimelineClip: Identifiable, Hashable {
    public let id: UUID
    public var mediaItem: MediaItem
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
    public var beatMarkers: [Double] // Beat / tagli ritmici legati al brano (secondi sorgente)
    public var beatBPM: Double? // BPM rilevato sul brano
    public var markers: [Double] // Marcatori manuali dell'utente (secondi sorgente, audio e video)
    public var priority: Int? // Priorità in Selezione: 1 = Hero, 2 = Buona, 3 = Filler, nil = nessuna
    public var isLocked: Bool // Lock manuale della clip in timeline (preservata in Auto-Fill e cancellazione)
    public var selectionSourceIn: Double? // Limite sinistro estratto in Selezione (per Slip/Roll in Modalità Gabbie)
    public var selectionSourceOut: Double? // Limite destro estratto in Selezione (per Slip/Roll in Modalità Gabbie)

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
        span: Int = 1,
        beatMarkers: [Double] = [],
        beatBPM: Double? = nil,
        markers: [Double] = [],
        priority: Int? = nil,
        isLocked: Bool = false,
        selectionSourceIn: Double? = nil,
        selectionSourceOut: Double? = nil
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
        self.beatMarkers = beatMarkers
        self.beatBPM = beatBPM
        self.markers = markers
        self.priority = priority
        self.isLocked = isLocked
        self.selectionSourceIn = selectionSourceIn
        self.selectionSourceOut = selectionSourceOut
    }

    /// Limiti sorgente disponibili (in Selezione se tracciati, altrimenti intera durata media).
    public var effectiveSourceBounds: (minSec: Double, maxSec: Double) {
        let total = max(0.0, CMTimeGetSeconds(mediaItem.duration))
        let lo = max(0.0, min(total, selectionSourceIn ?? 0.0))
        let hi = max(lo, min(total, selectionSourceOut ?? total))
        return (lo, hi)
    }

    private func mapSourceMarkersToTimeline(_ sourceMarkers: [Double]) -> [Double] {
        guard !sourceMarkers.isEmpty else { return [] }
        let tStart = CMTimeGetSeconds(timelineStart)
        let sIn = CMTimeGetSeconds(sourceIn)
        let sOut = CMTimeGetSeconds(sourceOut)
        let spd = speed > 0 ? speed : 1.0
        return sourceMarkers.compactMap { m in
            guard m >= sIn - 0.001 && m <= sOut + 0.001 else { return nil }
            return tStart + (m - sIn) / spd
        }
    }

    /// Converte i marker ritmici del brano (espressi in secondi sorgente) in secondi sulla timeline visibile.
    public func visibleBeatTimelineTimes() -> [Double] {
        mapSourceMarkersToTimeline(beatMarkers)
    }

    /// Converte i marcatori manuali (espressi in secondi sorgente) in secondi sulla timeline visibile.
    public func visibleMarkersTimelineTimes() -> [Double] {
        mapSourceMarkersToTimeline(markers)
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
