import Foundation
import AVFoundation

public enum ClipEdge {
    case start
    case end
}

public struct ClipboardClipEntry {
    public let mediaItem: MediaItem
    public let sourceIn: CMTime
    public let sourceOut: CMTime
    public let relativeStart: CMTime
    public let trackIndex: Int
    public let isVideo: Bool
    public let orientation: ClipOrientation
    public let linkGroupId: UUID?
    public let speed: Double
    public let span: Int
    public let beatMarkers: [Double]
    public let beatBPM: Double?
    public let markers: [Double]
    public let priority: Int?
    public let selectionSourceIn: Double?
    public let selectionSourceOut: Double?
    public let colorTag: ClipColorTag?
}

public final class VisionTimelineClipboard {
    public static let shared = VisionTimelineClipboard()
    public var entries: [ClipboardClipEntry] = []
    private init() {}
}

public struct SelectionSmartFilter: Equatable {
    public var includePriority1: Bool = false
    public var includePriority2: Bool = false
    public var includePriority3: Bool = false
    public var includePriority4: Bool = false
    public var includeNoPriority: Bool = false
    public var includeWithMarkers: Bool = false
    public var includeWithoutMarkers: Bool = false

    public var isActive: Bool {
        includePriority1 || includePriority2 || includePriority3 || includePriority4 || includeNoPriority || includeWithMarkers || includeWithoutMarkers
    }

    public func matches(_ clip: TimelineClip) -> Bool {
        guard isActive else { return true }

        let hasPriorityFilter = includePriority1 || includePriority2 || includePriority3 || includePriority4 || includeNoPriority
        if hasPriorityFilter {
            let pOk: Bool
            switch clip.priority {
            case 1?: pOk = includePriority1
            case 2?: pOk = includePriority2
            case 3?: pOk = includePriority3
            case 4?: pOk = includePriority4
            default: pOk = includeNoPriority
            }
            if !pOk { return false }
        }

        let hasMarkerFilter = includeWithMarkers || includeWithoutMarkers
        if hasMarkerFilter {
            let hasMarkers = !clip.markers.isEmpty
            if !((hasMarkers && includeWithMarkers) || (!hasMarkers && includeWithoutMarkers)) {
                return false
            }
        }

        return true
    }
}

public enum AutoFillOrderMode: String, CaseIterable {
    case chronological = "Cronologia Elastica (ordine Selezione)"
    case random = "Casuale (Random)"
}

public enum AutoFillStartMode: Int, CaseIterable {
    case fromFirstCage = 0
    case fromPlayhead = 1
}

public struct AutoFillForecast {
    public let totalTargetCages: Int
    public let lockedCagesCount: Int
    public let unlockedCagesCount: Int
    public let selectionClipCount: Int
    public let p4Count: Int
    public let p1Count: Int
    public let p2Count: Int
    public let p3Count: Int
    public let predictedUniqueCount: Int
    public let predictedSubsegmentCount: Int
    public let predictedFilledCount: Int
    public let predictedEmptyCount: Int
    public let startingCageNumber: Int // 1-based index in full cage list
}

public struct AutoFillResult {
    public let filledCount: Int
    public let totalUnlockedCages: Int
    public let lockedCagesCount: Int
    public let primaryUniqueCount: Int
    public let subsegmentCount: Int
    public let remainingEmptyCages: Int
    public let movedAudioToA2: Bool
}

public struct TimelineTrack: Identifiable, Hashable {
    public var id: Int
    public var name: String
    public let mediaType: AVMediaType
    public var clips: [TimelineClip]
    public var isEnabled: Bool
    public var isLocked: Bool

    public init(
        id: Int,
        name: String,
        mediaType: AVMediaType,
        clips: [TimelineClip] = [],
        isEnabled: Bool = true,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
        self.clips = clips
        self.isEnabled = isEnabled
        self.isLocked = isLocked
    }
}

public final class TimelineModel {
    public var id: UUID = UUID()
    public var name: String = "Timeline 1"
    public var isSelection: Bool // Special timeline used purely for selecting/trimming highlights before editing
    public var isTemporaryCompare: Bool = false // Timeline temporanea in memoria per Modalità Confronta (mai salvata su DB) = false

    public var videoTracks: [TimelineTrack]
    public var audioTracks: [TimelineTrack]

    // Multi-selection support (Marquee box selection & multi-select)
    public static let selectionChangedNotification = Notification.Name("TimelineModel.selectionChanged")
    public var selectedClipIds: Set<UUID> = [] {
        didSet {
            if oldValue != selectedClipIds {
                NotificationCenter.default.post(name: Self.selectionChangedNotification, object: self)
            }
        }
    }
    public var selectedClipId: UUID? {
        get {
            guard !selectedClipIds.isEmpty else { return nil }
            for track in videoTracks {
                if let vClip = track.clips.first(where: { selectedClipIds.contains($0.id) }) {
                    return vClip.id
                }
            }
            for track in audioTracks {
                if let aClip = track.clips.first(where: { selectedClipIds.contains($0.id) }) {
                    return aClip.id
                }
            }
            return selectedClipIds.first
        }
        set {
            if let id = newValue {
                selectedClipIds = [id]
            } else {
                selectedClipIds.removeAll()
            }
        }
    }

    /// Risolve in modo deterministico l'ID della clip video selezionata (o della clip video collegata se è selezionato solo il companion audio).
    public func resolvedVideoClipId(for ids: Set<UUID>? = nil) -> UUID? {
        let targetIds = ids ?? selectedClipIds
        guard !targetIds.isEmpty else { return nil }
        for track in videoTracks {
            if let vClip = track.clips.first(where: { targetIds.contains($0.id) }) {
                return vClip.id
            }
        }
        for track in audioTracks {
            if let aClip = track.clips.first(where: { targetIds.contains($0.id) }) {
                if let lid = aClip.linkGroupId {
                    for vTrack in videoTracks {
                        if let vClip = vTrack.clips.first(where: { $0.linkGroupId == lid }) {
                            return vClip.id
                        }
                    }
                }
                if isSelection {
                    let aStart = CMTimeGetSeconds(aClip.timelineStart)
                    let aEnd = CMTimeGetSeconds(aClip.timelineEnd)
                    for vTrack in videoTracks {
                        if let vClip = vTrack.clips.first(where: {
                            $0.mediaItem.url == aClip.mediaItem.url &&
                            abs(CMTimeGetSeconds($0.timelineStart) - aStart) < 0.025 &&
                            abs(CMTimeGetSeconds($0.timelineEnd) - aEnd) < 0.025
                        }) {
                            return vClip.id
                        }
                    }
                }
            }
        }
        return nil
    }

    public var format: TimelineFormat = .fhdLandscape

    // Pro NLE toggles
    public var isLinkActive: Bool = true                  // Link / Unlink A/V
    public var isSnappingActive: Bool = true              // Magnet / Snapping (Resolve style)
    public var isSelectionFollowsPlayhead: Bool = false   // Seleziona clip sotto la testina (Resolve style)
    public var isRippleTrimMode: Bool = true              // T = Trim senza scarto (Ripple), A = Selezione con scarto (Non-Ripple)
    public var isCageLockActive: Bool = true              // Blocco Cage: aggancia inizio/fine clip alle sbarre (OFF = montaggio libero)
    public var isSelectionSourceConstrained: Bool = true  // Sorgente come Selezione (U): ON = rispetta selectionSourceIn/Out, OFF = intera clip originale
    public var isEmptyGapsHighlighted: Bool = true        // Strumento Ghost: attivo all'avvio per evidenziare in rosso i vuoti video

    public func sourceBounds(for clip: TimelineClip) -> (minSec: Double, maxSec: Double) {
        if isSelectionSourceConstrained {
            return clip.effectiveSourceBounds
        }
        return (0.0, max(0.0, CMTimeGetSeconds(clip.mediaItem.duration)))
    }

    public func isUsingSelectionExtractBounds(for clip: TimelineClip) -> Bool {
        isSelectionSourceConstrained && (clip.selectionSourceIn != nil || clip.selectionSourceOut != nil)
    }

    /// Restituisce gli intervalli `[start, end]` privi di qualsiasi clip video (vuoti video) fino alla fine dell'ultima clip video, ignorando le tracce audio.
    public func emptyTimelineGapIntervals() -> [(start: Double, end: Double)] {
        var intervals: [(start: Double, end: Double)] = []
        intervals.reserveCapacity(64)

        for track in videoTracks {
            for (clip, dStart) in displayedClips(isVideo: true, trackIndex: track.id) {
                let s = max(0.0, CMTimeGetSeconds(dStart))
                let d = CMTimeGetSeconds(clip.duration)
                if d > 0.001 {
                    intervals.append((s, s + d))
                }
            }
        }

        guard !intervals.isEmpty else { return [] }
        intervals.sort { $0.start < $1.start }

        var gaps: [(start: Double, end: Double)] = []
        var cursor: Double = 0.0
        let minGapThreshold: Double = 0.005

        for iv in intervals {
            if iv.start - cursor > minGapThreshold {
                gaps.append((cursor, iv.start))
            }
            if iv.end > cursor {
                cursor = iv.end
            }
        }
        return gaps
    }

    // MARK: - Rhythmic Cages & Beat Grid (Montaggio a Gabbie)
    public var rhythmicCages: [RhythmicCage] = []
    public var detectedBPM: Double? = nil
    public var beatIntervalMode: BeatIntervalMode = .dynamicTransients
    public var peakSensitivity: Double = 0.45
    public var isRhythmicGridVisible: Bool = true
    public var smartFilter = SelectionSmartFilter()
    public var isSmartFilterActive: Bool { isSelection && smartFilter.isActive }
    public var videoTrackHeights: [Int: Double] = [:]
    public var audioTrackHeights: [Int: Double] = [:]
    public var playheadSeconds: Double = 0.0

    public var onModelChanged: (() -> Void)?

    public let maxTracks: Int = 5
    public var maxVideoTracks: Int { isSelection ? 1 : maxTracks }
    public var maxAudioTracks: Int { isSelection ? 1 : maxTracks }

    public init(name: String = "Timeline 1", isSelection: Bool = false) {
        self.name = name
        self.isSelection = isSelection
        self.videoTracks = [
            TimelineTrack(id: 0, name: "V1", mediaType: .video)
        ]
        self.audioTracks = [
            TimelineTrack(id: 0, name: "A1", mediaType: .audio)
        ]
    }

    public var totalDuration: CMTime {
        var maxTime: CMTime = .zero
        for track in videoTracks {
            for clip in track.clips {
                if CMTimeCompare(clip.timelineEnd, maxTime) > 0 {
                    maxTime = clip.timelineEnd
                }
            }
        }
        for track in audioTracks {
            for clip in track.clips {
                if CMTimeCompare(clip.timelineEnd, maxTime) > 0 {
                    maxTime = clip.timelineEnd
                }
            }
        }
        return maxTime
    }

    public func ensureVideoTrack(id: Int) {
        guard id < maxVideoTracks else { return }
        while videoTracks.count <= id && videoTracks.count < maxVideoTracks {
            let nextIndex = videoTracks.count
            videoTracks.append(TimelineTrack(id: nextIndex, name: "V\(nextIndex + 1)", mediaType: .video))
        }
    }

    public func ensureAudioTrack(id: Int) {
        guard id < maxAudioTracks else { return }
        while audioTracks.count <= id && audioTracks.count < maxAudioTracks {
            let nextIndex = audioTracks.count
            audioTracks.append(TimelineTrack(id: nextIndex, name: "A\(nextIndex + 1)", mediaType: .audio))
        }
    }

    // MARK: - Selection Conversion (Max 1 Video + 1 Audio)
    public var canConvertToSelection: (allowed: Bool, reason: String?) {
        if isSelection {
            return (false, "È già una Selezione.")
        }
        let nonEmptyVideoTracks = videoTracks.filter { !$0.clips.isEmpty }
        let nonEmptyAudioTracks = audioTracks.filter { !$0.clips.isEmpty }
        let hasExtraVideo = nonEmptyVideoTracks.count > 1 || (nonEmptyVideoTracks.first?.id ?? 0) > 0
        let hasExtraAudio = nonEmptyAudioTracks.count > 1 || (nonEmptyAudioTracks.first?.id ?? 0) > 0
        if hasExtraVideo || hasExtraAudio || videoTracks.count > 1 || audioTracks.count > 1 {
            // Consentito se le tracce oltre V1/A1 sono vuote (verranno pulite automaticamente)
            if hasExtraVideo || hasExtraAudio {
                return (false, "Una Selezione può avere al massimo una traccia Video (V1) e una traccia Audio (A1).")
            }
        }
        return (true, nil)
    }

    @discardableResult
    public func convertToSelection() -> Bool {
        let check = canConvertToSelection
        guard check.allowed else { return false }
        videoTracks = Array(videoTracks.prefix(1))
        audioTracks = Array(audioTracks.prefix(1))
        if videoTracks.isEmpty {
            videoTracks = [TimelineTrack(id: 0, name: "V1", mediaType: .video)]
        }
        if audioTracks.isEmpty {
            audioTracks = [TimelineTrack(id: 0, name: "A1", mediaType: .audio)]
        }
        isSelection = true
        if isSelection {
            repackSelectionContiguously()
        }
        onModelChanged?()
        return true
    }

    public func convertToTimeline() {
        guard isSelection else { return }
        isSelection = false
        smartFilter = SelectionSmartFilter()
        onModelChanged?()
    }

    // MARK: - Smart Filter (Selezione Compatta V1+A1)
    private struct FilteredSelectionEntry {
        let videoClip: TimelineClip?
        let audioClip: TimelineClip?
        let realStart: CMTime
        let realDuration: CMTime
        let displayStart: CMTime

        var displayEnd: CMTime { CMTimeAdd(displayStart, realDuration) }
        var realEnd: CMTime { CMTimeAdd(realStart, realDuration) }
    }

    private func filteredSelectionEntries() -> [FilteredSelectionEntry] {
        guard isSmartFilterActive else { return [] }
        let vClips = (videoTracks.first?.clips ?? []).sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        let aClips = (audioTracks.first?.clips ?? []).sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        var usedAudioIds: Set<UUID> = []

        func findCompanionAudio(for vClip: TimelineClip) -> TimelineClip? {
            if let lId = vClip.linkGroupId,
               let match = aClips.first(where: { !usedAudioIds.contains($0.id) && $0.linkGroupId == lId }) {
                return match
            }
            let vStart = CMTimeGetSeconds(vClip.timelineStart)
            let vEnd = CMTimeGetSeconds(vClip.timelineEnd)
            return aClips.first { aClip in
                !usedAudioIds.contains(aClip.id)
                    && aClip.mediaItem.url == vClip.mediaItem.url
                    && abs(CMTimeGetSeconds(aClip.timelineStart) - vStart) < 0.025
                    && abs(CMTimeGetSeconds(aClip.timelineEnd) - vEnd) < 0.025
            }
        }

        var rawPairs: [(video: TimelineClip?, audio: TimelineClip?, realStart: CMTime, dur: CMTime)] = []
        for v in vClips {
            let a = findCompanionAudio(for: v)
            if let a = a { usedAudioIds.insert(a.id) }
            let matches = smartFilter.matches(v) || (a.map { smartFilter.matches($0) } ?? false)
            if matches {
                let dur = max(v.duration, a?.duration ?? .zero)
                rawPairs.append((v, a, v.timelineStart, dur))
            }
        }
        for a in aClips where !usedAudioIds.contains(a.id) {
            if smartFilter.matches(a) {
                rawPairs.append((nil, a, a.timelineStart, a.duration))
            }
        }

        rawPairs.sort { CMTimeCompare($0.realStart, $1.realStart) < 0 }

        var cursor: CMTime = .zero
        var result: [FilteredSelectionEntry] = []
        result.reserveCapacity(rawPairs.count)
        for pair in rawPairs {
            result.append(FilteredSelectionEntry(
                videoClip: pair.video,
                audioClip: pair.audio,
                realStart: pair.realStart,
                realDuration: pair.dur,
                displayStart: cursor
            ))
            cursor = CMTimeAdd(cursor, pair.dur)
        }
        return result
    }

    public var displayedTotalDuration: CMTime {
        guard isSmartFilterActive else { return totalDuration }
        return filteredSelectionEntries().last?.displayEnd ?? .zero
    }

    public func displayedClips(isVideo: Bool, trackIndex: Int) -> [(clip: TimelineClip, displayStart: CMTime)] {
        if !isSmartFilterActive {
            let tracks = isVideo ? videoTracks : audioTracks
            guard trackIndex >= 0 && trackIndex < tracks.count else { return [] }
            return tracks[trackIndex].clips.map { ($0, $0.timelineStart) }
        }
        guard trackIndex == 0 else { return [] }
        return filteredSelectionEntries().compactMap { entry in
            if isVideo, let v = entry.videoClip {
                return (v, entry.displayStart)
            } else if !isVideo, let a = entry.audioClip {
                return (a, entry.displayStart)
            }
            return nil
        }
    }

    public func displayedStartTime(for clip: TimelineClip, isVideo: Bool) -> CMTime {
        guard isSmartFilterActive else { return clip.timelineStart }
        for entry in filteredSelectionEntries() {
            if isVideo, entry.videoClip?.id == clip.id { return entry.displayStart }
            if !isVideo, entry.audioClip?.id == clip.id { return entry.displayStart }
        }
        return clip.timelineStart
    }

    public func realTimelineTime(forDisplayedTime displayTime: CMTime) -> CMTime {
        guard isSmartFilterActive else { return displayTime }
        let entries = filteredSelectionEntries()
        guard !entries.isEmpty else { return .zero }
        let sec = CMTimeGetSeconds(displayTime)
        if sec <= 0 { return entries[0].realStart }
        for entry in entries {
            let ds = CMTimeGetSeconds(entry.displayStart)
            let de = CMTimeGetSeconds(entry.displayEnd)
            if sec >= ds && sec < de {
                let offset = CMTimeSubtract(displayTime, entry.displayStart)
                return CMTimeAdd(entry.realStart, offset)
            }
        }
        return entries.last?.realEnd ?? totalDuration
    }

    public func displayedTime(forRealTime realTime: CMTime) -> CMTime {
        guard isSmartFilterActive else { return realTime }
        let entries = filteredSelectionEntries()
        guard !entries.isEmpty else { return .zero }
        let sec = CMTimeGetSeconds(realTime)
        for entry in entries {
            let rs = CMTimeGetSeconds(entry.realStart)
            let re = CMTimeGetSeconds(entry.realEnd)
            if sec >= rs && sec < re {
                let offset = CMTimeSubtract(realTime, entry.realStart)
                return CMTimeAdd(entry.displayStart, offset)
            }
            if sec < rs {
                return entry.displayStart
            }
        }
        return displayedTotalDuration
    }

    public func compactedFilteredModel() -> TimelineModel {
        let copy = TimelineModel(name: name, isSelection: true)
        copy.format = format
        copy.isLinkActive = isLinkActive
        let entries = filteredSelectionEntries()
        for entry in entries {
            if var v = entry.videoClip {
                v.timelineStart = entry.displayStart
                copy.videoTracks[0].clips.append(v)
            }
            if var a = entry.audioClip {
                a.timelineStart = entry.displayStart
                copy.audioTracks[0].clips.append(a)
            }
        }
        return copy
    }

    // MARK: - Track Mute & Lock (Lucchetto)
    public func toggleTrackLock(id: Int, isVideo: Bool) {
        guard !isSelection else { return }
        if isVideo {
            guard id < videoTracks.count else { return }
            videoTracks[id].isLocked.toggle()
            DebugLogger.shared.log("Traccia V\(id + 1) \(videoTracks[id].isLocked ? "BLOCCATA 🔒" : "SBLOCCATA 🔓")", level: .info)
        } else {
            guard id < audioTracks.count else { return }
            audioTracks[id].isLocked.toggle()
            DebugLogger.shared.log("Traccia A\(id + 1) \(audioTracks[id].isLocked ? "BLOCCATA 🔒" : "SBLOCCATA 🔓")", level: .info)
        }
        onModelChanged?()
    }

    public func toggleTrackEnabled(id: Int, isVideo: Bool) {
        if isVideo {
            guard id < videoTracks.count else { return }
            videoTracks[id].isEnabled.toggle()
            DebugLogger.shared.log("Traccia V\(id + 1) \(videoTracks[id].isEnabled ? "ATTIVATA 👁️" : "DISATTIVATA 🚫")", level: .info)
        } else {
            guard id < audioTracks.count else { return }
            audioTracks[id].isEnabled.toggle()
            DebugLogger.shared.log("Traccia A\(id + 1) \(audioTracks[id].isEnabled ? "ATTIVATA 🔊" : "DISATTIVATA 🔇")", level: .info)
        }
        onModelChanged?()
    }

    // MARK: - Selection Follows Playhead (Resolve Style)
    public func updateSelectionAtPlayhead(time: CMTime) {
        guard isSelectionFollowsPlayhead else { return }
        let timeSec = CMTimeGetSeconds(time)

        if isSmartFilterActive {
            var foundClip: TimelineClip? = nil
            for (clip, dStart) in displayedClips(isVideo: true, trackIndex: 0) {
                let s = CMTimeGetSeconds(dStart)
                let e = s + CMTimeGetSeconds(clip.duration)
                if timeSec >= s && timeSec < e {
                    foundClip = clip
                    break
                }
            }
            if foundClip == nil {
                for (clip, dStart) in displayedClips(isVideo: false, trackIndex: 0) {
                    let s = CMTimeGetSeconds(dStart)
                    let e = s + CMTimeGetSeconds(clip.duration)
                    if timeSec >= s && timeSec < e {
                        foundClip = clip
                        break
                    }
                }
            }
            if let clip = foundClip {
                let newSelection = isLinkActive || isSelection ? resolveSelectionCompanionClipIds(for: [clip.id]) : [clip.id]
                if selectedClipIds != newSelection {
                    selectedClipIds = newSelection
                    onModelChanged?()
                }
            }
            return
        }

        // Prioritize highest unmuted, unlocked video track
        var foundClip: TimelineClip? = nil
        for track in videoTracks.reversed() where !track.isLocked && track.isEnabled {
            if let clip = track.clips.first(where: {
                let s = CMTimeGetSeconds($0.timelineStart)
                let e = CMTimeGetSeconds($0.timelineEnd)
                return timeSec >= s && timeSec < e
            }) {
                foundClip = clip
                break
            }
        }

        // If no video clip, search audio tracks
        if foundClip == nil {
            for track in audioTracks where !track.isLocked && track.isEnabled {
                if let clip = track.clips.first(where: {
                    let s = CMTimeGetSeconds($0.timelineStart)
                    let e = CMTimeGetSeconds($0.timelineEnd)
                    return timeSec >= s && timeSec < e
                }) {
                    foundClip = clip
                    break
                }
            }
        }

        if let clip = foundClip {
            var newSelection: Set<UUID> = [clip.id]
            if isLinkActive, let linkId = clip.linkGroupId {
                for track in audioTracks where !track.isLocked {
                    for aClip in track.clips where aClip.linkGroupId == linkId {
                        newSelection.insert(aClip.id)
                    }
                }
                for track in videoTracks where !track.isLocked {
                    for vClip in track.clips where vClip.linkGroupId == linkId {
                        newSelection.insert(vClip.id)
                    }
                }
            }
            if selectedClipIds != newSelection {
                selectedClipIds = newSelection
                onModelChanged?()
            }
        }
    }

    // MARK: - Storyboard Grid Reordering
    public func linkedSelectionIds(for initialIds: Set<UUID>) -> Set<UUID> {
        guard !initialIds.isEmpty else { return [] }
        if isSelection {
            return resolveSelectionCompanionClipIds(for: initialIds)
        }
        return expandLinkedClipIds(initialIds)
    }

    /// Selettore clip avanti (+1) o indietro (-1): seleziona la clip successiva o precedente (con audio linkato).
    @discardableResult
    public func selectAdjacentClip(direction: Int, fromPlayhead time: CMTime) -> (clip: TimelineClip, displayStart: CMTime)? {
        guard direction != 0 else { return nil }
        let orderedPairs: [(clip: TimelineClip, displayStart: CMTime)] = {
            if isSmartFilterActive {
                return displayedClips(isVideo: true, trackIndex: 0)
            }
            var allClips: [TimelineClip] = []
            for track in videoTracks where track.isEnabled {
                allClips.append(contentsOf: track.clips)
            }
            if allClips.isEmpty {
                for track in audioTracks where track.isEnabled {
                    allClips.append(contentsOf: track.clips)
                }
            }
            allClips.sort {
                let cmp = CMTimeCompare($0.timelineStart, $1.timelineStart)
                if cmp != 0 { return cmp < 0 }
                return $0.trackIndex < $1.trackIndex
            }
            return allClips.map { ($0, $0.timelineStart) }
        }()
        guard !orderedPairs.isEmpty else { return nil }

        let playheadSec = CMTimeGetSeconds(time)
        let currentRefId = resolvedVideoClipId() ?? selectedClipId

        let targetIdx: Int
        if let refId = currentRefId,
           let curIdx = orderedPairs.firstIndex(where: { $0.clip.id == refId }) {
            targetIdx = max(0, min(orderedPairs.count - 1, curIdx + (direction > 0 ? 1 : -1)))
        } else if direction > 0 {
            if let underIdx = orderedPairs.firstIndex(where: {
                let s = CMTimeGetSeconds($0.displayStart)
                let e = s + CMTimeGetSeconds($0.clip.duration)
                return playheadSec >= s - 0.005 && playheadSec < e - 0.005
            }) {
                targetIdx = min(orderedPairs.count - 1, underIdx + 1)
            } else {
                targetIdx = orderedPairs.firstIndex(where: { CMTimeGetSeconds($0.displayStart) > playheadSec + 0.005 }) ?? 0
            }
        } else {
            if let underIdx = orderedPairs.firstIndex(where: {
                let s = CMTimeGetSeconds($0.displayStart)
                let e = s + CMTimeGetSeconds($0.clip.duration)
                return playheadSec > s + 0.005 && playheadSec <= e + 0.005
            }) {
                targetIdx = max(0, underIdx)
            } else {
                targetIdx = orderedPairs.lastIndex(where: { CMTimeGetSeconds($0.displayStart) < playheadSec - 0.005 }) ?? (orderedPairs.count - 1)
            }
        }

        let target = orderedPairs[targetIdx]
        selectedClipIds = linkedSelectionIds(for: [target.clip.id])
        return target
    }

    /// Punti focali cronologici (secondi): 0, confini gabbie, intersezioni (inizio/fine clip video+audio), marcatori manuali e beat marker.
    public func timelineFocalPoints(excludingClipIds: Set<UUID> = []) -> [Double] {
        var pts: [Double] = [0.0]
        pts.append(contentsOf: activeCageBoundaries())
        for track in videoTracks where track.isEnabled {
            for (clip, dStart) in displayedClips(isVideo: true, trackIndex: track.id) {
                guard !excludingClipIds.contains(clip.id) else { continue }
                let s = max(0.0, CMTimeGetSeconds(dStart))
                let e = s + max(0.0, CMTimeGetSeconds(clip.duration))
                pts.append(s)
                pts.append(e)
                let spd = clip.speed > 0 ? clip.speed : 1.0
                let srcIn = CMTimeGetSeconds(clip.sourceIn)
                let srcOut = CMTimeGetSeconds(clip.sourceOut)
                for m in clip.markers where m >= srcIn - 0.005 && m <= srcOut + 0.005 {
                    pts.append(s + (m - srcIn) / spd)
                }
            }
        }
        for track in audioTracks where track.isEnabled {
            for (clip, dStart) in displayedClips(isVideo: false, trackIndex: track.id) {
                guard !excludingClipIds.contains(clip.id) else { continue }
                let s = max(0.0, CMTimeGetSeconds(dStart))
                let e = s + max(0.0, CMTimeGetSeconds(clip.duration))
                pts.append(s)
                pts.append(e)
                let spd = clip.speed > 0 ? clip.speed : 1.0
                let srcIn = CMTimeGetSeconds(clip.sourceIn)
                let srcOut = CMTimeGetSeconds(clip.sourceOut)
                for m in clip.markers + clip.beatMarkers where m >= srcIn - 0.005 && m <= srcOut + 0.005 {
                    pts.append(s + (m - srcIn) / spd)
                }
            }
        }
        pts.sort()
        var deduped: [Double] = []
        for p in pts where p >= 0.0 {
            if let last = deduped.last {
                if p - last > 0.003 { deduped.append(p) }
            } else {
                deduped.append(p)
            }
        }
        return deduped
    }

    public func adjacentFocalPoint(direction: Int, fromTime time: CMTime) -> CMTime? {
        let pts = timelineFocalPoints()
        guard !pts.isEmpty else { return nil }
        let cur = CMTimeGetSeconds(time)
        if direction < 0 {
            guard let prev = pts.last(where: { $0 < cur - 0.004 }) else { return nil }
            return CMTime(seconds: prev, preferredTimescale: 600)
        } else {
            guard let next = pts.first(where: { $0 > cur + 0.004 }) else { return nil }
            return CMTime(seconds: next, preferredTimescale: 600)
        }
    }

    public func canDropGridReorder(movingClipIds: Set<UUID>, toSlot slot: Int, trackIndex: Int) -> Bool {
        guard trackIndex >= 0, trackIndex < videoTracks.count, !videoTracks[trackIndex].isLocked else { return false }
        let clips = videoTracks[trackIndex].clips
        guard !clips.isEmpty else { return false }

        let moving = clips.filter { movingClipIds.contains($0.id) }
        guard !moving.isEmpty else { return false }
        if moving.contains(where: { $0.isEffectivelyLocked }) {
            return false
        }

        let clampedSlot = max(0, min(clips.count, slot))
        // Non inserire direttamente dentro un blocco di clip bloccate/approvate
        if let firstUnlocked = clips.firstIndex(where: { !$0.isEffectivelyLocked }), clampedSlot < firstUnlocked {
            return false
        }

        let activeCages = activeCageIntervals()
        if isCageLockActive && !isSelection && !activeCages.isEmpty {
            return true
        }

        // In modalità libera, ogni fascia delimitata da clip bloccate/approvate mantiene le clip bloccate ferme nel tempo
        let lockedClips = clips.filter { $0.isEffectivelyLocked }
        if lockedClips.isEmpty { return true }

        // Simula l'inserimento nel array completo lasciando le clip bloccate al loro posto: controlla che le somme prima di ogni lock non sforino
        return simulateFreeGridReorder(movingClipIds: movingClipIds, toSlot: clampedSlot, clips: clips) != nil
    }

    private func simulateFreeGridReorder(movingClipIds: Set<UUID>, toSlot slot: Int, clips: [TimelineClip]) -> [TimelineClip]? {
        // Verifica per ogni gruppo di clip bloccate che le clip sbloccate spostate davanti a una clip bloccata ci stiano entro il suo timelineStart
        var movingClips: [TimelineClip] = []
        var baseClips: [TimelineClip] = []
        var removedBefore = 0
        for (idx, c) in clips.enumerated() {
            if movingClipIds.contains(c.id) {
                guard !c.isEffectivelyLocked else { return nil }
                movingClips.append(c)
                if idx < slot { removedBefore += 1 }
            } else {
                baseClips.append(c)
            }
        }
        guard !movingClips.isEmpty else { return nil }
        let insertAt = max(0, min(baseClips.count, slot - removedBefore))
        baseClips.insert(contentsOf: movingClips, at: insertAt)

        // Ricostruisci posizioni temporali mantenendo ogni clip isEffectivelyLocked fissa al suo timelineStart originale
        var result = baseClips
        var cursor: CMTime = .zero
        for i in 0..<result.count {
            if result[i].isEffectivelyLocked {
                if CMTimeCompare(cursor, result[i].timelineStart) > 0 {
                    let overlapSec = CMTimeGetSeconds(CMTimeSubtract(cursor, result[i].timelineStart))
                    if overlapSec > 0.01 {
                        return nil
                    }
                }
                cursor = result[i].timelineEnd
            } else {
                result[i].timelineStart = cursor
                cursor = CMTimeAdd(cursor, result[i].duration)
            }
        }
        return result
    }

