import Foundation
import CoreMedia
import AVFoundation

public enum SelectionStripType: String, CaseIterable {
    case rejected = "rejected"  // ROSSA: Scarti (da buttare)
    case analysis = "analysis"  // BLU: Da analizzare (scatola centrale dei materiali)
    case selected = "selected"  // VERDE: Selezionati (da tenere come riferimento finale)
}

public struct SelectionClip: Identifiable, Hashable {
    public let id: UUID
    public var mediaItem: MediaItem
    public var sourceIn: CMTime
    public var duration: CMTime
    public var originalName: String

    public var sourceOut: CMTime {
        CMTimeAdd(sourceIn, duration)
    }

    public init(
        id: UUID = UUID(),
        mediaItem: MediaItem,
        sourceIn: CMTime = .zero,
        duration: CMTime? = nil
    ) {
        self.id = id
        self.mediaItem = mediaItem
        self.sourceIn = sourceIn
        self.duration = duration ?? mediaItem.duration
        self.originalName = mediaItem.name
    }
}

public final class SelectionModel: Identifiable {
    public let id: UUID
    public var name: String
    public var initialClips: [MediaItem] = []
    public var rejectedClips: [SelectionClip] = [] // ROSSA
    public var analysisClips: [SelectionClip] = [] // BLU
    public var selectedClips: [SelectionClip] = [] // VERDE
    public var createdAt: Date

    public var onSelectionChanged: (() -> Void)?

    public init(id: UUID = UUID(), name: String, clips: [MediaItem] = []) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.initialClips = clips
        
