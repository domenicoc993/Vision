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
    public var includeNoPriority: Bool = false
    public var includeWithMarkers: Bool = false
    public var includeWithoutMarkers: Bool = false

    public var isActive: Bool {
        includePriority1 || includePriority2 || includePriority3 || includeNoPriority || includeWithMarkers || includeWithoutMarkers
    }

    public func matches(_ clip: TimelineClip) -> Bool {
        guard isActive else { return true }

        let hasPriorityFilter = includePriority1 || includePriority2 || includePriority3 || includeNoPriority
        if hasPriorityFilter {
            let pOk: Bool
            switch clip.priority {
            case 1?: pOk = includePriority1
            case 2?: pOk = includePriority2
            case 3?: pOk = includePriority3
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
    public var isSelection: Bool = false

    public var videoTracks: [TimelineTrack]
    public var audioTracks: [TimelineTrack]

    // Multi-selection support (Marquee box selection & multi-select)
    public var selectedClipIds: Set<UUID> = []
    public var selectedClipId: UUID? {
        get { selectedClipIds.first }
        set {
            if let id = newValue {
                selectedClipIds = [id]
            } else {
                selectedClipIds.removeAll()
            }
        }
    }

    public var format: TimelineFormat = .fhdLandscape

    // Pro NLE toggles
    public var isLinkActive: Bool = true                  // Link / Unlink A/V
    public var isSnappingActive: Bool = true              // Magnet / Snapping (Resolve style)
    public var isSelectionFollowsPlayhead: Bool = false   // Seleziona clip sotto la testina (Resolve style)
    public var isCageLockActive: Bool = true              // Blocco Cage: aggancia inizio/fine clip alle sbarre (OFF = montaggio libero)

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
    public func reorderClips(trackIndex: Int, isVideo: Bool, fromIndex: Int, toIndex: Int) {
        guard trackIndex >= 0 else { return }
        if isVideo {
            guard trackIndex < videoTracks.count, !videoTracks[trackIndex].isLocked else { return }
            var clips = videoTracks[trackIndex].clips
            guard fromIndex >= 0 && fromIndex < clips.count else { return }
            let clampedTo = max(0, min(clips.count - 1, toIndex))
            guard fromIndex != clampedTo else { return }

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
                    for aTrackIdx in 0..<audioTracks.count where !audioTracks[aTrackIdx].isLocked {
                        if let aIdx = audioTracks[aTrackIdx].clips.firstIndex(where: { $0.linkGroupId == lId }) {
                            let aOldStart = audioTracks[aTrackIdx].clips[aIdx].timelineStart
                            let aNewStart = max(.zero, CMTime(seconds: CMTimeGetSeconds(aOldStart) + deltaSec, preferredTimescale: 600))
                            audioTracks[aTrackIdx].clips[aIdx].timelineStart = aNewStart
                            audioTracks[aTrackIdx].clips.sort(by: { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 })
                        }
                    }
                }
            }
            videoTracks[trackIndex].clips = clips
        } else {
            guard trackIndex < audioTracks.count, !audioTracks[trackIndex].isLocked else { return }
            var clips = audioTracks[trackIndex].clips
            guard fromIndex >= 0 && fromIndex < clips.count else { return }
            let clampedTo = max(0, min(clips.count - 1, toIndex))
            guard fromIndex != clampedTo else { return }

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
                        if let vIdx = videoTracks[vTrackIdx].clips.firstIndex(where: { $0.linkGroupId == lId }) {
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

            var movingClips: [TimelineClip] = []
            var remainingClips: [TimelineClip] = []
            var removedBeforeSlot = 0
            for (idx, c) in clips.enumerated() {
                if clipIds.contains(c.id) {
                    movingClips.append(c)
                    if idx < slot { removedBeforeSlot += 1 }
                } else {
                    remainingClips.append(c)
                }
            }
            guard !movingClips.isEmpty else { return false }
            let insertAt = max(0, min(remainingClips.count, slot - removedBeforeSlot))
            var reordered = remainingClips
            reordered.insert(contentsOf: movingClips, at: insertAt)

            var currentT: CMTime = .zero
            for i in 0..<reordered.count {
                let oldStart = reordered[i].timelineStart
                let newStart = currentT
                let deltaSec = CMTimeGetSeconds(newStart) - CMTimeGetSeconds(oldStart)
                reordered[i].timelineStart = newStart
                currentT = CMTimeAdd(currentT, reordered[i].duration)

                if isLinkActive, let lId = reordered[i].linkGroupId, abs(deltaSec) > 0.0005 {
                    for aTrackIdx in 0..<audioTracks.count where !audioTracks[aTrackIdx].isLocked {
                        if let aIdx = audioTracks[aTrackIdx].clips.firstIndex(where: { $0.linkGroupId == lId }) {
                            let aOldStart = audioTracks[aTrackIdx].clips[aIdx].timelineStart
                            audioTracks[aTrackIdx].clips[aIdx].timelineStart = max(.zero, CMTime(seconds: CMTimeGetSeconds(aOldStart) + deltaSec, preferredTimescale: 600))
                            audioTracks[aTrackIdx].clips.sort(by: { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 })
                        }
                    }
                }
            }
            videoTracks[trackIndex].clips = reordered
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
            ClipboardClipEntry(
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
                selectionSourceIn: clip.selectionSourceIn,
                selectionSourceOut: clip.selectionSourceOut
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
                selectionSourceOut: entry.selectionSourceOut
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
            guard clip.isLocked && !excludingClipIds.contains(clip.id) else { return false }
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
            .filter { $0.isLocked && !excludingClipIds.contains($0.id) }
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
            guard clip.id != incoming.id && clip.isLocked else { return false }
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
                        selectionSourceOut: clip.selectionSourceOut
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
                        selectionSourceOut: clip.selectionSourceOut
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
                if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isLocked }) {
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
                if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isLocked }) {
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
                if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isLocked }) {
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
                    if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == cId && !$0.isLocked }) {
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
                if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isLocked }) {
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
                    if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == cId && !$0.isLocked }) {
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
                    if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == move.id && !$0.isLocked }) {
                        let clip = videoTracks[trackIdx].clips.remove(at: clipIdx)
                        extracted.append((originalTrack: trackIdx, clip: clip, targetTrack: move.toTrack, isVideo: true, newStartTime: move.newStartTime))
                        break
                    }
                }
            } else {
                for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                    if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == move.id && !$0.isLocked }) {
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
        thresholdSeconds: Double
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

    // MARK: - Ripple Delete Engine (Eliminazione con Scarto - Modalità Senza Scarto)
    public func removeClipsWithRipple(ids: [UUID]) {
        guard !ids.isEmpty else { return }

        // Filter out clips on locked tracks or individually locked clips
        var candidateClips: [TimelineClip] = []
        for track in videoTracks where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) && !clip.isLocked {
                candidateClips.append(clip)
            }
        }
        for track in audioTracks where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) && !clip.isLocked {
                candidateClips.append(clip)
            }
        }

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
                    if !clip.isLocked && clipStart >= downstreamThreshold {
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
                    if !clip.isLocked && clipStart >= downstreamThreshold {
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

    // MARK: - Ripple Trim Engine (Modalità Senza Scarto + Link A/V)
    @discardableResult
    public func trimClipStart(at time: CMTime) -> CMTime? {
        var didTrim = false
        var targetVideoClipIds: Set<UUID> = []
        var targetAudioClipIds: Set<UUID> = []
        var targetTimelineStart: CMTime? = nil

        // 1. Identify clips spanning cut time
        for track in videoTracks where !track.isLocked {
            for clip in track.clips {
                let matches = selectedClipIds.contains(clip.id) || (selectedClipIds.isEmpty && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0)
                if matches && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0 {
                    targetVideoClipIds.insert(clip.id)
                    if targetTimelineStart == nil {
                        targetTimelineStart = clip.timelineStart
                    }
                    if isLinkActive, let lId = clip.linkGroupId {
                        for aTrack in audioTracks where !aTrack.isLocked {
                            for aClip in aTrack.clips where aClip.linkGroupId == lId {
                                targetAudioClipIds.insert(aClip.id)
                            }
                        }
                    }
                }
            }
        }

        for track in audioTracks where !track.isLocked {
            for clip in track.clips {
                let matches = selectedClipIds.contains(clip.id) || (selectedClipIds.isEmpty && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0)
                if matches && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0 {
                    targetAudioClipIds.insert(clip.id)
                    if targetTimelineStart == nil {
                        targetTimelineStart = clip.timelineStart
                    }
                    if isLinkActive, let lId = clip.linkGroupId {
                        for vTrack in videoTracks where !vTrack.isLocked {
                            for vClip in vTrack.clips where vClip.linkGroupId == lId {
                                targetVideoClipIds.insert(vClip.id)
                            }
                        }
                    }
                }
            }
        }

        // 2. Perform Ripple Trim Start on Video
        var totalDeltaSec: Double = 0
        for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
            for clipIdx in 0..<videoTracks[trackIdx].clips.count {
                let clip = videoTracks[trackIdx].clips[clipIdx]
                if targetVideoClipIds.contains(clip.id) {
                    let delta = CMTimeSubtract(time, clip.timelineStart)
                    let deltaSec = CMTimeGetSeconds(delta)
                    totalDeltaSec = max(totalDeltaSec, deltaSec)
                    videoTracks[trackIdx].clips[clipIdx].sourceIn = CMTimeAdd(clip.sourceIn, delta)
                    didTrim = true
                }
            }
        }

        // 3. Perform Ripple Trim Start on Audio
        for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
            for clipIdx in 0..<audioTracks[trackIdx].clips.count {
                let clip = audioTracks[trackIdx].clips[clipIdx]
                if targetAudioClipIds.contains(clip.id) {
                    let delta = CMTimeSubtract(time, clip.timelineStart)
                    let deltaSec = CMTimeGetSeconds(delta)
                    totalDeltaSec = max(totalDeltaSec, deltaSec)
                    audioTracks[trackIdx].clips[clipIdx].sourceIn = CMTimeAdd(clip.sourceIn, delta)
                    didTrim = true
                }
            }
        }

        // 4. Modalità senza scarto: Ripple downstream clips backward by totalDeltaSec
        if didTrim && totalDeltaSec > 0.001 {
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
            DebugLogger.shared.log("Trim Inizio Senza Scarto (Q) eseguito a \(String(format: "%.2f", CMTimeGetSeconds(time)))s (Ripple: \(String(format: "%.2f", totalDeltaSec))s)", level: .info)
            return targetTimelineStart
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
            for clip in track.clips {
                let matches = selectedClipIds.contains(clip.id) || (selectedClipIds.isEmpty && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0)
                if matches && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0 {
                    targetVideoClipIds.insert(clip.id)
                    if isLinkActive, let lId = clip.linkGroupId {
                        for aTrack in audioTracks where !aTrack.isLocked {
                            for aClip in aTrack.clips where aClip.linkGroupId == lId {
                                targetAudioClipIds.insert(aClip.id)
                            }
                        }
                    }
                }
            }
        }

        for track in audioTracks where !track.isLocked {
            for clip in track.clips {
                let matches = selectedClipIds.contains(clip.id) || (selectedClipIds.isEmpty && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0)
                if matches && CMTimeCompare(time, clip.timelineStart) > 0 && CMTimeCompare(time, clip.timelineEnd) < 0 {
                    targetAudioClipIds.insert(clip.id)
                    if isLinkActive, let lId = clip.linkGroupId {
                        for vTrack in videoTracks where !vTrack.isLocked {
                            for vClip in vTrack.clips where vClip.linkGroupId == lId {
                                targetVideoClipIds.insert(vClip.id)
                            }
                        }
                    }
                }
            }
        }

        // 2. Perform Trim End and calculate cut amount (delta)
        var totalDeltaSec: Double = 0
        for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
            for clipIdx in 0..<videoTracks[trackIdx].clips.count {
                let clip = videoTracks[trackIdx].clips[clipIdx]
                if targetVideoClipIds.contains(clip.id) {
                    let delta = CMTimeSubtract(clip.timelineEnd, time)
                    let deltaSec = CMTimeGetSeconds(delta)
                    totalDeltaSec = max(totalDeltaSec, deltaSec)
                    let remainingDur = CMTimeSubtract(time, clip.timelineStart)
                    videoTracks[trackIdx].clips[clipIdx].sourceOut = CMTimeAdd(clip.sourceIn, remainingDur)
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
                    let remainingDur = CMTimeSubtract(time, clip.timelineStart)
                    audioTracks[trackIdx].clips[clipIdx].sourceOut = CMTimeAdd(clip.sourceIn, remainingDur)
                    didTrim = true
                }
            }
        }

        // 3. Modalità senza scarto: Shift downstream timeline backward by totalDeltaSec
        if didTrim && totalDeltaSec > 0.001 {
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
            DebugLogger.shared.log("Trim Fine Senza Scarto (W) eseguito a \(String(format: "%.2f", CMTimeGetSeconds(time)))s (Ripple: \(String(format: "%.2f", totalDeltaSec))s)", level: .info)
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

                    if shouldSplit && CMTimeCompare(clip.timelineStart, time) < 0 && CMTimeCompare(clip.timelineEnd, time) > 0 {
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
                            selectionSourceIn: clip.selectionSourceIn,
                            selectionSourceOut: clip.selectionSourceOut
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
                            selectionSourceIn: clip.selectionSourceIn,
                            selectionSourceOut: clip.selectionSourceOut
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

        guard let clip = targetClip, !clip.isLocked else { return false }

        let mediaDurSec = CMTimeGetSeconds(clip.mediaItem.duration)
        let curInSec = CMTimeGetSeconds(clip.sourceIn)
        let curOutSec = CMTimeGetSeconds(clip.sourceOut)
        let curEndSec = CMTimeGetSeconds(clip.timelineEnd)

        if isStart {
            let minIn: Double = 0.0
            let maxIn: Double = max(minIn, curOutSec - 0.1)
            let proposedIn = max(minIn, min(maxIn, curInSec + deltaSeconds))
            let appliedInDelta = proposedIn - curInSec
            guard abs(appliedInDelta) > 0.001 else { return false }

            let durationDelta = -appliedInDelta

            func applyStartTrim(to trackList: inout [TimelineTrack], matchIds: Set<UUID>, matchLinkId: UUID?) {
                for tIdx in 0..<trackList.count where !trackList[tIdx].isLocked {
                    for cIdx in 0..<trackList[tIdx].clips.count {
                        let c = trackList[tIdx].clips[cIdx]
                        let isThisClip = matchIds.contains(c.id) || (matchLinkId != nil && c.linkGroupId == matchLinkId!)
                        if isThisClip {
                            let newIn = max(0, min(CMTimeGetSeconds(c.sourceOut) - 0.1, CMTimeGetSeconds(c.sourceIn) + appliedInDelta))
                            trackList[tIdx].clips[cIdx].sourceIn = CMTime(seconds: newIn, preferredTimescale: 600)
                        } else if CMTimeGetSeconds(c.timelineStart) >= curEndSec - 0.01 {
                            let newStart = max(0, CMTimeGetSeconds(c.timelineStart) + durationDelta)
                            trackList[tIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                        }
                    }
                }
            }

            applyStartTrim(to: &videoTracks, matchIds: pairedIds, matchLinkId: linkId)
            applyStartTrim(to: &audioTracks, matchIds: pairedIds, matchLinkId: linkId)

        } else {
            let minDur: Double = 0.1
            let maxDur: Double = max(minDur, mediaDurSec - curInSec)
            let curDur = curOutSec - curInSec
            let proposedDur = max(minDur, min(maxDur, curDur + deltaSeconds))
            let durationDelta = proposedDur - curDur
            guard abs(durationDelta) > 0.001 else { return false }

            func applyEndTrim(to trackList: inout [TimelineTrack], matchIds: Set<UUID>, matchLinkId: UUID?) {
                for tIdx in 0..<trackList.count where !trackList[tIdx].isLocked {
                    for cIdx in 0..<trackList[tIdx].clips.count {
                        let c = trackList[tIdx].clips[cIdx]
                        let isThisClip = matchIds.contains(c.id) || (matchLinkId != nil && c.linkGroupId == matchLinkId!)
                        if isThisClip {
                            let cIn = CMTimeGetSeconds(c.sourceIn)
                            let cMaxOut = CMTimeGetSeconds(c.mediaItem.duration)
                            let cNewOut = min(cMaxOut, max(cIn + 0.1, cIn + proposedDur))
                            trackList[tIdx].clips[cIdx].sourceOut = CMTime(seconds: cNewOut, preferredTimescale: 600)
                        } else if CMTimeGetSeconds(c.timelineStart) >= curEndSec - 0.01 {
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

    private func resolveSelectionCompanionClipIds(for seedIds: Set<UUID>) -> Set<UUID> {
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
        let effectiveTime = isSmartFilterActive ? realTimelineTime(forDisplayedTime: time) : time
        let timeSec = CMTimeGetSeconds(effectiveTime)
        let selectedIds = selectedClipIds

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

        if hasSelectedUnderPlayhead {
            return selectedIds
        }

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
        if targetIds.isEmpty && !selectedIds.isEmpty {
            targetIds = selectedIds
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

        // Determina target state: se almeno una clip target non è bloccata -> blocca tutte, altrimenti sblocca tutte
        var anyUnlocked = false
        for track in videoTracks where !track.isLocked {
            if track.clips.contains(where: { allTargetIds.contains($0.id) && !$0.isLocked }) {
                anyUnlocked = true
                break
            }
        }
        if !anyUnlocked {
            for track in audioTracks where !track.isLocked {
                if track.clips.contains(where: { allTargetIds.contains($0.id) && !$0.isLocked }) {
                    anyUnlocked = true
                    break
                }
            }
        }

        let targetLockedState = anyUnlocked
        var count = 0
        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            for cIdx in 0..<videoTracks[tIdx].clips.count where allTargetIds.contains(videoTracks[tIdx].clips[cIdx].id) {
                videoTracks[tIdx].clips[cIdx].isLocked = targetLockedState
                count += 1
            }
        }
        for tIdx in 0..<audioTracks.count where !audioTracks[tIdx].isLocked {
            for cIdx in 0..<audioTracks[tIdx].clips.count where allTargetIds.contains(audioTracks[tIdx].clips[cIdx].id) {
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
        let label = priority.map { "Priorità \($0)" } ?? "Priorità rimossa"
        let first = updatedNames.first ?? "Clip"
        let countSuffix = updatedNames.count > 1 ? " (+\(updatedNames.count - 1))" : ""
        return (max(updatedCount, updatedNames.count), "\(first)\(countSuffix) -> \(label)")
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
        let p1 = selectionClips.filter { ($0.priority ?? 1) == 1 }.count
        let p2 = selectionClips.filter { $0.priority == 2 }.count
        let p3 = selectionClips.filter { $0.priority == 3 }.count
        return AutoFillForecast(
            totalTargetCages: plan.targetCages.count,
            lockedCagesCount: plan.lockedCagesCount,
            unlockedCagesCount: plan.unlockedCages.count,
            selectionClipCount: selectionClips.count,
            p1Count: p1,
            p2Count: p2,
            p3Count: p3,
            predictedUniqueCount: plan.primaryUniqueCount,
            predictedSubsegmentCount: plan.subsegmentCount,
            predictedFilledCount: plan.assignments.count,
            predictedEmptyCount: max(0, plan.unlockedCages.count - plan.assignments.count),
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
        let assignments: [(cage: RhythmicCage, entryIdx: Int, effIn: Double, effOut: Double)]
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
            if clip.isLocked || isBeforeWindow {
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

            let prio = (1...3).contains(sClip.priority ?? 1) ? (sClip.priority ?? 1) : 1
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
                primaryUniqueCount: 0,
                subsegmentCount: 0
            )
        }

        let workingOrder: [Int]
        switch (orderMode, deterministicPreview) {
        case (.chronological, _), (.random, true):
            workingOrder = Array(0..<pool.count)
        case (.random, false):
            let p1 = (0..<pool.count).filter { pool[$0].effectivePriority == 1 }.shuffled()
            let p2 = (0..<pool.count).filter { pool[$0].effectivePriority == 2 }.shuffled()
            let p3 = (0..<pool.count).filter { pool[$0].effectivePriority == 3 }.shuffled()
            workingOrder = p1 + p2 + p3
        }

        var assignedPerCage: [Int: (entryIdx: Int, effIn: Double, effOut: Double)] = [:]
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

        // PASS 1: 1 spezzone per clip (nessuna ripetizione), priorità 1 -> 2 -> 3 + marcatori
        for (slotIdx, cage) in unlockedCages.enumerated() {
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
                            assignedPerCage[slotIdx] = (idx, slice.effIn, slice.effOut)
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

        // PASS 2: Sottospezzoni non sovrapposti se restano gabbie vuote
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
                            assignedPerCage[slotIdx] = (idx, slice.effIn, slice.effOut)
                            subsegmentCount += 1
                            matched = true
                            break
                        }
                    }
                    if matched { break }
                }
            }
        }

        var assignments: [(cage: RhythmicCage, entryIdx: Int, effIn: Double, effOut: Double)] = []
        for (slotIdx, cage) in unlockedCages.enumerated() {
            if let match = assignedPerCage[slotIdx] {
                assignments.append((cage, match.entryIdx, match.effIn, match.effOut))
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
            guard !aClip.isLocked else { return false }
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
                if clip.isLocked || linkedToPreservedV {
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
                span: 1,
                markers: sClip.markers,
                priority: sClip.priority,
                isLocked: false,
                selectionSourceIn: entry.selectionOriginIn,
                selectionSourceOut: entry.selectionOriginOut
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
                    span: 1,
                    markers: sClip.markers,
                    priority: sClip.priority,
                    isLocked: false,
                    selectionSourceIn: entry.selectionOriginIn,
                    selectionSourceOut: entry.selectionOriginOut
                )
                audioTracks[0].clips.append(aClip)
            }
        }

        videoTracks[targetTrackIndex].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        audioTracks[0].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }

        // Attiva automaticamente Modalità Montaggio a Gabbie dopo Auto-Fill
        isCageLockActive = true

        let filledCount = plan.assignments.count
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
            if let acIdx = audioTracks[aIdx].clips.firstIndex(where: { $0.linkGroupId == lId && !$0.isLocked }) {
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
        guard !draggedClip.isLocked else { return false }

        let targetCage = activeCages[targetCageIndex]
        let lockedClips = videoTracks[tIdx].clips.filter { $0.isLocked }
        if isCageOccupied(targetCage, by: lockedClips) {
            DebugLogger.shared.log("Impossibile spostare nella gabbia \(targetCageIndex + 1): gabbia bloccata 🔒.", level: .warning)
            return false
        }

        var unlockedClips = videoTracks[tIdx].clips.filter { !$0.isLocked }
        guard let draggedUnlockedIdx = unlockedClips.firstIndex(where: { $0.id == clipId }) else { return false }

        let freeCages = activeCages.filter { !isCageOccupied($0, by: lockedClips) }
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
            let bounds = clip.effectiveSourceBounds
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
        guard !videoTracks[tIdx].clips[cIdx].isLocked else {
            DebugLogger.shared.log("Clip bloccata: sblocca la clip (L) prima di eliminarla.", level: .warning)
            return false
        }

        let removedClip = videoTracks[tIdx].clips.remove(at: cIdx)
        if let lId = removedClip.linkGroupId, isLinkActive {
            for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                audioTracks[aIdx].clips.removeAll { $0.linkGroupId == lId && !$0.isLocked }
            }
        }

        let activeCages = activeCageIntervals()
        if !activeCages.isEmpty {
            let deletedStartCage = removedClip.cageIndex ?? cageIndex(at: removedClip.timelineStart) ?? cIdx
            let lockedClips = videoTracks[tIdx].clips.filter { $0.isLocked }
            let freeCagesAfter = activeCages.filter { $0.index >= deletedStartCage && !isCageOccupied($0, by: lockedClips) }

            var freeCursor = 0
            for i in 0..<videoTracks[tIdx].clips.count {
                var vClip = videoTracks[tIdx].clips[i]
                guard !vClip.isLocked else { continue }
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
                let bounds = vClip.effectiveSourceBounds
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

    /// Restituisce bounds e finestre correnti per la barra flottante Slip (`Tab+Drag`).
    public func slipClipSelectionBounds(clipId: UUID) -> (sourceIn: Double, sourceOut: Double, sourceDur: Double, boundsMin: Double, boundsMax: Double, markers: [Double])? {
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                let b = clip.effectiveSourceBounds
                let sIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
                let sDur = max(0.05, min(b.maxSec - b.minSec, CMTimeGetSeconds(clip.sourceDuration)))
                let markersInRange = clip.markers.filter { $0 >= b.minSec - 0.01 && $0 <= b.maxSec + 0.01 }
                return (sIn, sIn + sDur, sDur, b.minSec, b.maxSec, markersInRange)
            }
        }
        return nil
    }

    /// Scorre il frammento interno (`Tab+Drag`) strettamente dentro l'estratto dalla Selezione senza straripare dalla gabbia.
    @discardableResult
    public func slipClipWithinSelection(clipId: UUID, newSourceIn: Double) -> (newIn: Double, newOut: Double)? {
        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            if let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                var clip = videoTracks[tIdx].clips[cIdx]
                guard !clip.isLocked else { return nil }
                let b = clip.effectiveSourceBounds
                let sourceDurSec = min(b.maxSec - b.minSec, max(0.05, CMTimeGetSeconds(clip.sourceDuration)))
                let maxAllowedIn = max(b.minSec, b.maxSec - sourceDurSec)
                let clampedIn = min(maxAllowedIn, max(b.minSec, newSourceIn))
                let clampedOut = clampedIn + sourceDurSec

                clip.sourceIn = CMTime(seconds: clampedIn, preferredTimescale: 600)
                clip.sourceOut = CMTime(seconds: clampedOut, preferredTimescale: 600)
                videoTracks[tIdx].clips[cIdx] = clip

                syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: clip.speed, cageIndex: clip.cageIndex, span: clip.span)
                onModelChanged?()
                return (clampedIn, clampedOut)
            }
        }
        return nil
    }

    /// Slip Tool: fa scorrere il contenuto interno (`sourceIn`/`Out`) senza modificare i tagli sulla timeline (rispettando eventuali bounds Selezione).
    @discardableResult
    public func slipClip(clipId: UUID, deltaSeconds: Double) -> Bool {
        guard let info = slipClipSelectionBounds(clipId: clipId) else { return false }
        return slipClipWithinSelection(clipId: clipId, newSourceIn: info.sourceIn + deltaSeconds) != nil
    }

    /// Estende o riduce la copertura di una clip su 1, 2 o più gabbie consecutive
    @discardableResult
    public func setClipSpan(clipId: UUID, newSpan: Int) -> Bool {
        guard newSpan >= 1 else { return false }
        let activeCages = activeCageIntervals()
        for tIdx in 0..<videoTracks.count {
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var clip = videoTracks[tIdx].clips[cIdx]
            guard let startCageIdx = clip.cageIndex, startCageIdx < activeCages.count else { continue }

            let endCageIdx = min(activeCages.count - 1, startCageIdx + newSpan - 1)
            let combinedDur = activeCages[endCageIdx].endSeconds - activeCages[startCageIdx].startSeconds
            guard combinedDur > 0 else { continue }

            clip.span = newSpan
            let durTime = CMTime(seconds: combinedDur, preferredTimescale: 600)
            let scaledDur = clip.speed > 0 ? CMTime(seconds: combinedDur * clip.speed, preferredTimescale: 600) : durTime
            clip.sourceOut = CMTimeAdd(clip.sourceIn, scaledDur)
            videoTracks[tIdx].clips[cIdx] = clip

            var nextCageIdx = endCageIdx + 1
            for nextIdx in (cIdx + 1)..<videoTracks[tIdx].clips.count {
                if nextCageIdx < activeCages.count {
                    let nextCage = activeCages[nextCageIdx]
                    videoTracks[tIdx].clips[nextIdx].cageIndex = nextCageIdx
                    videoTracks[tIdx].clips[nextIdx].timelineStart = nextCage.startTime
                    let nDur = nextCage.durationTime
                    let nScaled = videoTracks[tIdx].clips[nextIdx].speed > 0 ? CMTime(seconds: CMTimeGetSeconds(nDur) * videoTracks[tIdx].clips[nextIdx].speed, preferredTimescale: 600) : nDur
                    videoTracks[tIdx].clips[nextIdx].sourceOut = CMTimeAdd(videoTracks[tIdx].clips[nextIdx].sourceIn, nScaled)
                    nextCageIdx += videoTracks[tIdx].clips[nextIdx].span
                }
            }

            DebugLogger.shared.log("Clip impostata per occupare \(newSpan) gabbie ritmate (\(String(format: "%.2f", combinedDur))s).", level: .info)
            onModelChanged?()
            return true
        }
        return false
    }

    /// Alterna la velocità della clip (`100% <-> 50%`) restando **dentro la gabbia attuale** (`R` / `⌥S`).
    @discardableResult
    public func toggleClipSpeed(clipId: UUID) -> Double? {
        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            if let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                var clip = videoTracks[tIdx].clips[cIdx]
                guard !clip.isLocked else { return nil }
                let newSpeed: Double = (abs(clip.speed - 1.0) < 0.01) ? 0.5 : 1.0
                let timelineDur = CMTimeGetSeconds(clip.duration)
                let newSourceDur = timelineDur * newSpeed
                let b = clip.effectiveSourceBounds
                var newIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
                var newOut = newIn + newSourceDur

                if newOut > b.maxSec {
                    let maxShift = max(b.minSec, b.maxSec - newSourceDur)
                    if newSourceDur <= (b.maxSec - b.minSec) + 0.01 {
                        newIn = maxShift
                        newOut = min(b.maxSec, newIn + newSourceDur)
                    } else {
                        DebugLogger.shared.log("Clip troppo corta per velocità \(Int(newSpeed * 100))% in questa gabbia.", level: .warning)
                        return nil
                    }
                }

                clip.speed = newSpeed
                clip.sourceIn = CMTime(seconds: newIn, preferredTimescale: 600)
                clip.sourceOut = CMTime(seconds: newOut, preferredTimescale: 600)
                videoTracks[tIdx].clips[cIdx] = clip

                syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: newSpeed, cageIndex: clip.cageIndex, span: clip.span)
                DebugLogger.shared.log("Velocità clip '\(clip.mediaItem.name)' in gabbia impostata a \(Int(newSpeed * 100))%.", level: .info)
                onModelChanged?()
                return newSpeed
            }
        }
        return nil
    }

    /// Alterna Slow-Mo 50% **straripando alla gabbia successiva (2 gabbie)** oppure riducendo a 1 gabbia a 100% (`⌘R`).
    /// - Rifiuta sempre se una qualsiasi clip successiva è `isLocked`.
    /// - Verifica che la clip sorgente abbia abbastanza frame per coprire `gabbia[i] + gabbia[i+1]` al 50%.
    /// - Sposta in avanti / indietro le clip successive con Ripple Forward/Back dentro le gabbie.
    @discardableResult
    public func toggleSlowMoMultiCage(clipId: UUID) -> (didChange: Bool, newSpeed: Double, newSpan: Int, errorMessage: String?) {
        let activeCages = activeCageIntervals()
        guard !activeCages.isEmpty else {
            return (false, 1.0, 1, "Nessuna gabbia ritmata attiva.")
        }

        for tIdx in 0..<videoTracks.count where !videoTracks[tIdx].isLocked {
            videoTracks[tIdx].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var clip = videoTracks[tIdx].clips[cIdx]
            guard !clip.isLocked else {
                return (false, clip.speed, clip.span, "Clip bloccata 🔒.")
            }

            // Blocco severo se esiste ANY clip successiva bloccata
            if (cIdx + 1) < videoTracks[tIdx].clips.count {
                let hasLaterLocked = videoTracks[tIdx].clips[(cIdx + 1)...].contains(where: { $0.isLocked })
                if hasLaterLocked {
                    let msg = "Slow-Mo multi-gabbia bloccato: presente una clip bloccata 🔒 successivamente."
                    DebugLogger.shared.log(msg, level: .warning)
                    return (false, clip.speed, clip.span, msg)
                }
            }

            let startCageIdx = clip.cageIndex ?? cageIndex(at: clip.timelineStart) ?? cIdx
            guard startCageIdx >= 0 && startCageIdx < activeCages.count else {
                return (false, clip.speed, clip.span, "Clip fuori dalle gabbie.")
            }

            if clip.span <= 1 {
                // ESPANDI a 2 gabbie in Slow-Mo 50%
                let nextCageIdx = startCageIdx + 1
                guard nextCageIdx < activeCages.count else {
                    let msg = "Nessuna gabbia successiva disponibile per estendere lo Slow-Mo."
                    DebugLogger.shared.log(msg, level: .warning)
                    return (false, clip.speed, clip.span, msg)
                }

                let combinedDur = activeCages[nextCageIdx].endSeconds - activeCages[startCageIdx].startSeconds
                let newSpeed = 0.5
                let neededSource = combinedDur * newSpeed
                let b = clip.effectiveSourceBounds
                let sIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
                let availAfterIn = max(0.0, b.maxSec - sIn)

                guard availAfterIn >= neededSource - 0.01 else {
                    let msg = String(format: "Materiale clip insufficiente: servono %.1fs originali (%.1fs al 50%%), disponibili %.1fs.", neededSource, combinedDur, availAfterIn)
                    DebugLogger.shared.log(msg, level: .warning)
                    return (false, clip.speed, clip.span, msg)
                }

                clip.speed = newSpeed
                clip.span = 2
                clip.cageIndex = startCageIdx
                clip.timelineStart = activeCages[startCageIdx].startTime
                clip.sourceIn = CMTime(seconds: sIn, preferredTimescale: 600)
                clip.sourceOut = CMTime(seconds: min(b.maxSec, sIn + neededSource), preferredTimescale: 600)
                videoTracks[tIdx].clips[cIdx] = clip
                syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: newSpeed, cageIndex: startCageIdx, span: 2)

                // Ripple forward di tutte le clip successive dentro le gabbie successive
                var cursorCage = startCageIdx + 2
                var overflowStart = activeCages.last!.endSeconds
                for i in (cIdx + 1)..<videoTracks[tIdx].clips.count {
                    var nextClip = videoTracks[tIdx].clips[i]
                    let nSpan = max(1, nextClip.span)
                    let nSpd = nextClip.speed > 0 ? nextClip.speed : 1.0
                    let nb = nextClip.effectiveSourceBounds
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

                onModelChanged?()
                DebugLogger.shared.log("Slow-Mo 50% esteso su 2 gabbie (Ripple avanti applicato).", level: .info)
                return (true, 0.5, 2, nil)
            } else {
                // RIDUCI a 1 gabbia a velocità 100%
                let singleDur = activeCages[startCageIdx].durationSeconds
                let newSpeed = 1.0
                let neededSource = singleDur * newSpeed
                let b = clip.effectiveSourceBounds
                var sIn = max(b.minSec, min(b.maxSec, CMTimeGetSeconds(clip.sourceIn)))
                var sOut = sIn + neededSource
                if sOut > b.maxSec {
                    sOut = b.maxSec
                    sIn = max(b.minSec, sOut - neededSource)
                }

                clip.speed = newSpeed
                clip.span = 1
                clip.cageIndex = startCageIdx
                clip.timelineStart = activeCages[startCageIdx].startTime
                clip.sourceIn = CMTime(seconds: sIn, preferredTimescale: 600)
                clip.sourceOut = CMTime(seconds: sOut, preferredTimescale: 600)
                videoTracks[tIdx].clips[cIdx] = clip
                syncLinkedAudioClip(for: clip, startTime: clip.timelineStart, sourceIn: clip.sourceIn, sourceOut: clip.sourceOut, speed: newSpeed, cageIndex: startCageIdx, span: 1)

                // Ripple backward delle clip successive
                var cursorCage = startCageIdx + 1
                for i in (cIdx + 1)..<videoTracks[tIdx].clips.count {
                    var nextClip = videoTracks[tIdx].clips[i]
                    guard cursorCage < activeCages.count else { break }
                    let nSpan = max(1, nextClip.span)
                    let nSpd = nextClip.speed > 0 ? nextClip.speed : 1.0
                    let endCage = min(activeCages.count - 1, cursorCage + nSpan - 1)
                    let actualSpan = endCage - cursorCage + 1
                    let cDur = activeCages[endCage].endSeconds - activeCages[cursorCage].startSeconds
                    let nb = nextClip.effectiveSourceBounds
                    let nIn = max(nb.minSec, min(nb.maxSec, CMTimeGetSeconds(nextClip.sourceIn)))
                    let nOut = min(nb.maxSec, nIn + cDur * nSpd)

                    nextClip.cageIndex = cursorCage
                    nextClip.span = actualSpan
                    nextClip.timelineStart = activeCages[cursorCage].startTime
                    nextClip.sourceIn = CMTime(seconds: nIn, preferredTimescale: 600)
                    nextClip.sourceOut = CMTime(seconds: nOut, preferredTimescale: 600)
                    videoTracks[tIdx].clips[i] = nextClip
                    syncLinkedAudioClip(for: nextClip, startTime: nextClip.timelineStart, sourceIn: nextClip.sourceIn, sourceOut: nextClip.sourceOut, speed: nSpd, cageIndex: cursorCage, span: actualSpan)

                    cursorCage = endCage + 1
                }

                onModelChanged?()
                DebugLogger.shared.log("Slow-Mo multi-gabbia disattivato: clip ridotta a 1 gabbia (100%).", level: .info)
                return (true, 1.0, 1, nil)
            }
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

        // Se una delle due clip adiacenti è bloccata (Lock), la sbarra non si muove!
        if let l = leftMatch, l.clip.isLocked { return nil }
        if let r = rightMatch, r.clip.isLocked { return nil }

        // Clamp ai limiti fisici/Selezione delle due clip adiacenti
        if let l = leftMatch {
            let lStart = CMTimeGetSeconds(l.clip.timelineStart)
            let lSrcIn = CMTimeGetSeconds(l.clip.sourceIn)
            let lSpd = l.clip.speed > 0 ? l.clip.speed : 1.0
            let lBounds = l.clip.effectiveSourceBounds
            minAllowed = max(minAllowed, lStart + minClipDur)
            let maxTimelineEndFromSource = lStart + max(minClipDur, (lBounds.maxSec - lSrcIn) / lSpd)
            maxAllowed = min(maxAllowed, maxTimelineEndFromSource)
        }
        if let r = rightMatch {
            let rEnd = CMTimeGetSeconds(r.clip.timelineEnd)
            let rSrcOut = CMTimeGetSeconds(r.clip.sourceOut)
            let rSpd = r.clip.speed > 0 ? r.clip.speed : 1.0
            let rBounds = r.clip.effectiveSourceBounds
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
            let newOutSec = min(updatedLeft.effectiveSourceBounds.maxSec, CMTimeGetSeconds(updatedLeft.sourceIn) + newDur * lSpd)
            updatedLeft.sourceOut = CMTime(seconds: newOutSec, preferredTimescale: 600)
            videoTracks[l.tIdx].clips[l.cIdx] = updatedLeft
            syncLinkedAudioClip(for: updatedLeft, startTime: updatedLeft.timelineStart, sourceIn: updatedLeft.sourceIn, sourceOut: updatedLeft.sourceOut, speed: updatedLeft.speed, cageIndex: updatedLeft.cageIndex, span: updatedLeft.span)
        }

        if let r = rightMatch {
            var updatedRight = r.clip
            let rStart = CMTimeGetSeconds(updatedRight.timelineStart)
            let rSpd = updatedRight.speed > 0 ? updatedRight.speed : 1.0
            let deltaTL = finalTimelineSec - rStart
            let newSrcIn = max(updatedRight.effectiveSourceBounds.minSec, CMTimeGetSeconds(updatedRight.sourceIn) + deltaTL * rSpd)
            updatedRight.timelineStart = CMTime(seconds: finalTimelineSec, preferredTimescale: 600)
            updatedRight.sourceIn = CMTime(seconds: newSrcIn, preferredTimescale: 600)
            videoTracks[r.tIdx].clips[r.cIdx] = updatedRight
            syncLinkedAudioClip(for: updatedRight, startTime: updatedRight.timelineStart, sourceIn: updatedRight.sourceIn, sourceOut: updatedRight.sourceOut, speed: updatedRight.speed, cageIndex: updatedRight.cageIndex, span: updatedRight.span)
        }

        onModelChanged?()
        return (finalTimelineSec, updatedMarkerSource)
    }

    /// Scambia di posto la clip con quella nella gabbia adiacente (sinistra -1, destra +1)
    @discardableResult
    public func swapAdjacentCages(clipId: UUID, direction: Int) -> Bool {
        for tIdx in 0..<videoTracks.count {
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            let targetIdx = cIdx + direction
            guard targetIdx >= 0 && targetIdx < videoTracks[tIdx].clips.count else { continue }
            guard !videoTracks[tIdx].clips[cIdx].isLocked && !videoTracks[tIdx].clips[targetIdx].isLocked else { return false }

            let targetCage = videoTracks[tIdx].clips[targetIdx].cageIndex ?? targetIdx
            return reorderClipInCages(clipId: clipId, toCageIndex: targetCage)
        }
        return false
    }
}
