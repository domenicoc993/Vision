import Foundation
import AVFoundation

public enum ClipColorTag: String, CaseIterable, Codable, Hashable {
    case teal
    case sky
    case indigo
    case violet
    case magenta
    case rose
    case coral
    case amber
    case ochre
    case olive
    case emerald
    case slate

    public var displayName: String {
        switch self {
        case .teal: return "Ottanio"
        case .sky: return "Azzurro"
        case .indigo: return "Indaco"
        case .violet: return "Viola"
        case .magenta: return "Magenta"
        case .rose: return "Rosa"
        case .coral: return "Corallo"
        case .amber: return "Ambra"
        case .ochre: return "Ocra"
        case .olive: return "Oliva"
        case .emerald: return "Smeraldo"
        case .slate: return "Ardesia"
        }
    }

    /// Balanced medium-saturation RGB components (neither too light nor too dark for white clip labels).
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .teal: return (0.16, 0.48, 0.52)
        case .sky: return (0.20, 0.46, 0.70)
        case .indigo: return (0.29, 0.34, 0.68)
        case .violet: return (0.46, 0.30, 0.64)
        case .magenta: return (0.60, 0.27, 0.50)
        case .rose: return (0.66, 0.28, 0.38)
        case .coral: return (0.70, 0.33, 0.26)
        case .amber: return (0.66, 0.44, 0.18)
        case .ochre: return (0.58, 0.50, 0.20)
        case .olive: return (0.41, 0.50, 0.24)
        case .emerald: return (0.20, 0.50, 0.33)
        case .slate: return (0.35, 0.40, 0.46)
        }
    }
}

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
    public var priority: Int? // Priorità in Selezione: 4 = Dialogo/Intera, 1 = Hero, 2 = Buona, 3 = Filler, nil = nessuna
    public var isLocked: Bool // Lock manuale della clip in timeline (preservata in Auto-Fill e cancellazione)
    public var isApproved: Bool // Approvata ("OK"): verde, immutabile come locked ma sbloccabile solo con '\'
    public var selectionSourceIn: Double? // Limite sinistro estratto in Selezione (per Slip/Roll in Modalità Gabbie)
    public var selectionSourceOut: Double? // Limite destro estratto in Selezione (per Slip/Roll in Modalità Gabbie)
    public var colorTag: ClipColorTag? // Colore estetico/gestionale opzionale della clip (nil = Default neutro)

    /// True se la clip è bloccata (manualmente con `L` oppure approvata con `\`).
    public var isEffectivelyLocked: Bool { isLocked || isApproved }

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
        isApproved: Bool = false,
        selectionSourceIn: Double? = nil,
        selectionSourceOut: Double? = nil,
        colorTag: ClipColorTag? = nil
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
        self.isApproved = isApproved
        self.selectionSourceIn = selectionSourceIn
        self.selectionSourceOut = selectionSourceOut
        self.colorTag = colorTag
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
