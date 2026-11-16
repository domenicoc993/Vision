import Foundation
import AVFoundation

public enum ClipEdge {
    case start
    case end
}

public enum AutoFillOrderMode: String, CaseIterable {
    case chronological = "Cronologia Elastica (ordine Selezione)"
    case random = "Casuale (Random)"
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
        onModelChanged?()
        return true
    }

    public func convertToTimeline() {
        guard isSelection else { return }
        isSelection = false
        onModelChanged?()
    }

    // MARK: - Track Mute & Lock (Lucchetto)
    public func toggleTrackLock(id: Int, isVideo: Bool) {
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

    // MARK: - Overwrite Editing Core Engine
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
                        markers: clip.markers
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
                        markers: clip.markers
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
            overwriteAndInsert(incoming: vClip, trackIndex: safeVideoTrack, isVideo: true)

            if mediaItem.hasAudio && isLinkActive {
                let audioTrackIdx = min(safeVideoTrack, maxAudioTracks - 1)
                ensureAudioTrack(id: audioTrackIdx)
                if !audioTracks[audioTrackIdx].isLocked {
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
            overwriteAndInsert(incoming: aClip, trackIndex: safeAudioTrack, isVideo: false)

            if mediaItem.hasVideo && isLinkActive {
                let videoTrackIdx = min(safeAudioTrack, maxVideoTracks - 1)
                ensureVideoTrack(id: videoTrackIdx)
                if !videoTracks[videoTrackIdx].isLocked {
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
        if isVideo {
            guard targetTrack < videoTracks.count, !videoTracks[targetTrack].isLocked else { return }
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isLocked }) {
                    videoTracks[trackIdx].clips[clipIdx].timelineStart = max(.zero, newStartTime)
                    videoTracks[trackIdx].clips[clipIdx].trackIndex = targetTrack
                    return
                }
            }
        } else {
            guard targetTrack < audioTracks.count, !audioTracks[targetTrack].isLocked else { return }
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isLocked }) {
                    audioTracks[trackIdx].clips[clipIdx].timelineStart = max(.zero, newStartTime)
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

        if isVideo {
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isLocked }) {
                    movedClip = videoTracks[trackIdx].clips.remove(at: clipIdx)
                    break
                }
            }
            var finalClipStart: CMTime? = nil
            var finalClipSourceOut: CMTime? = nil

            if var clip = movedClip {
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

                overwriteAndInsert(incoming: clip, trackIndex: targetTrack, isVideo: true)
            }

            if isLinkActive, let cId = companionId ?? findCompanionId(for: movedClip?.linkGroupId, isVideo: true) {
                for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                    if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == cId }) {
                        var aClip = audioTracks[trackIdx].clips.remove(at: clipIdx)
                        if let fStart = finalClipStart {
                            aClip.timelineStart = fStart
                        }
                        if let fOut = finalClipSourceOut {
                            let maxA = CMTimeGetSeconds(aClip.mediaItem.duration)
                            aClip.sourceOut = CMTime(seconds: min(maxA, CMTimeGetSeconds(fOut)), preferredTimescale: 600)
                        }
                        overwriteAndInsert(incoming: aClip, trackIndex: aClip.trackIndex, isVideo: false)
                        break
                    }
                }
            }
        } else {
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == id && !$0.isLocked }) {
                    movedClip = audioTracks[trackIdx].clips.remove(at: clipIdx)
                    break
                }
            }
            if var clip = movedClip {
                ensureAudioTrack(id: targetTrack)
                clip.trackIndex = targetTrack
                if let newStart = newStartTime {
                    clip.timelineStart = max(.zero, newStart)
                }
                overwriteAndInsert(incoming: clip, trackIndex: targetTrack, isVideo: false)
            }

            if isLinkActive, let cId = companionId ?? findCompanionId(for: movedClip?.linkGroupId, isVideo: false) {
                for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                    if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == cId }) {
                        let vClip = videoTracks[trackIdx].clips.remove(at: clipIdx)
                        overwriteAndInsert(incoming: vClip, trackIndex: vClip.trackIndex, isVideo: true)
                        break
                    }
                }
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
                    didMark = true
                }
            }
        }
        for tIdx in 0..<audioTracks.count {
            for cIdx in 0..<audioTracks[tIdx].clips.count {
                if audioTracks[tIdx].clips[cIdx].mediaItem.id == id || (url != nil && audioTracks[tIdx].clips[cIdx].mediaItem.url == url) {
                    audioTracks[tIdx].clips[cIdx].isOrphan = true
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
            if isLinkActive, let lId = targetClip.linkGroupId {
                for track in videoTracks where !track.isLocked {
                    for c in track.clips where c.linkGroupId == lId { idsToRemove.insert(c.id) }
                }
                for track in audioTracks where !track.isLocked {
                    for c in track.clips where c.linkGroupId == lId { idsToRemove.insert(c.id) }
                }
            }

            // Remove from tracks
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                videoTracks[trackIdx].clips.removeAll(where: { idsToRemove.contains($0.id) })
            }
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                audioTracks[trackIdx].clips.removeAll(where: { idsToRemove.contains($0.id) })
            }
            selectedClipIds.subtract(idsToRemove)

            // Modalità con scarto: ripple all clips on unlocked tracks starting at or after endSec backward (skip individually locked clips)
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                for cIdx in 0..<videoTracks[trackIdx].clips.count {
                    let clip = videoTracks[trackIdx].clips[cIdx]
                    guard !clip.isLocked else { continue }
                    let clipStart = CMTimeGetSeconds(clip.timelineStart)
                    if clipStart >= endSec - 0.01 {
                        let newStart = max(startSec, clipStart - durSec)
                        videoTracks[trackIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                    }
                }
            }
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                for cIdx in 0..<audioTracks[trackIdx].clips.count {
                    let clip = audioTracks[trackIdx].clips[cIdx]
                    guard !clip.isLocked else { continue }
                    let clipStart = CMTimeGetSeconds(clip.timelineStart)
                    if clipStart >= endSec - 0.01 {
                        let newStart = max(startSec, clipStart - durSec)
                        audioTracks[trackIdx].clips[cIdx].timelineStart = CMTime(seconds: newStart, preferredTimescale: 600)
                    }
                }
            }

            didRipple = true
        }

        if didRipple {
            onModelChanged?()
            DebugLogger.shared.log("Eliminazione con scarto (Ripple Delete) completata: rimosso spazio vuoto.", level: .info)
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
                            isLocked: clip.isLocked
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
                            isLocked: clip.isLocked
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
                    changed = true
                }
            }
        }
        for t in 0..<audioTracks.count {
            for c in 0..<audioTracks[t].clips.count {
                if audioTracks[t].clips[c].mediaItem.id == mediaId {
                    audioTracks[t].clips[c].isOrphan = true
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

            func applyStartTrim(to trackList: inout [TimelineTrack], matchClipId: UUID?, matchLinkId: UUID?) {
                for tIdx in 0..<trackList.count where !trackList[tIdx].isLocked {
                    for cIdx in 0..<trackList[tIdx].clips.count {
                        let c = trackList[tIdx].clips[cIdx]
                        let isThisClip = (matchClipId != nil && c.id == matchClipId!) ||
                                         (matchLinkId != nil && c.linkGroupId == matchLinkId!)
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

            applyStartTrim(to: &videoTracks, matchClipId: isVideo ? clipId : nil, matchLinkId: linkId)
            applyStartTrim(to: &audioTracks, matchClipId: !isVideo ? clipId : nil, matchLinkId: linkId)

        } else {
            let minDur: Double = 0.1
            let maxDur: Double = max(minDur, mediaDurSec - curInSec)
            let curDur = curOutSec - curInSec
            let proposedDur = max(minDur, min(maxDur, curDur + deltaSeconds))
            let durationDelta = proposedDur - curDur
            guard abs(durationDelta) > 0.001 else { return false }

            func applyEndTrim(to trackList: inout [TimelineTrack], matchClipId: UUID?, matchLinkId: UUID?) {
                for tIdx in 0..<trackList.count where !trackList[tIdx].isLocked {
                    for cIdx in 0..<trackList[tIdx].clips.count {
                        let c = trackList[tIdx].clips[cIdx]
                        let isThisClip = (matchClipId != nil && c.id == matchClipId!) ||
                                         (matchLinkId != nil && c.linkGroupId == matchLinkId!)
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

            applyEndTrim(to: &videoTracks, matchClipId: isVideo ? clipId : nil, matchLinkId: linkId)
            applyEndTrim(to: &audioTracks, matchClipId: !isVideo ? clipId : nil, matchLinkId: linkId)
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

    /// Aggiunge o rimuove (se entro ±0.08s) un marcatore sulle clip audio/video sotto la testina.
    @discardableResult
    public func toggleClipMarker(at time: CMTime) -> (added: Int, removed: Int, summary: [String]) {
        let timeSec = CMTimeGetSeconds(time)
        let selectedIds = selectedClipIds

        // Se almeno una clip selezionata si trova sotto la testina, agisci solo su quelle selezionate
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

                    if let existingIdx = clip.markers.firstIndex(where: { abs($0 - sourceSec) <= tolSource }) {
                        clip.markers.remove(at: existingIdx)
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
        func apply(_ tracks: inout [TimelineTrack]) -> Bool {
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                if let cIdx = tracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                    var clip = tracks[tIdx].clips[cIdx]
                    let cStart = CMTimeGetSeconds(clip.timelineStart)
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let sourceSec = max(CMTimeGetSeconds(clip.sourceIn), min(CMTimeGetSeconds(clip.sourceOut), CMTimeGetSeconds(clip.sourceIn) + (timelineSec - cStart) * spd))
                    let tolSource = 0.12 * spd
                    if let existingIdx = clip.markers.firstIndex(where: { abs($0 - sourceSec) <= tolSource }) {
                        clip.markers.remove(at: existingIdx)
                    } else {
                        clip.markers.append(sourceSec)
                        clip.markers.sort()
                    }
                    tracks[tIdx].clips[cIdx] = clip
                    return true
                }
            }
            return false
        }
        if apply(&videoTracks) || apply(&audioTracks) {
            onModelChanged?()
            return true
        }
        return false
    }

    @discardableResult
    public func clearMarkers(clipId: UUID) -> Bool {
        func clear(_ tracks: inout [TimelineTrack]) -> Bool {
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                if let cIdx = tracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                    tracks[tIdx].clips[cIdx].markers.removeAll()
                    return true
                }
            }
            return false
        }
        if clear(&videoTracks) || clear(&audioTracks) {
            onModelChanged?()
            return true
        }
        return false
    }

    @discardableResult
    public func clearAllClipMarkers(at time: CMTime?) -> Int {
        let selectedIds = selectedClipIds
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
        func update(in tracks: inout [TimelineTrack]) -> Double? {
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                guard let cIdx = tracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
                var clip = tracks[tIdx].clips[cIdx]
                let sIn = CMTimeGetSeconds(clip.sourceIn)
                let sOut = CMTimeGetSeconds(clip.sourceOut)
                let clamped = max(sIn, min(sOut, toSourceSec))

                var arr = isBeatMarker ? clip.beatMarkers : clip.markers
                guard let matchIdx = arr.enumerated().min(by: { abs($0.element - fromSourceSec) < abs($1.element - fromSourceSec) })?.offset,
                      abs(arr[matchIdx] - fromSourceSec) <= 0.25 else {
                    return nil
                }

                arr[matchIdx] = clamped
                arr.sort()
                if isBeatMarker {
                    clip.beatMarkers = arr
                } else {
                    clip.markers = arr
                }
                tracks[tIdx].clips[cIdx] = clip
                return clamped
            }
            return nil
        }

        if let newSec = update(in: &videoTracks) ?? update(in: &audioTracks) {
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
        func remove(in tracks: inout [TimelineTrack]) -> Bool {
            for tIdx in 0..<tracks.count where !tracks[tIdx].isLocked {
                guard let cIdx = tracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
                var clip = tracks[tIdx].clips[cIdx]
                var arr = isBeatMarker ? clip.beatMarkers : clip.markers
                guard let matchIdx = arr.enumerated().min(by: { abs($0.element - nearSourceSec) < abs($1.element - nearSourceSec) })?.offset,
                      abs(arr[matchIdx] - nearSourceSec) <= 0.25 else {
                    return false
                }
                arr.remove(at: matchIdx)
                if isBeatMarker {
                    clip.beatMarkers = arr
                } else {
                    clip.markers = arr
                }
                tracks[tIdx].clips[cIdx] = clip
                return true
            }
            return false
        }

        if remove(in: &videoTracks) || remove(in: &audioTracks) {
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
        onModelChanged?()
        return true
    }

    // MARK: - Selection Priority Tagging & Per-Clip Lock
    private func resolveTargetClipIds(at time: CMTime) -> Set<UUID> {
        let timeSec = CMTimeGetSeconds(time)
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
    public func activeCageIntervals() -> [RhythmicCage] {
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
    public func autoFillCagesDetailed(
        withSelectionTimeline selTimeline: TimelineModel,
        targetTrackIndex: Int = 0,
        overrideCages: [RhythmicCage]? = nil,
        orderMode: AutoFillOrderMode = .chronological
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
            orderMode: orderMode
        )
    }

    @discardableResult
    public func autoFillCages(
        withTimelineClips selectionClips: [TimelineClip],
        targetTrackIndex: Int = 0,
        overrideCages: [RhythmicCage]? = nil,
        orderMode: AutoFillOrderMode = .chronological
    ) -> Int {
        return autoFillCagesCore(
            withTimelineClips: selectionClips,
            selectionAudioClips: [],
            targetTrackIndex: targetTrackIndex,
            overrideCages: overrideCages,
            orderMode: orderMode
        ).filledCount
    }

    private struct AutoFillPoolEntry {
        let clip: TimelineClip
        let effectivePriority: Int
        let hasAudio: Bool
        var freeRanges: [(start: Double, end: Double)]
        var pass1Used: Bool = false
        var slicesTaken: Int = 0
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

        // Trova tutti i sotto-intervalli compatibili (>= neededDur - 0.02s, no slow-mo automatico)
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
                // Centra il marcatore più vicino al centro dell'intervallo
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

    private func autoFillCagesCore(
        withTimelineClips selectionClips: [TimelineClip],
        selectionAudioClips: [TimelineClip],
        targetTrackIndex: Int,
        overrideCages: [RhythmicCage]?,
        orderMode: AutoFillOrderMode
    ) -> AutoFillResult {
        let activeCages = overrideCages ?? activeCageIntervals()
        guard !activeCages.isEmpty else {
            DebugLogger.shared.log("Nessuna gabbia ritmata presente. Esegui prima l'analisi audio della traccia musicale.", level: .warning)
            return AutoFillResult(filledCount: 0, totalUnlockedCages: 0, lockedCagesCount: 0, primaryUniqueCount: 0, subsegmentCount: 0, remainingEmptyCages: 0, movedAudioToA2: false)
        }
        guard !selectionClips.isEmpty else {
            DebugLogger.shared.log("La selezione è vuota: aggiungi prima delle clip alla Selezione.", level: .warning)
            return AutoFillResult(filledCount: 0, totalUnlockedCages: activeCages.count, lockedCagesCount: 0, primaryUniqueCount: 0, subsegmentCount: 0, remainingEmptyCages: activeCages.count, movedAudioToA2: false)
        }

        ensureVideoTrack(id: targetTrackIndex)
        ensureAudioTrack(id: 0)

        // 1. Preserva le clip bloccate su V1 e rimuovi solo le clip sbloccate + relativo audio collegato
        let lockedVClips = videoTracks[targetTrackIndex].clips.filter { $0.isLocked }
        let unlockedVClips = videoTracks[targetTrackIndex].clips.filter { !$0.isLocked }
        let unlockedLinkIds = Set(unlockedVClips.compactMap { $0.linkGroupId })
        let lockedLinkIds = Set(lockedVClips.compactMap { $0.linkGroupId })

        videoTracks[targetTrackIndex].clips = lockedVClips

        // Pulisci da A1 solo gli audio collegati alle clip video rimosse
        audioTracks[0].clips.removeAll { aClip in
            guard !aClip.isLocked else { return false }
            if let lId = aClip.linkGroupId, unlockedLinkIds.contains(lId) {
                return true
            }
            return false
        }

        // Sposta da A1 ad A2 le tracce audio indipendenti (es. il brano musicale) così A1 resta dedicata all'audio dei video
        var movedAudioToA2 = false
        if targetTrackIndex == 0 {
            var remainingA1: [TimelineClip] = []
            var toMoveToA2: [TimelineClip] = []
            for clip in audioTracks[0].clips {
                let linkedToLockedV = clip.linkGroupId.map { lockedLinkIds.contains($0) } ?? false
                if clip.isLocked || linkedToLockedV {
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

        // 2. Identifica le gabbie già occupate da clip bloccate vs gabbie libere
        var unlockedCages: [RhythmicCage] = []
        var lockedCagesCount = 0
        for cage in activeCages {
            let isCoveredByLocked = lockedVClips.contains { locked in
                let lStart = CMTimeGetSeconds(locked.timelineStart)
                let lEnd = CMTimeGetSeconds(locked.timelineEnd)
                let overlap = min(lEnd, cage.endSeconds) - max(lStart, cage.startSeconds)
                return overlap > 0.02
            }
            if isCoveredByLocked {
                lockedCagesCount += 1
            } else {
                unlockedCages.append(cage)
            }
        }

        guard !unlockedCages.isEmpty else {
            onModelChanged?()
            return AutoFillResult(filledCount: 0, totalUnlockedCages: 0, lockedCagesCount: lockedCagesCount, primaryUniqueCount: 0, subsegmentCount: 0, remainingEmptyCages: 0, movedAudioToA2: movedAudioToA2)
        }

        // 3. Costruisci il pool candidati dalle clip della Selezione (nessun tag = priorità 1)
        var pool: [AutoFillPoolEntry] = []
        for sClip in selectionClips {
            let maxDur = CMTimeGetSeconds(sClip.mediaItem.duration)
            let origIn = max(0.0, CMTimeGetSeconds(sClip.sourceIn))
            let rawOut = CMTimeGetSeconds(sClip.sourceOut)
            let origOut = min(maxDur, max(origIn, rawOut))
            guard origOut - origIn > 0.05 else { continue }

            var freeRanges: [(start: Double, end: Double)] = [(origIn, origOut)]
            var lockedOverlapCount = 0
            for locked in lockedVClips where locked.mediaItem.id == sClip.mediaItem.id {
                let lIn = CMTimeGetSeconds(locked.sourceIn)
                let lOut = CMTimeGetSeconds(locked.sourceOut)
                if min(lOut, origOut) - max(lIn, origIn) > 0.02 {
                    lockedOverlapCount += 1
                }
                freeRanges = subtractUsedRange((lIn, lOut), from: freeRanges)
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
                freeRanges: freeRanges,
                pass1Used: lockedOverlapCount > 0,
                slicesTaken: lockedOverlapCount
            ))
        }

        guard !pool.isEmpty else {
            onModelChanged?()
            return AutoFillResult(filledCount: 0, totalUnlockedCages: unlockedCages.count, lockedCagesCount: lockedCagesCount, primaryUniqueCount: 0, subsegmentCount: 0, remainingEmptyCages: unlockedCages.count, movedAudioToA2: movedAudioToA2)
        }

        // Ordine di scansione (Cronologia Elastica vs Casuale entro ogni livello)
        let workingOrder: [Int]
        switch orderMode {
        case .chronological:
            workingOrder = Array(0..<pool.count)
        case .random:
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

        // PASS 1: 1 solo spezzone per clip (nessuna ripetizione), priorità 1 -> 2 -> 3 + preferenza clip con marcatori + cronologia elastica
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

        // PASS 2: Solo se restano gabbie vuote, prendi sottospezzoni non sovrapposti dagli intervalli liberi residui (prediligendo quelli con altri marcatori)
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

        // 4. Scrivi le clip piazzate su V1 (+ audio collegato su A1)
        for (slotIdx, cage) in unlockedCages.enumerated() {
            guard let match = assignedPerCage[slotIdx] else { continue }
            let entry = pool[match.entryIdx]
            let sClip = entry.clip
            let effIn = CMTime(seconds: match.effIn, preferredTimescale: 600)
            let effOut = CMTime(seconds: match.effOut, preferredTimescale: 600)
            let linkId = (targetTrackIndex == 0 && entry.hasAudio) ? UUID() : nil

            let vClip = TimelineClip(
                mediaItem: sClip.mediaItem,
                sourceIn: effIn,
                sourceOut: effOut,
                timelineStart: cage.startTime,
                trackIndex: targetTrackIndex,
                mediaType: .video,
                orientation: sClip.orientation,
                linkGroupId: linkId,
                speed: 1.0,
                cageIndex: cage.index,
                span: 1,
                markers: sClip.markers,
                priority: sClip.priority,
                isLocked: false
            )
            videoTracks[targetTrackIndex].clips.append(vClip)

            if targetTrackIndex == 0, entry.hasAudio {
                let aClip = TimelineClip(
                    mediaItem: sClip.mediaItem,
                    sourceIn: effIn,
                    sourceOut: effOut,
                    timelineStart: cage.startTime,
                    trackIndex: 0,
                    mediaType: .audio,
                    orientation: .normal,
                    linkGroupId: linkId,
                    speed: 1.0,
                    cageIndex: cage.index,
                    span: 1,
                    markers: sClip.markers,
                    priority: sClip.priority,
                    isLocked: false
                )
                audioTracks[0].clips.append(aClip)
            }
        }

        videoTracks[targetTrackIndex].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        audioTracks[0].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }

        let filledCount = assignedPerCage.count
        let remainingEmpty = unlockedCages.count - filledCount
        DebugLogger.shared.log(
            "Auto-Fill (\(orderMode == .chronological ? "Cronologia" : "Random")): \(filledCount)/\(unlockedCages.count) gabbie riempite (\(primaryUniqueCount) uniche, \(subsegmentCount) sottospezzoni, \(lockedCagesCount) bloccate\(movedAudioToA2 ? ", audio spostato su A2" : "")).",
            level: .info
        )
        onModelChanged?()

        return AutoFillResult(
            filledCount: filledCount,
            totalUnlockedCages: unlockedCages.count,
            lockedCagesCount: lockedCagesCount,
            primaryUniqueCount: primaryUniqueCount,
            subsegmentCount: subsegmentCount,
            remainingEmptyCages: remainingEmpty,
            movedAudioToA2: movedAudioToA2
        )
    }

    /// Cancellazione di una clip con adattamento a cascata delle gabbie sbloccate (Slot Ripple)
    @discardableResult
    public func slotRippleDelete(clipId: UUID) -> Bool {
        guard let tIdx = videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clipId }) }) else {
            return false
        }
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

        // Se ci sono gabbie ritmate attive, sposta indietro di 1 slot libero le clip sbloccate successive
        let activeCages = activeCageIntervals()
        if !activeCages.isEmpty {
            let deletedCageIdx = removedClip.cageIndex ?? cageIndex(at: removedClip.timelineStart) ?? cIdx
            var availableCageIndices: [Int] = []
            for cage in activeCages where cage.index >= deletedCageIdx {
                let occupiedByLocked = videoTracks[tIdx].clips.contains { locked in
                    guard locked.isLocked else { return false }
                    let lStart = CMTimeGetSeconds(locked.timelineStart)
                    let lEnd = CMTimeGetSeconds(locked.timelineEnd)
                    return min(lEnd, cage.endSeconds) - max(lStart, cage.startSeconds) > 0.02
                }
                if !occupiedByLocked {
                    availableCageIndices.append(cage.index)
                }
            }

            var slotCursor = 0
            for i in 0..<videoTracks[tIdx].clips.count {
                var vClip = videoTracks[tIdx].clips[i]
                guard !vClip.isLocked else { continue }
                let oldCageIdx = vClip.cageIndex ?? cageIndex(at: vClip.timelineStart) ?? i
                guard oldCageIdx > deletedCageIdx, slotCursor < availableCageIndices.count else { continue }

                let targetCageIdx = availableCageIndices[slotCursor]
                slotCursor += 1
                let targetCage = activeCages[targetCageIdx]

                vClip.cageIndex = targetCageIdx
                vClip.timelineStart = targetCage.startTime
                let dur = targetCage.durationTime
                let scaledDur = vClip.speed > 0 ? CMTime(seconds: CMTimeGetSeconds(dur) * vClip.speed, preferredTimescale: 600) : dur
                let maxMediaOut = vClip.mediaItem.duration
                vClip.sourceOut = CMTimeMinimum(CMTimeAdd(vClip.sourceIn, scaledDur), maxMediaOut)
                videoTracks[tIdx].clips[i] = vClip

                if let lId = vClip.linkGroupId, isLinkActive {
                    for aIdx in 0..<audioTracks.count where !audioTracks[aIdx].isLocked {
                        if let acIdx = audioTracks[aIdx].clips.firstIndex(where: { $0.linkGroupId == lId && !$0.isLocked }) {
                            audioTracks[aIdx].clips[acIdx].cageIndex = targetCageIdx
                            audioTracks[aIdx].clips[acIdx].timelineStart = targetCage.startTime
                            audioTracks[aIdx].clips[acIdx].sourceOut = CMTimeMinimum(CMTimeAdd(audioTracks[aIdx].clips[acIdx].sourceIn, scaledDur), maxMediaOut)
                        }
                    }
                }
            }
        }

        selectedClipIds.remove(clipId)
        DebugLogger.shared.log("Clip rimossa con Slot Ripple: le clip successive sbloccate hanno preso il posto mantenendo la griglia ritmica.", level: .info)
        onModelChanged?()
        return true
    }

    /// Slip Tool: fa scorrere il contenuto interno (sourceIn/Out) senza modificare i punti di taglio sulla timeline
    @discardableResult
    public func slipClip(clipId: UUID, deltaSeconds: Double) -> Bool {
        for tIdx in 0..<videoTracks.count {
            if let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                var clip = videoTracks[tIdx].clips[cIdx]
                let sourceDurSec = CMTimeGetSeconds(clip.sourceDuration)
                let maxMediaDurSec = CMTimeGetSeconds(clip.mediaItem.duration)
                let currentInSec = CMTimeGetSeconds(clip.sourceIn)

                let maxAllowedIn = max(0, maxMediaDurSec - sourceDurSec)
                let newInSec = min(maxAllowedIn, max(0, currentInSec + deltaSeconds))

                clip.sourceIn = CMTime(seconds: newInSec, preferredTimescale: 600)
                clip.sourceOut = CMTime(seconds: newInSec + sourceDurSec, preferredTimescale: 600)
                videoTracks[tIdx].clips[cIdx] = clip

                onModelChanged?()
                return true
            }
        }
        return false
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

            // Sposta le clip successive avanti per fare spazio alla gabbia allargata
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

    /// Alterna la velocità della clip (100% -> 50% slow-mo -> 100%)
    @discardableResult
    public func toggleClipSpeed(clipId: UUID) -> Double? {
        for tIdx in 0..<videoTracks.count {
            if let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) {
                var clip = videoTracks[tIdx].clips[cIdx]
                let newSpeed: Double = (clip.speed == 1.0) ? 0.5 : 1.0
                clip.speed = newSpeed

                // Mantieni la stessa durata sulla timeline ricalcolando la porzione sorgente
                let timelineDur = CMTimeGetSeconds(clip.duration)
                let newSourceDur = timelineDur * newSpeed
                clip.sourceOut = CMTimeAdd(clip.sourceIn, CMTime(seconds: newSourceDur, preferredTimescale: 600))
                videoTracks[tIdx].clips[cIdx] = clip

                DebugLogger.shared.log("Velocità clip '\(clip.mediaItem.name)' impostata a \(Int(newSpeed * 100))%.", level: .info)
                onModelChanged?()
                return newSpeed
            }
        }
        return nil
    }

    /// Scambia di posto la clip con quella nella gabbia adiacente (sinistra -1, destra +1)
    @discardableResult
    public func swapAdjacentCages(clipId: UUID, direction: Int) -> Bool {
        let activeCages = activeCageIntervals()
        for tIdx in 0..<videoTracks.count {
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            let targetIdx = cIdx + direction
            guard targetIdx >= 0 && targetIdx < videoTracks[tIdx].clips.count else { continue }

            videoTracks[tIdx].clips.swapAt(cIdx, targetIdx)

            // Riassegna le gabbie ritmate
            for i in min(cIdx, targetIdx)...max(cIdx, targetIdx) {
                if i < activeCages.count {
                    let cage = activeCages[i]
                    videoTracks[tIdx].clips[i].cageIndex = i
                    videoTracks[tIdx].clips[i].timelineStart = cage.startTime
                    let dur = cage.durationTime
                    let scaled = videoTracks[tIdx].clips[i].speed > 0 ? CMTime(seconds: CMTimeGetSeconds(dur) * videoTracks[tIdx].clips[i].speed, preferredTimescale: 600) : dur
                    videoTracks[tIdx].clips[i].sourceOut = CMTimeAdd(videoTracks[tIdx].clips[i].sourceIn, scaled)
                }
            }

            DebugLogger.shared.log("Clip scambiata di gabbia (\(direction > 0 ? "avanti" : "indietro")).", level: .info)
            onModelChanged?()
            return true
        }
        return false
    }
}