    private func syncCompanionAudioAfterGridReorder(oldClipsById: [UUID: TimelineClip], newClips: [TimelineClip]) {
        for newClip in newClips {
            guard let oldClip = oldClipsById[newClip.id] else { continue }
            let deltaSec = CMTimeGetSeconds(newClip.timelineStart) - CMTimeGetSeconds(oldClip.timelineStart)
            let durChanged = abs(CMTimeGetSeconds(newClip.duration) - CMTimeGetSeconds(oldClip.duration)) > 0.002
            guard abs(deltaSec) > 0.0005 || durChanged || newClip.cageIndex != oldClip.cageIndex || newClip.span != oldClip.span else { continue }

            if isSelection {
                let paired = resolveSelectionCompanionClipIds(for: [newClip.id])
                for aTrackIdx in 0..<audioTracks.count where !audioTracks[aTrackIdx].isLocked {
                    for aIdx in 0..<audioTracks[aTrackIdx].clips.count {
                        let ac = audioTracks[aTrackIdx].clips[aIdx]
                        if paired.contains(ac.id) && ac.id != newClip.id && !ac.isEffectivelyLocked {
                            audioTracks[aTrackIdx].clips[aIdx].timelineStart = newClip.timelineStart
                        }
                    }
                    audioTracks[aTrackIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                }
            } else if isLinkActive, let lId = newClip.linkGroupId {
                for aTrackIdx in 0..<audioTracks.count where !audioTracks[aTrackIdx].isLocked {
                    if let aIdx = audioTracks[aTrackIdx].clips.firstIndex(where: { $0.linkGroupId == lId && !$0.isEffectivelyLocked }) {
                        if durChanged {
                            let spd = audioTracks[aTrackIdx].clips[aIdx].speed > 0 ? audioTracks[aTrackIdx].clips[aIdx].speed : 1.0
                            audioTracks[aTrackIdx].clips[aIdx].timelineStart = newClip.timelineStart
                            audioTracks[aTrackIdx].clips[aIdx].sourceIn = newClip.sourceIn
                            audioTracks[aTrackIdx].clips[aIdx].sourceOut = CMTimeAdd(newClip.sourceIn, CMTime(seconds: CMTimeGetSeconds(newClip.duration) * spd, preferredTimescale: 600))
                            audioTracks[aTrackIdx].clips[aIdx].cageIndex = newClip.cageIndex
                            audioTracks[aTrackIdx].clips[aIdx].span = newClip.span
                        } else {
                            let aOldStart = audioTracks[aTrackIdx].clips[aIdx].timelineStart
                            audioTracks[aTrackIdx].clips[aIdx].timelineStart = max(.zero, CMTime(seconds: CMTimeGetSeconds(aOldStart) + deltaSec, preferredTimescale: 600))
                            audioTracks[aTrackIdx].clips[aIdx].cageIndex = newClip.cageIndex
                            audioTracks[aTrackIdx].clips[aIdx].span = newClip.span
                        }
                        audioTracks[aTrackIdx].clips.sort(by: { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 })
                    }
                }
            }
        }
    }

    private func applyCageOrderedSequence(unlockedClips: [TimelineClip], trackIndex: Int, activeCages: [RhythmicCage]) -> Bool {
        let lockedClips = videoTracks[trackIndex].clips.filter { $0.isEffectivelyLocked }
        let firstUnlockedCage = unlockedClips.compactMap { resolvedCageIndex(for: $0, in: activeCages) }.min() ?? 0
        let freeCages = activeCages.filter { $0.index >= firstUnlockedCage && !isCageOccupied($0, by: lockedClips) }
        guard !freeCages.isEmpty else { return false }

        var resultUnlocked = unlockedClips
        var freeCursor = 0
        for i in 0..<resultUnlocked.count {
            var clip = resultUnlocked[i]
            let spanCount = max(1, clip.span)
            guard freeCursor < freeCages.count else { break }

            var startFreeIdx = freeCursor
            if spanCount > 1 {
                while startFreeIdx + spanCount <= freeCages.count {
                    let firstRealIdx = freeCages[startFreeIdx].index
                    let lastRealIdx = freeCages[startFreeIdx + spanCount - 1].index
                    if lastRealIdx - firstRealIdx == spanCount - 1 {
                        break
                    }
                    startFreeIdx += 1
                }
            }

            let startCage: RhythmicCage
            let actualSpan: Int
            let combinedDur: Double
            if startFreeIdx + spanCount <= freeCages.count && freeCages[startFreeIdx + spanCount - 1].index - freeCages[startFreeIdx].index == spanCount - 1 {
                startCage = freeCages[startFreeIdx]
                actualSpan = spanCount
                combinedDur = freeCages[startFreeIdx + spanCount - 1].endSeconds - startCage.startSeconds
            } else {
                startFreeIdx = freeCursor
                startCage = freeCages[startFreeIdx]
                actualSpan = 1
                combinedDur = startCage.durationSeconds
            }

            let spd = clip.speed > 0 ? clip.speed : 1.0
            let neededSource = combinedDur * spd
            let bounds = sourceBounds(for: clip)
            var newSrcIn = max(bounds.minSec, min(CMTimeGetSeconds(clip.sourceIn), bounds.maxSec))
            var newSrcOut = newSrcIn + neededSource
            if newSrcOut > bounds.maxSec {
                newSrcOut = bounds.maxSec
                newSrcIn = max(bounds.minSec, newSrcOut - neededSource)
            }

            clip.cageIndex = startCage.index
            clip.span = actualSpan
            clip.timelineStart = startCage.startTime
            clip.sourceIn = CMTime(seconds: newSrcIn, preferredTimescale: 600)
            clip.sourceOut = CMTime(seconds: newSrcOut, preferredTimescale: 600)
            resultUnlocked[i] = clip
            syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: spd, cageIndex: clip.cageIndex, span: actualSpan)
            freeCursor = startFreeIdx + actualSpan
        }

        videoTracks[trackIndex].clips = (lockedClips + resultUnlocked).sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        audioTracks.indices.forEach { aIdx in
            audioTracks[aIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        }
        return true
    }

    public func reorderClips(trackIndex: Int, isVideo: Bool, fromIndex: Int, toIndex: Int) {
        guard trackIndex >= 0 else { return }
        if isVideo {
            guard trackIndex < videoTracks.count, !videoTracks[trackIndex].isLocked else { return }
            let clips = videoTracks[trackIndex].clips
            guard fromIndex >= 0 && fromIndex < clips.count else { return }
            let clampedTo = max(0, min(clips.count - 1, toIndex))
            guard fromIndex != clampedTo else { return }

            let movingClip = clips[fromIndex]
            guard !movingClip.isEffectivelyLocked else {
                DebugLogger.shared.log("Clip bloccata o approvata 🔒: impossibile spostarla.", level: .warning)
                return
            }

            let targetSlot = clampedTo > fromIndex ? clampedTo + 1 : clampedTo
            let activeCages = activeCageIntervals()
            if isCageLockActive && !isSelection && !activeCages.isEmpty {
                if let targetCage = resolvedCageIndex(for: clips[clampedTo], in: activeCages),
                   reorderClipInCages(clipId: movingClip.id, toCageIndex: targetCage) {
                    return
                }
                // Fallback su sequenza gabbie libere
                var unlocked = clips.filter { !$0.isEffectivelyLocked }
                if let uFrom = unlocked.firstIndex(where: { $0.id == movingClip.id }) {
                    let targetClip = clips[clampedTo]
                    let uTo = unlocked.firstIndex(where: { $0.id == targetClip.id }) ?? (clampedTo > fromIndex ? unlocked.count - 1 : 0)
                    let item = unlocked.remove(at: uFrom)
                    unlocked.insert(item, at: max(0, min(unlocked.count, uTo)))
                    if applyCageOrderedSequence(unlockedClips: unlocked, trackIndex: trackIndex, activeCages: activeCages) {
                        onModelChanged?()
                        return
                    }
                }
                return
            }

            guard let reordered = simulateFreeGridReorder(movingClipIds: [movingClip.id], toSlot: targetSlot, clips: clips) else {
                DebugLogger.shared.log("Spostamento bloccato: presente una clip bloccata o approvata 🔒 che impedisce il riordino.", level: .warning)
                return
            }
            let oldById = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
            videoTracks[trackIndex].clips = reordered
            syncCompanionAudioAfterGridReorder(oldClipsById: oldById, newClips: reordered)
            if isSelection {
                repackSelectionContiguously()
            }
        } else {
            guard trackIndex < audioTracks.count, !audioTracks[trackIndex].isLocked else { return }
            var clips = audioTracks[trackIndex].clips
            guard fromIndex >= 0 && fromIndex < clips.count else { return }
            let clampedTo = max(0, min(clips.count - 1, toIndex))
            guard fromIndex != clampedTo, !clips[fromIndex].isEffectivelyLocked else { return }

            let moved = clips.remove(at: fromIndex)
            clips.insert(moved, at: clampedTo)

            var currentT: CMTime = .zero
            for i in 0..<clips.count {
                let oldStart = clips[i].timelineStart
                let newStart = currentT
                let deltaSec = CMTimeGetSeconds(newStart) - CMTimeGetSeconds(oldStart)
                clips[i].timelineStart = newStart
                currentT = CMTimeAdd(currentT, clips[i].duration)

                if isLinkActive, let lId = clips[i].linkGroupId {
                    for vTrackIdx in 0..<videoTracks.count where !videoTracks[vTrackIdx].isLocked {
                        if let vIdx = videoTracks[vTrackIdx].clips.firstIndex(where: { $0.linkGroupId == lId && !$0.isEffectivelyLocked }) {
                            let vOldStart = videoTracks[vTrackIdx].clips[vIdx].timelineStart
                            let vNewStart = max(.zero, CMTime(seconds: CMTimeGetSeconds(vOldStart) + deltaSec, preferredTimescale: 600))
                            videoTracks[vTrackIdx].clips[vIdx].timelineStart = vNewStart
                            videoTracks[vTrackIdx].clips.sort(by: { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 })
                        }
                    }
                }
            }
            audioTracks[trackIndex].clips = clips
        }

        onModelChanged?()
        DebugLogger.shared.log("Clip riordinate sulla traccia \(isVideo ? "V\(trackIndex + 1)" : "A\(trackIndex + 1)"): spostata da #\(fromIndex + 1) a #\(toIndex + 1)", level: .info)
    }

    /// Reorders a group of selected clips sequentially on `trackIndex` to insertion `slot` (`0...clips.count`).
    @discardableResult
    public func reorderClipGroup(clipIds: Set<UUID>, trackIndex: Int, isVideo: Bool, toSlot slot: Int) -> Bool {
        guard trackIndex >= 0, !clipIds.isEmpty else { return false }
        if isVideo {
            guard trackIndex < videoTracks.count, !videoTracks[trackIndex].isLocked else { return false }
            let clips = videoTracks[trackIndex].clips
            guard !clips.isEmpty else { return false }

            let clampedSlot = max(0, min(clips.count, slot))
            let activeCages = activeCageIntervals()
            if isCageLockActive && !isSelection && !activeCages.isEmpty {
                let moving = clips.filter { clipIds.contains($0.id) }
                guard !moving.isEmpty, !moving.contains(where: { $0.isEffectivelyLocked }) else {
                    DebugLogger.shared.log("Gruppo bloccato 🔒: deseleziona le clip bloccate o approvate prima di riordinare.", level: .warning)
                    return false
                }
                if let firstUnlocked = clips.firstIndex(where: { !$0.isEffectivelyLocked }), clampedSlot < firstUnlocked {
                    return false
                }
                var movingUnlocked: [TimelineClip] = []
                var remainingUnlocked: [TimelineClip] = []
                var unlockedBeforeSlot = 0
                for (idx, c) in clips.enumerated() where !c.isEffectivelyLocked {
                    if clipIds.contains(c.id) {
                        movingUnlocked.append(c)
                    } else {
                        remainingUnlocked.append(c)
                        if idx < clampedSlot { unlockedBeforeSlot += 1 }
                    }
                }
                guard !movingUnlocked.isEmpty else { return false }
                let oldUnlockedOrder = clips.filter { !$0.isEffectivelyLocked }.map(\.id)
                let insertIdx = max(0, min(remainingUnlocked.count, unlockedBeforeSlot))
                remainingUnlocked.insert(contentsOf: movingUnlocked, at: insertIdx)
                guard remainingUnlocked.map(\.id) != oldUnlockedOrder else { return false }
                if applyCageOrderedSequence(unlockedClips: remainingUnlocked, trackIndex: trackIndex, activeCages: activeCages) {
                    onModelChanged?()
                    return true
                }
                return false
            }

            guard let reordered = simulateFreeGridReorder(movingClipIds: clipIds, toSlot: clampedSlot, clips: clips) else {
                DebugLogger.shared.log("Spostamento bloccato: presente una clip bloccata o approvata 🔒.", level: .warning)
                return false
            }
            guard reordered.map(\.id) != clips.map(\.id) else { return false }
            let oldById = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
            videoTracks[trackIndex].clips = reordered
            syncCompanionAudioAfterGridReorder(oldClipsById: oldById, newClips: reordered)
            if isSelection {
                repackSelectionContiguously()
            }
            onModelChanged?()
            return true
        }
        return false
    }

    /// Inserts media items sequentially at storyboard slot `slot` on `trackIndex`, shifting subsequent clips forward cleanly.
    @discardableResult
    public func insertMediaItemsSequentially(_ items: [MediaItem], atSlot slot: Int, trackIndex: Int = 0) -> Bool {
        guard !items.isEmpty, trackIndex >= 0, trackIndex < videoTracks.count, !videoTracks[trackIndex].isLocked else {
            return false
        }
        var clips = videoTracks[trackIndex].clips
        let clampedSlot = max(0, min(clips.count, slot))
        let insertStart: CMTime = clampedSlot == 0
            ? .zero
            : CMTimeAdd(clips[clampedSlot - 1].timelineStart, clips[clampedSlot - 1].duration)

        var newVideoClips: [TimelineClip] = []
        var newAudioClips: [TimelineClip] = []
        var cursor = insertStart
        var totalAddedDur: CMTime = .zero

        for item in items {
            let linkId = (item.hasVideo && item.hasAudio && isLinkActive) ? UUID() : nil
            if item.hasVideo {
                let vClip = TimelineClip(
                    mediaItem: item,
                    sourceIn: .zero,
                    sourceOut: item.duration,
                    timelineStart: cursor,
                    trackIndex: trackIndex,
                    mediaType: .video,
                    orientation: item.orientation,
                    linkGroupId: linkId
                )
                newVideoClips.append(vClip)
            }
            if item.hasAudio && (isLinkActive || !item.hasVideo) {
                let aTrack = min(trackIndex, max(0, audioTracks.count - 1))
                if aTrack < audioTracks.count && !audioTracks[aTrack].isLocked {
                    let aClip = TimelineClip(
                        mediaItem: item,
                        sourceIn: .zero,
                        sourceOut: item.duration,
                        timelineStart: cursor,
                        trackIndex: aTrack,
                        mediaType: .audio,
                        orientation: .normal,
                        linkGroupId: linkId
                    )
                    newAudioClips.append(aClip)
                }
            }
            cursor = CMTimeAdd(cursor, item.duration)
            totalAddedDur = CMTimeAdd(totalAddedDur, item.duration)
        }

        guard !newVideoClips.isEmpty || !newAudioClips.isEmpty else { return false }

        // Shift subsequent clips forward by totalAddedDur
        if clampedSlot < clips.count && !newVideoClips.isEmpty {
            let shiftDelta = CMTimeGetSeconds(totalAddedDur)
            for i in clampedSlot..<clips.count {
                let oldStart = clips[i].timelineStart
                clips[i].timelineStart = CMTimeAdd(oldStart, totalAddedDur)
                if isLinkActive, let lId = clips[i].linkGroupId {
                    for aTrackIdx in 0..<audioTracks.count where !audioTracks[aTrackIdx].isLocked {
                        if let aIdx = audioTracks[aTrackIdx].clips.firstIndex(where: { $0.linkGroupId == lId }) {
                            audioTracks[aTrackIdx].clips[aIdx].timelineStart = CMTimeAdd(
                                audioTracks[aTrackIdx].clips[aIdx].timelineStart,
                                CMTime(seconds: shiftDelta, preferredTimescale: 600)
                            )
                        }
                    }
                }
            }
        }

        if !newVideoClips.isEmpty {
            clips.insert(contentsOf: newVideoClips, at: clampedSlot)
            videoTracks[trackIndex].clips = clips
        }
        for aClip in newAudioClips {
            overwriteAndInsert(incoming: aClip, trackIndex: aClip.trackIndex, isVideo: false)
        }
        if !newAudioClips.isEmpty && newAudioClips[0].trackIndex < audioTracks.count {
            audioTracks[newAudioClips[0].trackIndex].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        }
        selectedClipIds = Set(newVideoClips.map(\.id) + newAudioClips.map(\.id))
        onModelChanged?()
        return true
    }

    // MARK: - Copy / Cut / Paste across Timelines & Selezioni

    @discardableResult
    public func copySelectedClips(atPlayhead playhead: CMTime) -> Int {
        var collected: [TimelineClip] = []
        var seenIds: Set<UUID> = []

        func collect(_ clip: TimelineClip) {
            if seenIds.insert(clip.id).inserted {
                collected.append(clip)
            }
        }

        if !selectedClipIds.isEmpty {
            for track in videoTracks {
                for clip in track.clips where selectedClipIds.contains(clip.id) {
                    collect(clip)
                }
            }
            for track in audioTracks {
                for clip in track.clips where selectedClipIds.contains(clip.id) {
                    collect(clip)
                }
            }
        } else {
            // Fallback to clip(s) under playhead
            for track in videoTracks {
                for clip in track.clips where CMTimeCompare(playhead, clip.timelineStart) >= 0 && CMTimeCompare(playhead, clip.timelineEnd) < 0 {
                    collect(clip)
                }
            }
            if collected.isEmpty {
                for track in audioTracks {
                    for clip in track.clips where CMTimeCompare(playhead, clip.timelineStart) >= 0 && CMTimeCompare(playhead, clip.timelineEnd) < 0 {
                        collect(clip)
                    }
                }
            }
        }

        // Also pull linked audio/video partners when in Selezione or Link mode
        if isSelection || isLinkActive {
            let linkIds = Set(collected.compactMap(\.linkGroupId))
            if !linkIds.isEmpty {
                for track in videoTracks {
                    for clip in track.clips where clip.linkGroupId != nil && linkIds.contains(clip.linkGroupId!) {
                        collect(clip)
                    }
                }
                for track in audioTracks {
                    for clip in track.clips where clip.linkGroupId != nil && linkIds.contains(clip.linkGroupId!) {
                        collect(clip)
                    }
                }
            }
        }

        guard !collected.isEmpty else { return 0 }
        let minStart = collected.map(\.timelineStart).min(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero

        VisionTimelineClipboard.shared.entries = collected.map { clip in
            let effSelIn = clip.selectionSourceIn ?? (isSelection ? CMTimeGetSeconds(clip.sourceIn) : nil)
            let effSelOut = clip.selectionSourceOut ?? (isSelection ? CMTimeGetSeconds(clip.sourceOut) : nil)
            return ClipboardClipEntry(
                mediaItem: clip.mediaItem,
                sourceIn: clip.sourceIn,
                sourceOut: clip.sourceOut,
                relativeStart: max(.zero, CMTimeSubtract(clip.timelineStart, minStart)),
                trackIndex: clip.trackIndex,
                isVideo: clip.mediaType == .video,
                orientation: clip.orientation,
                linkGroupId: clip.linkGroupId,
                speed: clip.speed,
                span: clip.span,
                beatMarkers: clip.beatMarkers,
                beatBPM: clip.beatBPM,
                markers: clip.markers,
                priority: clip.priority,
                selectionSourceIn: effSelIn,
                selectionSourceOut: effSelOut,
                colorTag: clip.colorTag
            )
        }
        return collected.count
    }

    @discardableResult
    public func pasteClipboardClips(at targetTime: CMTime) -> (pastedCount: Int, endTime: CMTime) {
        let entries = VisionTimelineClipboard.shared.entries
        guard !entries.isEmpty else { return (0, targetTime) }

        var baseTime = max(.zero, targetTime)
        if isSelection {
            let vEnd = videoTracks.first?.clips.map(\.timelineEnd).max(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero
            let aEnd = audioTracks.first?.clips.map(\.timelineEnd).max(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero
            let currentEnd = max(vEnd, aEnd)
            if CMTimeCompare(baseTime, currentEnd) > 0 {
                baseTime = currentEnd
            }
        }
        var linkMap: [UUID: UUID] = [:]
        var pastedIds: Set<UUID> = []
        var maxEnd = baseTime

        for entry in entries {
            let newLinkId: UUID? = entry.linkGroupId.map { oldId in
                if let mapped = linkMap[oldId] { return mapped }
                let fresh = UUID()
                linkMap[oldId] = fresh
                return fresh
            }

            let destTrackIdx = isSelection ? 0 : min(entry.trackIndex, (entry.isVideo ? maxVideoTracks : maxAudioTracks) - 1)
            if entry.isVideo {
                ensureVideoTrack(id: destTrackIdx)
                guard !videoTracks[destTrackIdx].isLocked else { continue }
            } else {
                ensureAudioTrack(id: destTrackIdx)
                guard !audioTracks[destTrackIdx].isLocked else { continue }
            }

            let destStart = CMTimeAdd(baseTime, entry.relativeStart)
            let dur = CMTime(seconds: CMTimeGetSeconds(CMTimeSubtract(entry.sourceOut, entry.sourceIn)) / max(0.05, entry.speed), preferredTimescale: 600)
            let destEnd = CMTimeAdd(destStart, dur)
            guard !hasLockedClipOverlap(start: destStart, end: destEnd, trackIndex: destTrackIdx, isVideo: entry.isVideo) else {
                continue
            }

            let newClip = TimelineClip(
                id: UUID(),
                mediaItem: entry.mediaItem,
                sourceIn: entry.sourceIn,
                sourceOut: entry.sourceOut,
                timelineStart: destStart,
                trackIndex: destTrackIdx,
                mediaType: entry.isVideo ? .video : .audio,
                orientation: entry.orientation,
                linkGroupId: newLinkId,
                speed: entry.speed,
                span: entry.span,
                beatMarkers: entry.beatMarkers,
                beatBPM: entry.beatBPM,
                markers: entry.markers,
                priority: entry.priority,
                selectionSourceIn: entry.selectionSourceIn,
                selectionSourceOut: entry.selectionSourceOut,
                colorTag: entry.colorTag
            )
            overwriteAndInsert(incoming: newClip, trackIndex: destTrackIdx, isVideo: entry.isVideo)
            pastedIds.insert(newClip.id)
            if CMTimeCompare(destEnd, maxEnd) > 0 {
                maxEnd = destEnd
            }
        }

        if !pastedIds.isEmpty {
            selectedClipIds = pastedIds
            onModelChanged?()
        }
        return (pastedIds.count, maxEnd)
    }

    // MARK: - Overwrite Editing Core Engine
    /// Returns true if placing `[start, end)` on the specified track would hit a locked track or overlap any locked clip (excluding `excludingClipIds`).
    public func hasLockedClipOverlap(
        start: CMTime,
        end: CMTime,
        trackIndex: Int,
        isVideo: Bool,
        excludingClipIds: Set<UUID> = []
    ) -> Bool {
        let s = CMTimeGetSeconds(start)
        let e = CMTimeGetSeconds(end)
        guard e > s + 0.001 else { return false }

        let tracks = isVideo ? videoTracks : audioTracks
        guard trackIndex >= 0 && trackIndex < tracks.count else { return false }
        let track = tracks[trackIndex]
        if track.isLocked { return true }

        return track.clips.contains { clip in
            guard clip.isEffectivelyLocked && !excludingClipIds.contains(clip.id) else { return false }
            let cs = CMTimeGetSeconds(clip.timelineStart)
            let ce = CMTimeGetSeconds(clip.timelineEnd)
            return max(cs, s) < min(ce, e) - 0.001
        }
    }

    /// Resolves a start time near `proposedStart` on `trackIndex` that avoids overlapping any locked clips.
    /// Returns `nil` if the track is locked or no nearby non-overlapping position is valid.
    public func resolveNonLockedStartTime(
        proposedStart: CMTime,
        duration: CMTime,
        trackIndex: Int,
        isVideo: Bool,
        excludingClipIds: Set<UUID> = []
    ) -> CMTime? {
        let dur = CMTimeGetSeconds(duration)
        let baseStart = max(0.0, CMTimeGetSeconds(proposedStart))
        let baseCM = CMTime(seconds: baseStart, preferredTimescale: 600)
        let baseEndCM = CMTimeAdd(baseCM, duration)

        if !hasLockedClipOverlap(start: baseCM, end: baseEndCM, trackIndex: trackIndex, isVideo: isVideo, excludingClipIds: excludingClipIds) {
            return baseCM
        }

        let tracks = isVideo ? videoTracks : audioTracks
        guard trackIndex >= 0 && trackIndex < tracks.count else { return baseCM }
        let track = tracks[trackIndex]
        if track.isLocked { return nil }

        let lockedClips = track.clips
            .filter { $0.isEffectivelyLocked && !excludingClipIds.contains($0.id) }
            .sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }

        var candidates: [Double] = []
        for lc in lockedClips {
            let cs = CMTimeGetSeconds(lc.timelineStart)
            let ce = CMTimeGetSeconds(lc.timelineEnd)
            if max(cs, baseStart) < min(ce, baseStart + dur) - 0.001 {
                let leftCandidate = cs - dur
                if leftCandidate >= 0.0 {
                    candidates.append(leftCandidate)
                }
                candidates.append(ce)
            }
        }

        let validCandidates = candidates.compactMap { candSec -> CMTime? in
            let candCM = CMTime(seconds: candSec, preferredTimescale: 600)
            let candEndCM = CMTimeAdd(candCM, duration)
            guard !hasLockedClipOverlap(start: candCM, end: candEndCM, trackIndex: trackIndex, isVideo: isVideo, excludingClipIds: excludingClipIds) else {
                return nil
            }
            return candCM
        }

        return validCandidates.min { abs(CMTimeGetSeconds($0) - baseStart) < abs(CMTimeGetSeconds($1) - baseStart) }
    }

    public func overwriteAndInsert(incoming: TimelineClip, trackIndex: Int, isVideo: Bool) {
        if isVideo {
            ensureVideoTrack(id: trackIndex)
            guard !videoTracks[trackIndex].isLocked else { return }
            var currentClips = videoTracks[trackIndex].clips
            currentClips = performOverwriteAlgorithm(existing: currentClips, incoming: incoming)
            videoTracks[trackIndex].clips = currentClips
        } else {
            ensureAudioTrack(id: trackIndex)
            guard !audioTracks[trackIndex].isLocked else { return }
            var currentClips = audioTracks[trackIndex].clips
            currentClips = performOverwriteAlgorithm(existing: currentClips, incoming: incoming)
            audioTracks[trackIndex].clips = currentClips
        }
    }

    private func performOverwriteAlgorithm(existing: [TimelineClip], incoming: TimelineClip) -> [TimelineClip] {
        var result: [TimelineClip] = []
        let S = CMTimeGetSeconds(incoming.timelineStart)
        let E = CMTimeGetSeconds(incoming.timelineEnd)

        guard E > S + 0.001 else { return existing }

        // Locked clips cannot be overwritten, split, or overlapped by incoming clips
        let hitsLockedClip = existing.contains { clip in
            guard clip.id != incoming.id && clip.isEffectivelyLocked else { return false }
            let CS = CMTimeGetSeconds(clip.timelineStart)
            let CE = CMTimeGetSeconds(clip.timelineEnd)
            return max(CS, S) < min(CE, E) - 0.001
        }
        if hitsLockedClip {
            return existing
        }

        for clip in existing {
            if clip.id == incoming.id {
                continue
            }

            let CS = CMTimeGetSeconds(clip.timelineStart)
            let CE = CMTimeGetSeconds(clip.timelineEnd)

            if max(CS, S) >= min(CE, E) - 0.001 {
                result.append(clip)
                continue
            }

            if S <= CS + 0.001 && E >= CE - 0.001 {
                continue
            }

            if CS < S - 0.001 && E < CE - 0.001 {
                let leftDur = S - CS
                if leftDur > 0.02 {
                    let leftIn = clip.sourceIn
                    let leftOut = CMTimeAdd(clip.sourceIn, CMTime(seconds: leftDur, preferredTimescale: 600))
                    let leftClip = TimelineClip(
                        id: clip.id,
                        mediaItem: clip.mediaItem,
                        sourceIn: leftIn,
                        sourceOut: leftOut,
                        timelineStart: clip.timelineStart,
                        trackIndex: clip.trackIndex,
                        mediaType: clip.mediaType,
                        orientation: clip.orientation,
                        linkGroupId: clip.linkGroupId,
                        isOrphan: clip.isOrphan,
                        speed: clip.speed,
                        beatMarkers: clip.beatMarkers,
                        beatBPM: clip.beatBPM,
                        markers: clip.markers,
                        selectionSourceIn: clip.selectionSourceIn,
                        selectionSourceOut: clip.selectionSourceOut,
                        colorTag: clip.colorTag
                    )
                    result.append(leftClip)
                }

                let rightDur = CE - E
                if rightDur > 0.02 {
                    let rightOffset = E - CS
                    let rightIn = CMTimeAdd(clip.sourceIn, CMTime(seconds: rightOffset, preferredTimescale: 600))
                    let rightOut = clip.sourceOut
                    let rightClip = TimelineClip(
                        id: UUID(),
                        mediaItem: clip.mediaItem,
                        sourceIn: rightIn,
                        sourceOut: rightOut,
                        timelineStart: CMTime(seconds: E, preferredTimescale: 600),
                        trackIndex: clip.trackIndex,
                        mediaType: clip.mediaType,
                        orientation: clip.orientation,
                        linkGroupId: clip.linkGroupId != nil ? UUID() : nil,
                        isOrphan: clip.isOrphan,
                        speed: clip.speed,
                        beatMarkers: clip.beatMarkers,
                        beatBPM: clip.beatBPM,
                        markers: clip.markers,
                        selectionSourceIn: clip.selectionSourceIn,
                        selectionSourceOut: clip.selectionSourceOut,
                        colorTag: clip.colorTag
                    )
                    result.append(rightClip)
                }
                continue
            }

            if S <= CS + 0.001 && E < CE - 0.001 {
                let remDur = CE - E
                if remDur > 0.02 {
                    let cutDelta = E - CS
                    let newSourceIn = CMTimeAdd(clip.sourceIn, CMTime(seconds: cutDelta, preferredTimescale: 600))
                    var trimmed = clip
                    trimmed.timelineStart = CMTime(seconds: E, preferredTimescale: 600)
                    trimmed.sourceIn = newSourceIn
                    result.append(trimmed)
                }
                continue
            }

            if CS < S - 0.001 && E >= CE - 0.001 {
                let remDur = S - CS
                if remDur > 0.02 {
                    let newSourceOut = CMTimeAdd(clip.sourceIn, CMTime(seconds: remDur, preferredTimescale: 600))
                    var trimmed = clip
                    trimmed.sourceOut = newSourceOut
                    result.append(trimmed)
                }
                continue
            }
        }

        result.append(incoming)
        result.sort(by: { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 })
        return result
    }

    public func appendClip(mediaItem: MediaItem, atTime targetTime: CMTime? = nil) {
        appendClipInternal(mediaItem: mediaItem, atTime: targetTime)
    }

    // MARK: - Framerate Compatibility & Slow-Mo Rules

    public static func formatFPSLabel(_ fps: Float) -> String {
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.05 {
            return "\(Int(rounded))"
        }
        return String(format: "%.3f", fps)
    }

    public static func isFrameRateCompatible(_ clipFPS: Double, withTimelineFPS timelineFPS: Double) -> Bool {
        guard clipFPS > 1.0, timelineFPS > 1.0 else { return true }
        let ratio = clipFPS / timelineFPS
        guard ratio >= 0.96 else { return false }
        let k = Int(ratio.rounded())
        guard k >= 1 else { return false }
        let expected = Double(k) * timelineFPS
        return abs(clipFPS - expected) / expected <= 0.015
    }

    public static func canSlowMo(clipFPS: Double, timelineFPS: Double) -> Bool {
        guard clipFPS > 1.0, timelineFPS > 1.0 else { return false }
        return clipFPS >= timelineFPS * 2.0 * 0.985
    }

    public func isClipFrameRateCompatible(_ clip: TimelineClip) -> Bool {
        guard clip.mediaItem.hasVideo, clip.mediaItem.frameRate > 1.0 else { return true }
        return Self.isFrameRateCompatible(Double(clip.mediaItem.frameRate), withTimelineFPS: Double(format.fps))
    }

    public func canSlowMoClip(_ clip: TimelineClip) -> Bool {
        guard clip.mediaItem.hasVideo else { return true }
        return Self.canSlowMo(clipFPS: Double(clip.mediaItem.frameRate), timelineFPS: Double(format.fps))
    }

    public func nonConformantFrameRateClips() -> [TimelineClip] {
        var result: [TimelineClip] = []
        for track in videoTracks {
            for clip in track.clips where !isClipFrameRateCompatible(clip) {
                result.append(clip)
            }
        }
        return result
    }

    private func logFrameRateWarningIfNeeded(for mediaItem: MediaItem) {
        guard mediaItem.hasVideo, mediaItem.frameRate > 1.0 else { return }
        if !Self.isFrameRateCompatible(Double(mediaItem.frameRate), withTimelineFPS: Double(format.fps)) {
            DebugLogger.shared.log(
                "⚠ Clip '\(mediaItem.name)' a \(Self.formatFPSLabel(mediaItem.frameRate))fps non conforme alla timeline (\(Self.formatFPSLabel(format.fps))fps).",
                level: .warning
            )
        }
    }

    private func appendClipInternal(mediaItem: MediaItem, atTime targetTime: CMTime? = nil) {
        logFrameRateWarningIfNeeded(for: mediaItem)
        let startTime: CMTime
        if let targetTime = targetTime {
            startTime = targetTime
        } else {
            let v1End = videoTracks[0].clips.map(\.timelineEnd).max(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero
            let a1End = audioTracks[0].clips.map(\.timelineEnd).max(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero
            startTime = max(v1End, a1End)
        }

        let linkId = (mediaItem.hasVideo && mediaItem.hasAudio && isLinkActive) ? UUID() : nil

        if mediaItem.hasVideo && !videoTracks[0].isLocked {
            let vClip = TimelineClip(
                mediaItem: mediaItem,
                sourceIn: .zero,
                sourceOut: mediaItem.duration,
                timelineStart: startTime,
                trackIndex: 0,
                mediaType: .video,
                orientation: mediaItem.orientation,
                linkGroupId: linkId
            )
            overwriteAndInsert(incoming: vClip, trackIndex: 0, isVideo: true)
        }

        if mediaItem.hasAudio && !audioTracks[0].isLocked && (isLinkActive || !mediaItem.hasVideo) {
            let aClip = TimelineClip(
                mediaItem: mediaItem,
                sourceIn: .zero,
                sourceOut: mediaItem.duration,
                timelineStart: startTime,
                trackIndex: 0,
                mediaType: .audio,
                orientation: .normal,
                linkGroupId: linkId
            )
            overwriteAndInsert(incoming: aClip, trackIndex: 0, isVideo: false)
        }
        onModelChanged?()
    }

    public func insertClip(mediaItem: MediaItem, atTime time: CMTime, targetTrackIndex: Int, isTargetVideo: Bool) {
        logFrameRateWarningIfNeeded(for: mediaItem)
        let linkId = (mediaItem.hasVideo && mediaItem.hasAudio && isLinkActive) ? UUID() : nil
        let validTime = max(.zero, time)

        let effectiveVideoTarget = mediaItem.hasVideo && (isTargetVideo || !mediaItem.hasAudio)
        if effectiveVideoTarget {
            let safeVideoTrack = min(targetTrackIndex, maxVideoTracks - 1)
            ensureVideoTrack(id: safeVideoTrack)
            guard !videoTracks[safeVideoTrack].isLocked else { return }

            var effectiveStart = validTime
            var effectiveOut = mediaItem.duration
            var assignedCageIndex: Int? = nil

            if isCageLockActive, let targetCage = nearestCageStart(to: CMTimeGetSeconds(validTime)) {
                effectiveStart = targetCage.startTime
                assignedCageIndex = targetCage.index
                let mediaDurSec = CMTimeGetSeconds(mediaItem.duration)
                if mediaDurSec >= targetCage.durationSeconds {
                    effectiveOut = targetCage.durationTime
                }
            }

            let vClip = TimelineClip(
                mediaItem: mediaItem,
                sourceIn: .zero,
                sourceOut: effectiveOut,
                timelineStart: effectiveStart,
                trackIndex: safeVideoTrack,
                mediaType: .video,
                orientation: mediaItem.orientation,
                linkGroupId: linkId,
                cageIndex: assignedCageIndex
            )
            guard !hasLockedClipOverlap(start: vClip.timelineStart, end: vClip.timelineEnd, trackIndex: safeVideoTrack, isVideo: true) else { return }
            overwriteAndInsert(incoming: vClip, trackIndex: safeVideoTrack, isVideo: true)

            if mediaItem.hasAudio && isLinkActive {
                let audioTrackIdx = min(safeVideoTrack, maxAudioTracks - 1)
                ensureAudioTrack(id: audioTrackIdx)
                if !hasLockedClipOverlap(start: effectiveStart, end: CMTimeAdd(effectiveStart, effectiveOut), trackIndex: audioTrackIdx, isVideo: false) {
                    let aClip = TimelineClip(
                        mediaItem: mediaItem,
                        sourceIn: .zero,
                        sourceOut: effectiveOut,
                        timelineStart: effectiveStart,
                        trackIndex: audioTrackIdx,
                        mediaType: .audio,
                        linkGroupId: linkId,
                        cageIndex: assignedCageIndex
                    )
                    overwriteAndInsert(incoming: aClip, trackIndex: audioTrackIdx, isVideo: false)
                }
            }
        } else if mediaItem.hasAudio {
            let requestedAudioTrack = isTargetVideo ? 0 : targetTrackIndex
            let safeAudioTrack = min(requestedAudioTrack, maxAudioTracks - 1)
            ensureAudioTrack(id: safeAudioTrack)
            guard !audioTracks[safeAudioTrack].isLocked else { return }

            let aClip = TimelineClip(
                mediaItem: mediaItem,
                sourceIn: .zero,
                sourceOut: mediaItem.duration,
                timelineStart: validTime,
                trackIndex: safeAudioTrack,
                mediaType: .audio,
                linkGroupId: linkId
            )
            guard !hasLockedClipOverlap(start: aClip.timelineStart, end: aClip.timelineEnd, trackIndex: safeAudioTrack, isVideo: false) else { return }
            overwriteAndInsert(incoming: aClip, trackIndex: safeAudioTrack, isVideo: false)

            if mediaItem.hasVideo && isLinkActive {
                let videoTrackIdx = min(safeAudioTrack, maxVideoTracks - 1)
                ensureVideoTrack(id: videoTrackIdx)
                if !hasLockedClipOverlap(start: validTime, end: CMTimeAdd(validTime, mediaItem.duration), trackIndex: videoTrackIdx, isVideo: true) {
                    let vClip = TimelineClip(
                        mediaItem: mediaItem,
                        sourceIn: .zero,
                        sourceOut: mediaItem.duration,
                        timelineStart: validTime,
                        trackIndex: videoTrackIdx,
                        mediaType: .video,
                        orientation: mediaItem.orientation,
                        linkGroupId: linkId
                    )
                    overwriteAndInsert(incoming: vClip, trackIndex: videoTrackIdx, isVideo: true)
                }
            }
        }
        onModelChanged?()
    }

    public func previewMoveClip(id: UUID, toTrack targetTrack: Int, isVideo: Bool, newStartTime: CMTime) {
        let clampedStart = max(.zero, newStartTime)
        if isVideo {
            guard targetTrack < videoTracks.count, !videoTracks[targetTrack].isLocked else { return }
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isEffectivelyLocked }) {
                    let dur = videoTracks[trackIdx].clips[clipIdx].duration
                    guard !hasLockedClipOverlap(start: clampedStart, end: CMTimeAdd(clampedStart, dur), trackIndex: targetTrack, isVideo: true, excludingClipIds: [id]) else {
                        return
                    }
                    videoTracks[trackIdx].clips[clipIdx].timelineStart = clampedStart
                    videoTracks[trackIdx].clips[clipIdx].trackIndex = targetTrack
                    return
                }
            }
        } else {
            guard targetTrack < audioTracks.count, !audioTracks[targetTrack].isLocked else { return }
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isEffectivelyLocked }) {
                    let dur = audioTracks[trackIdx].clips[clipIdx].duration
                    guard !hasLockedClipOverlap(start: clampedStart, end: CMTimeAdd(clampedStart, dur), trackIndex: targetTrack, isVideo: false, excludingClipIds: [id]) else {
                        return
                    }
                    audioTracks[trackIdx].clips[clipIdx].timelineStart = clampedStart
                    audioTracks[trackIdx].clips[clipIdx].trackIndex = targetTrack
                    return
                }
            }
        }
    }

    public func commitMoveClip(
        id: UUID,
        toTrack targetTrack: Int,
        isVideo: Bool,
        newStartTime: CMTime? = nil,
        companionId: UUID? = nil
    ) {
        var movedClip: TimelineClip? = nil
        var originalTrackIndex: Int = 0

        if isVideo {
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isEffectivelyLocked }) {
                    originalTrackIndex = trackIdx
                    movedClip = videoTracks[trackIdx].clips.remove(at: clipIdx)
                    break
                }
            }
            var finalClipStart: CMTime? = nil
            var finalClipSourceOut: CMTime? = nil
            var didRevertPrimary = false

            if let originalClip = movedClip {
                var clip = originalClip
                ensureVideoTrack(id: targetTrack)
                clip.trackIndex = targetTrack
                if let newStart = newStartTime {
                    clip.timelineStart = max(.zero, newStart)
                }

                if isCageLockActive, !activeCageBoundaries().isEmpty {
                    let startSec = CMTimeGetSeconds(clip.timelineStart)
                    if let targetCage = nearestCageStart(to: startSec) {
                        clip.timelineStart = targetCage.startTime
                        clip.cageIndex = targetCage.index
                    }
                    let alignedStartSec = CMTimeGetSeconds(clip.timelineStart)
                    let curEndSec = alignedStartSec + CMTimeGetSeconds(clip.duration)
                    let boundaries = activeCageBoundaries()
                    let alreadyOnBar = boundaries.contains(where: { abs($0 - curEndSec) < 0.015 })
                    if !alreadyOnBar {
                        let availSource = max(0.1, CMTimeGetSeconds(clip.mediaItem.duration) - CMTimeGetSeconds(clip.sourceIn))
                        let speedFactor = clip.speed > 0 ? clip.speed : 1.0
                        let maxTimelineDur = availSource / speedFactor
                        if let snappedEnd = snappedCageEnd(forStart: alignedStartSec, desiredEndSeconds: curEndSec, maxAvailableTimelineDuration: maxTimelineDur) {
                            let newTimelineDur = max(0.1, snappedEnd - alignedStartSec)
                            let newSourceOut = min(CMTimeGetSeconds(clip.mediaItem.duration), CMTimeGetSeconds(clip.sourceIn) + newTimelineDur * speedFactor)
                            clip.sourceOut = CMTime(seconds: newSourceOut, preferredTimescale: 600)
                        }
                    }
                    finalClipStart = clip.timelineStart
                    finalClipSourceOut = clip.sourceOut
                }

                if hasLockedClipOverlap(start: clip.timelineStart, end: clip.timelineEnd, trackIndex: targetTrack, isVideo: true, excludingClipIds: [clip.id]) {
                    var restored = originalClip
                    restored.trackIndex = originalTrackIndex
                    overwriteAndInsert(incoming: restored, trackIndex: originalTrackIndex, isVideo: true)
                    didRevertPrimary = true
                } else {
                    overwriteAndInsert(incoming: clip, trackIndex: targetTrack, isVideo: true)
                }
            }

            if isLinkActive, let cId = companionId ?? findCompanionId(for: movedClip?.linkGroupId, isVideo: true) {
                for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                    if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == cId && !$0.isEffectivelyLocked }) {
                        let originalAClip = audioTracks[trackIdx].clips.remove(at: clipIdx)
                        if didRevertPrimary {
                            overwriteAndInsert(incoming: originalAClip, trackIndex: trackIdx, isVideo: false)
                            break
                        }
                        var aClip = originalAClip
                        if let fStart = finalClipStart {
                            aClip.timelineStart = fStart
                        }
                        if let fOut = finalClipSourceOut {
                            let maxA = CMTimeGetSeconds(aClip.mediaItem.duration)
                            aClip.sourceOut = CMTime(seconds: min(maxA, CMTimeGetSeconds(fOut)), preferredTimescale: 600)
                        }
                        if hasLockedClipOverlap(start: aClip.timelineStart, end: aClip.timelineEnd, trackIndex: aClip.trackIndex, isVideo: false, excludingClipIds: [aClip.id]) {
                            overwriteAndInsert(incoming: originalAClip, trackIndex: trackIdx, isVideo: false)
                        } else {
                            overwriteAndInsert(incoming: aClip, trackIndex: aClip.trackIndex, isVideo: false)
                        }
                        break
                    }
                }
            }
        } else {
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isEffectivelyLocked }) {
                    originalTrackIndex = trackIdx
                    movedClip = audioTracks[trackIdx].clips.remove(at: clipIdx)
                    break
                }
            }
            var didRevertPrimary = false
            if let originalClip = movedClip {
                var clip = originalClip
                ensureAudioTrack(id: targetTrack)
                clip.trackIndex = targetTrack
                if let newStart = newStartTime {
                    clip.timelineStart = max(.zero, newStart)
                }
                if hasLockedClipOverlap(start: clip.timelineStart, end: clip.timelineEnd, trackIndex: targetTrack, isVideo: false, excludingClipIds: [clip.id]) {
                    var restored = originalClip
                    restored.trackIndex = originalTrackIndex
                    overwriteAndInsert(incoming: restored, trackIndex: originalTrackIndex, isVideo: false)
                    didRevertPrimary = true
                } else {
                    overwriteAndInsert(incoming: clip, trackIndex: targetTrack, isVideo: false)
                }
            }

            if isLinkActive, let cId = companionId ?? findCompanionId(for: movedClip?.linkGroupId, isVideo: false) {
                for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                    if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == cId && !$0.isEffectivelyLocked }) {
                        let originalVClip = videoTracks[trackIdx].clips.remove(at: clipIdx)
                        if didRevertPrimary || hasLockedClipOverlap(start: originalVClip.timelineStart, end: originalVClip.timelineEnd, trackIndex: originalVClip.trackIndex, isVideo: true, excludingClipIds: [originalVClip.id]) {
                            overwriteAndInsert(incoming: originalVClip, trackIndex: trackIdx, isVideo: true)
                        } else {
                            overwriteAndInsert(incoming: originalVClip, trackIndex: originalVClip.trackIndex, isVideo: true)
                        }
                        break
                    }
                }
            }
        }
        onModelChanged?()
    }

    /// Moves a batch of clips atomically (used for multi-selection drag / ⌘A drag),
    /// removing all moved clips before re-inserting so contiguous clips do not overwrite each other.
    public func commitMoveClips(_ moves: [(id: UUID, toTrack: Int, isVideo: Bool, newStartTime: CMTime)]) {
        guard !moves.isEmpty else { return }

        var extracted: [(originalTrack: Int, clip: TimelineClip, targetTrack: Int, isVideo: Bool, newStartTime: CMTime)] = []
        var seenIds: Set<UUID> = []

        for move in moves {
            guard seenIds.insert(move.id).inserted else { continue }
            if move.isVideo {
                for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                    if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == move.id && !$0.isEffectivelyLocked }) {
                        let clip = videoTracks[trackIdx].clips.remove(at: clipIdx)
                        extracted.append((originalTrack: trackIdx, clip: clip, targetTrack: move.toTrack, isVideo: true, newStartTime: move.newStartTime))
                        break
                    }
                }
            } else {
                for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                    if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == move.id && !$0.isEffectivelyLocked }) {
                        let clip = audioTracks[trackIdx].clips.remove(at: clipIdx)
                        extracted.append((originalTrack: trackIdx, clip: clip, targetTrack: move.toTrack, isVideo: false, newStartTime: move.newStartTime))
                        break
                    }
                }
            }
        }

        guard !extracted.isEmpty else { return }

        // Apply video clips first so cage locks can compute consistent audio companion adjustments if needed
        let ordered = extracted.sorted { a, b in
            if a.isVideo != b.isVideo { return a.isVideo && !b.isVideo }
            return CMTimeCompare(a.newStartTime, b.newStartTime) < 0
        }

        var videoAdjustmentsByLink: [UUID: (start: CMTime, sourceOut: CMTime)] = [:]
        var plannedPlacements: [(clip: TimelineClip, targetTrack: Int, isVideo: Bool)] = []
        var anyLockedConflict = false

        for entry in ordered {
            var candidate = entry.clip
            if entry.isVideo {
                ensureVideoTrack(id: entry.targetTrack)
                guard entry.targetTrack < videoTracks.count, !videoTracks[entry.targetTrack].isLocked else {
                    anyLockedConflict = true
                    break
                }
                candidate.trackIndex = entry.targetTrack
                candidate.timelineStart = max(.zero, entry.newStartTime)

                if isCageLockActive, !activeCageBoundaries().isEmpty {
                    let startSec = CMTimeGetSeconds(candidate.timelineStart)
                    if let targetCage = nearestCageStart(to: startSec) {
                        candidate.timelineStart = targetCage.startTime
                        candidate.cageIndex = targetCage.index
                    }
                    let alignedStartSec = CMTimeGetSeconds(candidate.timelineStart)
                    let curEndSec = alignedStartSec + CMTimeGetSeconds(candidate.duration)
                    let boundaries = activeCageBoundaries()
                    let alreadyOnBar = boundaries.contains(where: { abs($0 - curEndSec) < 0.015 })
                    if !alreadyOnBar {
                        let availSource = max(0.1, CMTimeGetSeconds(candidate.mediaItem.duration) - CMTimeGetSeconds(candidate.sourceIn))
                        let speedFactor = candidate.speed > 0 ? candidate.speed : 1.0
                        let maxTimelineDur = availSource / speedFactor
                        if let snappedEnd = snappedCageEnd(forStart: alignedStartSec, desiredEndSeconds: curEndSec, maxAvailableTimelineDuration: maxTimelineDur) {
                            let newTimelineDur = max(0.1, snappedEnd - alignedStartSec)
                            let newSourceOut = min(CMTimeGetSeconds(candidate.mediaItem.duration), CMTimeGetSeconds(candidate.sourceIn) + newTimelineDur * speedFactor)
                            candidate.sourceOut = CMTime(seconds: newSourceOut, preferredTimescale: 600)
                        }
                    }
                    if isLinkActive, let lId = candidate.linkGroupId {
                        videoAdjustmentsByLink[lId] = (candidate.timelineStart, candidate.sourceOut)
                    }
                }
                if hasLockedClipOverlap(start: candidate.timelineStart, end: candidate.timelineEnd, trackIndex: entry.targetTrack, isVideo: true, excludingClipIds: [candidate.id]) {
                    anyLockedConflict = true
                    break
                }
                plannedPlacements.append((clip: candidate, targetTrack: entry.targetTrack, isVideo: true))
            } else {
                ensureAudioTrack(id: entry.targetTrack)
                guard entry.targetTrack < audioTracks.count, !audioTracks[entry.targetTrack].isLocked else {
                    anyLockedConflict = true
                    break
                }
                candidate.trackIndex = entry.targetTrack
                candidate.timelineStart = max(.zero, entry.newStartTime)
                if let lId = candidate.linkGroupId, let adj = videoAdjustmentsByLink[lId] {
                    candidate.timelineStart = adj.start
                    let maxA = CMTimeGetSeconds(candidate.mediaItem.duration)
                    candidate.sourceOut = CMTime(seconds: min(maxA, CMTimeGetSeconds(adj.sourceOut)), preferredTimescale: 600)
                }
                if hasLockedClipOverlap(start: candidate.timelineStart, end: candidate.timelineEnd, trackIndex: entry.targetTrack, isVideo: false, excludingClipIds: [candidate.id]) {
                    anyLockedConflict = true
                    break
                }
                plannedPlacements.append((clip: candidate, targetTrack: entry.targetTrack, isVideo: false))
            }
        }

        if anyLockedConflict {
            for entry in ordered {
                var restored = entry.clip
                restored.trackIndex = entry.originalTrack
                overwriteAndInsert(incoming: restored, trackIndex: entry.originalTrack, isVideo: entry.isVideo)
            }
        } else {
            for item in plannedPlacements {
                overwriteAndInsert(incoming: item.clip, trackIndex: item.targetTrack, isVideo: item.isVideo)
            }
        }

        onModelChanged?()
    }

    private func findCompanionId(for linkId: UUID?, isVideo: Bool) -> UUID? {
        guard let lId = linkId else { return nil }
        if isVideo {
            for track in audioTracks where !track.isLocked {
                if let clip = track.clips.first(where: { $0.linkGroupId == lId }) {
                    return clip.id
                }
            }
        } else {
            for track in videoTracks where !track.isLocked {
                if let clip = track.clips.first(where: { $0.linkGroupId == lId }) {
                    return clip.id
                }
            }
        }
        return nil
    }

    public func snap(
        startTime: CMTime,
        duration: CMTime,
        playhead: CMTime,
        thresholdSeconds: Double,
        draggedClip: TimelineClip? = nil,
        targetTrackIndex: Int? = nil,
        isVideo: Bool? = nil
    ) -> (snappedTime: CMTime, didSnap: Bool, snapPoint: CMTime?) {
        guard isSnappingActive else { return (startTime, false, nil) }

        let targetStartSec = CMTimeGetSeconds(startTime)
        let durSec = CMTimeGetSeconds(duration)
        let targetEndSec = targetStartSec + durSec

        var bestNewStart = targetStartSec
        var minDiff = thresholdSeconds
        var snappedRefPoint: Double? = nil

        var snapPoints: [Double] = [0.0]
        let playheadSec = CMTimeGetSeconds(playhead)
        if playheadSec >= 0 {
            snapPoints.append(playheadSec)
        }

        for track in videoTracks {
            for clip in track.clips {
                if !selectedClipIds.contains(clip.id) {
                    snapPoints.append(CMTimeGetSeconds(clip.timelineStart))
                    snapPoints.append(CMTimeGetSeconds(clip.timelineEnd))
                }
            }
        }
        for track in audioTracks {
            for clip in track.clips {
                if !selectedClipIds.contains(clip.id) {
                    snapPoints.append(CMTimeGetSeconds(clip.timelineStart))
                    snapPoints.append(CMTimeGetSeconds(clip.timelineEnd))
                }
            }
        }

        if isRhythmicGridVisible {
            for cage in activeCageIntervals() {
                snapPoints.append(cage.startSeconds)
                snapPoints.append(cage.endSeconds)
            }
        }

        for track in videoTracks {
            for clip in track.clips where !clip.markers.isEmpty {
                snapPoints.append(contentsOf: clip.visibleMarkersTimelineTimes())
            }
        }
        for track in audioTracks {
            for clip in track.clips where !clip.markers.isEmpty {
                snapPoints.append(contentsOf: clip.visibleMarkersTimelineTimes())
            }
        }

        for pt in snapPoints {
            let diffStart = abs(targetStartSec - pt)
            if diffStart < minDiff {
                minDiff = diffStart
                bestNewStart = pt
                snappedRefPoint = pt
            }

            let diffEnd = abs(targetEndSec - pt)
            if diffEnd < minDiff {
                minDiff = diffEnd
                bestNewStart = max(0.0, pt - durSec)
                snappedRefPoint = pt
            }
        }

        // Magnet beat-to-beat tra frammenti della stessa clip audio su tracce diverse (es. A2 vs A4)
        if isVideo == false,
           let dClip = draggedClip,
           let tTrack = targetTrackIndex,
           !dClip.beatMarkers.isEmpty {
            let dIn = CMTimeGetSeconds(dClip.sourceIn)
            let dOut = CMTimeGetSeconds(dClip.sourceOut)
            let dSpd = dClip.speed > 0 ? dClip.speed : 1.0
            let dragBeatOffsets = dClip.beatMarkers
                .filter { $0 >= dIn - 0.001 && $0 <= dOut + 0.001 }
                .map { ($0 - dIn) / dSpd }

            if !dragBeatOffsets.isEmpty {
                let dUrl = dClip.mediaItem.url.standardizedFileURL
                for track in audioTracks where track.id != tTrack {
                    for otherClip in track.clips {
                        guard otherClip.id != dClip.id,
                              !selectedClipIds.contains(otherClip.id),
                              !otherClip.beatMarkers.isEmpty else { continue }
                        let sameAudio = otherClip.mediaItem.id == dClip.mediaItem.id
                            || otherClip.mediaItem.url.standardizedFileURL == dUrl
                        guard sameAudio else { continue }

                        for otherBeatSec in otherClip.visibleBeatTimelineTimes() {
                            for offset in dragBeatOffsets {
                                let dragBeatSec = targetStartSec + offset
                                let diff = abs(dragBeatSec - otherBeatSec)
                                if diff < minDiff {
                                    minDiff = diff
                                    bestNewStart = max(0.0, otherBeatSec - offset)
                                    snappedRefPoint = otherBeatSec
                                }
                            }
                        }
                    }
                }
            }
        }

        if minDiff < thresholdSeconds, let refPt = snappedRefPoint {
            let snappedCM = CMTime(seconds: max(0.0, bestNewStart), preferredTimescale: 600)
            let refCM = CMTime(seconds: refPt, preferredTimescale: 600)
            return (snappedCM, true, refCM)
        }

        return (startTime, false, nil)
    }

    public func cleanEmptyTracks() {
        var newVideo: [TimelineTrack] = []
        for track in videoTracks {
            if !track.clips.isEmpty || track.id == 0 {
                var t = track
                t.id = newVideo.count
                t.name = "V\(newVideo.count + 1)"
                for i in 0..<t.clips.count {
                    t.clips[i].trackIndex = t.id
                }
                newVideo.append(t)
            }
        }
        if newVideo.isEmpty {
            newVideo = [TimelineTrack(id: 0, name: "V1", mediaType: .video)]
        }
        self.videoTracks = newVideo

        var newAudio: [TimelineTrack] = []
        for track in audioTracks {
            if !track.clips.isEmpty || track.id == 0 {
                var t = track
                t.id = newAudio.count
                t.name = "A\(newAudio.count + 1)"
                for i in 0..<t.clips.count {
                    t.clips[i].trackIndex = t.id
                }
                newAudio.append(t)
            }
        }
        if newAudio.isEmpty {
            newAudio = [TimelineTrack(id: 0, name: "A1", mediaType: .audio)]
        }
        self.audioTracks = newAudio

        onModelChanged?()
        DebugLogger.shared.log("Pulizia completata: rimaste \(videoTracks.count) tracce video e \(audioTracks.count) tracce audio.", level: .info)
    }

    /// Removes trailing temporary empty tracks created above the baseline counts during a drag gesture.
    public func trimEmptyTracksCreatedSince(videoCount: Int, audioCount: Int) {
        let minV = max(1, videoCount)
        while videoTracks.count > minV, let last = videoTracks.last, last.clips.isEmpty {
            videoTracks.removeLast()
        }
        let minA = max(1, audioCount)
        while audioTracks.count > minA, let last = audioTracks.last, last.clips.isEmpty {
            audioTracks.removeLast()
        }
    }

    public func setClipOrientation(id: UUID, orientation: ClipOrientation) {
        for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
            if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id }) {
                videoTracks[trackIdx].clips[clipIdx].orientation = orientation
                onModelChanged?()
                return
            }
        }
    }

    // MARK: - Orphan Clips (File eliminati dal Media Pool)
    public func markOrphans(forMediaId id: UUID, url: URL? = nil) {
        var didMark = false
        for tIdx in 0..<videoTracks.count {
            for cIdx in 0..<videoTracks[tIdx].clips.count {
                if videoTracks[tIdx].clips[cIdx].mediaItem.id == id || (url != nil && videoTracks[tIdx].clips[cIdx].mediaItem.url == url) {
                    videoTracks[tIdx].clips[cIdx].isOrphan = true
                    videoTracks[tIdx].clips[cIdx].mediaItem.beatAnalysis = nil
                    didMark = true
                }
            }
        }
        for tIdx in 0..<audioTracks.count {
            for cIdx in 0..<audioTracks[tIdx].clips.count {
                if audioTracks[tIdx].clips[cIdx].mediaItem.id == id || (url != nil && audioTracks[tIdx].clips[cIdx].mediaItem.url == url) {
                    audioTracks[tIdx].clips[cIdx].isOrphan = true
                    audioTracks[tIdx].clips[cIdx].mediaItem.beatAnalysis = nil
                    didMark = true
                }
            }
        }
        if didMark {
            onModelChanged?()
            DebugLogger.shared.log("Clip orfane rilevate e contrassegnate in rosso ⚠️", level: .warning)
        }
    }

    // MARK: - Ripple & Normal Delete Engine (Eliminazione Clip)
    private func collectRemovalCandidatesAndIds(from ids: [UUID]) -> (candidates: [TimelineClip], expandedIds: Set<UUID>) {
        var candidateClips: [TimelineClip] = []
        for track in videoTracks where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) && !clip.isEffectivelyLocked {
                candidateClips.append(clip)
            }
        }
        for track in audioTracks where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) && !clip.isEffectivelyLocked {
                candidateClips.append(clip)
            }
        }
        var expandedIds = Set(candidateClips.map { $0.id })
        if isSelection {
            expandedIds = resolveSelectionCompanionClipIds(for: expandedIds)
        } else if isLinkActive {
            for targetClip in candidateClips {
                if let lId = targetClip.linkGroupId {
                    for track in videoTracks where !track.isLocked {
                        for c in track.clips where c.linkGroupId == lId && !c.isEffectivelyLocked { expandedIds.insert(c.id) }
                    }
                    for track in audioTracks where !track.isLocked {
                        for c in track.clips where c.linkGroupId == lId && !c.isEffectivelyLocked { expandedIds.insert(c.id) }
                    }
                }
            }
        }
        return (candidateClips, expandedIds)
    }

    public func removeClipsWithoutRipple(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let collected = collectRemovalCandidatesAndIds(from: ids)
        guard !collected.candidates.isEmpty else {
            DebugLogger.shared.log("Nessuna clip eliminabile: le clip o tracce selezionate sono bloccate 🔒", level: .warning)
            return
        }

        let idsToRemove = collected.expandedIds
        var removedCount = 0
        for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
            let before = videoTracks[trackIdx].clips.count
            videoTracks[trackIdx].clips.removeAll(where: { idsToRemove.contains($0.id) })
            removedCount += (before - videoTracks[trackIdx].clips.count)
        }
        for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
            let before = audioTracks[trackIdx].clips.count
            audioTracks[trackIdx].clips.removeAll(where: { idsToRemove.contains($0.id) })
            removedCount += (before - audioTracks[trackIdx].clips.count)
        }
        selectedClipIds.subtract(idsToRemove)

        if removedCount > 0 {
            if isSelection {
                repackSelectionContiguously()
            }
            onModelChanged?()
            DebugLogger.shared.log("Clip rimossa lasciando lo spazio (modalità con scarto).", level: .info)
        }
    }

    public func removeClipsWithRipple(ids: [UUID]) {
        guard !ids.isEmpty else { return }

        var candidateClips = collectRemovalCandidatesAndIds(from: ids).candidates

        guard !candidateClips.isEmpty else {
            DebugLogger.shared.log("Nessuna clip eliminabile: le tracce selezionate sono bloccate 🔒", level: .warning)
            return
        }

        // Sort descending by timelineStart so we ripple from right to left
        candidateClips.sort(by: { CMTimeCompare($0.timelineStart, $1.timelineStart) > 0 })

        var didRipple = false

        for targetClip in candidateClips {
            let startSec = CMTimeGetSeconds(targetClip.timelineStart)
            let endSec = CMTimeGetSeconds(targetClip.timelineEnd)
            let durSec = CMTimeGetSeconds(targetClip.duration)
            guard durSec > 0.001 else { continue }

            var idsToRemove: Set<UUID> = [targetClip.id]
            if isSelection {
                idsToRemove = resolveSelectionCompanionClipIds(for: [targetClip.id])
            } else if isLinkActive, let lId = targetClip.linkGroupId {
                for track in videoTracks where !track.isLocked {
                    for c in track.clips where c.linkGroupId == lId { idsToRemove.insert(c.id) }
                }
                for track in audioTracks where !track.isLocked {
                    for c in track.clips where c.linkGroupId == lId { idsToRemove.insert(c.id) }
                }
            }

            // Remove from tracks (skip if already removed as companion of a previously processed clip)
            var removedCount = 0
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                let before = videoTracks[trackIdx].clips.count
                videoTracks[trackIdx].clips.removeAll(where: { idsToRemove.contains($0.id) })
                removedCount += (before - videoTracks[trackIdx].clips.count)
            }
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                let before = audioTracks[trackIdx].clips.count
                audioTracks[trackIdx].clips.removeAll(where: { idsToRemove.contains($0.id) })
                removedCount += (before - audioTracks[trackIdx].clips.count)
            }
            selectedClipIds.subtract(idsToRemove)
            guard removedCount > 0 else { continue }

            // Modalità con scarto: ripple all clips on unlocked tracks starting at or after endSec backward (skip individually locked clips)
            let downstreamThreshold = endSec - 0.025
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                let sortedIndices = videoTracks[trackIdx].clips.indices.sorted {
                    CMTimeCompare(videoTracks[trackIdx].clips[$0].timelineStart, videoTracks[trackIdx].clips[$1].timelineStart) < 0
                }
                var prevEndSec: Double = 0.0
                for cIdx in sortedIndices {
                    let clip = videoTracks[trackIdx].clips[cIdx]
                    let clipStart = CMTimeGetSeconds(clip.timelineStart)
                    let clipDur = CMTimeGetSeconds(clip.duration)
                    if !clip.isEffectivelyLocked && clipStart >= downstreamThreshold {
                        let newStart = max(startSec, max(prevEndSec, clipStart - durSec))
                        videoTracks[trackIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                        prevEndSec = max(prevEndSec, newStart + clipDur)
                    } else {
                        prevEndSec = max(prevEndSec, clipStart + clipDur)
                    }
                }
            }
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                let sortedIndices = audioTracks[trackIdx].clips.indices.sorted {
                    CMTimeCompare(audioTracks[trackIdx].clips[$0].timelineStart, audioTracks[trackIdx].clips[$1].timelineStart) < 0
                }
                var prevEndSec: Double = 0.0
                for cIdx in sortedIndices {
                    let clip = audioTracks[trackIdx].clips[cIdx]
                    let clipStart = CMTimeGetSeconds(clip.timelineStart)
                    let clipDur = CMTimeGetSeconds(clip.duration)
                    if !clip.isEffectivelyLocked && clipStart >= downstreamThreshold {
                        let newStart = max(startSec, max(prevEndSec, clipStart - durSec))
                        audioTracks[trackIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                        prevEndSec = max(prevEndSec, newStart + clipDur)
                    } else {
                        prevEndSec = max(prevEndSec, clipStart + clipDur)
                    }
                }
            }

            didRipple = true
        }

        if didRipple {
            if isSelection {
                repackSelectionContiguously()
            }
            onModelChanged?()
            DebugLogger.shared.log("Eliminazione con scarto (Ripple Delete) completata: rimosso spazio vuoto.", level: .info)
        }
    }

    /// Garantisce che in Selezione tutte le clip su V1 e A1 restino sempre perfettamente contigue
    /// dalla posizione 0 senza buchi vuoti né sovrapposizioni dopo split, trim o ripple delete.
    public func repackSelectionContiguously() {
        guard isSelection else { return }

        if !videoTracks.isEmpty {
            let originalVideo = videoTracks[0].clips.sorted {
                let c = CMTimeCompare($0.timelineStart, $1.timelineStart)
                if c != 0 { return c < 0 }
                return CMTimeCompare($0.sourceIn, $1.sourceIn) < 0
            }

            var newStartByLink: [UUID: CMTime] = [:]
            var matchedAudioIndices: Set<Int> = []
            var newAudioStartByAudioIdx: [Int: CMTime] = [:]

            var cursor: CMTime = .zero
            var repackedVideo: [TimelineClip] = []
            repackedVideo.reserveCapacity(originalVideo.count)

            let existingAudio = audioTracks.first?.clips ?? []

            for var vClip in originalVideo {
                let oldStart = CMTimeGetSeconds(vClip.timelineStart)
                let oldEnd = CMTimeGetSeconds(vClip.timelineEnd)
                vClip.timelineStart = cursor
                vClip.trackIndex = 0
                repackedVideo.append(vClip)

                if let lid = vClip.linkGroupId {
                    newStartByLink[lid] = cursor
                }
                for (aIdx, aClip) in existingAudio.enumerated() where !matchedAudioIndices.contains(aIdx) {
                    if let lid = vClip.linkGroupId, aClip.linkGroupId == lid {
                        matchedAudioIndices.insert(aIdx)
                        newAudioStartByAudioIdx[aIdx] = cursor
                        break
                    }
                    let asSec = CMTimeGetSeconds(aClip.timelineStart)
                    let aeSec = CMTimeGetSeconds(aClip.timelineEnd)
                    if aClip.mediaItem.url == vClip.mediaItem.url && abs(asSec - oldStart) < 0.05 && abs(aeSec - oldEnd) < 0.05 {
                        matchedAudioIndices.insert(aIdx)
                        newAudioStartByAudioIdx[aIdx] = cursor
                        break
                    }
                }
                cursor = CMTimeAdd(cursor, vClip.duration)
            }
            videoTracks[0].clips = repackedVideo

            if !audioTracks.isEmpty {
                var repackedAudio: [TimelineClip] = []
                var tailCursor = cursor
                for (aIdx, var aClip) in existingAudio.enumerated() {
                    if let mappedStart = newAudioStartByAudioIdx[aIdx] {
                        aClip.timelineStart = mappedStart
                    } else if let lid = aClip.linkGroupId, let mappedStart = newStartByLink[lid] {
                        aClip.timelineStart = mappedStart
                    } else {
                        aClip.timelineStart = tailCursor
                        tailCursor = CMTimeAdd(tailCursor, aClip.duration)
                    }
                    aClip.trackIndex = 0
                    repackedAudio.append(aClip)
                }
                repackedAudio.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                audioTracks[0].clips = repackedAudio
            }
        }
    }

    public func removeClip(id: UUID) {
        removeClipsWithRipple(ids: [id])
    }

    public func removeSelectedClips() {
        removeClipsWithRipple(ids: Array(selectedClipIds))
    }

    public func removeSelectedClipsWithoutRipple() {
        removeClipsWithoutRipple(ids: Array(selectedClipIds))
    }

    // MARK: - Ripple Trim Engine (Modalità Senza Scarto + Link A/V)
    @discardableResult
    public func trimClipStart(at time: CMTime) -> CMTime? {
        var didTrim = false
        var targetVideoClipIds: Set<UUID> = []
        var targetAudioClipIds: Set<UUID> = []
        var targetTimelineStart: CMTime? = nil

        // 1. Identify clips spanning cut time
        // 1. Identify all clips spanning the cut time
        for track in videoTracks where !track.isLocked {
            for clip in track.clips where !clip.isEffectivelyLocked {
                let matches = selectedClipIds.contains(clip.id) || (selectedClipIds.isEmpty && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0)
                if matches && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0 {
                    targetVideoClipIds.insert(clip.id)
                    if targetTimelineStart == nil {
                        targetTimelineStart = clip.timelineStart
                    }
                    if isLinkActive, let lId = clip.linkGroupId {
                        for aTrack in audioTracks where !aTrack.isLocked {
                            for aClip in aTrack.clips where aClip.linkGroupId == lId && !aClip.isEffectivelyLocked {
                                targetAudioClipIds.insert(aClip.id)
                            }
                        }
                    }
                }
            }
        }

        for track in audioTracks where !track.isLocked {
            for clip in track.clips where !clip.isEffectivelyLocked {
                let matches = selectedClipIds.contains(clip.id) || (selectedClipIds.isEmpty && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0)
                if matches && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0 {
                    targetAudioClipIds.insert(clip.id)
                    if targetTimelineStart == nil {
                        targetTimelineStart = clip.timelineStart
                    }
                    if isLinkActive, let lId = clip.linkGroupId {
                        for vTrack in videoTracks where !vTrack.isLocked {
                            for vClip in vTrack.clips where vClip.linkGroupId == lId && !vClip.isEffectivelyLocked {
                                targetVideoClipIds.insert(vClip.id)
                            }
                        }
                    }
                }
            }
        }

        let useRipple = isRippleTrimMode || isSelection

        // 2. Perform Trim Start on Video
        var totalDeltaSec: Double = 0
        for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
            for clipIdx in 0..<videoTracks[trackIdx].clips.count {
                let clip = videoTracks[trackIdx].clips[clipIdx]
                if targetVideoClipIds.contains(clip.id) {
                    let delta = CMTimeSubtract(time, clip.timelineStart)
                    let deltaSec = CMTimeGetSeconds(delta)
                    totalDeltaSec = max(totalDeltaSec, deltaSec)
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let srcDelta = CMTime(seconds: deltaSec * spd, preferredTimescale: 600)
                    videoTracks[trackIdx].clips[clipIdx].sourceIn = CMTimeAdd(clip.sourceIn, srcDelta)
                    if !useRipple {
                        videoTracks[trackIdx].clips[clipIdx].timelineStart = time
                    }
                    didTrim = true
                }
            }
        }

        // 3. Perform Trim Start on Audio
        for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
            for clipIdx in 0..<audioTracks[trackIdx].clips.count {
                let clip = audioTracks[trackIdx].clips[clipIdx]
                if targetAudioClipIds.contains(clip.id) {
                    let delta = CMTimeSubtract(time, clip.timelineStart)
                    let deltaSec = CMTimeGetSeconds(delta)
                    totalDeltaSec = max(totalDeltaSec, deltaSec)
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let srcDelta = CMTime(seconds: deltaSec * spd, preferredTimescale: 600)
                    audioTracks[trackIdx].clips[clipIdx].sourceIn = CMTimeAdd(clip.sourceIn, srcDelta)
                    if !useRipple {
                        audioTracks[trackIdx].clips[clipIdx].timelineStart = time
                    }
                    didTrim = true
                }
            }
        }

        // 4. Modalità senza scarto (T): Ripple downstream clips backward by totalDeltaSec
        if useRipple && didTrim && totalDeltaSec > 0.001 {
            let cutSec = CMTimeGetSeconds(time)
            let rippleThreshold = cutSec - totalDeltaSec - 0.01

            func rippleTracks(_ tracks: inout [TimelineTrack]) {
                for trackIdx in 0..<tracks.count where !tracks[trackIdx].isLocked {
                    for clipIdx in 0..<tracks[trackIdx].clips.count {
                        let clip = tracks[trackIdx].clips[clipIdx]
                        let startSec = CMTimeGetSeconds(clip.timelineStart)
                        if startSec >= rippleThreshold && !targetVideoClipIds.contains(clip.id) && !targetAudioClipIds.contains(clip.id) {
                            let newStartSec = max(0, startSec - totalDeltaSec)
                            tracks[trackIdx].clips[clipIdx].timelineStart = CMTime(seconds: newStartSec, preferredTimescale: 600)
                        }
                    }
                }
            }

            rippleTracks(&videoTracks)
            rippleTracks(&audioTracks)
        }

        if didTrim {
            if isSelection {
                repackSelectionContiguously()
            }
            onModelChanged?()
            if useRipple {
                DebugLogger.shared.log("Trim Inizio Senza Scarto (Q) eseguito a \(String(format: "%.2f", CMTimeGetSeconds(time)))s (Ripple: \(String(format: "%.2f", totalDeltaSec))s)", level: .info)
                return targetTimelineStart
            } else {
                DebugLogger.shared.log("Trim Inizio Con Scarto (Q, modalità A) eseguito a \(String(format: "%.2f", CMTimeGetSeconds(time)))s", level: .info)
                return time
            }
        }
        return nil
    }

    @discardableResult
    public func trimClipEnd(at time: CMTime) -> Bool {
        var didTrim = false
        var targetVideoClipIds: Set<UUID> = []
        var targetAudioClipIds: Set<UUID> = []

        // 1. Identify clips spanning cut time
        for track in videoTracks where !track.isLocked {
            for clip in track.clips where !clip.isEffectivelyLocked {
                let matches = selectedClipIds.contains(clip.id) || (selectedClipIds.isEmpty && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0)
                if matches && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0 {
                    targetVideoClipIds.insert(clip.id)
                    if isLinkActive, let lId = clip.linkGroupId {
                        for aTrack in audioTracks where !aTrack.isLocked {
                            for aClip in aTrack.clips where aClip.linkGroupId == lId && !aClip.isEffectivelyLocked {
                                targetAudioClipIds.insert(aClip.id)
                            }
                        }
                    }
                }
            }
        }

        for track in audioTracks where !track.isLocked {
            for clip in track.clips where !clip.isEffectivelyLocked {
                let matches = selectedClipIds.contains(clip.id) || (selectedClipIds.isEmpty && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0)
                if matches && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0 {
                    targetAudioClipIds.insert(clip.id)
                    if isLinkActive, let lId = clip.linkGroupId {
                        for vTrack in videoTracks where !vTrack.isLocked {
                            for vClip in vTrack.clips where vClip.linkGroupId == lId && !vClip.isEffectivelyLocked {
                                targetVideoClipIds.insert(vClip.id)
                            }
                        }
                    }
                }
            }
        }

        let useRipple = isRippleTrimMode || isSelection

        // 2. Perform Trim End and calculate cut amount (delta)
        var totalDeltaSec: Double = 0
        for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
            for clipIdx in 0..<videoTracks[trackIdx].clips.count {
                let clip = videoTracks[trackIdx].clips[clipIdx]
                if targetVideoClipIds.contains(clip.id) {
                    let delta = CMTimeSubtract(clip.timelineEnd, time)
                    let deltaSec = CMTimeGetSeconds(delta)
                    totalDeltaSec = max(totalDeltaSec, deltaSec)
                    let remainingDur = CMTimeGetSeconds(CMTimeSubtract(time, clip.timelineStart))
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let srcDur = CMTime(seconds: max(0.05, remainingDur * spd), preferredTimescale: 600)
                    videoTracks[trackIdx].clips[clipIdx].sourceOut = CMTimeAdd(clip.sourceIn, srcDur)
                    didTrim = true
                }
            }
        }

        for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
            for clipIdx in 0..<audioTracks[trackIdx].clips.count {
                let clip = audioTracks[trackIdx].clips[clipIdx]
                if targetAudioClipIds.contains(clip.id) {
                    let delta = CMTimeSubtract(clip.timelineEnd, time)
                    let deltaSec = CMTimeGetSeconds(delta)
                    totalDeltaSec = max(totalDeltaSec, deltaSec)
                    let remainingDur = CMTimeGetSeconds(CMTimeSubtract(time, clip.timelineStart))
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let srcDur = CMTime(seconds: max(0.05, remainingDur * spd), preferredTimescale: 600)
                    audioTracks[trackIdx].clips[clipIdx].sourceOut = CMTimeAdd(clip.sourceIn, srcDur)
                    didTrim = true
                }
            }
        }

        // 3. Modalità senza scarto (T): Shift downstream timeline backward by totalDeltaSec
        if useRipple && didTrim && totalDeltaSec > 0.001 {
            let cutSec = CMTimeGetSeconds(time)

            func rippleTracks(_ tracks: inout [TimelineTrack]) {
                for trackIdx in 0..<tracks.count where !tracks[trackIdx].isLocked {
                    for clipIdx in 0..<tracks[trackIdx].clips.count {
                        let clip = tracks[trackIdx].clips[clipIdx]
                        let startSec = CMTimeGetSeconds(clip.timelineStart)
                        if startSec >= cutSec - 0.01 && !targetVideoClipIds.contains(clip.id) && !targetAudioClipIds.contains(clip.id) {
                            let newStartSec = max(cutSec, startSec - totalDeltaSec)
                            tracks[trackIdx].clips[clipIdx].timelineStart = CMTime(seconds: newStartSec, preferredTimescale: 600)
                        }
                    }
                }
            }

            rippleTracks(&videoTracks)
            rippleTracks(&audioTracks)
        }

        if didTrim {
            if isSelection {
                repackSelectionContiguously()
            }
            onModelChanged?()
            if useRipple {
                DebugLogger.shared.log("Trim Fine Senza Scarto (W) eseguito a \(String(format: "%.2f", CMTimeGetSeconds(time)))s (Ripple: \(String(format: "%.2f", totalDeltaSec))s)", level: .info)
            } else {
                DebugLogger.shared.log("Trim Fine Con Scarto (W, modalità A) eseguito a \(String(format: "%.2f", CMTimeGetSeconds(time)))s", level: .info)
            }
        }
        return didTrim
    }

    @discardableResult
    public func splitClip(at time: CMTime) -> Bool {
        var didSplit = false
        var selectedLinkGroupIds: Set<UUID> = []
        if isLinkActive && !selectedClipIds.isEmpty {
            for track in videoTracks {
                for clip in track.clips where selectedClipIds.contains(clip.id) {
                    if let lid = clip.linkGroupId { selectedLinkGroupIds.insert(lid) }
                }
            }
            for track in audioTracks {
                for clip in track.clips where selectedClipIds.contains(clip.id) {
                    if let lid = clip.linkGroupId { selectedLinkGroupIds.insert(lid) }
                }
            }
        }

        var splitRightLinkMap: [UUID: UUID] = [:]
        let linkActive = isLinkActive
        let selectedIds = selectedClipIds

        func split(in tracks: inout [TimelineTrack]) {
            for trackIdx in 0..<tracks.count where !tracks[trackIdx].isLocked {
                var newClips: [TimelineClip] = []
                for clip in tracks[trackIdx].clips {
                    let shouldSplit: Bool
                    if selectedIds.isEmpty {
                        shouldSplit = true
                    } else if selectedIds.contains(clip.id) {
                        shouldSplit = true
                    } else if linkActive, let lId = clip.linkGroupId {
                        shouldSplit = selectedLinkGroupIds.contains(lId)
                    } else {
                        shouldSplit = false
                    }

                    if shouldSplit && !clip.isEffectivelyLocked && CMTimeCompare(clip.timelineStart, time) < 0 && CMTimeCompare(clip.timelineEnd, time) > 0 {
                        didSplit = true
                        let spd = clip.speed > 0 ? clip.speed : 1.0
                        let offsetSec = CMTimeGetSeconds(CMTimeSubtract(time, clip.timelineStart)) * spd
                        let sourceCutPoint = CMTimeAdd(clip.sourceIn, CMTime(seconds: offsetSec, preferredTimescale: 600))
                        let newLinkId: UUID? = clip.linkGroupId.map { lId in
                            if let existing = splitRightLinkMap[lId] { return existing }
                            let created = UUID()
                            splitRightLinkMap[lId] = created
                            return created
                        }

                        let leftClip = TimelineClip(
                            id: UUID(),
                            mediaItem: clip.mediaItem,
                            sourceIn: clip.sourceIn,
                            sourceOut: sourceCutPoint,
                            timelineStart: clip.timelineStart,
                            trackIndex: clip.trackIndex,
                            mediaType: clip.mediaType,
                            orientation: clip.orientation,
                            linkGroupId: clip.linkGroupId,
                            isOrphan: clip.isOrphan,
                            speed: clip.speed,
                            beatMarkers: clip.beatMarkers,
                            beatBPM: clip.beatBPM,
                            markers: clip.markers,
                            priority: clip.priority,
                            isLocked: clip.isLocked,
                            isApproved: clip.isApproved,
                            selectionSourceIn: clip.selectionSourceIn,
                            selectionSourceOut: clip.selectionSourceOut,
                            colorTag: clip.colorTag
                        )

                        let rightClip = TimelineClip(
                            id: UUID(),
                            mediaItem: clip.mediaItem,
                            sourceIn: sourceCutPoint,
                            sourceOut: clip.sourceOut,
                            timelineStart: time,
                            trackIndex: clip.trackIndex,
                            mediaType: clip.mediaType,
                            orientation: clip.orientation,
                            linkGroupId: newLinkId,
                            isOrphan: clip.isOrphan,
                            speed: clip.speed,
                            beatMarkers: clip.beatMarkers,
                            beatBPM: clip.beatBPM,
                            markers: clip.markers,
                            priority: clip.priority,
                            isLocked: clip.isLocked,
                            isApproved: clip.isApproved,
                            selectionSourceIn: clip.selectionSourceIn,
                            selectionSourceOut: clip.selectionSourceOut,
                            colorTag: clip.colorTag
                        )

                        newClips.append(leftClip)
                        newClips.append(rightClip)
                    } else {
                        newClips.append(clip)
                    }
                }
                tracks[trackIdx].clips = newClips
            }
        }

        split(in: &videoTracks)
        split(in: &audioTracks)
        if didSplit {
            onModelChanged?()
            DebugLogger.shared.log("Spezza (S) eseguito a \(String(format: "%.2f", CMTimeGetSeconds(time)))s", level: .info)
        }
        return didSplit
    }

    // MARK: - Close Gaps Between Selected Clips (Cmd + Option + W)
    @discardableResult
    public func closeGapsBetweenSelectedClips() -> Bool {
        guard !selectedClipIds.isEmpty else { return false }

        var didClose = false

        // 1. Process Video Tracks
        for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
            var clips = videoTracks[trackIdx].clips
            guard clips.count > 1 else { continue }

            let selectedIndices = clips.indices.filter { selectedClipIds.contains(clips[$0].id) }.sorted()
            guard selectedIndices.count >= 2 else { continue }

            for i in 1..<selectedIndices.count {
                let prevIdx = selectedIndices[i - 1]
                let currIdx = selectedIndices[i]

                let prevEndSec = CMTimeGetSeconds(clips[prevIdx].timelineEnd)
                let currStartSec = CMTimeGetSeconds(clips[currIdx].timelineStart)

                if currStartSec > prevEndSec + 0.005 {
                    let gapSec = currStartSec - prevEndSec
                    didClose = true

                    for k in currIdx..<clips.count {
                        let oldStart = CMTimeGetSeconds(clips[k].timelineStart)
                        let newStart = max(prevEndSec, oldStart - gapSec)
                        clips[k].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)

                        if isLinkActive, let lId = clips[k].linkGroupId {
                            shiftLinkedAudioClips(linkGroupId: lId, bySeconds: gapSec)
                        }
                    }
                }
            }
            videoTracks[trackIdx].clips = clips
        }

        // 2. Process Audio Tracks
        for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
            var clips = audioTracks[trackIdx].clips
            guard clips.count > 1 else { continue }

            let selectedIndices = clips.indices.filter { selectedClipIds.contains(clips[$0].id) }.sorted()
            guard selectedIndices.count >= 2 else { continue }

            for i in 1..<selectedIndices.count {
                let prevIdx = selectedIndices[i - 1]
                let currIdx = selectedIndices[i]

                let prevEndSec = CMTimeGetSeconds(clips[prevIdx].timelineEnd)
                let currStartSec = CMTimeGetSeconds(clips[currIdx].timelineStart)

                if currStartSec > prevEndSec + 0.005 {
                    let gapSec = currStartSec - prevEndSec
                    didClose = true

                    for k in currIdx..<clips.count {
                        let oldStart = CMTimeGetSeconds(clips[k].timelineStart)
                        let newStart = max(prevEndSec, oldStart - gapSec)
                        clips[k].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)

                        if isLinkActive, let lId = clips[k].linkGroupId {
                            shiftLinkedVideoClips(linkGroupId: lId, bySeconds: gapSec)
                        }
                    }
                }
            }
            audioTracks[trackIdx].clips = clips
        }

        if didClose {
            onModelChanged?()
            DebugLogger.shared.log("Svuotamento spazi tra le clip completato (⌥⌘W)", level: .info)
        }
        return didClose
    }

    private func shiftLinkedAudioClips(linkGroupId: UUID, bySeconds deltaSec: Double) {
        for tIdx in 0..<audioTracks.count where !audioTracks[tIdx].isLocked {
            for cIdx in 0..<audioTracks[tIdx].clips.count {
                if audioTracks[tIdx].clips[cIdx].linkGroupId == linkGroupId {
                    let oldStart = CMTimeGetSeconds(audioTracks[tIdx].clips[cIdx].timelineStart)
                    let newStart = max(0, oldStart - deltaSec)
                    audioTracks[tIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                }
            }
        }
    }

    private func shiftLinkedVideoClips(linkGroupId: UUID, bySeconds deltaSec: Double) {
        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            for cIdx in 0..<videoTracks[tIdx].clips.count {
                if videoTracks[tIdx].clips[cIdx].linkGroupId == linkGroupId {
                    let oldStart = CMTimeGetSeconds(videoTracks[tIdx].clips[cIdx].timelineStart)
                    let newStart = max(0, oldStart - deltaSec)
                    videoTracks[tIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                }
            }
        }
    }

    public func markOrphans(forMediaId mediaId: UUID) {
        var changed = false
        for t in 0..<videoTracks.count {
            for c in 0..<videoTracks[t].clips.count {
                if videoTracks[t].clips[c].mediaItem.id == mediaId {
                    videoTracks[t].clips[c].isOrphan = true
                    videoTracks[t].clips[c].mediaItem.beatAnalysis = nil
                    changed = true
                }
            }
        }
        for t in 0..<audioTracks.count {
            for c in 0..<audioTracks[t].clips.count {
                if audioTracks[t].clips[c].mediaItem.id == mediaId {
                    audioTracks[t].clips[c].isOrphan = true
                    audioTracks[t].clips[c].mediaItem.beatAnalysis = nil
                    changed = true
                }
            }
        }
        if changed {
            onModelChanged?()
        }
    }

    // MARK: - Edge Trim Gesture (In-Place / Ripple)
    @discardableResult
    public func trimClipEdge(
        clipId: UUID,
        isStart: Bool,
        deltaSeconds: Double,
        isVideo: Bool
    ) -> Bool {
        var targetClip: TimelineClip?
        var linkId: UUID?
        let pairedIds: Set<UUID> = isSelection ? resolveSelectionCompanionClipIds(for: [clipId]) : [clipId]

        if isVideo {
            for track in videoTracks {
                if let c = track.clips.first(where: { $0.id == clipId }) {
                    targetClip = c
                    linkId = isLinkActive ? c.linkGroupId : nil
                    break
                }
            }
        } else {
            for track in audioTracks {
                if let c = track.clips.first(where: { $0.id == clipId }) {
                    targetClip = c
                    linkId = isLinkActive ? c.linkGroupId : nil
                    break
                }
            }
        }

        guard let clip = targetClip, !clip.isEffectivelyLocked else { return false }

        let targetBounds = sourceBounds(for: clip)
        let curInSec = CMTimeGetSeconds(clip.sourceIn)
        let curOutSec = CMTimeGetSeconds(clip.sourceOut)
        let curStartSec = CMTimeGetSeconds(clip.timelineStart)
        let curEndSec = CMTimeGetSeconds(clip.timelineEnd)
        let useRipple = isRippleTrimMode || isSelection

        if !useRipple {
            // Modalità A (Con Scarto / Non-Ripple): sposta solo il bordo della clip lasciando o chiudendo il gap senza spostare le clip successive
            let spd = clip.speed > 0 ? clip.speed : 1.0
            func isMatched(_ c: TimelineClip) -> Bool {
                pairedIds.contains(c.id) || (linkId != nil && c.linkGroupId == linkId!)
            }

            func overwriteUnlockedClips(with updatedClips: [TimelineClip], in trackList: inout [TimelineTrack]) {
                for incoming in updatedClips {
                    let tIdx = incoming.trackIndex
                    guard tIdx >= 0, tIdx < trackList.count, !trackList[tIdx].isLocked else { continue }
                    let S = CMTimeGetSeconds(incoming.timelineStart)
                    let E = CMTimeGetSeconds(incoming.timelineEnd)
                    var nextClips: [TimelineClip] = [incoming]
                    for other in trackList[tIdx].clips where other.id != incoming.id {
                        if other.isEffectivelyLocked {
                            nextClips.append(other)
                            continue
                        }
                        let CS = CMTimeGetSeconds(other.timelineStart)
                        let CE = CMTimeGetSeconds(other.timelineEnd)
                        if max(CS, S) >= min(CE, E) - 0.002 {
                            nextClips.append(other)
                            continue
                        }
                        // Completamente coperta
                        if S <= CS + 0.002 && E >= CE - 0.002 {
                            continue
                        }
                        let spd = other.speed > 0 ? other.speed : 1.0
                        // Parte sinistra sopravvive prima di S
                        if CS < S - 0.002 && S - CS > 0.02 {
                            var left = other
                            left.sourceOut = CMTimeAdd(other.sourceIn, CMTime(seconds: (S - CS) * spd, preferredTimescale: 600))
                            nextClips.append(left)
                        }
                        // Parte destra sopravvive dopo E
                        if CE > E + 0.002 && CE - E > 0.02 {
                            var right = other
                            if CS < S - 0.002 {
                                right = TimelineClip(
                                    id: UUID(),
                                    mediaItem: other.mediaItem,
                                    sourceIn: CMTimeAdd(other.sourceIn, CMTime(seconds: (E - CS) * spd, preferredTimescale: 600)),
                                    sourceOut: other.sourceOut,
                                    timelineStart: incoming.timelineEnd,
                                    trackIndex: other.trackIndex,
                                    mediaType: other.mediaType,
                                    orientation: other.orientation,
                                    linkGroupId: nil,
                                    isOrphan: other.isOrphan,
                                    speed: other.speed,
                                    cageIndex: other.cageIndex,
                                    span: other.span,
                                    beatMarkers: other.beatMarkers,
                                    beatBPM: other.beatBPM,
                                    markers: other.markers,
                                    priority: other.priority,
                                    isLocked: other.isLocked,
                                    isApproved: other.isApproved,
                                    selectionSourceIn: other.selectionSourceIn,
                                    selectionSourceOut: other.selectionSourceOut,
                                    colorTag: other.colorTag
                                )
                            } else {
                                right.timelineStart = incoming.timelineEnd
                                right.sourceIn = CMTimeAdd(other.sourceIn, CMTime(seconds: (E - CS) * spd, preferredTimescale: 600))
                            }
                            nextClips.append(right)
                        }
                    }
                    nextClips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                    trackList[tIdx].clips = nextClips
                }
            }

            if isStart {
                // Clamp delta timeline-space: non andare < 0, non sovrapporre clip bloccate/OK, non oltrepassare sourceBounds o dur < 0.1
                let minTargetIn = min(curInSec, targetBounds.minSec)
                var minTimelineDelta = -min(curStartSec, max(0.0, curInSec - minTargetIn) / spd)
                var maxTimelineDelta = max(0.0, (curOutSec - curInSec) / spd - 0.1)

                func constrainLeft(tracks: [TimelineTrack]) {
                    for tr in tracks where !tr.isLocked {
                        for c in tr.clips where isMatched(c) {
                            let cs = CMTimeGetSeconds(c.timelineStart)
                            let cSpd = c.speed > 0 ? c.speed : 1.0
                            let cb = sourceBounds(for: c)
                            let cMinIn = min(CMTimeGetSeconds(c.sourceIn), cb.minSec)
                            let prevLockedEnd = tr.clips
                                .filter { !isMatched($0) && $0.isEffectivelyLocked && CMTimeGetSeconds($0.timelineEnd) <= cs + 0.005 }
                                .map { CMTimeGetSeconds($0.timelineEnd) }
                                .max() ?? 0.0
                            minTimelineDelta = max(minTimelineDelta, -(cs - prevLockedEnd))
                            minTimelineDelta = max(minTimelineDelta, -max(0.0, (CMTimeGetSeconds(c.sourceIn) - cMinIn) / cSpd))
                            maxTimelineDelta = min(maxTimelineDelta, max(0.0, (CMTimeGetSeconds(c.sourceOut) - CMTimeGetSeconds(c.sourceIn)) / cSpd - 0.1))
                        }
                    }
                }
                constrainLeft(tracks: videoTracks)
                constrainLeft(tracks: audioTracks)

                let appliedDelta = max(minTimelineDelta, min(maxTimelineDelta, deltaSeconds))
                guard abs(appliedDelta) > 0.001 else { return false }

                func applyNonRippleStart(to trackList: inout [TimelineTrack]) {
                    var updatedMatched: [TimelineClip] = []
                    for tIdx in 0..<trackList.count where !trackList[tIdx].isLocked {
                        for cIdx in 0..<trackList[tIdx].clips.count {
                            let c = trackList[tIdx].clips[cIdx]
                            if isMatched(c) {
                                let cSpd = c.speed > 0 ? c.speed : 1.0
                                let cb = sourceBounds(for: c)
                                let cMinIn = min(CMTimeGetSeconds(c.sourceIn), cb.minSec)
                                let newStart = max(0.0, CMTimeGetSeconds(c.timelineStart) + appliedDelta)
                                let newIn = max(cMinIn, min(CMTimeGetSeconds(c.sourceOut) - 0.1, CMTimeGetSeconds(c.sourceIn) + appliedDelta * cSpd))
                                trackList[tIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                                trackList[tIdx].clips[cIdx].sourceIn = CMTime(seconds: newIn, preferredTimescale: 600)
                                updatedMatched.append(trackList[tIdx].clips[cIdx])
                            }
                        }
                    }
                    if appliedDelta < 0 {
                        overwriteUnlockedClips(with: updatedMatched, in: &trackList)
                    }
                }
                applyNonRippleStart(to: &videoTracks)
                applyNonRippleStart(to: &audioTracks)
            } else {
                let maxTargetOut = max(curOutSec, targetBounds.maxSec)
                var minTimelineDelta = -max(0.0, (curOutSec - curInSec) / spd - 0.1)
                var maxTimelineDelta = max(0.0, (maxTargetOut - curOutSec) / spd)

                func constrainRight(tracks: [TimelineTrack]) {
                    for tr in tracks where !tr.isLocked {
                        for c in tr.clips where isMatched(c) {
                            let ce = CMTimeGetSeconds(c.timelineEnd)
                            let cSpd = c.speed > 0 ? c.speed : 1.0
                            let cb = sourceBounds(for: c)
                            let cMaxOut = max(CMTimeGetSeconds(c.sourceOut), cb.maxSec)
                            let nextLockedStart = tr.clips
                                .filter { !isMatched($0) && $0.isEffectivelyLocked && CMTimeGetSeconds($0.timelineStart) >= ce - 0.005 }
                                .map { CMTimeGetSeconds($0.timelineStart) }
                                .min()
                            if let ns = nextLockedStart {
                                maxTimelineDelta = min(maxTimelineDelta, max(0.0, ns - ce))
                            }
                            let cMaxMedia = max(0.0, (cMaxOut - CMTimeGetSeconds(c.sourceOut)) / cSpd)
                            maxTimelineDelta = min(maxTimelineDelta, cMaxMedia)
                            minTimelineDelta = max(minTimelineDelta, -max(0.0, (CMTimeGetSeconds(c.sourceOut) - CMTimeGetSeconds(c.sourceIn)) / cSpd - 0.1))
                        }
                    }
                }
                constrainRight(tracks: videoTracks)
                constrainRight(tracks: audioTracks)

                let appliedDelta = max(minTimelineDelta, min(maxTimelineDelta, deltaSeconds))
                guard abs(appliedDelta) > 0.001 else { return false }

                func applyNonRippleEnd(to trackList: inout [TimelineTrack]) {
                    var updatedMatched: [TimelineClip] = []
                    for tIdx in 0..<trackList.count where !trackList[tIdx].isLocked {
                        for cIdx in 0..<trackList[tIdx].clips.count {
                            let c = trackList[tIdx].clips[cIdx]
                            if isMatched(c) {
                                let cSpd = c.speed > 0 ? c.speed : 1.0
                                let cb = sourceBounds(for: c)
                                let cMaxOut = max(CMTimeGetSeconds(c.sourceOut), cb.maxSec)
                                let newOut = min(cMaxOut, max(CMTimeGetSeconds(c.sourceIn) + 0.1, CMTimeGetSeconds(c.sourceOut) + appliedDelta * cSpd))
                                trackList[tIdx].clips[cIdx].sourceOut = CMTime(seconds: newOut, preferredTimescale: 600)
                                updatedMatched.append(trackList[tIdx].clips[cIdx])
                            }
                        }
                    }
                    if appliedDelta > 0 {
                        overwriteUnlockedClips(with: updatedMatched, in: &trackList)
                    }
                }
                applyNonRippleEnd(to: &videoTracks)
                applyNonRippleEnd(to: &audioTracks)
            }

            onModelChanged?()
            return true
        }

        func rippleBlockedByLockedDownstream(durationDelta: Double) -> Bool {
            func trackHasBlockingLock(tracks: [TimelineTrack]) -> Bool {
                for tr in tracks where !tr.isLocked {
                    let hasMatchedOnTrack = tr.clips.contains {
                        pairedIds.contains($0.id) || (linkId != nil && $0.linkGroupId == linkId!)
                    }
                    guard hasMatchedOnTrack else { continue }
                    let sortedDownstream = tr.clips
                        .filter {
                            let isThis = pairedIds.contains($0.id) || (linkId != nil && $0.linkGroupId == linkId!)
                            return !isThis && CMTimeGetSeconds($0.timelineStart) >= curEndSec - 0.01
                        }
                        .sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                    if let firstLocked = sortedDownstream.first(where: { $0.isEffectivelyLocked }) {
                        if durationDelta > 0 {
                            let lockedStart = CMTimeGetSeconds(firstLocked.timelineStart)
                            let unlockedDur = sortedDownstream
                                .prefix(while: { !$0.isEffectivelyLocked })
                                .reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
                            if curEndSec + durationDelta + unlockedDur > lockedStart + 0.005 {
                                return true
                            }
                        } else {
                            // In presenza di clip bloccata/OK successiva, non tirare indietro la timeline oltre i limiti
                            return true
                        }
                    }
                }
                return false
            }
            return trackHasBlockingLock(tracks: videoTracks) || trackHasBlockingLock(tracks: audioTracks)
        }

        if isStart {
            let spd = clip.speed > 0 ? clip.speed : 1.0
            let minIn: Double = min(curInSec, targetBounds.minSec)
            let maxIn: Double = max(minIn, curOutSec - 0.1 * spd)
            let proposedIn = max(minIn, min(maxIn, curInSec + deltaSeconds * spd))
            let proposedInTime = CMTime(seconds: proposedIn, preferredTimescale: 600)
            guard CMTimeCompare(proposedInTime, clip.sourceIn) != 0 else { return false }

            var previewClip = clip
            previewClip.sourceIn = proposedInTime
            let durationDelta = CMTimeGetSeconds(previewClip.timelineEnd) - curEndSec
            guard abs(durationDelta) > 0.0001 else { return false }
            if rippleBlockedByLockedDownstream(durationDelta: durationDelta) { return false }

            func applyStartTrim(to trackList: inout [TimelineTrack], matchIds: Set<UUID>, matchLinkId: UUID?) {
                for tIdx in 0..<trackList.count where !trackList[tIdx].isLocked {
                    for cIdx in 0..<trackList[tIdx].clips.count {
                        let c = trackList[tIdx].clips[cIdx]
                        let isThisClip = matchIds.contains(c.id) || (matchLinkId != nil && c.linkGroupId == matchLinkId!)
                        if isThisClip {
                            if c.id == clip.id {
                                trackList[tIdx].clips[cIdx].sourceIn = proposedInTime
                            } else {
                                let cSpd = c.speed > 0 ? c.speed : 1.0
                                let cb = sourceBounds(for: c)
                                let cMinIn = min(CMTimeGetSeconds(c.sourceIn), cb.minSec)
                                let cNewIn = max(cMinIn, min(CMTimeGetSeconds(c.sourceOut) - 0.1 * cSpd, CMTimeGetSeconds(c.sourceIn) - durationDelta * cSpd))
                                trackList[tIdx].clips[cIdx].sourceIn = CMTime(seconds: cNewIn, preferredTimescale: 600)
                            }
                        } else if !c.isEffectivelyLocked && CMTimeGetSeconds(c.timelineStart) >= curEndSec - 0.01 {
                            let newStart = max(0, CMTimeGetSeconds(c.timelineStart) + durationDelta)
                            trackList[tIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                        }
                    }
                }
            }

            applyStartTrim(to: &videoTracks, matchIds: pairedIds, matchLinkId: linkId)
            applyStartTrim(to: &audioTracks, matchIds: pairedIds, matchLinkId: linkId)

        } else {
            let spd = clip.speed > 0 ? clip.speed : 1.0
            let minDur: Double = 0.1
            let maxTargetOut = max(curOutSec, targetBounds.maxSec)
            let maxDur: Double = max(minDur, (maxTargetOut - curInSec) / spd)
            let curDur = (curOutSec - curInSec) / spd
            let proposedDur = max(minDur, min(maxDur, curDur + deltaSeconds))
            let proposedOutSec = min(maxTargetOut, max(curInSec + minDur * spd, curInSec + proposedDur * spd))
            let proposedOutTime = CMTime(seconds: proposedOutSec, preferredTimescale: 600)
            guard CMTimeCompare(proposedOutTime, clip.sourceOut) != 0 else { return false }

            var previewClip = clip
            previewClip.sourceOut = proposedOutTime
            let durationDelta = CMTimeGetSeconds(previewClip.timelineEnd) - curEndSec
            guard abs(durationDelta) > 0.0001 else { return false }
            if rippleBlockedByLockedDownstream(durationDelta: durationDelta) { return false }

            func applyEndTrim(to trackList: inout [TimelineTrack], matchIds: Set<UUID>, matchLinkId: UUID?) {
                for tIdx in 0..<trackList.count where !trackList[tIdx].isLocked {
                    for cIdx in 0..<trackList[tIdx].clips.count {
                        let c = trackList[tIdx].clips[cIdx]
                        let isThisClip = matchIds.contains(c.id) || (matchLinkId != nil && c.linkGroupId == matchLinkId!)
                        if isThisClip {
                            if c.id == clip.id {
                                trackList[tIdx].clips[cIdx].sourceOut = proposedOutTime
                            } else {
                                let cSpd = c.speed > 0 ? c.speed : 1.0
                                let cIn = CMTimeGetSeconds(c.sourceIn)
                                let cb = sourceBounds(for: c)
                                let cMaxOut = max(CMTimeGetSeconds(c.sourceOut), cb.maxSec)
                                let targetDur = curDur + durationDelta
                                let cNewOut = min(cMaxOut, max(cIn + 0.1 * cSpd, cIn + targetDur * cSpd))
                                trackList[tIdx].clips[cIdx].sourceOut = CMTime(seconds: cNewOut, preferredTimescale: 600)
                            }
                        } else if !c.isEffectivelyLocked && CMTimeGetSeconds(c.timelineStart) >= curEndSec - 0.01 {
                            let newStart = max(0, CMTimeGetSeconds(c.timelineStart) + durationDelta)
                            trackList[tIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                        }
                    }
                }
            }

            applyEndTrim(to: &videoTracks, matchIds: pairedIds, matchLinkId: linkId)
            applyEndTrim(to: &audioTracks, matchIds: pairedIds, matchLinkId: linkId)
        }

        if isSelection {
            repackSelectionContiguously()
        }
        onModelChanged?()
        return true
    }

    // MARK: - Rhythmic Cage & Beat Grid Operations (Montaggio a Gabbie Ritmate)

    public func audioClip(withId clipId: UUID) -> TimelineClip? {
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                return clip
            }
        }
        return nil
    }

    public func setAudioClipBeatMarkers(clipId: UUID, markers: [Double], bpm: Double?) {
        for tIdx in 0..<audioTracks.count {
            if let cIdx = audioTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                audioTracks[tIdx].clips[cIdx].beatMarkers = markers.sorted()
                audioTracks[tIdx].clips[cIdx].beatBPM = bpm
                onModelChanged?()
                return
            }
        }
    }

    // MARK: - Manual Clip Markers (M) on Audio & Video Clips

    public func resolveSelectionCompanionClipIds(for seedIds: Set<UUID>) -> Set<UUID> {
        guard isSelection, !seedIds.isEmpty else { return seedIds }
        var result = seedIds
        var linkGroups: Set<UUID> = []
        var windows: [(url: URL, start: Double, end: Double)] = []

        for track in videoTracks {
            for c in track.clips where seedIds.contains(c.id) {
                if let lid = c.linkGroupId { linkGroups.insert(lid) }
                windows.append((c.mediaItem.url, CMTimeGetSeconds(c.timelineStart), CMTimeGetSeconds(c.timelineEnd)))
            }
        }
        for track in audioTracks {
            for c in track.clips where seedIds.contains(c.id) {
                if let lid = c.linkGroupId { linkGroups.insert(lid) }
                windows.append((c.mediaItem.url, CMTimeGetSeconds(c.timelineStart), CMTimeGetSeconds(c.timelineEnd)))
            }
        }

        func matches(_ c: TimelineClip) -> Bool {
            if let lid = c.linkGroupId, linkGroups.contains(lid) { return true }
            let cs = CMTimeGetSeconds(c.timelineStart)
            let ce = CMTimeGetSeconds(c.timelineEnd)
            return windows.contains { w in
                w.url == c.mediaItem.url && abs(w.start - cs) < 0.025 && abs(w.end - ce) < 0.025
            }
        }

        for track in videoTracks {
            for c in track.clips where matches(c) { result.insert(c.id) }
        }
        for track in audioTracks {
            for c in track.clips where matches(c) { result.insert(c.id) }
        }
        return result
    }

    /// Aggiunge o rimuove (se entro ±0.08s) un marcatore sulle clip audio/video sotto la testina.
    /// In Selezione (`isSelection`), Video e Audio vengono sempre gestiti insieme in modo sincronizzato.
    @discardableResult
    public func toggleClipMarker(at time: CMTime) -> (added: Int, removed: Int, summary: [String]) {
        let effectiveTime = isSmartFilterActive ? realTimelineTime(forDisplayedTime: time) : time
        let timeSec = CMTimeGetSeconds(effectiveTime)
        let selectedIds = isSelection ? resolveSelectionCompanionClipIds(for: selectedClipIds) : selectedClipIds

        // Se almeno una clip selezionata si trova sotto la testina, agisci solo su quelle selezionate (e companion in Selezione)
        var hasSelectedUnderPlayhead = false
        if !selectedIds.isEmpty {
            for track in videoTracks where !track.isLocked {
                if track.clips.contains(where: { selectedIds.contains($0.id) && timeSec >= CMTimeGetSeconds($0.timelineStart) - 0.001 && timeSec <= CMTimeGetSeconds($0.timelineEnd) + 0.001 }) {
                    hasSelectedUnderPlayhead = true
                    break
                }
            }
            if !hasSelectedUnderPlayhead {
                for track in audioTracks where !track.isLocked {
                    if track.clips.contains(where: { selectedIds.contains($0.id) && timeSec >= CMTimeGetSeconds($0.timelineStart) - 0.001 && timeSec <= CMTimeGetSeconds($0.timelineEnd) + 0.001 }) {
                        hasSelectedUnderPlayhead = true
                        break
                    }
                }
            }
        }

        // In Selezione, se almeno uno tra V e A ha già un marcatore in quel punto, rimuovi su entrambi; altrimenti aggiungi su entrambi
        var forceSelectionRemove: Bool? = nil
        if isSelection {
            var anyExisting = false
            for track in (videoTracks + audioTracks) where !track.isLocked {
                for clip in track.clips {
                    if hasSelectedUnderPlayhead && !selectedIds.contains(clip.id) { continue }
                    let cStart = CMTimeGetSeconds(clip.timelineStart)
                    let cEnd = CMTimeGetSeconds(clip.timelineEnd)
                    guard timeSec >= cStart - 0.001 && timeSec <= cEnd + 0.001 else { continue }
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let sourceSec = max(CMTimeGetSeconds(clip.sourceIn), min(CMTimeGetSeconds(clip.sourceOut), CMTimeGetSeconds(clip.sourceIn) + (timeSec - cStart) * spd))
                    if clip.markers.contains(where: { abs($0 - sourceSec) <= 0.08 * spd }) {
                        anyExisting = true
                        break
                    }
                }
                if anyExisting { break }
            }
            forceSelectionRemove = anyExisting
        }

        var added = 0
        var removed = 0
        var summary: [String] = []

        func process(_ tracks: inout [TimelineTrack]) {
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                for cIdx in 0..<tracks[tIdx].clips.count {
                    var clip = tracks[tIdx].clips[cIdx]
                    if hasSelectedUnderPlayhead && !selectedIds.contains(clip.id) { continue }
                    let cStart = CMTimeGetSeconds(clip.timelineStart)
                    let cEnd = CMTimeGetSeconds(clip.timelineEnd)
                    guard timeSec >= cStart - 0.001 && timeSec <= cEnd + 0.001 else { continue }

                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let sourceSec = max(CMTimeGetSeconds(clip.sourceIn), min(CMTimeGetSeconds(clip.sourceOut), CMTimeGetSeconds(clip.sourceIn) + (timeSec - cStart) * spd))
                    let tolSource = 0.08 * spd
                    let existingIdx = clip.markers.firstIndex(where: { abs($0 - sourceSec) <= tolSource })

                    if let forceRemove = forceSelectionRemove {
                        if forceRemove {
                            if let idx = existingIdx {
                                clip.markers.remove(at: idx)
                                removed += 1
                                summary.append("\(clip.mediaItem.name): rimosso a \(formatMarkerTime(timeSec))")
                            }
                        } else if existingIdx == nil {
                            clip.markers.append(sourceSec)
                            clip.markers.sort()
                            added += 1
                            summary.append("\(clip.mediaItem.name): segnato a \(formatMarkerTime(timeSec)) (\(clip.markers.count))")
                        }
                    } else if let idx = existingIdx {
                        clip.markers.remove(at: idx)
                        removed += 1
                        summary.append("\(clip.mediaItem.name): rimosso a \(formatMarkerTime(timeSec))")
                    } else {
                        clip.markers.append(sourceSec)
                        clip.markers.sort()
                        added += 1
                        summary.append("\(clip.mediaItem.name): segnato a \(formatMarkerTime(timeSec)) (\(clip.markers.count))")
                    }
                    tracks[tIdx].clips[cIdx] = clip
                }
            }
        }

        process(&videoTracks)
        process(&audioTracks)

        if added > 0 || removed > 0 {
            onModelChanged?()
        }
        return (added, removed, summary)
    }

    @discardableResult
    public func toggleMarker(clipId: UUID, at timelineSec: Double) -> Bool {
        let targetIds = isSelection ? resolveSelectionCompanionClipIds(for: [clipId]) : [clipId]

        // Determina se il marker va rimosso (in base alla clip cliccata) per mantenerne sincronia su V+A in Selezione
        var shouldRemove: Bool? = nil
        if isSelection {
            for track in (videoTracks + audioTracks) where !track.isLocked {
                if let clip = track.clips.first(where: { $0.id == clipId }) {
                    let cStart = CMTimeGetSeconds(clip.timelineStart)
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let sourceSec = max(CMTimeGetSeconds(clip.sourceIn), min(CMTimeGetSeconds(clip.sourceOut), CMTimeGetSeconds(clip.sourceIn) + (timelineSec - cStart) * spd))
                    shouldRemove = clip.markers.contains(where: { abs($0 - sourceSec) <= 0.12 * spd })
                    break
                }
            }
        }

        func apply(_ tracks: inout [TimelineTrack]) -> Bool {
            var changed = false
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                for cIdx in 0..<tracks[tIdx].clips.count where targetIds.contains(tracks[tIdx].clips[cIdx].id) {
                    var clip = tracks[tIdx].clips[cIdx]
                    let cStart = CMTimeGetSeconds(clip.timelineStart)
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let sourceSec = max(CMTimeGetSeconds(clip.sourceIn), min(CMTimeGetSeconds(clip.sourceOut), CMTimeGetSeconds(clip.sourceIn) + (timelineSec - cStart) * spd))
                    let tolSource = 0.12 * spd
                    let existingIdx = clip.markers.firstIndex(where: { abs($0 - sourceSec) <= tolSource })

                    if let removeAction = shouldRemove {
                        if removeAction {
                            if let idx = existingIdx {
                                clip.markers.remove(at: idx)
                                changed = true
                            }
                        } else if existingIdx == nil {
                            clip.markers.append(sourceSec)
                            clip.markers.sort()
                            changed = true
                        }
                    } else if let idx = existingIdx {
                        clip.markers.remove(at: idx)
                        changed = true
                    } else {
                        clip.markers.append(sourceSec)
                        clip.markers.sort()
                        changed = true
                    }
                    tracks[tIdx].clips[cIdx] = clip
                }
            }
            return changed
        }

        let didV = apply(&videoTracks)
        let didA = apply(&audioTracks)
        if didV || didA {
            onModelChanged?()
            return true
        }
        return false
    }

    @discardableResult
    public func clearMarkers(clipId: UUID) -> Bool {
        let targetIds = isSelection ? resolveSelectionCompanionClipIds(for: [clipId]) : [clipId]
        func clear(_ tracks: inout [TimelineTrack]) -> Bool {
            var changed = false
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                for cIdx in 0..<tracks[tIdx].clips.count where targetIds.contains(tracks[tIdx].clips[cIdx].id) {
                    if !tracks[tIdx].clips[cIdx].markers.isEmpty {
                        tracks[tIdx].clips[cIdx].markers.removeAll()
                        changed = true
                    }
                }
            }
            return changed
        }
        let didV = clear(&videoTracks)
        let didA = clear(&audioTracks)
        if didV || didA {
            onModelChanged?()
            return true
        }
        return false
    }

    @discardableResult
    public func clearAllClipMarkers(at time: CMTime?) -> Int {
        let selectedIds = isSelection ? resolveSelectionCompanionClipIds(for: selectedClipIds) : selectedClipIds
        let timeSec = time.map { CMTimeGetSeconds($0) }
        var clearedCount = 0

        func clearMatching(_ tracks: inout [TimelineTrack]) {
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                for cIdx in 0..<tracks[tIdx].clips.count {
                    let clip = tracks[tIdx].clips[cIdx]
                    guard !clip.markers.isEmpty else { continue }
                    let matchesSelected = !selectedIds.isEmpty && selectedIds.contains(clip.id)
                    let matchesPlayhead = selectedIds.isEmpty && (timeSec.map { $0 >= CMTimeGetSeconds(clip.timelineStart) - 0.001 && $0 <= CMTimeGetSeconds(clip.timelineEnd) + 0.001 } ?? false)
                    if matchesSelected || matchesPlayhead {
                        clearedCount += clip.markers.count
                        tracks[tIdx].clips[cIdx].markers.removeAll()
                    }
                }
            }
        }

        clearMatching(&videoTracks)
        clearMatching(&audioTracks)
        if clearedCount > 0 {
            onModelChanged?()
        }
        return clearedCount
    }

    /// Sposta un marcatore manuale (`M`) o automatico (`beatMarkers`) su qualsiasi clip video/audio non bloccata dalla traccia.
    @discardableResult
    public func moveClipMarker(
        clipId: UUID,
        isBeatMarker: Bool,
        fromSourceSec: Double,
        toSourceSec: Double
    ) -> Double? {
        let targetIds: Set<UUID> = (isSelection && !isBeatMarker)
            ? resolveSelectionCompanionClipIds(for: [clipId])
            : [clipId]

        func update(in tracks: inout [TimelineTrack], matchingIds: Set<UUID>) -> Double? {
            var firstUpdated: Double? = nil
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                for cIdx in 0..<tracks[tIdx].clips.count where matchingIds.contains(tracks[tIdx].clips[cIdx].id) {
                    var clip = tracks[tIdx].clips[cIdx]
                    let sIn = CMTimeGetSeconds(clip.sourceIn)
                    let sOut = CMTimeGetSeconds(clip.sourceOut)
                    let clamped = max(sIn, min(sOut, toSourceSec))

                    var arr = isBeatMarker ? clip.beatMarkers : clip.markers
                    guard let matchIdx = arr.enumerated().min(by: { abs($0.element - fromSourceSec) < abs($1.element - fromSourceSec) })?.offset,
                          abs(arr[matchIdx] - fromSourceSec) <= 0.25 else {
                        continue
                    }

                    arr[matchIdx] = clamped
                    arr.sort()
                    if isBeatMarker {
                        clip.beatMarkers = arr
                    } else {
                        clip.markers = arr
                    }
                    tracks[tIdx].clips[cIdx] = clip
                    if firstUpdated == nil { firstUpdated = clamped }
                }
            }
            return firstUpdated
        }

        let resV = update(in: &videoTracks, matchingIds: targetIds)
        let resA = update(in: &audioTracks, matchingIds: targetIds)
        if let newSec = resV ?? resA {
            onModelChanged?()
            return newSec
        }
        return nil
    }

    /// Elimina un singolo marcatore manuale (`M`) o automatico (`beatMarkers`) da una clip video/audio.
    @discardableResult
    public func removeClipMarker(
        clipId: UUID,
        isBeatMarker: Bool,
        nearSourceSec: Double
    ) -> Bool {
        let targetIds: Set<UUID> = (isSelection && !isBeatMarker)
            ? resolveSelectionCompanionClipIds(for: [clipId])
            : [clipId]

        func remove(in tracks: inout [TimelineTrack], matchingIds: Set<UUID>) -> Bool {
            var didRemove = false
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                for cIdx in 0..<tracks[tIdx].clips.count where matchingIds.contains(tracks[tIdx].clips[cIdx].id) {
                    var clip = tracks[tIdx].clips[cIdx]
                    var arr = isBeatMarker ? clip.beatMarkers : clip.markers
                    guard let matchIdx = arr.enumerated().min(by: { abs($0.element - nearSourceSec) < abs($1.element - nearSourceSec) })?.offset,
                          abs(arr[matchIdx] - nearSourceSec) <= 0.25 else {
                        continue
                    }
                    arr.remove(at: matchIdx)
                    if isBeatMarker {
                        clip.beatMarkers = arr
                    } else {
                        clip.markers = arr
                    }
                    tracks[tIdx].clips[cIdx] = clip
                    didRemove = true
                }
            }
            return didRemove
        }

        let didV = remove(in: &videoTracks, matchingIds: targetIds)
        let didA = remove(in: &audioTracks, matchingIds: targetIds)
        if didV || didA {
            onModelChanged?()
            return true
        }
        return false
    }

    /// Sposta una sbarra statica di `rhythmicCages` ("Timeline Globale") rispettando un intervallo minimo di 0.12s.
    @discardableResult
    public func moveTimelineCageBoundary(from oldSeconds: Double, to newSeconds: Double) -> Double? {
        guard !rhythmicCages.isEmpty else { return nil }
        var boundaries: [Double] = []
        for c in rhythmicCages {
            boundaries.append(c.startSeconds)
            boundaries.append(c.endSeconds)
        }
        boundaries.sort()
        var unique: [Double] = []
        for b in boundaries {
            if let last = unique.last, abs(b - last) < 0.015 { continue }
            unique.append(b)
        }
        guard let idx = unique.enumerated().min(by: { abs($0.element - oldSeconds) < abs($1.element - oldSeconds) })?.offset,
              abs(unique[idx] - oldSeconds) <= 0.25 else { return nil }

        let minBound = idx > 0 ? (unique[idx - 1] + 0.15) : 0.0
        let maxBound = (idx + 1 < unique.count) ? (unique[idx + 1] - 0.15) : Double.greatestFiniteMagnitude
        let clamped = max(minBound, min(maxBound, newSeconds))
        unique[idx] = clamped

        var rebuilt: [RhythmicCage] = []
        for i in 0..<(unique.count - 1) {
            let dur = unique[i + 1] - unique[i]
            if dur >= 0.12 {
                rebuilt.append(RhythmicCage(index: rebuilt.count, startSeconds: unique[i], durationSeconds: dur))
            }
        }
        guard !rebuilt.isEmpty else { return nil }
        rhythmicCages = rebuilt
        onModelChanged?()
        return clamped
    }

    /// Elimina una sbarra statica da `rhythmicCages` unendo le due gabbie adiacenti.
    @discardableResult
    public func removeTimelineCageBoundary(near seconds: Double) -> Bool {
        guard !rhythmicCages.isEmpty else { return false }
        var boundaries: [Double] = []
        for c in rhythmicCages {
            boundaries.append(c.startSeconds)
            boundaries.append(c.endSeconds)
        }
        boundaries.sort()
        var unique: [Double] = []
        for b in boundaries {
            if let last = unique.last, abs(b - last) < 0.015 { continue }
            unique.append(b)
        }
        guard let idx = unique.enumerated().min(by: { abs($0.element - seconds) < abs($1.element - seconds) })?.offset,
              abs(unique[idx] - seconds) <= 0.25 else { return false }

        unique.remove(at: idx)
        if unique.count < 2 {
            rhythmicCages = []
            onModelChanged?()
            return true
        }
        var rebuilt: [RhythmicCage] = []
        for i in 0..<(unique.count - 1) {
            let dur = unique[i + 1] - unique[i]
            if dur >= 0.12 {
                rebuilt.append(RhythmicCage(index: rebuilt.count, startSeconds: unique[i], durationSeconds: dur))
            }
        }
        rhythmicCages = rebuilt
        if isSelection {
            repackSelectionContiguously()
        }
        onModelChanged?()
        return true
    }

    // MARK: - Selection Priority Tagging & Per-Clip Lock
    private func resolveTargetClipIds(at time: CMTime) -> Set<UUID> {
        let selectedIds = selectedClipIds
        if !selectedIds.isEmpty {
            return selectedIds
        }

        let effectiveTime = isSmartFilterActive ? realTimelineTime(forDisplayedTime: time) : time
        let timeSec = CMTimeGetSeconds(effectiveTime)

        var targetIds: Set<UUID> = []
        for track in videoTracks.reversed() where !track.isLocked {
            if let c = track.clips.first(where: { timeSec >= CMTimeGetSeconds($0.timelineStart) - 0.001 && timeSec <= CMTimeGetSeconds($0.timelineEnd) + 0.001 }) {
                targetIds.insert(c.id)
                break
            }
        }
        if targetIds.isEmpty {
            for track in audioTracks where !track.isLocked {
                if let c = track.clips.first(where: { timeSec >= CMTimeGetSeconds($0.timelineStart) - 0.001 && timeSec <= CMTimeGetSeconds($0.timelineEnd) + 0.001 }) {
                    targetIds.insert(c.id)
                    break
                }
            }
        }
        return targetIds
    }

    private func expandLinkedClipIds(_ initialIds: Set<UUID>) -> Set<UUID> {
        var allTargetIds = initialIds
        guard isLinkActive else { return allTargetIds }

        var linkGroups: Set<UUID> = []
        for track in videoTracks {
            for c in track.clips where initialIds.contains(c.id) {
                if let lId = c.linkGroupId { linkGroups.insert(lId) }
            }
        }
        for track in audioTracks {
            for c in track.clips where initialIds.contains(c.id) {
                if let lId = c.linkGroupId { linkGroups.insert(lId) }
            }
        }
        if !linkGroups.isEmpty {
            for track in videoTracks {
                for c in track.clips where c.linkGroupId.map({ linkGroups.contains($0) }) == true {
                    allTargetIds.insert(c.id)
                }
            }
            for track in audioTracks {
                for c in track.clips where c.linkGroupId.map({ linkGroups.contains($0) }) == true {
                    allTargetIds.insert(c.id)
                }
            }
        }
        return allTargetIds
    }

    @discardableResult
    public func toggleClipLock(clipId: UUID) -> (toggledCount: Int, isNowLocked: Bool) {
        return toggleLock(for: [clipId])
    }

    @discardableResult
    public func toggleSelectedClipsLock(at time: CMTime) -> (toggledCount: Int, isNowLocked: Bool) {
        let targets = resolveTargetClipIds(at: time)
        return toggleLock(for: targets)
    }

    private func toggleLock(for initialIds: Set<UUID>) -> (toggledCount: Int, isNowLocked: Bool) {
        guard !initialIds.isEmpty else { return (0, false) }
        let allTargetIds = expandLinkedClipIds(initialIds)

        // Determina target state: esclude clip approvate con '\' (sbloccabili solo con '\').
        var anyUnlocked = false
        for track in videoTracks where !track.isLocked {
            if track.clips.contains(where: { allTargetIds.contains($0.id) && !$0.isApproved && !$0.isLocked }) {
                anyUnlocked = true
                break
            }
        }
        if !anyUnlocked {
            for track in audioTracks where !track.isLocked {
                if track.clips.contains(where: { allTargetIds.contains($0.id) && !$0.isApproved && !$0.isLocked }) {
                    anyUnlocked = true
                    break
                }
            }
        }

        let targetLockedState = anyUnlocked
        var count = 0
        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            for cIdx in 0..<videoTracks[tIdx].clips.count where allTargetIds.contains(videoTracks[tIdx].clips[cIdx].id) && !videoTracks[tIdx].clips[cIdx].isApproved {
                videoTracks[tIdx].clips[cIdx].isLocked = targetLockedState
                count += 1
            }
        }
        for tIdx in 0..<audioTracks.count where !audioTracks[tIdx].isLocked {
            for cIdx in 0..<audioTracks[tIdx].clips.count where allTargetIds.contains(audioTracks[tIdx].clips[cIdx].id) && !audioTracks[tIdx].clips[cIdx].isApproved {
                audioTracks[tIdx].clips[cIdx].isLocked = targetLockedState
                if count == 0 { count += 1 }
            }
        }

        if count > 0 {
            onModelChanged?()
        }
        return (count, targetLockedState)
    }

    @discardableResult
    public func toggleClipApproved(clipId: UUID) -> (toggledCount: Int, isNowApproved: Bool) {
        return toggleApproval(for: [clipId])
    }

    @discardableResult
    public func toggleSelectedClipsApproved(at time: CMTime) -> (toggledCount: Int, isNowApproved: Bool) {
        let targets = resolveTargetClipIds(at: time)
        return toggleApproval(for: targets)
    }

    private func toggleApproval(for initialIds: Set<UUID>) -> (toggledCount: Int, isNowApproved: Bool) {
        guard !initialIds.isEmpty else { return (0, false) }
        let allTargetIds = expandLinkedClipIds(initialIds)

        var anyUnapproved = false
        for track in videoTracks where !track.isLocked {
            if track.clips.contains(where: { allTargetIds.contains($0.id) && !$0.isApproved }) {
                anyUnapproved = true
                break
            }
        }
        if !anyUnapproved {
            for track in audioTracks where !track.isLocked {
                if track.clips.contains(where: { allTargetIds.contains($0.id) && !$0.isApproved }) {
                    anyUnapproved = true
                    break
                }
            }
        }

        let targetApproved = anyUnapproved
        var count = 0
        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            for cIdx in 0..<videoTracks[tIdx].clips.count where allTargetIds.contains(videoTracks[tIdx].clips[cIdx].id) {
                videoTracks[tIdx].clips[cIdx].isApproved = targetApproved
                count += 1
            }
        }
        for tIdx in 0..<audioTracks.count where !audioTracks[tIdx].isLocked {
            for cIdx in 0..<audioTracks[tIdx].clips.count where allTargetIds.contains(audioTracks[tIdx].clips[cIdx].id) {
                audioTracks[tIdx].clips[cIdx].isApproved = targetApproved
                if count == 0 { count += 1 }
            }
        }

        if count > 0 {
            onModelChanged?()
        }
        return (count, targetApproved)
    }

    @discardableResult
    public func setClipPriority(_ priority: Int?, at time: CMTime) -> (updatedCount: Int, summary: String) {
        let targetIds = resolveTargetClipIds(at: time)
        return applyPriority(priority, to: targetIds)
    }

    @discardableResult
    public func setClipPriority(clipId: UUID, priority: Int?) -> (updatedCount: Int, summary: String) {
        return applyPriority(priority, to: [clipId])
    }

    private func applyPriority(_ priority: Int?, to initialIds: Set<UUID>) -> (updatedCount: Int, summary: String) {
        guard !initialIds.isEmpty else { return (0, "") }
        let allTargetIds = expandLinkedClipIds(initialIds)

        var updatedNames: [String] = []
        var updatedCount = 0

        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            for cIdx in 0..<videoTracks[tIdx].clips.count {
                if allTargetIds.contains(videoTracks[tIdx].clips[cIdx].id) {
                    videoTracks[tIdx].clips[cIdx].priority = priority
                    updatedCount += 1
                    updatedNames.append(videoTracks[tIdx].clips[cIdx].mediaItem.name)
                }
            }
        }
        for tIdx in 0..<audioTracks.count where !audioTracks[tIdx].isLocked {
            for cIdx in 0..<audioTracks[tIdx].clips.count {
                if allTargetIds.contains(audioTracks[tIdx].clips[cIdx].id) {
                    audioTracks[tIdx].clips[cIdx].priority = priority
                    if updatedCount == 0 {
                        updatedNames.append(audioTracks[tIdx].clips[cIdx].mediaItem.name)
                    }
                }
            }
        }

        if updatedCount > 0 || !updatedNames.isEmpty {
            onModelChanged?()
        }
        let label: String
        switch priority {
        case 4?: label = "Priorità 4 — Dialogo / Intera"
        case let p?: label = "Priorità \(p)"
        case nil: label = "Priorità rimossa"
        }
        let first = updatedNames.first ?? "Clip"
        let countSuffix = updatedNames.count > 1 ? " (+\(updatedNames.count - 1))" : ""
        return (max(updatedCount, updatedNames.count), "\(first)\(countSuffix) -> \(label)")
    }

    @discardableResult
    public func setClipColor(_ color: ClipColorTag?, at time: CMTime) -> (updatedCount: Int, summary: String) {
        let targetIds = resolveTargetClipIds(at: time)
        return setClipColor(color, forClipIds: targetIds)
    }

    @discardableResult
    public func setClipColor(_ color: ClipColorTag?, forClipIds initialIds: Set<UUID>) -> (updatedCount: Int, summary: String) {
        guard !initialIds.isEmpty else { return (0, "") }
        let allTargetIds = expandLinkedClipIds(initialIds)

        var updatedNames: [String] = []
        var updatedCount = 0

        for tIdx in 0..<videoTracks.count {
            for cIdx in 0..<videoTracks[tIdx].clips.count {
                if allTargetIds.contains(videoTracks[tIdx].clips[cIdx].id) {
                    videoTracks[tIdx].clips[cIdx].colorTag = color
                    updatedCount += 1
                    updatedNames.append(videoTracks[tIdx].clips[cIdx].mediaItem.name)
                }
            }
        }
        for tIdx in 0..<audioTracks.count {
            for cIdx in 0..<audioTracks[tIdx].clips.count {
                if allTargetIds.contains(audioTracks[tIdx].clips[cIdx].id) {
                    audioTracks[tIdx].clips[cIdx].colorTag = color
                    if !videoTracks.contains(where: { $0.clips.contains(where: { $0.linkGroupId != nil && $0.linkGroupId == audioTracks[tIdx].clips[cIdx].linkGroupId && allTargetIds.contains($0.id) }) }) {
                        updatedCount += 1
                        updatedNames.append(audioTracks[tIdx].clips[cIdx].mediaItem.name)
                    }
                }
            }
        }

        if updatedCount > 0 {
            onModelChanged?()
        }
        let label = color?.displayName ?? "Default (Neutro)"
        let first = updatedNames.first ?? "Clip"
        let countSuffix = updatedNames.count > 1 ? " (+\(updatedNames.count - 1))" : ""
        return (updatedCount, "\(first)\(countSuffix) -> \(label)")
    }

    private func formatMarkerTime(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = sec - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    public func clearTimelineCages() {
        rhythmicCages = []
        detectedBPM = nil
        onModelChanged?()
    }

    public func cagesFromAudioClip(_ clip: TimelineClip) -> [RhythmicCage] {
        let beats = clip.visibleBeatTimelineTimes()
        let customBars = clip.visibleMarkersTimelineTimes()
        let rawBars = (beats + customBars).sorted()
        guard !rawBars.isEmpty else { return [] }

        let cStart = CMTimeGetSeconds(clip.timelineStart)
        let cEnd = CMTimeGetSeconds(clip.timelineEnd)
        var points: [Double] = [cStart] + rawBars + [cEnd]
        points.sort()

        // Deduplica sbarre troppo ravvicinate (< 0.12s) preservando sempre i tagli interni espliciti
        var cleaned: [Double] = []
        for t in points where t >= cStart - 0.005 && t <= cEnd + 0.005 {
            if let last = cleaned.last, (t - last) < 0.12 {
                continue
            }
            cleaned.append(t)
        }
        // Assicura che il bordo finale della clip non venga tagliato via se l'ultimo intervallo è valido
        if let last = cleaned.last, (cEnd - last) >= 0.18 {
            cleaned.append(cEnd)
        }
        guard cleaned.count >= 2 else { return [] }

        var cages: [RhythmicCage] = []
        cages.reserveCapacity(cleaned.count - 1)
        for i in 0..<(cleaned.count - 1) {
            let dur = cleaned[i + 1] - cleaned[i]
            if dur >= 0.12 {
                cages.append(RhythmicCage(index: cages.count, startSeconds: cleaned[i], durationSeconds: dur))
            }
        }
        return cages
    }

    /// Costruisce dinamicamente tutte le gabbie dai clip audio editati (beat + marcatori M personalizzati) in ordine di timeline.
    public func cagesFromAllAudioClips() -> [RhythmicCage] {
        let candidateClips = audioTracks
            .filter { $0.isEnabled }
            .flatMap(\.clips)
            .filter { !$0.visibleBeatTimelineTimes().isEmpty || !$0.visibleMarkersTimelineTimes().isEmpty }
            .sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }

        guard !candidateClips.isEmpty else { return [] }

        var result: [RhythmicCage] = []
        for clip in candidateClips {
            let clipCages = cagesFromAudioClip(clip)
            for cage in clipCages {
                if let prev = result.last, cage.startSeconds < prev.endSeconds - 0.05 {
                    continue
                }
                result.append(RhythmicCage(
                    index: result.count,
                    startSeconds: cage.startSeconds,
                    durationSeconds: cage.durationSeconds
                ))
            }
        }
        return result
    }

    public var effectiveDetectedBPM: Double? {
        if let bpm = detectedBPM { return bpm }
        for track in audioTracks {
            for clip in track.clips {
                if let bpm = clip.beatBPM { return bpm }
            }
        }
        return nil
    }

    /// Restituisce le gabbie attive in questo momento guardando la timeline e le tracce audio editate (beat + marcatori M).
    /// Le timeline di Selezione non usano gabbie né sbarre ritmiche.
    public func activeCageIntervals() -> [RhythmicCage] {
        guard !isSelection else { return [] }
        let clipsWithBeats = audioTracks
            .filter { $0.isEnabled }
            .flatMap(\.clips)
            .filter { !$0.visibleBeatTimelineTimes().isEmpty }

        if !clipsWithBeats.isEmpty {
            return cagesFromAllAudioClips()
        }

        if !rhythmicCages.isEmpty {
            let enabledAudioClips = audioTracks.filter { $0.isEnabled }.flatMap(\.clips)
            let baseCages: [RhythmicCage]
            if enabledAudioClips.isEmpty {
                baseCages = rhythmicCages
            } else {
                // Filtra le gabbie affinché seguano l'effettiva estensione delle tracce audio correnti
                let overlapping = rhythmicCages.filter { cage in
                    enabledAudioClips.contains { clip in
                        let cS = CMTimeGetSeconds(clip.timelineStart)
                        let cE = CMTimeGetSeconds(clip.timelineEnd)
                        return min(cE, cage.endSeconds) - max(cS, cage.startSeconds) > 0.05
                    }
                }
                baseCages = overlapping.enumerated().map { idx, c in
                    RhythmicCage(id: c.id, index: idx, startSeconds: c.startSeconds, durationSeconds: c.durationSeconds, assignedClipId: c.assignedClipId, span: c.span)
                }
            }

            // Integra eventuali sbarre personalizzate (M) dalle tracce audio dentro le gabbie della timeline
            let customMarkers = enabledAudioClips.flatMap { $0.visibleMarkersTimelineTimes() }
            if customMarkers.isEmpty || baseCages.isEmpty {
                return baseCages
            }
            var points: [Double] = []
            for c in baseCages {
                points.append(c.startSeconds)
                points.append(c.endSeconds)
            }
            points.append(contentsOf: customMarkers)
            points.sort()
            var merged: [Double] = []
            for p in points {
                if let last = merged.last, (p - last) < 0.08 { continue }
                merged.append(p)
            }
            guard merged.count >= 2 else { return baseCages }
            var splitCages: [RhythmicCage] = []
            for i in 0..<(merged.count - 1) {
                let dur = merged[i + 1] - merged[i]
                if dur >= 0.12 {
                    splitCages.append(RhythmicCage(index: splitCages.count, startSeconds: merged[i], durationSeconds: dur))
                }
            }
            return splitCages
        }

        return cagesFromAllAudioClips()
    }

    /// Restituisce tutti i timestamp (in secondi timeline) delle sbarre attive, ordinati e deduplicati.
    public func activeCageBoundaries() -> [Double] {
        let cages = activeCageIntervals()
        guard !cages.isEmpty else { return [] }
        var raw: [Double] = []
        raw.reserveCapacity(cages.count * 2)
        for cage in cages {
            raw.append(cage.startSeconds)
            raw.append(cage.endSeconds)
        }
        raw.sort()
        var unique: [Double] = []
        for t in raw {
            if let last = unique.last, abs(t - last) < 0.015 {
                continue
            }
            unique.append(t)
        }
        return unique
    }

    public func nearestCageBoundary(to seconds: Double) -> Double? {
        let boundaries = activeCageBoundaries()
        return boundaries.min(by: { abs($0 - seconds) < abs($1 - seconds) })
    }

    public func nearestCageStart(to seconds: Double) -> RhythmicCage? {
        let cages = activeCageIntervals()
        return cages.min(by: { abs($0.startSeconds - seconds) < abs($1.startSeconds - seconds) })
    }

    public func snappedCageEnd(
        forStart startSeconds: Double,
        desiredEndSeconds: Double,
        maxAvailableTimelineDuration: Double
    ) -> Double? {
        let maxEnd = startSeconds + maxAvailableTimelineDuration
        let candidates = activeCageBoundaries().filter { $0 > startSeconds + 0.08 && $0 <= maxEnd + 0.002 }
        return candidates.min(by: { abs($0 - desiredEndSeconds) < abs($1 - desiredEndSeconds) })
    }

    public func cage(at time: CMTime) -> RhythmicCage? {
        let sec = CMTimeGetSeconds(time)
        return activeCageIntervals().first { sec >= $0.startSeconds && sec < $0.endSeconds }
    }

    public func cageIndex(at time: CMTime) -> Int? {
        cage(at: time)?.index
    }

    public func cage(for clipId: UUID) -> RhythmicCage? {
        let cages = activeCageIntervals()
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                if let cIdx = clip.cageIndex, cIdx < cages.count {
                    return cages[cIdx]
                }
                return cage(at: clip.timelineStart)
            }
        }
        return nil
    }

    /// Riempie le gabbie ritmate correnti usando una Selezione (Timeline speciale) con regole v2:
    /// - Priorità 1 -> 2 -> 3 (clip senza tag valgono 1)
    /// - Pass 1: nessuna ripetizione (1 spezzone per clip), rispettando Cronologia Elastica o Random e centrando i marcatori
    /// - Pass 2: solo se restano gabbie vuote, preleva sottospezzoni non sovrapposti dagli spezzoni residui delle clip
    /// - Rispetta clip bloccate (`isLocked`) su V1 e sposta eventuale musica da A1 ad A2 mettendo su A1 l'audio dei video.
    @discardableResult
    public func autoFillCages(
        withSelectionTimeline selTimeline: TimelineModel,
        targetTrackIndex: Int = 0,
        overrideCages: [RhythmicCage]? = nil,
        orderMode: AutoFillOrderMode = .chronological
    ) -> Int {
        return autoFillCagesDetailed(
            withSelectionTimeline: selTimeline,
            targetTrackIndex: targetTrackIndex,
            overrideCages: overrideCages,
            orderMode: orderMode
        ).filledCount
    }

    @discardableResult
    public func autoFillCages(
        withSelectionTimeline selTimeline: TimelineModel,
        targetTrackIndex: Int = 0,
        overrideCages: [RhythmicCage]? = nil,
        orderMode: AutoFillOrderMode = .chronological,
        startFromPlayhead: Double? = nil
    ) -> Int {
        return autoFillCagesDetailed(
            withSelectionTimeline: selTimeline,
            targetTrackIndex: targetTrackIndex,
            overrideCages: overrideCages,
            orderMode: orderMode,
            startFromPlayhead: startFromPlayhead
        ).filledCount
    }

    @discardableResult
    public func autoFillCagesDetailed(
        withSelectionTimeline selTimeline: TimelineModel,
        targetTrackIndex: Int = 0,
        overrideCages: [RhythmicCage]? = nil,
        orderMode: AutoFillOrderMode = .chronological,
        startFromPlayhead: Double? = nil
    ) -> AutoFillResult {
        let clips = (selTimeline.videoTracks.first?.clips ?? []).sorted {
            CMTimeCompare($0.timelineStart, $1.timelineStart) < 0
        }
        let selAudioClips = selTimeline.audioTracks.first?.clips ?? []
        return autoFillCagesCore(
            withTimelineClips: clips,
            selectionAudioClips: selAudioClips,
            targetTrackIndex: targetTrackIndex,
            overrideCages: overrideCages,
            orderMode: orderMode,
            startFromPlayhead: startFromPlayhead
        )
    }

    /// Pre-calcolo leggero (senza modificare la timeline) per mostrare conteggio gabbie vs clip prima di eseguire Auto-Fill.
    public func previewAutoFill(
        withSelectionTimeline selTimeline: TimelineModel,
        targetTrackIndex: Int = 0,
        overrideCages: [RhythmicCage]? = nil,
        orderMode: AutoFillOrderMode = .chronological,
        startFromPlayhead: Double? = nil
    ) -> AutoFillForecast {
        let selectionClips = (selTimeline.videoTracks.first?.clips ?? []).sorted {
            CMTimeCompare($0.timelineStart, $1.timelineStart) < 0
        }
        let selAudioClips = selTimeline.audioTracks.first?.clips ?? []
        let allCages = overrideCages ?? activeCageIntervals()
        let plan = planAutoFill(
            allCages: allCages,
            selectionClips: selectionClips,
            selectionAudioClips: selAudioClips,
            targetTrackIndex: targetTrackIndex,
            orderMode: orderMode,
            startFromPlayhead: startFromPlayhead,
            deterministicPreview: true
        )
        let p4 = selectionClips.filter { $0.priority == 4 }.count
        let p1 = selectionClips.filter { ($0.priority ?? 1) == 1 }.count
        let p2 = selectionClips.filter { $0.priority == 2 }.count
        let p3 = selectionClips.filter { $0.priority == 3 }.count
        return AutoFillForecast(
            totalTargetCages: plan.targetCages.count,
            lockedCagesCount: plan.lockedCagesCount,
            unlockedCagesCount: plan.unlockedCages.count,
            selectionClipCount: selectionClips.count,
            p4Count: p4,
            p1Count: p1,
            p2Count: p2,
            p3Count: p3,
            predictedUniqueCount: plan.primaryUniqueCount,
            predictedSubsegmentCount: plan.subsegmentCount,
            predictedFilledCount: plan.filledCagesCount,
            predictedEmptyCount: max(0, plan.unlockedCages.count - plan.filledCagesCount),
            startingCageNumber: (plan.targetCages.first?.index ?? 0) + 1
        )
    }

    @discardableResult
    public func autoFillCages(
        withTimelineClips selectionClips: [TimelineClip],
        targetTrackIndex: Int = 0,
        overrideCages: [RhythmicCage]? = nil,
        orderMode: AutoFillOrderMode = .chronological,
        startFromPlayhead: Double? = nil
    ) -> Int {
        return autoFillCagesCore(
            withTimelineClips: selectionClips,
            selectionAudioClips: [],
            targetTrackIndex: targetTrackIndex,
            overrideCages: overrideCages,
            orderMode: orderMode,
            startFromPlayhead: startFromPlayhead
        ).filledCount
    }

    private struct AutoFillPoolEntry {
        let clip: TimelineClip
        let effectivePriority: Int
        let hasAudio: Bool
        let selectionOriginIn: Double
        let selectionOriginOut: Double
        var freeRanges: [(start: Double, end: Double)]
        var pass1Used: Bool = false
        var slicesTaken: Int = 0
    }

    private struct AutoFillPlan {
        let targetCages: [RhythmicCage]
        let unlockedCages: [RhythmicCage]
        let lockedCagesCount: Int
        let startAnchorSec: Double
        let preservedClips: [TimelineClip]
        let replacedClips: [TimelineClip]
        let pool: [AutoFillPoolEntry]
        let assignments: [(cage: RhythmicCage, entryIdx: Int, effIn: Double, effOut: Double, span: Int)]
        let filledCagesCount: Int
        let primaryUniqueCount: Int
        let subsegmentCount: Int
    }

    private func subtractUsedRange(
        _ used: (start: Double, end: Double),
        from ranges: [(start: Double, end: Double)]
    ) -> [(start: Double, end: Double)] {
        var next: [(start: Double, end: Double)] = []
        for r in ranges {
            if used.end <= r.start + 0.02 || used.start >= r.end - 0.02 {
                next.append(r)
                continue
            }
            if used.start - r.start >= 0.10 {
                next.append((r.start, used.start))
            }
            if r.end - used.end >= 0.10 {
                next.append((used.end, r.end))
            }
        }
        return next
    }

    private func consumeBestSlice(
        in entry: inout AutoFillPoolEntry,
        neededDur: Double
    ) -> (effIn: Double, effOut: Double)? {
        guard neededDur > 0.02 else { return nil }
        let markers = entry.clip.markers

        var bestRangeIdx: Int? = nil
        var bestChosenIn: Double = 0
        var bestChosenOut: Double = 0
        var foundWithMarker = false

        for (idx, r) in entry.freeRanges.enumerated() {
            let rDur = r.end - r.start
            guard rDur >= neededDur - 0.02 else { continue }
            let actualDur = min(neededDur, rDur)

            let markersInRange = markers.filter { $0 >= r.start - 0.01 && $0 <= r.end + 0.01 }
            if !markersInRange.isEmpty {
                let rMid = (r.start + r.end) * 0.5
                let chosenMarker = markersInRange.min(by: { abs($0 - rMid) < abs($1 - rMid) }) ?? markersInRange[0]
                let desiredIn = chosenMarker - actualDur * 0.5
                let effIn = min(r.end - actualDur, max(r.start, desiredIn))
                bestRangeIdx = idx
                bestChosenIn = effIn
                bestChosenOut = effIn + actualDur
                foundWithMarker = true
                break
            } else if !foundWithMarker && bestRangeIdx == nil {
                bestRangeIdx = idx
                bestChosenIn = r.start
                bestChosenOut = r.start + actualDur
            }
        }

        guard bestRangeIdx != nil else { return nil }
        entry.freeRanges = subtractUsedRange((bestChosenIn, bestChosenOut), from: entry.freeRanges)
        return (bestChosenIn, bestChosenOut)
    }

    private func planAutoFill(
        allCages: [RhythmicCage],
        selectionClips: [TimelineClip],
        selectionAudioClips: [TimelineClip],
        targetTrackIndex: Int,
        orderMode: AutoFillOrderMode,
        startFromPlayhead: Double?,
        deterministicPreview: Bool
    ) -> AutoFillPlan {
        // Scegli gabbie bersaglio (dalla prima oppure dalla gabbia sotto la testina inclusa)
        let targetCages: [RhythmicCage]
        if let ph = startFromPlayhead {
            targetCages = allCages.filter { $0.endSeconds > ph + 0.02 }
        } else {
            targetCages = allCages
        }

        let startAnchorSec = targetCages.first?.startSeconds ?? 0.0
        let existingClips = targetTrackIndex < videoTracks.count ? videoTracks[targetTrackIndex].clips : []

        var preservedClips: [TimelineClip] = []
        var replacedClips: [TimelineClip] = []
        for clip in existingClips {
            let cEnd = CMTimeGetSeconds(clip.timelineEnd)
            let isBeforeWindow = (startFromPlayhead != nil) && (cEnd <= startAnchorSec + 0.02)
            if clip.isEffectivelyLocked || isBeforeWindow {
                preservedClips.append(clip)
            } else {
                replacedClips.append(clip)
            }
        }

        // Classifica gabbie occupate da clip preservate (bloccate o prima della testina) vs libere
        var unlockedCages: [RhythmicCage] = []
        var lockedCagesCount = 0
        for cage in targetCages {
            let isOccupied = preservedClips.contains { preserved in
                let pStart = CMTimeGetSeconds(preserved.timelineStart)
                let pEnd = CMTimeGetSeconds(preserved.timelineEnd)
                return min(pEnd, cage.endSeconds) - max(pStart, cage.startSeconds) > 0.02
            }
            if isOccupied {
                lockedCagesCount += 1
            } else {
                unlockedCages.append(cage)
            }
        }

        // Costruisci pool dalle clip della Selezione, sottraendo gli spezzoni già presenti/bloccati su timeline
        var pool: [AutoFillPoolEntry] = []
        for sClip in selectionClips {
            let maxDur = CMTimeGetSeconds(sClip.mediaItem.duration)
            let origIn = max(0.0, CMTimeGetSeconds(sClip.sourceIn))
            let rawOut = CMTimeGetSeconds(sClip.sourceOut)
            let origOut = min(maxDur, max(origIn, rawOut))
            guard origOut - origIn > 0.05 else { continue }

            var freeRanges: [(start: Double, end: Double)] = [(origIn, origOut)]
            var usedBeforeOrLockedCount = 0
            for preserved in preservedClips where preserved.mediaItem.id == sClip.mediaItem.id {
                let pIn = CMTimeGetSeconds(preserved.sourceIn)
                let pOut = CMTimeGetSeconds(preserved.sourceOut)
                if min(pOut, origOut) - max(pIn, origIn) > 0.02 {
                    usedBeforeOrLockedCount += 1
                }
                freeRanges = subtractUsedRange((pIn, pOut), from: freeRanges)
            }
            guard !freeRanges.isEmpty else { continue }

            let prio = (1...4).contains(sClip.priority ?? 1) ? (sClip.priority ?? 1) : 1
            let hasAudioInSel: Bool
            if !selectionAudioClips.isEmpty {
                hasAudioInSel = sClip.mediaItem.hasAudio && selectionAudioClips.contains { a in
                    if let lId = sClip.linkGroupId, a.linkGroupId == lId { return true }
                    return a.mediaItem.id == sClip.mediaItem.id &&
                           abs(CMTimeGetSeconds(a.timelineStart) - CMTimeGetSeconds(sClip.timelineStart)) < 0.05
                }
            } else {
                hasAudioInSel = sClip.mediaItem.hasAudio
            }

            pool.append(AutoFillPoolEntry(
                clip: sClip,
                effectivePriority: prio,
                hasAudio: hasAudioInSel,
                selectionOriginIn: origIn,
                selectionOriginOut: origOut,
                freeRanges: freeRanges,
                pass1Used: usedBeforeOrLockedCount > 0,
                slicesTaken: usedBeforeOrLockedCount
            ))
        }

        guard !unlockedCages.isEmpty && !pool.isEmpty else {
            return AutoFillPlan(
                targetCages: targetCages,
                unlockedCages: unlockedCages,
                lockedCagesCount: lockedCagesCount,
                startAnchorSec: startAnchorSec,
                preservedClips: preservedClips,
                replacedClips: replacedClips,
                pool: pool,
                assignments: [],
                filledCagesCount: 0,
                primaryUniqueCount: 0,
                subsegmentCount: 0
            )
        }

        let workingOrder: [Int]
        switch (orderMode, deterministicPreview) {
        case (.chronological, _), (.random, true):
            workingOrder = Array(0..<pool.count)
        case (.random, false):
            let p4 = (0..<pool.count).filter { pool[$0].effectivePriority == 4 }.shuffled()
            let p1 = (0..<pool.count).filter { pool[$0].effectivePriority == 1 }.shuffled()
            let p2 = (0..<pool.count).filter { pool[$0].effectivePriority == 2 }.shuffled()
            let p3 = (0..<pool.count).filter { pool[$0].effectivePriority == 3 }.shuffled()
            workingOrder = p4 + p1 + p2 + p3
        }

        var assignedPerCage: [Int: (entryIdx: Int, effIn: Double, effOut: Double, span: Int)] = [:]
        var occupiedSlots: Set<Int> = []
        var unfilledSlotIndices: [Int] = []
        var primaryUniqueCount = 0
        var subsegmentCount = 0

        func hasFittingMarker(in entry: AutoFillPoolEntry, neededDur: Double) -> Bool {
            guard !entry.clip.markers.isEmpty else { return false }
            return entry.freeRanges.contains { r in
                guard (r.end - r.start) >= neededDur - 0.02 else { return false }
                return entry.clip.markers.contains { $0 >= r.start - 0.01 && $0 <= r.end + 0.01 }
            }
        }

        // PASS 0 (Priorità 4 — Dialogo / Intera): inserita intera dall'inizio della prima gabbia libera che la contiene senza tagli e senza colpire clip bloccate; eventuale coda dell'ultima gabbia resta vuota.
        let lastTargetEndSec = targetCages.last?.endSeconds ?? 0.0
        for idx in workingOrder where pool[idx].effectivePriority == 4 && !pool[idx].pass1Used {
            let entry = pool[idx]
            let fullDur = entry.selectionOriginOut - entry.selectionOriginIn
            guard fullDur > 0.05 else { continue }
            let intactSource = entry.freeRanges.contains {
                $0.start <= entry.selectionOriginIn + 0.02 && $0.end >= entry.selectionOriginOut - 0.02
            }
            guard intactSource else { continue }

            for (slotIdx, startCage) in unlockedCages.enumerated() where !occupiedSlots.contains(slotIdx) {
                let startSec = startCage.startSeconds
                let endSec = startSec + fullDur
                guard endSec <= lastTargetEndSec + 0.05 else { continue }

                let hitsPreserved = preservedClips.contains { preserved in
                    let pStart = CMTimeGetSeconds(preserved.timelineStart)
                    let pEnd = CMTimeGetSeconds(preserved.timelineEnd)
                    return min(pEnd, endSec) - max(pStart, startSec) > 0.02
                }
                guard !hitsPreserved else { continue }

                let coveredSlots = unlockedCages.indices.filter { uIdx in
                    let uCage = unlockedCages[uIdx]
                    return min(uCage.endSeconds, endSec) - max(uCage.startSeconds, startSec) > 0.02
                }
                guard coveredSlots.contains(slotIdx), coveredSlots.allSatisfy({ !occupiedSlots.contains($0) }) else {
                    continue
                }

                occupiedSlots.formUnion(coveredSlots)
                assignedPerCage[slotIdx] = (idx, entry.selectionOriginIn, entry.selectionOriginOut, max(1, coveredSlots.count))
                pool[idx].pass1Used = true
                pool[idx].slicesTaken += 1
                pool[idx].freeRanges = []
                primaryUniqueCount += 1
                break
            }
        }

        // PASS 1: 1 spezzone per clip (nessuna ripetizione), priorità 1 -> 2 -> 3 + marcatori
        for (slotIdx, cage) in unlockedCages.enumerated() where !occupiedSlots.contains(slotIdx) {
            let neededDur = cage.durationSeconds
            var matched = false

            for tier in 1...3 {
                for requireMarker in [true, false] {
                    for idx in workingOrder {
                        guard pool[idx].effectivePriority == tier, !pool[idx].pass1Used else { continue }
                        if requireMarker && !hasFittingMarker(in: pool[idx], neededDur: neededDur) { continue }
                        if let slice = consumeBestSlice(in: &pool[idx], neededDur: neededDur) {
                            pool[idx].pass1Used = true
                            pool[idx].slicesTaken += 1
                            occupiedSlots.insert(slotIdx)
                            assignedPerCage[slotIdx] = (idx, slice.effIn, slice.effOut, 1)
                            primaryUniqueCount += 1
                            matched = true
                            break
                        }
                    }
                    if matched { break }
                }
                if matched { break }
            }

            if !matched {
                unfilledSlotIndices.append(slotIdx)
            }
        }

        // PASS 2: Sottospezzoni non sovrapposti se restano gabbie vuote (mai Priorità 4)
        if !unfilledSlotIndices.isEmpty {
            for slotIdx in unfilledSlotIndices {
                let cage = unlockedCages[slotIdx]
                let neededDur = cage.durationSeconds
                var matched = false

                for tier in 1...3 {
                    let candidates = workingOrder
                        .filter { pool[$0].effectivePriority == tier }
                        .sorted { lhs, rhs in
                            let lhsHasMarker = hasFittingMarker(in: pool[lhs], neededDur: neededDur)
                            let rhsHasMarker = hasFittingMarker(in: pool[rhs], neededDur: neededDur)
                            if lhsHasMarker != rhsHasMarker {
                                return lhsHasMarker && !rhsHasMarker
                            }
                            return pool[lhs].slicesTaken < pool[rhs].slicesTaken
                        }

                    for idx in candidates {
                        if let slice = consumeBestSlice(in: &pool[idx], neededDur: neededDur) {
                            pool[idx].slicesTaken += 1
                            occupiedSlots.insert(slotIdx)
                            assignedPerCage[slotIdx] = (idx, slice.effIn, slice.effOut, 1)
                            subsegmentCount += 1
                            matched = true
                            break
                        }
                    }
                    if matched { break }
                }
            }
        }

        var assignments: [(cage: RhythmicCage, entryIdx: Int, effIn: Double, effOut: Double, span: Int)] = []
        for (slotIdx, cage) in unlockedCages.enumerated() {
            if let match = assignedPerCage[slotIdx] {
                assignments.append((cage, match.entryIdx, match.effIn, match.effOut, match.span))
            }
        }

        return AutoFillPlan(
            targetCages: targetCages,
            unlockedCages: unlockedCages,
            lockedCagesCount: lockedCagesCount,
            startAnchorSec: startAnchorSec,
            preservedClips: preservedClips,
            replacedClips: replacedClips,
            pool: pool,
            assignments: assignments,
            filledCagesCount: occupiedSlots.count,
            primaryUniqueCount: primaryUniqueCount,
            subsegmentCount: subsegmentCount
        )
    }

    private func autoFillCagesCore(
        withTimelineClips selectionClips: [TimelineClip],
        selectionAudioClips: [TimelineClip],
        targetTrackIndex: Int,
        overrideCages: [RhythmicCage]?,
        orderMode: AutoFillOrderMode,
        startFromPlayhead: Double?
    ) -> AutoFillResult {
        let allCages = overrideCages ?? activeCageIntervals()
        guard !allCages.isEmpty else {
            DebugLogger.shared.log("Nessuna gabbia ritmata presente. Esegui prima Beat Finder su una traccia audio.", level: .warning)
            return AutoFillResult(filledCount: 0, totalUnlockedCages: 0, lockedCagesCount: 0, primaryUniqueCount: 0, subsegmentCount: 0, remainingEmptyCages: 0, movedAudioToA2: false)
        }
        guard !selectionClips.isEmpty else {
            DebugLogger.shared.log("La selezione è vuota: aggiungi prima delle clip alla Selezione.", level: .warning)
            return AutoFillResult(filledCount: 0, totalUnlockedCages: allCages.count, lockedCagesCount: 0, primaryUniqueCount: 0, subsegmentCount: 0, remainingEmptyCages: allCages.count, movedAudioToA2: false)
        }

        ensureVideoTrack(id: targetTrackIndex)
        ensureAudioTrack(id: 0)

        let plan = planAutoFill(
            allCages: allCages,
            selectionClips: selectionClips,
            selectionAudioClips: selectionAudioClips,
            targetTrackIndex: targetTrackIndex,
            orderMode: orderMode,
            startFromPlayhead: startFromPlayhead,
            deterministicPreview: false
        )

        // Preserva clip bloccate o precedenti alla gabbia di partenza; rimuovi solo le sbloccate nel range
        let replacedLinkIds = Set(plan.replacedClips.compactMap { $0.linkGroupId })
        let preservedLinkIds = Set(plan.preservedClips.compactMap { $0.linkGroupId })

        videoTracks[targetTrackIndex].clips = plan.preservedClips

        audioTracks[0].clips.removeAll { aClip in
            guard !aClip.isEffectivelyLocked else { return false }
            if let lId = aClip.linkGroupId, replacedLinkIds.contains(lId) {
                return true
            }
            return false
        }

        // Sposta su A2 le tracce audio indipendenti (es. la musica) così A1 resta libera per audio video
        var movedAudioToA2 = false
        if targetTrackIndex == 0 {
            var remainingA1: [TimelineClip] = []
            var toMoveToA2: [TimelineClip] = []
            for clip in audioTracks[0].clips {
                let linkedToPreservedV = clip.linkGroupId.map { preservedLinkIds.contains($0) } ?? false
                if clip.isEffectivelyLocked || linkedToPreservedV {
                    remainingA1.append(clip)
                } else {
                    toMoveToA2.append(clip)
                }
            }
            if !toMoveToA2.isEmpty {
                ensureAudioTrack(id: 1)
                audioTracks[0].clips = remainingA1
                for var moved in toMoveToA2 {
                    moved.trackIndex = 1
                    overwriteAndInsert(incoming: moved, trackIndex: 1, isVideo: false)
                }
                audioTracks[1].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                movedAudioToA2 = true
            }
        }

        guard !plan.assignments.isEmpty else {
            onModelChanged?()
            return AutoFillResult(
                filledCount: 0,
                totalUnlockedCages: plan.unlockedCages.count,
                lockedCagesCount: plan.lockedCagesCount,
                primaryUniqueCount: 0,
                subsegmentCount: 0,
                remainingEmptyCages: plan.unlockedCages.count,
                movedAudioToA2: movedAudioToA2
            )
        }

        for item in plan.assignments {
            let entry = plan.pool[item.entryIdx]
            let sClip = entry.clip
            let effIn = CMTime(seconds: item.effIn, preferredTimescale: 600)
            let effOut = CMTime(seconds: item.effOut, preferredTimescale: 600)
            let linkId = (targetTrackIndex == 0 && entry.hasAudio) ? UUID() : nil

            let vClip = TimelineClip(
                mediaItem: sClip.mediaItem,
                sourceIn: effIn,
                sourceOut: effOut,
                timelineStart: item.cage.startTime,
                trackIndex: targetTrackIndex,
                mediaType: .video,
                orientation: sClip.orientation,
                linkGroupId: linkId,
                speed: 1.0,
                cageIndex: item.cage.index,
                span: item.span,
                markers: sClip.markers,
                priority: sClip.priority,
                isLocked: false,
                isApproved: false,
                selectionSourceIn: entry.selectionOriginIn,
                selectionSourceOut: entry.selectionOriginOut,
                colorTag: sClip.colorTag
            )
            videoTracks[targetTrackIndex].clips.append(vClip)

            if targetTrackIndex == 0, entry.hasAudio {
                let aClip = TimelineClip(
                    mediaItem: sClip.mediaItem,
                    sourceIn: effIn,
                    sourceOut: effOut,
                    timelineStart: item.cage.startTime,
                    trackIndex: 0,
                    mediaType: .audio,
                    orientation: .normal,
                    linkGroupId: linkId,
                    speed: 1.0,
                    cageIndex: item.cage.index,
                    span: item.span,
                    markers: sClip.markers,
                    priority: sClip.priority,
                    isLocked: false,
                    isApproved: false,
                    selectionSourceIn: entry.selectionOriginIn,
                    selectionSourceOut: entry.selectionOriginOut,
                    colorTag: sClip.colorTag
                )
                audioTracks[0].clips.append(aClip)
            }
        }

        videoTracks[targetTrackIndex].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        audioTracks[0].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }

        // Attiva automaticamente Modalità Montaggio a Gabbie dopo Auto-Fill
        isCageLockActive = true

        let filledCount = plan.filledCagesCount
        let remainingEmpty = max(0, plan.unlockedCages.count - filledCount)
        DebugLogger.shared.log(
            "Auto-Fill (\(orderMode == .chronological ? "Cronologia" : "Random")): \(filledCount)/\(plan.unlockedCages.count) gabbie riempite (\(plan.primaryUniqueCount) uniche, \(plan.subsegmentCount) sottospezzoni, \(plan.lockedCagesCount) bloccate\(movedAudioToA2 ? ", audio spostato su A2" : "")). Modalità Gabbie ATTIVA.",
            level: .info
        )
        onModelChanged?()

        return AutoFillResult(
            filledCount: filledCount,
            totalUnlockedCages: plan.unlockedCages.count,
            lockedCagesCount: plan.lockedCagesCount,
            primaryUniqueCount: plan.primaryUniqueCount,
            subsegmentCount: plan.subsegmentCount,
            remainingEmptyCages: remainingEmpty,
            movedAudioToA2: movedAudioToA2
        )
    }

    // MARK: - Modalità Montaggio Gabbie (Reordering, Slip, Slow-Mo 1x/2x Cage, Ripple & Roll)

    private func isCageOccupied(_ cage: RhythmicCage, by clips: [TimelineClip]) -> Bool {
        clips.contains { c in
            let s = CMTimeGetSeconds(c.timelineStart)
            let e = CMTimeGetSeconds(c.timelineEnd)
            return min(e, cage.endSeconds) - max(s, cage.startSeconds) > 0.02
        }
    }

    private func syncLinkedAudioClip(for vClip: TimelineClip, startTime: CMTime, sourceIn: CMTime, sourceOut: CMTime, speed: Double, cageIndex: Int?, span: Int) {
        guard isLinkActive, let lId = vClip.linkGroupId else { return }
        for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
            if let acIdx = audioTracks[aIdx].clips.firstIndex(where: { $0.linkGroupId == lId && !$0.isEffectivelyLocked }) {
                audioTracks[aIdx].clips[acIdx].timelineStart = startTime
                audioTracks[aIdx].clips[acIdx].sourceIn = sourceIn
                audioTracks[aIdx].clips[acIdx].sourceOut = sourceOut
                audioTracks[aIdx].clips[acIdx].speed = speed
                audioTracks[aIdx].clips[acIdx].cageIndex = cageIndex
                audioTracks[aIdx].clips[acIdx].span = span
            }
        }
    }

    /// Riordina le clip dentro le gabbie senza mai sovrascrivere: `(C1)(C2)(C3)` con `C3` -> `C2` diventa `(C1)(C3)(C2)`.
    /// Le clip `isLocked` restano inchiodate; quelle sbloccate le scavalcano.
    @discardableResult
    public func reorderClipInCages(clipId: UUID, toCageIndex targetCageIndex: Int) -> Bool {
        let activeCages = activeCageIntervals()
        guard !activeCages.isEmpty, targetCageIndex >= 0 && targetCageIndex < activeCages.count else { return false }

        guard let tIdx = videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clipId }) }),
              !videoTracks[tIdx].isLocked else { return false }

        videoTracks[tIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        guard let draggedArrIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { return false }
        let draggedClip = videoTracks[tIdx].clips[draggedArrIdx]
        guard !draggedClip.isEffectivelyLocked else { return false }

        let targetCage = activeCages[targetCageIndex]
        let lockedClips = videoTracks[tIdx].clips.filter { $0.isEffectivelyLocked }
        if isCageOccupied(targetCage, by: lockedClips) {
            DebugLogger.shared.log("Impossibile spostare nella gabbia \(targetCageIndex + 1): gabbia bloccata 🔒.", level: .warning)
            return false
        }

        var unlockedClips = videoTracks[tIdx].clips.filter { !$0.isEffectivelyLocked }
        guard let draggedUnlockedIdx = unlockedClips.firstIndex(where: { $0.id == clipId }) else { return false }

        // Preserva eventuali gabbie vuote iniziali prima della prima clip sbloccata (a meno che l'utente non stia spostando proprio lì)
        let firstUnlockedCage = unlockedClips.compactMap { resolvedCageIndex(for: $0, in: activeCages) }.min() ?? 0
        let minAllowedCage = min(firstUnlockedCage, targetCageIndex)
        let freeCages = activeCages.filter { $0.index >= minAllowedCage && !isCageOccupied($0, by: lockedClips) }
        guard !freeCages.isEmpty else { return false }

        // Trova lo slot nella sequenza di clip sbloccate corrispondente a `targetCageIndex`
        let targetSlotInUnlocked: Int
        if let freeIdx = freeCages.firstIndex(where: { $0.index == targetCageIndex }) {
            // Se esiste una clip sbloccata che occupa targetCage, prendi il suo indice ordinale
            if let occIdx = unlockedClips.firstIndex(where: { c in
                let s = CMTimeGetSeconds(c.timelineStart)
                let e = CMTimeGetSeconds(c.timelineEnd)
                return min(e, targetCage.endSeconds) - max(s, targetCage.startSeconds) > 0.02
            }) {
                targetSlotInUnlocked = occIdx
            } else {
                targetSlotInUnlocked = min(freeIdx, max(0, unlockedClips.count - 1))
            }
        } else {
            return false
        }

        if targetSlotInUnlocked == draggedUnlockedIdx {
            return false
        }

        let moved = unlockedClips.remove(at: draggedUnlockedIdx)
        unlockedClips.insert(moved, at: min(targetSlotInUnlocked, unlockedClips.count))

        // Riposiziona le clip sbloccate sequenzialmente sulle gabbie libere, saltando eventuali gabbie Lock
        var freeCursor = 0
        for i in 0..<unlockedClips.count {
            var clip = unlockedClips[i]
            let spanCount = max(1, clip.span)
            guard freeCursor < freeCages.count else { break }

            // Per multi-span assicuriamo gabbie fisicamente contigue se disponibili
            var startFreeIdx = freeCursor
            if spanCount > 1 {
                while startFreeIdx + spanCount <= freeCages.count {
                    let firstRealIdx = freeCages[startFreeIdx].index
                    let lastRealIdx = freeCages[startFreeIdx + spanCount - 1].index
                    if lastRealIdx - firstRealIdx == spanCount - 1 {
                        break
                    }
                    startFreeIdx += 1
                }
            }
            guard startFreeIdx < freeCages.count else { break }

            let startCage = freeCages[startFreeIdx]
            let endFreeIdx = min(freeCages.count - 1, startFreeIdx + spanCount - 1)
            let actualSpan: Int
            let combinedDur: Double
            if spanCount > 1 && freeCages[endFreeIdx].index - startCage.index == endFreeIdx - startFreeIdx {
                actualSpan = endFreeIdx - startFreeIdx + 1
                combinedDur = freeCages[endFreeIdx].endSeconds - startCage.startSeconds
            } else {
                actualSpan = 1
                combinedDur = startCage.durationSeconds
            }

            let spd = clip.speed > 0 ? clip.speed : 1.0
            let neededSource = combinedDur * spd
            let bounds = sourceBounds(for: clip)
            var newSrcIn = max(bounds.minSec, min(CMTimeGetSeconds(clip.sourceIn), bounds.maxSec))
            var newSrcOut = newSrcIn + neededSource
            if newSrcOut > bounds.maxSec {
                newSrcOut = bounds.maxSec
                newSrcIn = max(bounds.minSec, newSrcOut - neededSource)
            }

            clip.cageIndex = startCage.index
            clip.span = actualSpan
            clip.timelineStart = startCage.startTime
            clip.sourceIn = CMTime(seconds: newSrcIn, preferredTimescale: 600)
            clip.sourceOut = CMTime(seconds: newSrcOut, preferredTimescale: 600)
            unlockedClips[i] = clip
            syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: spd, cageIndex: clip.cageIndex, span: actualSpan)
            freeCursor = startFreeIdx + actualSpan
        }

        videoTracks[tIdx].clips = (lockedClips + unlockedClips).sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        audioTracks.indices.forEach { aIdx in
            audioTracks[aIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        }
        onModelChanged?()
        DebugLogger.shared.log("Clip '\(draggedClip.mediaItem.name)' riordinata nella gabbia #\(targetCageIndex + 1).", level: .info)
        return true
    }

    /// Cancellazione di una clip con adattamento a cascata delle gabbie sbloccate (Slot Ripple)
    @discardableResult
    public func slotRippleDelete(clipId: UUID) -> Bool {
        guard let tIdx = videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clipId }) }),
              !videoTracks[tIdx].isLocked else {
            return false
        }
        videoTracks[tIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else {
            return false
        }
        guard !videoTracks[tIdx].clips[cIdx].isEffectivelyLocked else {
            DebugLogger.shared.log("Clip bloccata o approvata: sblocca prima di eliminarla.", level: .warning)
            return false
        }

        let removedClip = videoTracks[tIdx].clips.remove(at: cIdx)
        if let lId = removedClip.linkGroupId, isLinkActive {
            for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                audioTracks[aIdx].clips.removeAll { $0.linkGroupId == lId && !$0.isEffectivelyLocked }
            }
        }

        let activeCages = activeCageIntervals()
        if !activeCages.isEmpty {
            let deletedStartCage = removedClip.cageIndex ?? cageIndex(at: removedClip.timelineStart) ?? cIdx
            let lockedClips = videoTracks[tIdx].clips.filter { $0.isEffectivelyLocked }
            let freeCagesAfter = activeCages.filter { $0.index >= deletedStartCage && !isCageOccupied($0, by: lockedClips) }

            var freeCursor = 0
            for i in 0..<videoTracks[tIdx].clips.count {
                var vClip = videoTracks[tIdx].clips[i]
                guard !vClip.isEffectivelyLocked else { continue }
                let oldCageIdx = vClip.cageIndex ?? cageIndex(at: vClip.timelineStart) ?? i
                guard oldCageIdx > deletedStartCage, freeCursor < freeCagesAfter.count else { continue }

                let spanCount = max(1, vClip.span)
                let startCage = freeCagesAfter[freeCursor]
                let endIdx = min(freeCagesAfter.count - 1, freeCursor + spanCount - 1)
                let actualSpan: Int
                let combinedDur: Double
                if spanCount > 1 && freeCagesAfter[endIdx].index - startCage.index == endIdx - freeCursor {
                    actualSpan = endIdx - freeCursor + 1
                    combinedDur = freeCagesAfter[endIdx].endSeconds - startCage.startSeconds
                } else {
                    actualSpan = 1
                    combinedDur = startCage.durationSeconds
                }

                let spd = vClip.speed > 0 ? vClip.speed : 1.0
                let scaledSec = combinedDur * spd
                let bounds = sourceBounds(for: vClip)
                let sIn = max(bounds.minSec, min(CMTimeGetSeconds(vClip.sourceIn), bounds.maxSec))
                let sOut = min(bounds.maxSec, sIn + scaledSec)

                vClip.cageIndex = startCage.index
                vClip.span = actualSpan
                vClip.timelineStart = startCage.startTime
                vClip.sourceIn = CMTime(seconds: sIn, preferredTimescale: 600)
                vClip.sourceOut = CMTime(seconds: sOut, preferredTimescale: 600)
                videoTracks[tIdx].clips[i] = vClip

                syncLinkedAudioClip(for: vClip, startTime: vClip.timelineStart, sourceIn: vClip.sourceIn, sourceOut: vClip.sourceOut, speed: spd, cageIndex: vClip.cageIndex, span: actualSpan)
                freeCursor += actualSpan
            }
        }

        selectedClipIds.remove(clipId)
        DebugLogger.shared.log("Clip rimossa con Slot Ripple: le clip successive sbloccate hanno preso il posto lasciando nessuno spazio.", level: .info)
        if isSelection {
            repackSelectionContiguously()
        }
        onModelChanged?()
        return true
    }

    /// Restituisce bounds e finestre correnti per la barra flottante Slip (`Tab+Drag`) su qualsiasi clip video o audio.
    public func slipClipSelectionBounds(clipId: UUID) -> (sourceIn: Double, sourceOut: Double, sourceDur: Double, boundsMin: Double, boundsMax: Double, markers: [Double], isExtract: Bool)? {
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                let b = sourceBounds(for: clip)
                let sIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
                let sDur = max(0.05, min(b.maxSec - b.minSec, CMTimeGetSeconds(clip.sourceDuration)))
                let markersInRange = clip.markers.filter { $0 >= b.minSec - 0.01 && $0 <= b.maxSec + 0.01 }
                let isExtract = isUsingSelectionExtractBounds(for: clip)
                return (sIn, sIn + sDur, sDur, b.minSec, b.maxSec, markersInRange, isExtract)
            }
        }
        for track in audioTracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                let b = sourceBounds(for: clip)
                let sIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
                let sDur = max(0.05, min(b.maxSec - b.minSec, CMTimeGetSeconds(clip.sourceDuration)))
                let markersInRange = clip.markers.filter { $0 >= b.minSec - 0.01 && $0 <= b.maxSec + 0.01 }
                let isExtract = isUsingSelectionExtractBounds(for: clip)
                return (sIn, sIn + sDur, sDur, b.minSec, b.maxSec, markersInRange, isExtract)
            }
        }
        return nil
    }

    /// Scorre il frammento interno (`Tab+Drag`) dentro i bounds sorgente della clip mantenendo invariati durata e bordi su timeline.
    @discardableResult
    public func slipClipWithinSelection(clipId: UUID, newSourceIn: Double) -> (newIn: Double, newOut: Double)? {
        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            if let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                var clip = videoTracks[tIdx].clips[cIdx]
                guard !clip.isEffectivelyLocked else { return nil }
                let b = sourceBounds(for: clip)
                let exactSourceDur = clip.sourceDuration
                let sourceDurSec = max(0.0, CMTimeGetSeconds(exactSourceDur))
                guard sourceDurSec > 0.001, (b.maxSec - b.minSec) >= sourceDurSec - 0.001 else { return nil }

                let oldSourceIn = clip.sourceIn
                let maxAllowedIn = max(b.minSec, b.maxSec - sourceDurSec)
                let clampedIn = min(maxAllowedIn, max(b.minSec, newSourceIn))
                let newInTime = CMTime(seconds: clampedIn, preferredTimescale: 600)
                let newOutTime = CMTimeAdd(newInTime, exactSourceDur)
                let deltaCM = CMTimeSubtract(newInTime, oldSourceIn)

                clip.sourceIn = newInTime
                clip.sourceOut = newOutTime
                videoTracks[tIdx].clips[cIdx] = clip

                if isLinkActive || isSelection {
                    let paired = isSelection ? resolveSelectionCompanionClipIds(for: [clip.id]) : []
                    for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                        for acIdx in 0..<audioTracks[aIdx].clips.count {
                            let ac = audioTracks[aIdx].clips[acIdx]
                            let matchesLink = isLinkActive && clip.linkGroupId != nil && ac.linkGroupId == clip.linkGroupId
                            if (matchesLink || paired.contains(ac.id)) && !ac.isEffectivelyLocked {
                                shiftAudioOrVideoCompanionSlip(in: &audioTracks, trackIdx: aIdx, clipIdx: acIdx, delta: deltaCM)
                            }
                        }
                    }
                }
                onModelChanged?()
                return (CMTimeGetSeconds(clip.sourceIn), CMTimeGetSeconds(clip.sourceOut))
            }
        }

        for tIdx in 0..<audioTracks.count where !audioTracks[tIdx].isLocked {
            if let cIdx = audioTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                var clip = audioTracks[tIdx].clips[cIdx]
                guard !clip.isEffectivelyLocked else { return nil }
                let b = sourceBounds(for: clip)
                let exactSourceDur = clip.sourceDuration
                let sourceDurSec = max(0.0, CMTimeGetSeconds(exactSourceDur))
                guard sourceDurSec > 0.001, (b.maxSec - b.minSec) >= sourceDurSec - 0.001 else { return nil }

                let oldSourceIn = clip.sourceIn
                let maxAllowedIn = max(b.minSec, b.maxSec - sourceDurSec)
                let clampedIn = min(maxAllowedIn, max(b.minSec, newSourceIn))
                let newInTime = CMTime(seconds: clampedIn, preferredTimescale: 600)
                let newOutTime = CMTimeAdd(newInTime, exactSourceDur)
                let deltaCM = CMTimeSubtract(newInTime, oldSourceIn)

                clip.sourceIn = newInTime
                clip.sourceOut = newOutTime
                audioTracks[tIdx].clips[cIdx] = clip

                if isLinkActive || isSelection {
                    let paired = isSelection ? resolveSelectionCompanionClipIds(for: [clip.id]) : []
                    for vIdx in 0..<videoTracks.count where !videoTracks[vIdx].isLocked {
                        for vcIdx in 0..<videoTracks[vIdx].clips.count {
                            let vc = videoTracks[vIdx].clips[vcIdx]
                            let matchesLink = isLinkActive && clip.linkGroupId != nil && vc.linkGroupId == clip.linkGroupId
                            if (matchesLink || paired.contains(vc.id)) && !vc.isEffectivelyLocked {
                                shiftAudioOrVideoCompanionSlip(in: &videoTracks, trackIdx: vIdx, clipIdx: vcIdx, delta: deltaCM)
                            }
                        }
                    }
                }
                onModelChanged?()
                return (CMTimeGetSeconds(clip.sourceIn), CMTimeGetSeconds(clip.sourceOut))
            }
        }
        return nil
    }

    private func shiftAudioOrVideoCompanionSlip(in tracks: inout [TimelineTrack], trackIdx: Int, clipIdx: Int, delta: CMTime) {
        var comp = tracks[trackIdx].clips[clipIdx]
        let exactDur = comp.sourceDuration
        let durSec = max(0.0, CMTimeGetSeconds(exactDur))
        let b = sourceBounds(for: comp)
        let maxIn = max(b.minSec, b.maxSec - durSec)
        let targetInSec = min(maxIn, max(b.minSec, CMTimeGetSeconds(comp.sourceIn) + CMTimeGetSeconds(delta)))
        let newIn = CMTime(seconds: targetInSec, preferredTimescale: 600)
        comp.sourceIn = newIn
        comp.sourceOut = CMTimeAdd(newIn, exactDur)
        tracks[trackIdx].clips[clipIdx] = comp
    }

    /// Slip Tool: fa scorrere il contenuto interno (`sourceIn`/`Out`) senza modificare i tagli sulla timeline (rispettando eventuali bounds Selezione).
    @discardableResult
    public func slipClip(clipId: UUID, deltaSeconds: Double) -> Bool {
        guard let info = slipClipSelectionBounds(clipId: clipId) else { return false }
        return slipClipWithinSelection(clipId: clipId, newSourceIn: info.sourceIn + deltaSeconds) != nil
    }

    private func resolvedCageIndex(for clip: TimelineClip, in activeCages: [RhythmicCage]) -> Int? {
        guard !activeCages.isEmpty else { return nil }
        let startSec = CMTimeGetSeconds(clip.timelineStart)
        if let explicit = clip.cageIndex,
           explicit >= 0, explicit < activeCages.count,
           abs(activeCages[explicit].startSeconds - startSec) <= 0.35 {
            return explicit
        }
        if let contained = activeCages.firstIndex(where: { startSec >= $0.startSeconds - 0.04 && startSec < $0.endSeconds - 0.04 }) {
            return contained
        }
        return activeCages.enumerated().min(by: {
            abs($0.element.startSeconds - startSec) < abs($1.element.startSeconds - startSec)
        })?.offset
    }

    private func resolvedEndCageIndex(for clip: TimelineClip, startCageIdx: Int, in activeCages: [RhythmicCage]) -> Int {
        guard startCageIdx >= 0, startCageIdx < activeCages.count else { return max(0, activeCages.count - 1) }
        let endSec = CMTimeGetSeconds(clip.timelineEnd)
        let bySpan = min(activeCages.count - 1, startCageIdx + max(1, clip.span) - 1)
        if abs(activeCages[bySpan].endSeconds - endSec) <= 0.15 {
            return bySpan
        }
        var best = startCageIdx
        var bestDist = abs(activeCages[startCageIdx].endSeconds - endSec)
        for e in startCageIdx..<activeCages.count {
            let d = abs(activeCages[e].endSeconds - endSec)
            if d < bestDist {
                bestDist = d
                best = e
            }
        }
        return best
    }

    private func rippleDownstreamClipsInCages(tIdx: Int, afterClipIndex cIdx: Int, startingAtCage startCursor: Int, activeCages: [RhythmicCage]) {
        var cursorCage = startCursor
        var overflowStart = activeCages.last?.endSeconds ?? 0.0
        for i in (cIdx + 1)..<videoTracks[tIdx].clips.count {
            var nextClip = videoTracks[tIdx].clips[i]
            if nextClip.isEffectivelyLocked { break }
            let nSpan = max(1, nextClip.span)
            let nSpd = nextClip.speed > 0 ? nextClip.speed : 1.0
            let nb = sourceBounds(for: nextClip)
            let nIn = max(nb.minSec, min(nb.maxSec, CMTimeGetSeconds(nextClip.sourceIn)))

            if cursorCage < activeCages.count {
                let endCage = min(activeCages.count - 1, cursorCage + nSpan - 1)
                let actualSpan = endCage - cursorCage + 1
                let cDur = activeCages[endCage].endSeconds - activeCages[cursorCage].startSeconds
                let nOut = min(nb.maxSec, nIn + cDur * nSpd)

                nextClip.cageIndex = cursorCage
                nextClip.span = actualSpan
                nextClip.timelineStart = activeCages[cursorCage].startTime
                nextClip.sourceIn = CMTime(seconds: nIn, preferredTimescale: 600)
                nextClip.sourceOut = CMTime(seconds: nOut, preferredTimescale: 600)
                videoTracks[tIdx].clips[i] = nextClip
                syncLinkedAudioClip(for: nextClip, startTime: nextClip.timelineStart, sourceIn: nextClip.sourceIn, sourceOut: nextClip.sourceOut, speed: nSpd, cageIndex: cursorCage, span: actualSpan)

                cursorCage = endCage + 1
                overflowStart = activeCages[endCage].endSeconds
            } else {
                nextClip.cageIndex = nil
                nextClip.timelineStart = CMTime(seconds: overflowStart, preferredTimescale: 600)
                videoTracks[tIdx].clips[i] = nextClip
                syncLinkedAudioClip(for: nextClip, startTime: nextClip.timelineStart, sourceIn: nextClip.sourceIn, sourceOut: nextClip.sourceOut, speed: nSpd, cageIndex: nil, span: nSpan)
                overflowStart += CMTimeGetSeconds(nextClip.duration)
            }
        }
    }

    /// Estende o riduce la copertura di una clip su 1, 2 o più gabbie consecutive, rispettando la durata disponibile e il verso dei tagli.
    @discardableResult
    public func setClipSpan(clipId: UUID, newSpan: Int) -> Bool {
        setClipSpanDetailed(clipId: clipId, newSpan: newSpan).didChange
    }

    @discardableResult
    public func setClipSpanDetailed(clipId: UUID, newSpan: Int, keepSourceInPinned: Bool = false) -> (didChange: Bool, errorMessage: String?) {
        guard newSpan >= 1 else { return (false, nil) }
        let activeCages = activeCageIntervals()
        guard !activeCages.isEmpty else {
            return (false, "Nessuna gabbia ritmata attiva.")
        }

        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            videoTracks[tIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var clip = videoTracks[tIdx].clips[cIdx]
            guard !clip.isEffectivelyLocked else {
                return (false, "Clip bloccata 🔒.")
            }
            guard let startCageIdx = resolvedCageIndex(for: clip, in: activeCages),
                  startCageIdx >= 0, startCageIdx < activeCages.count else {
                return (false, "Clip fuori dalle gabbie.")
            }

            let endCageIdx = startCageIdx + newSpan - 1
            guard endCageIdx < activeCages.count else {
                return (false, "Limite gabbie raggiunto: nessuna gabbia successiva disponibile.")
            }

            let combinedDur = activeCages[endCageIdx].endSeconds - activeCages[startCageIdx].startSeconds
            guard combinedDur > 0 else { return (false, nil) }

            let spd = clip.speed > 0 ? clip.speed : 1.0
            let neededSource = combinedDur * spd
            let b = sourceBounds(for: clip)
            var sIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
            let availFromIn = max(0.0, b.maxSec - sIn)

            if availFromIn < neededSource - 0.005 {
                if !keepSourceInPinned && isUsingSelectionExtractBounds(for: clip) && (b.maxSec - b.minSec) >= neededSource - 0.005 {
                    sIn = max(b.minSec, b.maxSec - neededSource)
                } else {
                    let msg = String(
                        format: "Materiale clip insufficiente per %d gabbie (servono %.1fs originali, disponibili %.1fs).",
                        newSpan, neededSource, availFromIn
                    )
                    DebugLogger.shared.log(msg, level: .warning)
                    return (false, msg)
                }
            }

            let newEndSec = activeCages[endCageIdx].endSeconds
            let clipStartSec = activeCages[startCageIdx].startSeconds
            if !isRippleTrimMode {
                // Con scarto (A) in Modalità Gabbia: sovrascrive clip sbloccate nelle gabbie coperte; blocca se incontra una clip L o OK.
                if (cIdx + 1) < videoTracks[tIdx].clips.count,
                   videoTracks[tIdx].clips[(cIdx + 1)...].contains(where: {
                       $0.isEffectivelyLocked && CMTimeGetSeconds($0.timelineStart) < newEndSec - 0.01
                   }) {
                    let msg = "Espansione bloccata: presente una clip bloccata o approvata 🔒 nelle gabbie coperte."
                    DebugLogger.shared.log(msg, level: .warning)
                    return (false, msg)
                }
                if isLinkActive, let lId = clip.linkGroupId, tIdx == 0, !audioTracks.isEmpty {
                    let hitsLockedAudio = audioTracks[0].clips.contains { aClip in
                        guard aClip.isEffectivelyLocked && aClip.linkGroupId != lId else { return false }
                        let aStart = CMTimeGetSeconds(aClip.timelineStart)
                        let aEnd = CMTimeGetSeconds(aClip.timelineEnd)
                        return max(aStart, clipStartSec) < min(aEnd, newEndSec) - 0.01
                    }
                    if hitsLockedAudio {
                        let msg = "Espansione bloccata: clip audio bloccata o approvata 🔒 su A1."
                        DebugLogger.shared.log(msg, level: .warning)
                        return (false, msg)
                    }
                }
            } else if (cIdx + 1) < videoTracks[tIdx].clips.count {
                let firstLockedAfter = videoTracks[tIdx].clips[(cIdx + 1)...].first(where: { $0.isEffectivelyLocked })
                if let lockedClip = firstLockedAfter {
                    let lockedStart = CMTimeGetSeconds(lockedClip.timelineStart)
                    if newEndSec > lockedStart + 0.02 {
                        let msg = "Espansione bloccata: presente una clip bloccata 🔒 successivamente."
                        DebugLogger.shared.log(msg, level: .warning)
                        return (false, msg)
                    }
                    // Verifica anche che le clip sbloccate intermedie abbiano spazio fino alla clip bloccata
                    let unlockedBetween = videoTracks[tIdx].clips[(cIdx + 1)...].prefix(while: { !$0.isEffectivelyLocked }).reduce(0) { $0 + max(1, $1.span) }
                    if let lockedCageIdx = resolvedCageIndex(for: lockedClip, in: activeCages),
                       endCageIdx + 1 + unlockedBetween > lockedCageIdx {
                        let msg = "Espansione bloccata: spazio insufficiente prima della clip bloccata 🔒."
                        DebugLogger.shared.log(msg, level: .warning)
                        return (false, msg)
                    }
                }
            }

            clip.cageIndex = startCageIdx
            clip.span = newSpan
            clip.timelineStart = activeCages[startCageIdx].startTime
            clip.sourceIn = CMTime(seconds: sIn, preferredTimescale: 600)
            clip.sourceOut = CMTime(seconds: min(b.maxSec, sIn + neededSource), preferredTimescale: 600)
            videoTracks[tIdx].clips[cIdx] = clip
            syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: spd, cageIndex: startCageIdx, span: newSpan)

            if isRippleTrimMode {
                rippleDownstreamClipsInCages(tIdx: tIdx, afterClipIndex: cIdx, startingAtCage: endCageIdx + 1, activeCages: activeCages)
            } else {
                // Sovrascrivi eventuali clip sbloccate coperte dalla nuova estensione in gabbia
                var removedLinkIds: Set<UUID> = []
                var nextClips: [TimelineClip] = []
                for (i, other) in videoTracks[tIdx].clips.enumerated() {
                    if i == cIdx || other.isEffectivelyLocked {
                        nextClips.append(other)
                        continue
                    }
                    let cs = CMTimeGetSeconds(other.timelineStart)
                    let ce = CMTimeGetSeconds(other.timelineEnd)
                    if cs >= newEndSec - 0.01 || ce <= clipStartSec + 0.01 {
                        nextClips.append(other)
                    } else if ce <= newEndSec + 0.01 {
                        if let lId = other.linkGroupId { removedLinkIds.insert(lId) }
                    } else {
                        // Clip multi-gabbia che continua oltre endCageIdx: taglia la testa alla gabbia successiva
                        var trimmed = other
                        let cutDur = newEndSec - cs
                        let oSpd = other.speed > 0 ? other.speed : 1.0
                        let nextCage = endCageIdx + 1
                        let oldEndCage = resolvedEndCageIndex(for: other, startCageIdx: resolvedCageIndex(for: other, in: activeCages) ?? nextCage, in: activeCages)
                        trimmed.timelineStart = CMTime(seconds: newEndSec, preferredTimescale: 600)
                        trimmed.sourceIn = CMTimeAdd(other.sourceIn, CMTime(seconds: cutDur * oSpd, preferredTimescale: 600))
                        if nextCage < activeCages.count {
                            trimmed.cageIndex = nextCage
                            trimmed.span = max(1, oldEndCage - nextCage + 1)
                        }
                        nextClips.append(trimmed)
                        syncLinkedAudioClip(for: trimmed, startTime: trimmed.timelineStart, sourceIn: trimmed.sourceIn, sourceOut: trimmed.sourceOut, speed: oSpd, cageIndex: trimmed.cageIndex, span: trimmed.span)
                    }
                }
                videoTracks[tIdx].clips = nextClips.sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                if !removedLinkIds.isEmpty, isLinkActive {
                    for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                        audioTracks[aIdx].clips.removeAll { aClip in
                            guard !aClip.isEffectivelyLocked, let lId = aClip.linkGroupId else { return false }
                            return removedLinkIds.contains(lId)
                        }
                    }
                }
            }

            DebugLogger.shared.log("Clip '\(clip.mediaItem.name)' estesa su \(newSpan) gabbie ritmate (\(String(format: "%.2f", combinedDur))s).", level: .info)
            onModelChanged?()
            return (true, nil)
        }
        return (false, nil)
    }

    /// Allinea inizio/fine delle clip selezionate (o sotto la testina) alle sbarre gabbia vicine entro `maxFrameThreshold` frame.
    @discardableResult
    public func alignSelectedClipsToCages(at time: CMTime, maxFrameThreshold: Int = 6) -> (alignedCount: Int, skippedCount: Int) {
        let activeCages = activeCageIntervals()
        guard !activeCages.isEmpty, !isSelection else { return (0, 0) }
        let boundaries = activeCageBoundaries()
        guard !boundaries.isEmpty else { return (0, 0) }

        let targetIds = resolveTargetClipIds(at: time)
        guard !targetIds.isEmpty else { return (0, 0) }

        let fps = max(1.0, Double(format.fps))
        let thresholdSec = max(0.08, Double(maxFrameThreshold) / fps)
        let minDur = 0.05

        var alignedCount = 0
        var skippedCount = 0

        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            videoTracks[tIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
            let count = videoTracks[tIdx].clips.count
            guard count > 0 else { continue }

            var desiredStarts: [Double] = videoTracks[tIdx].clips.map { CMTimeGetSeconds($0.timelineStart) }
            var desiredEnds: [Double] = videoTracks[tIdx].clips.map { CMTimeGetSeconds($0.timelineEnd) }
            var wantsStartAlign = Array(repeating: false, count: count)
            var wantsEndAlign = Array(repeating: false, count: count)

            for i in 0..<count {
                let c = videoTracks[tIdx].clips[i]
                guard targetIds.contains(c.id) else { continue }
                guard !c.isEffectivelyLocked else {
                    skippedCount += 1
                    continue
                }
                let s = desiredStarts[i]
                let e = desiredEnds[i]
                if let ns = boundaries.min(by: { abs($0 - s) < abs($1 - s) }),
                   abs(ns - s) <= thresholdSec && abs(ns - s) > 0.0005 {
                    desiredStarts[i] = ns
                    wantsStartAlign[i] = true
                }
                if let ne = boundaries.min(by: { abs($0 - e) < abs($1 - e) }),
                   abs(ne - e) <= thresholdSec && abs(ne - e) > 0.0005 {
                    desiredEnds[i] = ne
                    wantsEndAlign[i] = true
                }
            }

            for i in 0..<count {
                var c = videoTracks[tIdx].clips[i]
                guard wantsStartAlign[i] || wantsEndAlign[i] else { continue }
                let oldStart = CMTimeGetSeconds(c.timelineStart)
                let oldEnd = CMTimeGetSeconds(c.timelineEnd)
                let spd = c.speed > 0 ? c.speed : 1.0
                let b = sourceBounds(for: c)
                let oldIn = CMTimeGetSeconds(c.sourceIn)
                let oldOut = CMTimeGetSeconds(c.sourceOut)

                let prevLimit = i > 0 ? desiredEnds[i - 1] : 0.0
                let nextLimit = (i + 1) < count ? desiredStarts[i + 1] : Double.infinity

                var newStart = oldStart
                var newIn = oldIn
                if wantsStartAlign[i] {
                    let candStart = max(0.0, desiredStarts[i])
                    let neededIn = oldIn + (candStart - oldStart) * spd
                    let canPrev = candStart >= prevLimit - 0.002
                    let canSrc = neededIn >= b.minSec - 0.001 && neededIn <= oldOut - minDur * spd
                    if canPrev && canSrc {
                        newStart = candStart
                        newIn = max(b.minSec, min(oldOut - minDur * spd, neededIn))
                    } else {
                        desiredStarts[i] = oldStart
                    }
                }

                var newEnd = oldEnd
                var newOut = oldOut
                if wantsEndAlign[i] {
                    let candEnd = desiredEnds[i]
                    let neededOut = oldOut + (candEnd - oldEnd) * spd
                    let canNext = candEnd <= nextLimit + 0.002
                    let canSrc = neededOut <= b.maxSec + 0.001 && neededOut >= newIn + minDur * spd
                    if canNext && canSrc {
                        newEnd = candEnd
                        newOut = min(b.maxSec, max(newIn + minDur * spd, neededOut))
                    } else {
                        desiredEnds[i] = oldEnd
                    }
                }

                if newEnd - newStart < minDur {
                    desiredStarts[i] = oldStart
                    desiredEnds[i] = oldEnd
                    skippedCount += 1
                    continue
                }

                if abs(newStart - oldStart) > 0.0005 || abs(newEnd - oldEnd) > 0.0005 {
                    c.timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                    c.sourceIn = CMTime(seconds: newIn, preferredTimescale: 600)
                    c.sourceOut = CMTime(seconds: newOut, preferredTimescale: 600)
                    if let sCage = activeCages.firstIndex(where: { abs($0.startSeconds - newStart) <= 0.008 }),
                       let eCage = activeCages.lastIndex(where: { abs($0.endSeconds - newEnd) <= 0.008 }),
                       eCage >= sCage {
                        c.cageIndex = sCage
                        c.span = eCage - sCage + 1
                    }
                    videoTracks[tIdx].clips[i] = c
                    syncLinkedAudioClip(for: c, startTime: c.timelineStart, sourceIn: c.sourceIn, sourceOut: c.sourceOut, speed: spd, cageIndex: c.cageIndex, span: c.span)
                    alignedCount += 1
                } else {
                    skippedCount += 1
                }
            }
        }

        if alignedCount > 0 {
            onModelChanged?()
        }
        return (alignedCount, skippedCount)
    }

    /// Trascinamento bordo sinistro/destro in Modalità Gabbie + Magnete: concilia micro-vuoti (anche di 1 frame) agganciandosi alla prima
    /// sbarra disponibile e supporta l'espansione multi-gabbia, rispettando Con scarto (sovrascrive) / Senza scarto (sposta) e clip bloccate.
    @discardableResult
    public func trimClipEdgeInCages(clipId: UUID, isStart: Bool, targetTimeSeconds: Double) -> Bool {
        let activeCages = activeCageIntervals()
        let boundaries = activeCageBoundaries()
        guard !activeCages.isEmpty, !boundaries.isEmpty else { return false }

        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            videoTracks[tIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var clip = videoTracks[tIdx].clips[cIdx]
            guard !clip.isEffectivelyLocked else { return false }

            let spd = clip.speed > 0 ? clip.speed : 1.0
            let b = sourceBounds(for: clip)
            let curStartSec = CMTimeGetSeconds(clip.timelineStart)
            let curEndSec = CMTimeGetSeconds(clip.timelineEnd)
            let curInSec = CMTimeGetSeconds(clip.sourceIn)
            let curOutSec = CMTimeGetSeconds(clip.sourceOut)

            if !isStart {
                let maxOutSec = max(curOutSec, b.maxSec)
                let maxEndBySource = curStartSec + max(0.05, (maxOutSec - curInSec) / spd)
                let nextClipStart: Double = (cIdx + 1) < videoTracks[tIdx].clips.count
                    ? CMTimeGetSeconds(videoTracks[tIdx].clips[cIdx + 1].timelineStart)
                    : Double.infinity

                var maxAllowedEndSec = Double.infinity
                if !isRippleTrimMode {
                    // Con scarto (A): sovrascrive sbloccate ma si ferma davanti alla prima clip bloccata/OK
                    if let locked = videoTracks[tIdx].clips[(cIdx + 1)...].first(where: { $0.isEffectivelyLocked }) {
                        maxAllowedEndSec = min(maxAllowedEndSec, CMTimeGetSeconds(locked.timelineStart))
                    }
                    if isLinkActive, let lId = clip.linkGroupId, tIdx == 0, !audioTracks.isEmpty {
                        if let lockedA = audioTracks[0].clips
                            .filter({ $0.isEffectivelyLocked && $0.linkGroupId != lId && CMTimeGetSeconds($0.timelineEnd) > curStartSec + 0.01 })
                            .min(by: { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }) {
                            maxAllowedEndSec = min(maxAllowedEndSec, CMTimeGetSeconds(lockedA.timelineStart))
                        }
                    }
                } else {
                    // Senza scarto (T): chiude liberamente eventuali vuoti fino a `nextClipStart`; oltre spinge solo finché c'è spazio prima di `lockedClip`
                    if let lockedIdx = videoTracks[tIdx].clips[(cIdx + 1)...].firstIndex(where: { $0.isEffectivelyLocked }) {
                        let lockedStart = CMTimeGetSeconds(videoTracks[tIdx].clips[lockedIdx].timelineStart)
                        let unlockedDurBetween = videoTracks[tIdx].clips[(cIdx + 1)..<lockedIdx].reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
                        maxAllowedEndSec = max(nextClipStart, lockedStart - unlockedDurBetween)
                    }
                    if isLinkActive, let lId = clip.linkGroupId, tIdx == 0, !audioTracks.isEmpty {
                        let sortedAudio = audioTracks[0].clips.sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                        if let myAIdx = sortedAudio.firstIndex(where: { $0.linkGroupId == lId }),
                           let lockedAIdx = sortedAudio[(myAIdx + 1)...].firstIndex(where: { $0.isEffectivelyLocked }) {
                            let lockedAStart = CMTimeGetSeconds(sortedAudio[lockedAIdx].timelineStart)
                            let unlockedADur = sortedAudio[(myAIdx + 1)..<lockedAIdx].reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
                            maxAllowedEndSec = min(maxAllowedEndSec, max(nextClipStart, lockedAStart - unlockedADur))
                        }
                    }
                }

                let validEnds = boundaries.filter { bd in
                    bd >= curStartSec + 0.05 &&
                    bd <= maxEndBySource + 0.004 &&
                    bd <= maxAllowedEndSec + 0.004
                }
                guard let bestEndSec = validEnds.min(by: { abs($0 - targetTimeSeconds) < abs($1 - targetTimeSeconds) }) else {
                    return false
                }
                guard abs(bestEndSec - curEndSec) >= 0.002 else { return false }

                let delta = bestEndSec - curEndSec
                let newOutSec = min(maxOutSec, max(curInSec + 0.05 * spd, curOutSec + delta * spd))
                clip.sourceOut = CMTime(seconds: newOutSec, preferredTimescale: 600)
                let actualEndSec = CMTimeGetSeconds(clip.timelineEnd)
                if let sCage = activeCages.firstIndex(where: { abs($0.startSeconds - curStartSec) <= 0.008 }),
                   let eCage = activeCages.lastIndex(where: { abs($0.endSeconds - actualEndSec) <= 0.008 }),
                   eCage >= sCage {
                    clip.cageIndex = sCage
                    clip.span = eCage - sCage + 1
                } else if let eCage = activeCages.lastIndex(where: { abs($0.endSeconds - actualEndSec) <= 0.015 }),
                          let sCage = resolvedCageIndex(for: clip, in: activeCages), eCage >= sCage {
                    clip.cageIndex = sCage
                    clip.span = eCage - sCage + 1
                }
                videoTracks[tIdx].clips[cIdx] = clip
                syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: spd, cageIndex: clip.cageIndex, span: clip.span)

                if isRippleTrimMode {
                    // Chiude un vuoto senza toccare il successivo se non lo raggiunge/supera; se accorcia o supera `nextClipStart`, shifta le sbloccate successive
                    let shiftDelta: Double
                    if actualEndSec < curEndSec - 0.001 {
                        shiftDelta = actualEndSec - curEndSec
                    } else if actualEndSec > nextClipStart + 0.002 {
                        shiftDelta = actualEndSec - nextClipStart
                    } else {
                        shiftDelta = 0.0
                    }

                    if abs(shiftDelta) > 0.001 {
                        var stopTime = Double.infinity
                        for i in (cIdx + 1)..<videoTracks[tIdx].clips.count {
                            if videoTracks[tIdx].clips[i].isEffectivelyLocked {
                                stopTime = CMTimeGetSeconds(videoTracks[tIdx].clips[i].timelineStart)
                                break
                            }
                            let nextStart = max(actualEndSec, CMTimeGetSeconds(videoTracks[tIdx].clips[i].timelineStart) + shiftDelta)
                            videoTracks[tIdx].clips[i].timelineStart = CMTime(seconds: nextStart, preferredTimescale: 600)
                            if let sC = activeCages.firstIndex(where: { abs($0.startSeconds - nextStart) <= 0.015 }) {
                                videoTracks[tIdx].clips[i].cageIndex = sC
                            }
                            if isLinkActive, let lId = videoTracks[tIdx].clips[i].linkGroupId, tIdx == 0 {
                                for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                                    for acIdx in 0..<audioTracks[aIdx].clips.count where audioTracks[aIdx].clips[acIdx].linkGroupId == lId && !audioTracks[aIdx].clips[acIdx].isEffectivelyLocked {
                                        audioTracks[aIdx].clips[acIdx].timelineStart = CMTime(seconds: nextStart, preferredTimescale: 600)
                                    }
                                }
                            }
                        }
                        if isLinkActive, tIdx == 0 {
                            let myLinkId = clip.linkGroupId
                            let linkedIdsMoved = Set(videoTracks[tIdx].clips[(cIdx + 1)...].prefix(while: { !$0.isEffectivelyLocked }).compactMap(\.linkGroupId))
                            for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                                for acIdx in 0..<audioTracks[aIdx].clips.count {
                                    let ac = audioTracks[aIdx].clips[acIdx]
                                    if !ac.isEffectivelyLocked,
                                       ac.linkGroupId != myLinkId,
                                       ac.linkGroupId.map({ !linkedIdsMoved.contains($0) }) ?? true,
                                       CMTimeGetSeconds(ac.timelineStart) >= curEndSec - 0.01,
                                       CMTimeGetSeconds(ac.timelineStart) < stopTime - 0.01 {
                                        let nS = max(0.0, CMTimeGetSeconds(ac.timelineStart) + shiftDelta)
                                        audioTracks[aIdx].clips[acIdx].timelineStart = CMTime(seconds: nS, preferredTimescale: 600)
                                    }
                                }
                            }
                        }
                    }
                } else if bestEndSec > nextClipStart + 0.002 {
                    // Modalità Con Scarto (A): sovrascrivi clip sbloccate coperte fino a `bestEndSec`
                    var removedLinkIds: Set<UUID> = []
                    var nextClips: [TimelineClip] = []
                    for (i, other) in videoTracks[tIdx].clips.enumerated() {
                        if i == cIdx || other.isEffectivelyLocked {
                            nextClips.append(other)
                            continue
                        }
                        let cs = CMTimeGetSeconds(other.timelineStart)
                        let ce = CMTimeGetSeconds(other.timelineEnd)
                        if cs >= bestEndSec - 0.002 || ce <= curStartSec + 0.002 {
                            nextClips.append(other)
                        } else if ce <= bestEndSec + 0.002 {
                            if let lId = other.linkGroupId { removedLinkIds.insert(lId) }
                        } else {
                            var trimmed = other
                            let cutDur = bestEndSec - cs
                            let oSpd = other.speed > 0 ? other.speed : 1.0
                            trimmed.timelineStart = CMTime(seconds: bestEndSec, preferredTimescale: 600)
                            trimmed.sourceIn = CMTimeAdd(other.sourceIn, CMTime(seconds: cutDur * oSpd, preferredTimescale: 600))
                            if let sC = activeCages.firstIndex(where: { abs($0.startSeconds - bestEndSec) <= 0.015 }),
                               let eC = activeCages.lastIndex(where: { abs($0.endSeconds - ce) <= 0.015 }), eC >= sC {
                                trimmed.cageIndex = sC
                                trimmed.span = eC - sC + 1
                            }
                            nextClips.append(trimmed)
                            syncLinkedAudioClip(for: trimmed, startTime: trimmed.timelineStart, sourceIn: trimmed.sourceIn, sourceOut: trimmed.sourceOut, speed: oSpd, cageIndex: trimmed.cageIndex, span: trimmed.span)
                        }
                    }
                    videoTracks[tIdx].clips = nextClips.sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                    if !removedLinkIds.isEmpty, isLinkActive {
                        for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                            audioTracks[aIdx].clips.removeAll { aClip in
                                guard !aClip.isEffectivelyLocked, let lId = aClip.linkGroupId else { return false }
                                return removedLinkIds.contains(lId)
                            }
                        }
                    }
                }

                onModelChanged?()
                return true
            } else {
                // Bordo sinistro: aggancia alla sbarra più vicina valida (chiude micro-vuoti a sinistra o espande su gabbie precedenti)
                let minInSec = min(curInSec, b.minSec)
                let minStartBySource = curEndSec - max(0.05, (curOutSec - minInSec) / spd)
                let prevClipEnd: Double = cIdx > 0 ? CMTimeGetSeconds(videoTracks[tIdx].clips[cIdx - 1].timelineEnd) : 0.0

                var minAllowedStartSec: Double = 0.0
                if isRippleTrimMode {
                    minAllowedStartSec = prevClipEnd
                } else {
                    if let lockedPrev = videoTracks[tIdx].clips[..<cIdx].last(where: { $0.isEffectivelyLocked }) {
                        minAllowedStartSec = max(minAllowedStartSec, CMTimeGetSeconds(lockedPrev.timelineEnd))
                    }
                    if isLinkActive, let lId = clip.linkGroupId, tIdx == 0, !audioTracks.isEmpty {
                        if let lockedA = audioTracks[0].clips
                            .filter({ $0.isEffectivelyLocked && $0.linkGroupId != lId && CMTimeGetSeconds($0.timelineStart) < curEndSec - 0.01 })
                            .max(by: { CMTimeCompare($0.timelineEnd, $1.timelineEnd) < 0 }) {
                            minAllowedStartSec = max(minAllowedStartSec, CMTimeGetSeconds(lockedA.timelineEnd))
                        }
                    }
                }

                let validStarts = boundaries.filter { bd in
                    bd <= curEndSec - 0.05 &&
                    bd >= max(0.0, minStartBySource - 0.004) &&
                    bd >= minAllowedStartSec - 0.004
                }
                guard let bestStartSec = validStarts.min(by: { abs($0 - targetTimeSeconds) < abs($1 - targetTimeSeconds) }) else {
                    return false
                }
                guard abs(bestStartSec - curStartSec) >= 0.002 else { return false }

                let delta = bestStartSec - curStartSec
                let newInSec = max(minInSec, min(curOutSec - 0.05 * spd, curInSec + delta * spd))
                clip.timelineStart = CMTime(seconds: bestStartSec, preferredTimescale: 600)
                clip.sourceIn = CMTime(seconds: newInSec, preferredTimescale: 600)
                if let sCage = activeCages.firstIndex(where: { abs($0.startSeconds - bestStartSec) <= 0.008 }),
                   let eCage = activeCages.lastIndex(where: { abs($0.endSeconds - curEndSec) <= 0.008 }),
                   eCage >= sCage {
                    clip.cageIndex = sCage
                    clip.span = eCage - sCage + 1
                } else if let sCage = activeCages.firstIndex(where: { abs($0.startSeconds - bestStartSec) <= 0.015 }) {
                    let eCage = resolvedEndCageIndex(for: clip, startCageIdx: sCage, in: activeCages)
                    clip.cageIndex = sCage
                    clip.span = max(1, eCage - sCage + 1)
                }
                videoTracks[tIdx].clips[cIdx] = clip
                syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: spd, cageIndex: clip.cageIndex, span: clip.span)

                if !isRippleTrimMode && bestStartSec < prevClipEnd - 0.002 {
                    var removedLinkIds: Set<UUID> = []
                    var nextClips: [TimelineClip] = []
                    for (i, other) in videoTracks[tIdx].clips.enumerated() {
                        if i == cIdx || other.isEffectivelyLocked {
                            nextClips.append(other)
                            continue
                        }
                        let cs = CMTimeGetSeconds(other.timelineStart)
                        let ce = CMTimeGetSeconds(other.timelineEnd)
                        if ce <= bestStartSec + 0.002 || cs >= curEndSec - 0.002 {
                            nextClips.append(other)
                        } else if cs >= bestStartSec - 0.002 {
                            if let lId = other.linkGroupId { removedLinkIds.insert(lId) }
                        } else {
                            var trimmed = other
                            let newDur = max(0.05, bestStartSec - cs)
                            let oSpd = other.speed > 0 ? other.speed : 1.0
                            trimmed.sourceOut = CMTimeAdd(other.sourceIn, CMTime(seconds: newDur * oSpd, preferredTimescale: 600))
                            if let sC = activeCages.firstIndex(where: { abs($0.startSeconds - cs) <= 0.015 }),
                               let eC = activeCages.lastIndex(where: { abs($0.endSeconds - bestStartSec) <= 0.015 }), eC >= sC {
                                trimmed.cageIndex = sC
                                trimmed.span = eC - sC + 1
                            }
                            nextClips.append(trimmed)
                            syncLinkedAudioClip(for: trimmed, startTime: trimmed.timelineStart, sourceIn: trimmed.sourceIn, sourceOut: trimmed.sourceOut, speed: oSpd, cageIndex: trimmed.cageIndex, span: trimmed.span)
                        }
                    }
                    videoTracks[tIdx].clips = nextClips.sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
                    if !removedLinkIds.isEmpty, isLinkActive {
                        for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                            audioTracks[aIdx].clips.removeAll { aClip in
                                guard !aClip.isEffectivelyLocked, let lId = aClip.linkGroupId else { return false }
                                return removedLinkIds.contains(lId)
                            }
                        }
                    }
                }

                onModelChanged?()
                return true
            }
        }
        return false
    }

    /// Alterna la velocità della clip (`100% <-> 50%`) restando **dentro la gabbia attuale** (`R` / `⌥S`).
    @discardableResult
    public func toggleClipSpeed(clipId: UUID) -> Double? {
        toggleClipSpeedDetailed(clipId: clipId).newSpeed
    }

    @discardableResult
    public func toggleClipSpeedDetailed(clipId: UUID) -> (newSpeed: Double?, errorMessage: String?) {
        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            if let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                var clip = videoTracks[tIdx].clips[cIdx]
                guard !clip.isEffectivelyLocked else { return (nil, "Clip bloccata 🔒.") }
                let newSpeed: Double = (abs(clip.speed - 1.0) < 0.01) ? 0.5 : 1.0

                if newSpeed < 1.0 && !canSlowMoClip(clip) {
                    let reqFPS = Self.formatFPSLabel(format.fps * 2.0)
                    let clipFPS = Self.formatFPSLabel(clip.mediaItem.frameRate)
                    let msg = "Slow-Mo bloccato: '\(clip.mediaItem.name)' è a \(clipFPS)fps (servono almeno \(reqFPS)fps per timeline a \(Self.formatFPSLabel(format.fps))fps)."
                    DebugLogger.shared.log(msg, level: .warning)
                    return (nil, msg)
                }

                let timelineDur = CMTimeGetSeconds(clip.duration)
                let newSourceDur = timelineDur * newSpeed
                let b = sourceBounds(for: clip)
                var newIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
                var newOut = newIn + newSourceDur

                if newOut > b.maxSec {
                    let maxShift = max(b.minSec, b.maxSec - newSourceDur)
                    if newSourceDur <= (b.maxSec - b.minSec) + 0.01 {
                        newIn = maxShift
                        newOut = min(b.maxSec, newIn + newSourceDur)
                    } else {
                        let msg = "Clip troppo corta per velocità \(Int(newSpeed * 100))% in questa gabbia."
                        DebugLogger.shared.log(msg, level: .warning)
                        return (nil, msg)
                    }
                }

                clip.speed = newSpeed
                clip.sourceIn = CMTime(seconds: newIn, preferredTimescale: 600)
                clip.sourceOut = CMTime(seconds: newOut, preferredTimescale: 600)
                videoTracks[tIdx].clips[cIdx] = clip

                syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: newSpeed, cageIndex: clip.cageIndex, span: clip.span)
                DebugLogger.shared.log("Velocità clip '\(clip.mediaItem.name)' in gabbia impostata a \(Int(newSpeed * 100))%.", level: .info)
                onModelChanged?()
                return (newSpeed, nil)
            }
        }
        return (nil, nil)
    }

    /// Alterna Slow-Mo 50% <-> 100% con scarto (Ripple) (`⌘R`):
    /// - Non sposta MAI l'inizio della clip (`timelineStart` e `sourceIn` restano ancorati).
    /// - Con Modalità Gabbie ON: termina alla prima sbarra disponibile (rispettando `sourceBounds`).
    /// - Con Modalità Gabbie OFF (o nessuna gabbia): termina alla durata naturale risultante dal cambio velocità.
    /// - Shifta avanti/indietro le clip successive sbloccate (bloccandosi se una clip successiva `isLocked`/`OK` non ha spazio).
    @discardableResult
    public func toggleSlowMoMultiCage(clipId: UUID) -> (didChange: Bool, newSpeed: Double, newSpan: Int, errorMessage: String?) {
        let activeCages = activeCageIntervals()
        let boundaries = activeCageBoundaries()

        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            videoTracks[tIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var clip = videoTracks[tIdx].clips[cIdx]
            guard !clip.isEffectivelyLocked else {
                return (false, clip.speed, clip.span, "Clip bloccata 🔒.")
            }

            let oldSpeed = clip.speed > 0 ? clip.speed : 1.0
            let isSlowingDown = oldSpeed >= 0.99
            let newSpeed: Double = isSlowingDown ? 0.5 : 1.0

            if isSlowingDown && !canSlowMoClip(clip) {
                let reqFPS = Self.formatFPSLabel(format.fps * 2.0)
                let clipFPS = Self.formatFPSLabel(clip.mediaItem.frameRate)
                let msg = "Slow-Mo bloccato: '\(clip.mediaItem.name)' è a \(clipFPS)fps (servono almeno \(reqFPS)fps per timeline a \(Self.formatFPSLabel(format.fps))fps)."
                DebugLogger.shared.log(msg, level: .warning)
                return (false, clip.speed, clip.span, msg)
            }

            // Il punto di inizio sulla timeline e nella sorgente non va MAI mosso
            let curStartSec = CMTimeGetSeconds(clip.timelineStart)
            let sIn = CMTimeGetSeconds(clip.sourceIn)
            let curOutSec = CMTimeGetSeconds(clip.sourceOut)
            let oldDurSec = max(0.05, CMTimeGetSeconds(clip.duration))
            let oldEndSec = curStartSec + oldDurSec

            let b = sourceBounds(for: clip)
            let maxOutSec = max(curOutSec, b.maxSec)
            let naturalSourceDur = max(0.05, curOutSec - sIn)
            let naturalEndSec = curStartSec + naturalSourceDur / newSpeed
            let maxEndBySource = curStartSec + max(0.05, (maxOutSec - sIn) / newSpeed)

            let targetEndSec: Double
            if isCageLockActive && !boundaries.isEmpty {
                let validBars = boundaries.filter { $0 >= curStartSec + 0.05 && $0 <= maxEndBySource + 0.004 }
                if isSlowingDown {
                    // Prima barra disponibile >= fine naturale; se il materiale non basta, ultima barra valida prima del limite
                    targetEndSec = validBars.first(where: { $0 >= naturalEndSec - 0.02 })
                        ?? validBars.last
                        ?? min(naturalEndSec, maxEndBySource)
                } else {
                    targetEndSec = validBars.min(by: { abs($0 - naturalEndSec) < abs($1 - naturalEndSec) })
                        ?? min(naturalEndSec, maxEndBySource)
                }
            } else {
                targetEndSec = min(naturalEndSec, maxEndBySource)
            }

            let newTimelineDur = max(0.05, targetEndSec - curStartSec)
            let newSourceOutSec = min(maxOutSec, sIn + newTimelineDur * newSpeed)
            clip.speed = newSpeed
            clip.sourceOut = CMTime(seconds: newSourceOutSec, preferredTimescale: 600)

            let actualEndSec = CMTimeGetSeconds(clip.timelineEnd)
            let rippleDelta = actualEndSec - oldEndSec

            // Controllo collisione con eventuale clip bloccata/OK successiva prima di mutare la traccia
            if rippleDelta > 0.001, (cIdx + 1) < videoTracks[tIdx].clips.count {
                let downstream = videoTracks[tIdx].clips[(cIdx + 1)...]
                if let firstLocked = downstream.first(where: { $0.isEffectivelyLocked }) {
                    let lockedStart = CMTimeGetSeconds(firstLocked.timelineStart)
                    let unlockedDur = downstream.prefix(while: { !$0.isEffectivelyLocked }).reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
                    if actualEndSec + unlockedDur > lockedStart + 0.005 {
                        let msg = "Operazione bloccata: spazio insufficiente prima della clip bloccata 🔒 successiva."
                        DebugLogger.shared.log(msg, level: .warning)
                        return (false, oldSpeed, clip.span, msg)
                    }
                }
            }

            if isCageLockActive && !activeCages.isEmpty,
               let sCage = activeCages.firstIndex(where: { abs($0.startSeconds - curStartSec) <= 0.015 }),
               let eCage = activeCages.lastIndex(where: { abs($0.endSeconds - actualEndSec) <= 0.015 }),
               eCage >= sCage {
                clip.cageIndex = sCage
                clip.span = eCage - sCage + 1
            } else if !isCageLockActive {
                clip.cageIndex = nil
                clip.span = 1
            }

            videoTracks[tIdx].clips[cIdx] = clip
            syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: newSpeed, cageIndex: clip.cageIndex, span: clip.span)

            if abs(rippleDelta) > 0.0001 {
                var stopTime = Double.infinity
                var prevEdge = actualEndSec
                for i in (cIdx + 1)..<videoTracks[tIdx].clips.count {
                    if videoTracks[tIdx].clips[i].isEffectivelyLocked {
                        stopTime = CMTimeGetSeconds(videoTracks[tIdx].clips[i].timelineStart)
                        break
                    }
                    let oldNextStart = CMTimeGetSeconds(videoTracks[tIdx].clips[i].timelineStart)
                    let shiftedStart = max(0.0, oldNextStart + rippleDelta)
                    let newNextStart = rippleDelta > 0 ? max(prevEdge, shiftedStart) : shiftedStart
                    videoTracks[tIdx].clips[i].timelineStart = CMTime(seconds: newNextStart, preferredTimescale: 600)
                    prevEdge = newNextStart + CMTimeGetSeconds(videoTracks[tIdx].clips[i].duration)

                    if isCageLockActive && !activeCages.isEmpty,
                       let sC = activeCages.firstIndex(where: { abs($0.startSeconds - newNextStart) <= 0.015 }) {
                        videoTracks[tIdx].clips[i].cageIndex = sC
                    } else if !isCageLockActive {
                        videoTracks[tIdx].clips[i].cageIndex = nil
                    }

                    if isLinkActive, let lId = videoTracks[tIdx].clips[i].linkGroupId, tIdx == 0 {
                        for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                            for acIdx in 0..<audioTracks[aIdx].clips.count where audioTracks[aIdx].clips[acIdx].linkGroupId == lId && !audioTracks[aIdx].clips[acIdx].isEffectivelyLocked {
                                audioTracks[aIdx].clips[acIdx].timelineStart = CMTime(seconds: newNextStart, preferredTimescale: 600)
                            }
                        }
                    }
                }

                if isLinkActive && tIdx == 0 {
                    let myLinkId = clip.linkGroupId
                    let linkedIdsMoved = Set(videoTracks[tIdx].clips[(cIdx + 1)...].prefix(while: { !$0.isEffectivelyLocked }).compactMap(\.linkGroupId))
                    for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                        for acIdx in 0..<audioTracks[aIdx].clips.count {
                            let ac = audioTracks[aIdx].clips[acIdx]
                            if !ac.isEffectivelyLocked,
                               ac.linkGroupId != myLinkId,
                               ac.linkGroupId.map({ !linkedIdsMoved.contains($0) }) ?? true,
                               CMTimeGetSeconds(ac.timelineStart) >= oldEndSec - 0.01,
                               CMTimeGetSeconds(ac.timelineStart) < stopTime - 0.01 {
                                let nS = max(0.0, CMTimeGetSeconds(ac.timelineStart) + rippleDelta)
                                audioTracks[aIdx].clips[acIdx].timelineStart = CMTime(seconds: nS, preferredTimescale: 600)
                            }
                        }
                    }
                }
            }

            if isSelection {
                repackSelectionContiguously()
            }
            onModelChanged?()
            DebugLogger.shared.log("Velocità clip '\(clip.mediaItem.name)' impostata a \(Int(newSpeed * 100))% con scarto (inizio fisso).", level: .info)
            return (true, newSpeed, clip.span, nil)
        }
        return (false, 1.0, 1, nil)
    }

    /// Spostamento sbarra in Modalità Gabbie (Rolling Edit): sposta il marcatore/sbarra della gabbia e riadatta insieme
    /// la fine della clip sinistra (`leftClip`) e l'inizio della clip destra (`rightClip`) con il loro audio linkato (mai la musica).
    @discardableResult
    public func rollCageBoundaryWithAdjacentClips(
        oldSeconds: Double,
        newSeconds: Double,
        audioClipId: UUID?,
        isBeatMarker: Bool,
        markerSourceSec: Double?
    ) -> (newTimelineSec: Double, newMarkerSourceSec: Double?)? {
        var minAllowed = 0.0
        var maxAllowed = Double.greatestFiniteMagnitude
        let minClipDur = 0.15

        // Limite dalle sbarre adiacenti così nessuna sbarra scavalca un'altra
        let boundaries = activeCageBoundaries()
        if let bIdx = boundaries.enumerated().min(by: { abs($0.element - oldSeconds) < abs($1.element - oldSeconds) })?.offset {
            if bIdx > 0 { minAllowed = max(minAllowed, boundaries[bIdx - 1] + minClipDur) }
            if bIdx + 1 < boundaries.count { maxAllowed = min(maxAllowed, boundaries[bIdx + 1] - minClipDur) }
        }

        // Trova le clip video adiacenti su V1 (o altre tracce non bloccate) attorno a `oldSeconds`
        ensureVideoTrack(id: 0)
        var leftMatch: (tIdx: Int, cIdx: Int, clip: TimelineClip)? = nil
        var rightMatch: (tIdx: Int, cIdx: Int, clip: TimelineClip)? = nil

        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            for (cIdx, clip) in videoTracks[tIdx].clips.enumerated() {
                let cStart = CMTimeGetSeconds(clip.timelineStart)
                let cEnd = CMTimeGetSeconds(clip.timelineEnd)
                if leftMatch == nil && abs(cEnd - oldSeconds) <= 0.12 {
                    leftMatch = (tIdx, cIdx, clip)
                }
                if rightMatch == nil && abs(cStart - oldSeconds) <= 0.12 {
                    rightMatch = (tIdx, cIdx, clip)
                }
            }
        }

        // Se una delle due clip adiacenti è bloccata (Lock / Approvata), la sbarra non si muove!
        if let l = leftMatch, l.clip.isEffectivelyLocked { return nil }
        if let r = rightMatch, r.clip.isEffectivelyLocked { return nil }

        // Clamp ai limiti fisici/Selezione delle due clip adiacenti
        if let l = leftMatch {
            let lStart = CMTimeGetSeconds(l.clip.timelineStart)
            let lSrcIn = CMTimeGetSeconds(l.clip.sourceIn)
            let lSpd = l.clip.speed > 0 ? l.clip.speed : 1.0
            let lBounds = sourceBounds(for: l.clip)
            minAllowed = max(minAllowed, lStart + minClipDur)
            let maxTimelineEndFromSource = lStart + max(minClipDur, (lBounds.maxSec - lSrcIn) / lSpd)
            maxAllowed = min(maxAllowed, maxTimelineEndFromSource)
        }
        if let r = rightMatch {
            let rEnd = CMTimeGetSeconds(r.clip.timelineEnd)
            let rSrcOut = CMTimeGetSeconds(r.clip.sourceOut)
            let rSpd = r.clip.speed > 0 ? r.clip.speed : 1.0
            let rBounds = sourceBounds(for: r.clip)
            maxAllowed = min(maxAllowed, rEnd - minClipDur)
            let minTimelineStartFromSource = rEnd - max(minClipDur, (rSrcOut - rBounds.minSec) / rSpd)
            minAllowed = max(minAllowed, minTimelineStartFromSource)
        }

        guard minAllowed <= maxAllowed + 0.001 else { return nil }
        let clampedTimelineSec = max(minAllowed, min(maxAllowed, newSeconds))
        if abs(clampedTimelineSec - oldSeconds) < 0.0005 {
            return nil
        }

        // 1. Sposta la sbarra ritmica sottostante
        var updatedMarkerSource: Double? = nil
        var finalTimelineSec = clampedTimelineSec
        if let aId = audioClipId, let oldSrc = markerSourceSec,
           let aClip = audioTracks.flatMap(\.clips).first(where: { $0.id == aId }) {
            let aStart = CMTimeGetSeconds(aClip.timelineStart)
            let aSpd = aClip.speed > 0 ? aClip.speed : 1.0
            let targetSrc = CMTimeGetSeconds(aClip.sourceIn) + (clampedTimelineSec - aStart) * aSpd
            guard let movedSrc = moveClipMarker(clipId: aId, isBeatMarker: isBeatMarker, fromSourceSec: oldSrc, toSourceSec: targetSrc) else {
                return nil
            }
            updatedMarkerSource = movedSrc
            finalTimelineSec = aStart + (movedSrc - CMTimeGetSeconds(aClip.sourceIn)) / aSpd
        } else {
            guard let movedStatic = moveTimelineCageBoundary(from: oldSeconds, to: clampedTimelineSec) else {
                return nil
            }
            finalTimelineSec = movedStatic
        }

        // 2. Aggiorna i bordi delle clip video (e relativo audio linkato dello stesso file)
        if let l = leftMatch {
            var updatedLeft = l.clip
            let lStart = CMTimeGetSeconds(updatedLeft.timelineStart)
            let lSpd = updatedLeft.speed > 0 ? updatedLeft.speed : 1.0
            let newDur = max(minClipDur, finalTimelineSec - lStart)
            let newOutSec = min(sourceBounds(for: updatedLeft).maxSec, CMTimeGetSeconds(updatedLeft.sourceIn) + newDur * lSpd)
            updatedLeft.sourceOut = CMTime(seconds: newOutSec, preferredTimescale: 600)
            videoTracks[l.tIdx].clips[l.cIdx] = updatedLeft
            syncLinkedAudioClip(for: updatedLeft, startTime: updatedLeft.timelineStart, sourceIn: updatedLeft.sourceIn, sourceOut: updatedLeft.sourceOut, speed: updatedLeft.speed, cageIndex: updatedLeft.cageIndex, span: updatedLeft.span)
        }

        if let r = rightMatch {
            var updatedRight = r.clip
            let rStart = CMTimeGetSeconds(updatedRight.timelineStart)
            let rSpd = updatedRight.speed > 0 ? updatedRight.speed : 1.0
            let deltaTL = finalTimelineSec - rStart
            let newSrcIn = max(sourceBounds(for: updatedRight).minSec, CMTimeGetSeconds(updatedRight.sourceIn) + deltaTL * rSpd)
            updatedRight.timelineStart = CMTime(seconds: finalTimelineSec, preferredTimescale: 600)
            updatedRight.sourceIn = CMTime(seconds: newSrcIn, preferredTimescale: 600)
            videoTracks[r.tIdx].clips[r.cIdx] = updatedRight
            syncLinkedAudioClip(for: updatedRight, startTime: updatedRight.timelineStart, sourceIn: updatedRight.sourceIn, sourceOut: updatedRight.sourceOut, speed: updatedRight.speed, cageIndex: updatedRight.cageIndex, span: updatedRight.span)
        }

        onModelChanged?()
        return (finalTimelineSec, updatedMarkerSource)
    }

    private func fitClip(_ clip: inout TimelineClip, intoCageStart sIdx: Int, desiredSpan: Int, in activeCages: [RhythmicCage]) {
        guard sIdx >= 0, sIdx < activeCages.count else { return }
        let endIdx = min(activeCages.count - 1, sIdx + max(1, desiredSpan) - 1)
        let actualSpan = endIdx - sIdx + 1
        let combinedDur = activeCages[endIdx].endSeconds - activeCages[sIdx].startSeconds
        let spd = clip.speed > 0 ? clip.speed : 1.0
        let neededSource = combinedDur * spd
        let b = sourceBounds(for: clip)
        var newIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
        var newOut = newIn + neededSource
        if newOut > b.maxSec {
            newOut = b.maxSec
            newIn = max(b.minSec, newOut - neededSource)
        }
        clip.cageIndex = sIdx
        clip.span = actualSpan
        clip.timelineStart = activeCages[sIdx].startTime
        clip.sourceIn = CMTime(seconds: newIn, preferredTimescale: 600)
        clip.sourceOut = CMTime(seconds: newOut, preferredTimescale: 600)
    }

    /// Scambia di posto SOLO la clip selezionata con quella nella gabbia adiacente (sinistra -1, destra +1),
    /// oppure scorre nella gabbia vuota adiacente, senza spostare le altre clip o riempire gabbie vuote all'inizio.
    @discardableResult
    public func swapAdjacentCages(clipId: UUID, direction: Int) -> Bool {
        guard direction == -1 || direction == 1 else { return false }
        let activeCages = activeCageIntervals()
        guard !activeCages.isEmpty else { return false }

        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            videoTracks[tIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var clipA = videoTracks[tIdx].clips[cIdx]
            guard !clipA.isEffectivelyLocked else { return false }
            guard let startA = resolvedCageIndex(for: clipA, in: activeCages) else { continue }
            let endA = resolvedEndCageIndex(for: clipA, startCageIdx: startA, in: activeCages)
            let spanA = max(1, endA - startA + 1)

            if direction < 0 {
                guard startA > 0 else { return false }
                if cIdx > 0 {
                    var clipB = videoTracks[tIdx].clips[cIdx - 1]
                    guard let startB = resolvedCageIndex(for: clipB, in: activeCages) else { return false }
                    let endB = resolvedEndCageIndex(for: clipB, startCageIdx: startB, in: activeCages)
                    let spanB = max(1, endB - startB + 1)

                    if endB < startA - 1 {
                        // Gabbia adiacente vuota a sinistra: sposta solo clipA di 1 gabbia a sinistra
                        fitClip(&clipA, intoCageStart: startA - 1, desiredSpan: spanA, in: activeCages)
                        videoTracks[tIdx].clips[cIdx] = clipA
                        syncLinkedAudioClip(for: clipA, startTime: clipA.timelineStart, sourceIn: clipA.sourceIn, sourceOut: clipA.sourceOut, speed: clipA.speed, cageIndex: clipA.cageIndex, span: clipA.span)
                        onModelChanged?()
                        return true
                    }

                    // Scambia solo clipA e clipB lasciando intatte tutte le altre clip e gabbie vuote
                    guard !clipB.isEffectivelyLocked else { return false }
                    fitClip(&clipA, intoCageStart: startB, desiredSpan: spanA, in: activeCages)
                    fitClip(&clipB, intoCageStart: startB + clipA.span, desiredSpan: spanB, in: activeCages)
                    videoTracks[tIdx].clips[cIdx - 1] = clipA
                    videoTracks[tIdx].clips[cIdx] = clipB
                    syncLinkedAudioClip(for: clipA, startTime: clipA.timelineStart, sourceIn: clipA.sourceIn, sourceOut: clipA.sourceOut, speed: clipA.speed, cageIndex: clipA.cageIndex, span: clipA.span)
                    syncLinkedAudioClip(for: clipB, startTime: clipB.timelineStart, sourceIn: clipB.sourceIn, sourceOut: clipB.sourceOut, speed: clipB.speed, cageIndex: clipB.cageIndex, span: clipB.span)
                    onModelChanged?()
                    return true
                } else {
                    // Prima clip della traccia con gabbie vuote prima: sposta di 1 gabbia a sinistra
                    fitClip(&clipA, intoCageStart: startA - 1, desiredSpan: spanA, in: activeCages)
                    videoTracks[tIdx].clips[cIdx] = clipA
                    syncLinkedAudioClip(for: clipA, startTime: clipA.timelineStart, sourceIn: clipA.sourceIn, sourceOut: clipA.sourceOut, speed: clipA.speed, cageIndex: clipA.cageIndex, span: clipA.span)
                    onModelChanged?()
                    return true
                }
            } else {
                guard endA + 1 < activeCages.count else { return false }
                if (cIdx + 1) < videoTracks[tIdx].clips.count {
                    var clipB = videoTracks[tIdx].clips[cIdx + 1]
                    guard let startB = resolvedCageIndex(for: clipB, in: activeCages) else { return false }
                    let endB = resolvedEndCageIndex(for: clipB, startCageIdx: startB, in: activeCages)
                    let spanB = max(1, endB - startB + 1)

                    if startB > endA + 1 {
                        // Gabbia adiacente vuota a destra: sposta solo clipA di 1 gabbia a destra
                        fitClip(&clipA, intoCageStart: startA + 1, desiredSpan: spanA, in: activeCages)
                        videoTracks[tIdx].clips[cIdx] = clipA
                        syncLinkedAudioClip(for: clipA, startTime: clipA.timelineStart, sourceIn: clipA.sourceIn, sourceOut: clipA.sourceOut, speed: clipA.speed, cageIndex: clipA.cageIndex, span: clipA.span)
                        onModelChanged?()
                        return true
                    }

                    // Scambia solo clipA e clipB lasciando intatte tutte le altre clip
                    guard !clipB.isEffectivelyLocked else { return false }
                    fitClip(&clipB, intoCageStart: startA, desiredSpan: spanB, in: activeCages)
                    fitClip(&clipA, intoCageStart: startA + clipB.span, desiredSpan: spanA, in: activeCages)
                    videoTracks[tIdx].clips[cIdx] = clipB
                    videoTracks[tIdx].clips[cIdx + 1] = clipA
                    syncLinkedAudioClip(for: clipB, startTime: clipB.timelineStart, sourceIn: clipB.sourceIn, sourceOut: clipB.sourceOut, speed: clipB.speed, cageIndex: clipB.cageIndex, span: clipB.span)
                    syncLinkedAudioClip(for: clipA, startTime: clipA.timelineStart, sourceIn: clipA.sourceIn, sourceOut: clipA.sourceOut, speed: clipA.speed, cageIndex: clipA.cageIndex, span: clipA.span)
                    onModelChanged?()
                    return true
                } else {
                    // Ultima clip della traccia con gabbie vuote dopo: sposta di 1 gabbia a destra
                    fitClip(&clipA, intoCageStart: startA + 1, desiredSpan: spanA, in: activeCages)
                    videoTracks[tIdx].clips[cIdx] = clipA
                    syncLinkedAudioClip(for: clipA, startTime: clipA.timelineStart, sourceIn: clipA.sourceIn, sourceOut: clipA.sourceOut, speed: clipA.speed, cageIndex: clipA.cageIndex, span: clipA.span)
                    onModelChanged?()
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Modalità Confronta (Differenze temporanee in memoria)

    /// Costruisce una timeline temporanea (non salvata su DB) contenente tutto il girato presente in `source`
    /// che NON è incluso in `reference` (sottrazione esatta degli intervalli sorgente per ciascun media).
    public static func buildDifferenceCompareTimeline(
        source: TimelineModel,
        excludingReference reference: TimelineModel
    ) -> (timeline: TimelineModel, segmentCount: Int, totalSeconds: Double) {
        // 1. Raccogli e fondi tutti gli intervalli sorgente già utilizzati in `reference` per URL media
        var rawUsedByURL: [URL: [(start: Double, end: Double)]] = [:]
        for track in reference.videoTracks {
            for c in track.clips {
                let s = CMTimeGetSeconds(c.sourceIn)
                let e = CMTimeGetSeconds(c.sourceOut)
                if e - s > 0.02 {
                    rawUsedByURL[c.mediaItem.url, default: []].append((s, e))
                }
            }
        }
        for track in reference.audioTracks {
            for c in track.clips where c.beatMarkers.isEmpty && !c.mediaItem.hasVideo {
                let s = CMTimeGetSeconds(c.sourceIn)
                let e = CMTimeGetSeconds(c.sourceOut)
                if e - s > 0.02 {
                    rawUsedByURL[c.mediaItem.url, default: []].append((s, e))
                }
            }
        }

        var mergedUsedByURL: [URL: [(start: Double, end: Double)]] = [:]
        for (url, intervals) in rawUsedByURL {
            let sorted = intervals.sorted { $0.start < $1.start }
            var merged: [(start: Double, end: Double)] = []
            for iv in sorted {
                if let last = merged.last, iv.start <= last.end + 0.08 {
                    merged[merged.count - 1].end = max(last.end, iv.end)
                } else {
                    merged.append(iv)
                }
            }
            mergedUsedByURL[url] = merged
        }

        func subtractUsed(_ base: (start: Double, end: Double), used: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
            var remaining: [(start: Double, end: Double)] = [base]
            for u in used {
                var next: [(start: Double, end: Double)] = []
                for r in remaining {
                    if u.end <= r.start + 0.02 || u.start >= r.end - 0.02 {
                        next.append(r)
                    } else {
                        if u.start > r.start + 0.02 {
                            next.append((r.start, min(r.end, u.start)))
                        }
                        if u.end < r.end - 0.02 {
                            next.append((max(r.start, u.end), r.end))
                        }
                    }
                }
                remaining = next
            }
            return remaining.filter { ($0.end - $0.start) >= 0.25 }
        }

        let compareTL = TimelineModel(
            name: "Confronto: \(source.name) − \(reference.name)",
            isSelection: false
        )
        compareTL.format = source.format
        compareTL.isTemporaryCompare = true
        compareTL.isRippleTrimMode = source.isRippleTrimMode
        compareTL.isLinkActive = true

        // Indicizza le clip audio di `source` per abbinarle alle clip video estratte
        let allSourceAudio = source.audioTracks.flatMap(\.clips)
        var cursorSec: Double = 0.0
        var totalDurSec: Double = 0.0
        var count = 0

        let sortedSourceVideos = source.videoTracks
            .flatMap(\.clips)
            .sorted {
                let c = CMTimeCompare($0.timelineStart, $1.timelineStart)
                if c != 0 { return c < 0 }
                return CMTimeCompare($0.sourceIn, $1.sourceIn) < 0
            }

        for vClip in sortedSourceVideos {
            let sIn = CMTimeGetSeconds(vClip.sourceIn)
            let sOut = CMTimeGetSeconds(vClip.sourceOut)
            guard sOut - sIn >= 0.25 else { continue }
            let diffs = subtractUsed((sIn, sOut), used: mergedUsedByURL[vClip.mediaItem.url] ?? [])
            guard !diffs.isEmpty else { continue }

            let hasLinkedAudio = vClip.mediaItem.hasAudio || (vClip.linkGroupId != nil && allSourceAudio.contains(where: { $0.linkGroupId == vClip.linkGroupId }))

            for diff in diffs {
                let dur = diff.end - diff.start
                let linkId: UUID? = hasLinkedAudio ? UUID() : nil
                let filteredMarkers = vClip.markers.filter { $0 >= diff.start - 0.01 && $0 <= diff.end + 0.01 }
                let tStart = CMTime(seconds: cursorSec, preferredTimescale: 600)
                let srcInT = CMTime(seconds: diff.start, preferredTimescale: 600)
                let srcOutT = CMTime(seconds: diff.end, preferredTimescale: 600)

                let newV = TimelineClip(
                    mediaItem: vClip.mediaItem,
                    sourceIn: srcInT,
                    sourceOut: srcOutT,
                    timelineStart: tStart,
                    trackIndex: 0,
                    mediaType: .video,
                    orientation: vClip.orientation,
                    linkGroupId: linkId,
                    speed: 1.0,
                    markers: filteredMarkers,
                    priority: vClip.priority,
                    isLocked: false,
                    selectionSourceIn: vClip.selectionSourceIn,
                    selectionSourceOut: vClip.selectionSourceOut,
                    colorTag: vClip.colorTag
                )
                compareTL.videoTracks[0].clips.append(newV)

                if let lid = linkId {
                    let newA = TimelineClip(
                        mediaItem: vClip.mediaItem,
                        sourceIn: srcInT,
                        sourceOut: srcOutT,
                        timelineStart: tStart,
                        trackIndex: 0,
                        mediaType: .audio,
                        orientation: .normal,
                        linkGroupId: lid,
                        speed: 1.0,
                        markers: filteredMarkers,
                        priority: vClip.priority,
                        isLocked: false,
                        selectionSourceIn: vClip.selectionSourceIn,
                        selectionSourceOut: vClip.selectionSourceOut,
                        colorTag: vClip.colorTag
                    )
                    compareTL.audioTracks[0].clips.append(newA)
                }

                cursorSec += dur
                totalDurSec += dur
                count += 1
            }
        }

        // Includi eventuali clip solo-audio di `source` (non musicali) assenti in `reference`
        let sortedSourceAudioOnly = allSourceAudio
            .filter { !$0.mediaItem.hasVideo && $0.beatMarkers.isEmpty }
            .sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }

        for aClip in sortedSourceAudioOnly {
            let sIn = CMTimeGetSeconds(aClip.sourceIn)
            let sOut = CMTimeGetSeconds(aClip.sourceOut)
            guard sOut - sIn >= 0.25 else { continue }
            let diffs = subtractUsed((sIn, sOut), used: mergedUsedByURL[aClip.mediaItem.url] ?? [])
            for diff in diffs {
                let dur = diff.end - diff.start
                let newA = TimelineClip(
                    mediaItem: aClip.mediaItem,
                    sourceIn: CMTime(seconds: diff.start, preferredTimescale: 600),
                    sourceOut: CMTime(seconds: diff.end, preferredTimescale: 600),
                    timelineStart: CMTime(seconds: cursorSec, preferredTimescale: 600),
                    trackIndex: 0,
                    mediaType: .audio,
                    orientation: .normal,
                    linkGroupId: nil,
                    speed: 1.0,
                    markers: aClip.markers.filter { $0 >= diff.start - 0.01 && $0 <= diff.end + 0.01 },
                    priority: aClip.priority,
                    isLocked: false,
                    selectionSourceIn: diff.start,
                    selectionSourceOut: diff.end,
                    colorTag: aClip.colorTag
                )
                compareTL.audioTracks[0].clips.append(newA)
                cursorSec += dur
                totalDurSec += dur
                count += 1
            }
        }

        return (compareTL, count, totalDurSec)
    }

    /// Sposta una singola clip o un gruppo di clip selezionate a sinistra (`-1`) o a destra (`+1`) in una Selezione (`V1+A1`),
    /// mantenendo tutte le clip contigue da 00:00 e sincronizzando video e audio collegati.
    @discardableResult
    public func moveSelectedClipsInSelection(clipIds: Set<UUID>, direction: Int) -> Bool {
        guard isSelection, direction == -1 || direction == 1, !clipIds.isEmpty else { return false }

        let expandedIds = resolveSelectionCompanionClipIds(for: clipIds)
        let vClips = (videoTracks.first?.clips ?? []).sorted {
            let c = CMTimeCompare($0.timelineStart, $1.timelineStart)
            if c != 0 { return c < 0 }
            return CMTimeCompare($0.sourceIn, $1.sourceIn) < 0
        }
        let aClips = (audioTracks.first?.clips ?? []).sorted {
            let c = CMTimeCompare($0.timelineStart, $1.timelineStart)
            if c != 0 { return c < 0 }
            return CMTimeCompare($0.sourceIn, $1.sourceIn) < 0
        }

        struct SelectionSlot {
            var video: TimelineClip?
            var audio: TimelineClip?
            let isSelected: Bool
            let isLocked: Bool
            let isVisible: Bool
        }

        var usedAudioIds: Set<UUID> = []
        var slots: [SelectionSlot] = []
        slots.reserveCapacity(vClips.count + aClips.count)

        for v in vClips {
            var matchedAudio: TimelineClip? = nil
            if let lId = v.linkGroupId,
               let match = aClips.first(where: { !usedAudioIds.contains($0.id) && $0.linkGroupId == lId }) {
                matchedAudio = match
            } else {
                let vStart = CMTimeGetSeconds(v.timelineStart)
                let vEnd = CMTimeGetSeconds(v.timelineEnd)
                matchedAudio = aClips.first { a in
                    !usedAudioIds.contains(a.id)
                        && a.mediaItem.url == v.mediaItem.url
                        && abs(CMTimeGetSeconds(a.timelineStart) - vStart) < 0.05
                        && abs(CMTimeGetSeconds(a.timelineEnd) - vEnd) < 0.05
                }
            }
            if let a = matchedAudio {
                usedAudioIds.insert(a.id)
            }
            let sel = expandedIds.contains(v.id) || (matchedAudio.map { expandedIds.contains($0.id) } ?? false)
            let locked = v.isEffectivelyLocked || (matchedAudio?.isEffectivelyLocked ?? false)
            let visible = !isSmartFilterActive || smartFilter.matches(v) || (matchedAudio.map { smartFilter.matches($0) } ?? false)
            slots.append(SelectionSlot(video: v, audio: matchedAudio, isSelected: sel, isLocked: locked, isVisible: visible))
        }

        for a in aClips where !usedAudioIds.contains(a.id) {
            let sel = expandedIds.contains(a.id)
            let visible = !isSmartFilterActive || smartFilter.matches(a)
            slots.append(SelectionSlot(video: nil, audio: a, isSelected: sel, isLocked: a.isEffectivelyLocked, isVisible: visible))
        }

        guard slots.count >= 2 else { return false }

        let targetIndices = isSmartFilterActive ? slots.indices.filter { slots[$0].isVisible } : Array(slots.indices)
        guard targetIndices.count >= 2 else { return false }

        var didMove = false
        if direction < 0 {
            for k in 1..<targetIndices.count {
                let curIdx = targetIndices[k]
                let prevIdx = targetIndices[k - 1]
                if slots[curIdx].isSelected && !slots[curIdx].isLocked && !slots[prevIdx].isSelected && !slots[prevIdx].isLocked {
                    slots.swapAt(curIdx, prevIdx)
                    didMove = true
                }
            }
        } else {
            for k in stride(from: targetIndices.count - 2, through: 0, by: -1) {
                let curIdx = targetIndices[k]
                let nextIdx = targetIndices[k + 1]
                if slots[curIdx].isSelected && !slots[curIdx].isLocked && !slots[nextIdx].isSelected && !slots[nextIdx].isLocked {
                    slots.swapAt(curIdx, nextIdx)
                    didMove = true
                }
            }
        }

        guard didMove else { return false }

        var newVideo: [TimelineClip] = []
        var newAudio: [TimelineClip] = []
        var cursor: CMTime = .zero
        for slot in slots {
            let dur = max(slot.video?.duration ?? .zero, slot.audio?.duration ?? .zero)
            if var v = slot.video {
                v.timelineStart = cursor
                v.trackIndex = 0
                newVideo.append(v)
            }
            if var a = slot.audio {
                a.timelineStart = cursor
                a.trackIndex = 0
                newAudio.append(a)
            }
            cursor = CMTimeAdd(cursor, dur)
        }

        if !videoTracks.isEmpty {
            videoTracks[0].clips = newVideo
        }
        if !audioTracks.isEmpty {
            audioTracks[0].clips = newAudio
        }
        selectedClipIds = resolveSelectionCompanionClipIds(for: expandedIds)
        onModelChanged?()
        return true
    }
}
