import Foundation
import AVFoundation

public enum ClipEdge {
    case start
    case end
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

    // MARK: - Rhythmic Cages & Beat Grid (Montaggio a Gabbie)
    public var rhythmicCages: [RhythmicCage] = []
    public var detectedBPM: Double? = nil
    public var beatIntervalMode: BeatIntervalMode = .twoBeats
    public var isRhythmicGridVisible: Bool = true

    public var onModelChanged: (() -> Void)?

    public let maxTracks: Int = 5

    public init(name: String = "Timeline 1") {
        self.name = name
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
        guard id < maxTracks else { return }
        while videoTracks.count <= id && videoTracks.count < maxTracks {
            let nextIndex = videoTracks.count
            videoTracks.append(TimelineTrack(id: nextIndex, name: "V\(nextIndex + 1)", mediaType: .video))
        }
    }

    public func ensureAudioTrack(id: Int) {
        guard id < maxTracks else { return }
        while audioTracks.count <= id && audioTracks.count < maxTracks {
            let nextIndex = audioTracks.count
            audioTracks.append(TimelineTrack(id: nextIndex, name: "A\(nextIndex + 1)", mediaType: .audio))
        }
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
                        isOrphan: clip.isOrphan
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
                        isOrphan: clip.isOrphan
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

        if mediaItem.hasVideo && isTargetVideo {
            ensureVideoTrack(id: targetTrackIndex)
            guard !videoTracks[targetTrackIndex].isLocked else { return }

            let vClip = TimelineClip(
                mediaItem: mediaItem,
                sourceIn: .zero,
                sourceOut: mediaItem.duration,
                timelineStart: validTime,
                trackIndex: targetTrackIndex,
                mediaType: .video,
                orientation: mediaItem.orientation,
                linkGroupId: linkId
            )
            overwriteAndInsert(incoming: vClip, trackIndex: targetTrackIndex, isVideo: true)

            if mediaItem.hasAudio && isLinkActive {
                let audioTrackIdx = min(targetTrackIndex, maxTracks - 1)
                ensureAudioTrack(id: audioTrackIdx)
                if !audioTracks[audioTrackIdx].isLocked {
                    let aClip = TimelineClip(
                        mediaItem: mediaItem,
                        sourceIn: .zero,
                        sourceOut: mediaItem.duration,
                        timelineStart: validTime,
                        trackIndex: audioTrackIdx,
                        mediaType: .audio,
                        linkGroupId: linkId
                    )
                    overwriteAndInsert(incoming: aClip, trackIndex: audioTrackIdx, isVideo: false)
                }
            }
        } else if mediaItem.hasAudio && !isTargetVideo {
            ensureAudioTrack(id: targetTrackIndex)
            guard !audioTracks[targetTrackIndex].isLocked else { return }

            let aClip = TimelineClip(
                mediaItem: mediaItem,
                sourceIn: .zero,
                sourceOut: mediaItem.duration,
                timelineStart: validTime,
                trackIndex: targetTrackIndex,
                mediaType: .audio,
                linkGroupId: linkId
            )
            overwriteAndInsert(incoming: aClip, trackIndex: targetTrackIndex, isVideo: false)

            if mediaItem.hasVideo && isLinkActive {
                let videoTrackIdx = min(targetTrackIndex, maxTracks - 1)
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
                if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id }) {
                    videoTracks[trackIdx].clips[clipIdx].timelineStart = max(.zero, newStartTime)
                    videoTracks[trackIdx].clips[clipIdx].trackIndex = targetTrack
                    return
                }
            }
        } else {
            guard targetTrack < audioTracks.count, !audioTracks[targetTrack].isLocked else { return }
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == id }) {
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
                if let clipIdx = videoTracks[trackIdx].clips.firstIndex(where: { $0.id == id }) {
                    movedClip = videoTracks[trackIdx].clips.remove(at: clipIdx)
                    break
                }
            }
            if var clip = movedClip {
                ensureVideoTrack(id: targetTrack)
                clip.trackIndex = targetTrack
                if let newStart = newStartTime {
                    clip.timelineStart = max(.zero, newStart)
                }
                overwriteAndInsert(incoming: clip, trackIndex: targetTrack, isVideo: true)
            }

            if isLinkActive, let cId = companionId ?? findCompanionId(for: movedClip?.linkGroupId, isVideo: true) {
                for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                    if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == cId }) {
                        let aClip = audioTracks[trackIdx].clips.remove(at: clipIdx)
                        overwriteAndInsert(incoming: aClip, trackIndex: aClip.trackIndex, isVideo: false)
                        break
                    }
                }
            }
        } else {
            for trackIdx in 0..<audioTracks.count where !audioTracks[trackIdx].isLocked {
                if let clipIdx = audioTracks[trackIdx].clips.firstIndex(where: { $0.id == id }) {
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
            for cage in rhythmicCages {
                snapPoints.append(cage.startSeconds)
                snapPoints.append(cage.endSeconds)
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

        // Filter out clips on locked tracks
        var candidateClips: [TimelineClip] = []
        for track in videoTracks where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) {
                candidateClips.append(clip)
            }
        }
        for track in audioTracks where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) {
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

            // Modalità con scarto: ripple all clips on unlocked tracks starting at or after endSec backward
            for trackIdx in 0..<videoTracks.count where !videoTracks[trackIdx].isLocked {
                for cIdx in 0..<videoTracks[trackIdx].clips.count {
                    let clip = videoTracks[trackIdx].clips[cIdx]
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

    public func trimClipEnd(at time: CMTime) {
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
    }

    public func splitClip(at time: CMTime) {
        var didSplit = false
        func split(in tracks: inout [TimelineTrack], isVideoTracks: Bool) {
            for trackIdx in 0..<tracks.count where !tracks[trackIdx].isLocked {
                var newClips: [TimelineClip] = []
                for clip in tracks[trackIdx].clips {
                    let shouldSplit: Bool
                    if selectedClipIds.isEmpty {
                        shouldSplit = true
                    } else if selectedClipIds.contains(clip.id) {
                        shouldSplit = true
                    } else if isLinkActive, let lId = clip.linkGroupId {
                        let partnerSelected = videoTracks.contains(where: { $0.clips.contains(where: { $0.linkGroupId == lId && selectedClipIds.contains($0.id) }) }) ||
                                              audioTracks.contains(where: { $0.clips.contains(where: { $0.linkGroupId == lId && selectedClipIds.contains($0.id) }) })
                        shouldSplit = partnerSelected
                    } else {
                        shouldSplit = false
                    }

                    if shouldSplit && CMTimeCompare(clip.timelineStart, time) < 0 && CMTimeCompare(clip.timelineEnd, time) > 0 {
                        didSplit = true
                        let offsetFromStart = CMTimeSubtract(time, clip.timelineStart)
                        let sourceCutPoint = CMTimeAdd(clip.sourceIn, offsetFromStart)

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
                            isOrphan: clip.isOrphan
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
                            linkGroupId: clip.linkGroupId != nil ? UUID() : nil,
                            isOrphan: clip.isOrphan
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

        split(in: &videoTracks, isVideoTracks: true)
        split(in: &audioTracks, isVideoTracks: false)
        if didSplit {
            onModelChanged?()
            DebugLogger.shared.log("Spezza (S) eseguito a \(String(format: "%.2f", CMTimeGetSeconds(time)))s", level: .info)
        }
    }

    // MARK: - Close Gaps Between Selected Clips (Cmd + Option + W)
    public func closeGapsBetweenSelectedClips() {
        guard !selectedClipIds.isEmpty else { return }

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

        guard let clip = targetClip else { return false }

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

    public func cage(at time: CMTime) -> RhythmicCage? {
        let sec = CMTimeGetSeconds(time)
        return rhythmicCages.first { sec >= $0.startSeconds && sec < $0.endSeconds }
    }

    public func cageIndex(at time: CMTime) -> Int? {
        cage(at: time)?.index
    }

    public func cage(for clipId: UUID) -> RhythmicCage? {
        for track in videoTracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) {
                if let cIdx = clip.cageIndex, cIdx < rhythmicCages.count {
                    return rhythmicCages[cIdx]
                }
                return cage(at: clip.timelineStart)
            }
        }
        return nil
    }

    /// Riempie le gabbie ritmate correnti usando le clip approvate dalla Selezione (Striscia Verde)
    @discardableResult
    public func autoFillCages(with selectionClips: [SelectionClip], targetTrackIndex: Int = 0) -> Int {
        guard !rhythmicCages.isEmpty else {
            DebugLogger.shared.log("Nessuna gabbia ritmata presente. Esegui prima l'analisi audio della traccia musicale.", level: .warning)
            return 0
        }
        guard !selectionClips.isEmpty else {
            DebugLogger.shared.log("La selezione è vuota: approva prima delle clip nella striscia Verde (Selezione).", level: .warning)
            return 0
        }

        ensureVideoTrack(id: targetTrackIndex)
        // Rimuove eventuali clip video preesistenti sulla traccia target
        videoTracks[targetTrackIndex].clips.removeAll()

        var filledCount = 0
        var selIdx = 0

        for cage in rhythmicCages {
            let sClip = selectionClips[selIdx % selectionClips.count]
            selIdx += 1

            let cageDur = cage.durationTime
            let neededSourceSec = CMTimeGetSeconds(cageDur)
            let maxSourceSec = CMTimeGetSeconds(sClip.mediaItem.duration)
            let sInSec = CMTimeGetSeconds(sClip.sourceIn)

            // Verifica che ci sia abbastanza girato dal punto In, altrimenti resetta a 0
            let effectiveInSec: Double
            if (sInSec + neededSourceSec) <= maxSourceSec {
                effectiveInSec = sInSec
            } else if neededSourceSec <= maxSourceSec {
                effectiveInSec = max(0, maxSourceSec - neededSourceSec)
            } else {
                effectiveInSec = 0
            }

            let effectiveIn = CMTime(seconds: effectiveInSec, preferredTimescale: 600)
            let effectiveOut = CMTimeAdd(effectiveIn, cageDur)

            let tClip = TimelineClip(
                mediaItem: sClip.mediaItem,
                sourceIn: effectiveIn,
                sourceOut: effectiveOut,
                timelineStart: cage.startTime,
                trackIndex: targetTrackIndex,
                mediaType: .video,
                orientation: sClip.mediaItem.orientation,
                speed: 1.0,
                cageIndex: cage.index,
                span: 1
            )

            videoTracks[targetTrackIndex].clips.append(tClip)
            filledCount += 1
        }

        DebugLogger.shared.log("Auto-Fill completato: \(filledCount) gabbie riempite a tempo su traccia V\(targetTrackIndex + 1).", level: .info)
        onModelChanged?()
        return filledCount
    }

    /// Cancellazione di una clip con adattamento a cascata delle gabbie (Slot Ripple)
    @discardableResult
    public func slotRippleDelete(clipId: UUID) -> Bool {
        guard let tIdx = videoTracks.firstIndex(where: { $0.clips.contains(where: { $0.id == clipId }) }) else {
            return false
        }
        guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else {
            return false
        }

        _ = videoTracks[tIdx].clips.remove(at: cIdx)

        // Se ci sono gabbie ritmate attive, le clip successive scorrono indietro di 1 gabbia e si adattano alla nuova durata
        if !rhythmicCages.isEmpty {
            for i in cIdx..<videoTracks[tIdx].clips.count {
                let oldCageIdx = videoTracks[tIdx].clips[i].cageIndex ?? (i + 1)
                let newCageIdx = max(0, oldCageIdx - 1)
                videoTracks[tIdx].clips[i].cageIndex = newCageIdx

                if newCageIdx < rhythmicCages.count {
                    let targetCage = rhythmicCages[newCageIdx]
                    videoTracks[tIdx].clips[i].timelineStart = targetCage.startTime

                    // Adatta il punto Out affinché la clip calzi a pennello nella nuova gabbia
                    let currentIn = videoTracks[tIdx].clips[i].sourceIn
                    let dur = targetCage.durationTime
                    let scaledDur = videoTracks[tIdx].clips[i].speed > 0 ? CMTime(seconds: CMTimeGetSeconds(dur) * videoTracks[tIdx].clips[i].speed, preferredTimescale: 600) : dur
                    videoTracks[tIdx].clips[i].sourceOut = CMTimeAdd(currentIn, scaledDur)
                }
            }
        }

        selectedClipIds.remove(clipId)
        DebugLogger.shared.log("Clip rimossa con Slot Ripple: le clip successive hanno preso il posto mantenendo la griglia ritmica.", level: .info)
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
        for tIdx in 0..<videoTracks.count {
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            var clip = videoTracks[tIdx].clips[cIdx]
            guard let startCageIdx = clip.cageIndex, startCageIdx < rhythmicCages.count else { continue }

            let endCageIdx = min(rhythmicCages.count - 1, startCageIdx + newSpan - 1)
            let combinedDur = rhythmicCages[endCageIdx].endSeconds - rhythmicCages[startCageIdx].startSeconds
            guard combinedDur > 0 else { continue }

            clip.span = newSpan
            let durTime = CMTime(seconds: combinedDur, preferredTimescale: 600)
            let scaledDur = clip.speed > 0 ? CMTime(seconds: combinedDur * clip.speed, preferredTimescale: 600) : durTime
            clip.sourceOut = CMTimeAdd(clip.sourceIn, scaledDur)
            videoTracks[tIdx].clips[cIdx] = clip

            // Sposta le clip successive avanti per fare spazio alla gabbia allargata
            var nextCageIdx = endCageIdx + 1
            for nextIdx in (cIdx + 1)..<videoTracks[tIdx].clips.count {
                if nextCageIdx < rhythmicCages.count {
                    let nextCage = rhythmicCages[nextCageIdx]
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
        for tIdx in 0..<videoTracks.count {
            guard let cIdx = videoTracks[tIdx].clips.firstIndex(where: { $0.id == clipId }) else { continue }
            let targetIdx = cIdx + direction
            guard targetIdx >= 0 && targetIdx < videoTracks[tIdx].clips.count else { continue }

            videoTracks[tIdx].clips.swapAt(cIdx, targetIdx)

            // Riassegna le gabbie ritmate
            for i in min(cIdx, targetIdx)...max(cIdx, targetIdx) {
                if i < rhythmicCages.count {
                    let cage = rhythmicCages[i]
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