        // Ordina le clip per nome in stile Finder (alfabetico naturale)
        let sortedItems = clips.sorted(by: {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
        self.analysisClips = sortedItems.map { SelectionClip(mediaItem: $0) }
        self.rejectedClips = []
        self.selectedClips = []
    }

    public var totalRejectedDuration: CMTime {
        var total = CMTime.zero
        for c in rejectedClips { total = CMTimeAdd(total, c.duration) }
        return total
    }

    public var totalAnalysisDuration: CMTime {
        var total = CMTime.zero
        for c in analysisClips { total = CMTimeAdd(total, c.duration) }
        return total
    }

    public var totalSelectedDuration: CMTime {
        var total = CMTime.zero
        for c in selectedClips { total = CMTimeAdd(total, c.duration) }
        return total
    }

    public var maxDuration: CMTime {
        let r = CMTimeGetSeconds(totalRejectedDuration)
        let a = CMTimeGetSeconds(totalAnalysisDuration)
        let s = CMTimeGetSeconds(totalSelectedDuration)
        return CMTime(seconds: max(r, max(a, s)), preferredTimescale: 600)
    }

    public func clips(for strip: SelectionStripType) -> [SelectionClip] {
        switch strip {
        case .rejected: return rejectedClips
        case .analysis: return analysisClips
        case .selected: return selectedClips
        }
    }

    public func sortClips(_ list: inout [SelectionClip]) {
        list.sort { a, b in
            let cmp = a.mediaItem.name.localizedStandardCompare(b.mediaItem.name)
            if cmp == .orderedAscending { return true }
            if cmp == .orderedDescending { return false }
            return CMTimeCompare(a.sourceIn, b.sourceIn) < 0
        }
    }

    // Dalla striscia BLU agli SCARTI (Freccia Su ↑)
    @discardableResult
    public func rejectClip(id: UUID) -> Bool {
        guard let idx = analysisClips.firstIndex(where: { $0.id == id }) else { return false }
        let clip = analysisClips.remove(at: idx)
        rejectedClips.append(clip)
        onSelectionChanged?()
        return true
    }

    // Dagli SCARTI indietro alla striscia BLU (Freccia Giù ↓)
    @discardableResult
    public func restoreFromRejected(id: UUID) -> Bool {
        guard let idx = rejectedClips.firstIndex(where: { $0.id == id }) else { return false }
        let clip = rejectedClips.remove(at: idx)
        analysisClips.append(clip)
        sortClips(&analysisClips)
        onSelectionChanged?()
        return true
    }

    // Dalla striscia BLU ai SELEZIONATI (Freccia Giù ↓)
    @discardableResult
    public func approveClip(id: UUID) -> Bool {
        guard let idx = analysisClips.firstIndex(where: { $0.id == id }) else { return false }
        let clip = analysisClips.remove(at: idx)
        selectedClips.append(clip)
        sortClips(&selectedClips)
        onSelectionChanged?()
        return true
    }

    // Dai SELEZIONATI indietro alla striscia BLU (Freccia Su ↑)
    @discardableResult
    public func unapproveClip(id: UUID) -> Bool {
        guard let idx = selectedClips.firstIndex(where: { $0.id == id }) else { return false }
        let clip = selectedClips.remove(at: idx)
        analysisClips.append(clip)
        sortClips(&analysisClips)
        onSelectionChanged?()
        return true
    }

    // Trim Inizio su clip in analisi: la porzione prima del taglio va in Scarti (Rossa)
    @discardableResult
    public func trimStart(clipId: UUID, atOffset offset: CMTime) -> Bool {
        guard let idx = analysisClips.firstIndex(where: { $0.id == clipId }) else { return false }
        let clip = analysisClips[idx]
        guard CMTimeCompare(offset, .zero) > 0, CMTimeCompare(offset, clip.duration) < 0 else { return false }

        // Blocco scartato: [0 .. offset]
        let rejectedPart = SelectionClip(
            mediaItem: clip.mediaItem,
            sourceIn: clip.sourceIn,
            duration: offset
        )
        rejectedClips.append(rejectedPart)

        // Blocco tenuto: [offset .. duration]
        let keptDuration = CMTimeSubtract(clip.duration, offset)
        analysisClips[idx].sourceIn = CMTimeAdd(clip.sourceIn, offset)
        analysisClips[idx].duration = keptDuration

        onSelectionChanged?()
        return true
    }

    // Trim Fine su clip in analisi: la porzione dopo il taglio va in Scarti (Rossa)
    @discardableResult
    public func trimEnd(clipId: UUID, atOffset offset: CMTime) -> Bool {
        guard let idx = analysisClips.firstIndex(where: { $0.id == clipId }) else { return false }
        let clip = analysisClips[idx]
        guard CMTimeCompare(offset, .zero) > 0, CMTimeCompare(offset, clip.duration) < 0 else { return false }

        // Blocco scartato: [offset .. duration]
        let rejectedPart = SelectionClip(
            mediaItem: clip.mediaItem,
            sourceIn: CMTimeAdd(clip.sourceIn, offset),
            duration: CMTimeSubtract(clip.duration, offset)
        )
        rejectedClips.append(rejectedPart)

        // Blocco tenuto: [0 .. offset]
        analysisClips[idx].duration = offset

        onSelectionChanged?()
        return true
    }

    // Spezza (Split) una clip in due blocchi indipendenti all'interno della striscia in analisi
    @discardableResult
    public func splitClip(clipId: UUID, atOffset offset: CMTime) -> Bool {
        guard let idx = analysisClips.firstIndex(where: { $0.id == clipId }) else { return false }
        let clip = analysisClips[idx]
        guard CMTimeCompare(offset, .zero) > 0, CMTimeCompare(offset, clip.duration) < 0 else { return false }

        let firstPart = SelectionClip(
            mediaItem: clip.mediaItem,
            sourceIn: clip.sourceIn,
            duration: offset
        )
        let secondPart = SelectionClip(
            mediaItem: clip.mediaItem,
            sourceIn: CMTimeAdd(clip.sourceIn, offset),
            duration: CMTimeSubtract(clip.duration, offset)
        )

        analysisClips[idx] = firstPart
        analysisClips.insert(secondPart, at: idx + 1)
        onSelectionChanged?()
        return true
    }

    // Genera un TimelineModel provvisorio lineare per alimentare l'AVPlayer e il CompositionEngine
    public func makeTimelineModel(for strip: SelectionStripType) -> TimelineModel {
        let clipsList = clips(for: strip)
        let model = TimelineModel(name: "\(name) - \(strip.rawValue)")
        
        var runningTime = CMTime.zero
        for sClip in clipsList {
            let linkId = UUID()
            let vClip = TimelineClip(
                mediaItem: sClip.mediaItem,
                sourceIn: sClip.sourceIn,
                sourceOut: CMTimeAdd(sClip.sourceIn, sClip.duration),
                timelineStart: runningTime,
                trackIndex: 0,
                mediaType: .video,
                orientation: sClip.mediaItem.orientation,
                linkGroupId: linkId
            )
            let aClip = TimelineClip(
                mediaItem: sClip.mediaItem,
                sourceIn: sClip.sourceIn,
                sourceOut: CMTimeAdd(sClip.sourceIn, sClip.duration),
                timelineStart: runningTime,
                trackIndex: 0,
                mediaType: .audio,
                orientation: .normal,
                linkGroupId: linkId
            )

            model.videoTracks[0].clips.append(vClip)
            model.audioTracks[0].clips.append(aClip)

            runningTime = CMTimeAdd(runningTime, sClip.duration)
        }

        return model
    }
}
