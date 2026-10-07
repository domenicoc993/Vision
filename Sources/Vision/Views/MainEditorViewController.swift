import AppKit
import AVFoundation

public final class MainEditorViewController: NSViewController, MediaPoolDelegate {
    private var timelineModel: TimelineModel = EditorProject.shared.activeTimeline
    private let playbackController = PlaybackController()

    private var mediaPoolVC: MediaPoolViewController!
    private var playerVC: PlayerViewController!
    private var timelineVC: TimelineViewController!

    private let mainSplit = NSSplitView()
    private var activeSection: FocusedSection = .timeline
    private var rebuildTask: Task<Void, Never>?

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        timelineModel = EditorProject.shared.activeTimeline

        mediaPoolVC = MediaPoolViewController()
        mediaPoolVC.delegate = self
        mediaPoolVC.timelineModel = timelineModel

        playerVC = PlayerViewController(playbackController: playbackController)

        timelineVC = TimelineViewController(model: timelineModel, playbackController: playbackController)
        timelineVC.onTimelineModified = { [weak self] in
            self?.mediaPoolVC.refreshTimelineGrid()
            self?.rebuildComposition()
        }
        timelineVC.onFormatChangedCallback = { [weak self] format in
            self?.playerVC.updateAspectRatio(formatSize: format.size)
        }
        timelineVC.onResolveMediaItem = { [weak self] id, url in
            guard let self = self else { return nil }
            if let id = id {
                return self.mediaPoolVC.mediaItem(for: id)
            }
            if let url = url {
                return self.mediaPoolVC.mediaItem(for: url)
            }
            return nil
        }
        timelineVC.onSectionActivated = { [weak self] in
            self?.activeSection = .timeline
        }
        timelineVC.onSwitchTimeline = { [weak self] targetTL in
            self?.didSwitchActiveTimeline(to: targetTL)
        }

        EditorProject.shared.onProjectChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.mediaPoolVC.updateTimelinePopUp()
                self?.mediaPoolVC.updateFolderPopUp()
            }
        }

        // Horizontal Split: Media Pool / Timeline Grid (left) | Player Viewer (right)
        let topSplit = NSSplitView()
        topSplit.isVertical = true
        topSplit.dividerStyle = .thin
        topSplit.translatesAutoresizingMaskIntoConstraints = false

        topSplit.addArrangedSubview(mediaPoolVC.view)
        topSplit.addArrangedSubview(playerVC.view)

        // Vertical Split: Top (Pool + Player) / Bottom (Timeline)
        // Clean 3-panel professional NLE layout without debug console
        mainSplit.isVertical = false
        mainSplit.dividerStyle = .paneSplitter
        mainSplit.translatesAutoresizingMaskIntoConstraints = false

        mainSplit.addArrangedSubview(topSplit)
        mainSplit.addArrangedSubview(timelineVC.view)

        root.addSubview(mainSplit)

        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: root.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            mediaPoolVC.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            playerVC.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            topSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            timelineVC.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])

        addChild(mediaPoolVC)
        addChild(playerVC)
        addChild(timelineVC)

        self.view = root

        playerVC.updateAspectRatio(formatSize: timelineModel.format.size)

        DebugLogger.shared.log("Vision avviato. Scorciatoie: ⌃F (Schermo Intero), Spazio (Play/Pause), Q (Trim Inizio), W (Trim Fine), S (Spezza), ⌥⌘W (Chiudi Spazi), ⌘A/⌃A (Seleziona Tutto), N (Magnet/Snap), ⌘L (Link/Unlink), Backspace/Canc (Elimina con scarto).", level: .info)

        // Keyboard monitor for professional editing shortcuts
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if let firstResponder = self.view.window?.firstResponder, firstResponder is NSTextView {
                return event
            }

            let isOption = event.modifierFlags.contains(.option)
            let isCommand = event.modifierFlags.contains(.command)
            let isControl = event.modifierFlags.contains(.control)

            // Control + F -> Fullscreen Viewer from ANYWHERE in the app
            if isControl && (event.keyCode == 3 || event.charactersIgnoringModifiers?.lowercased() == "f") {
                self.playerVC.toggleFullScreen()
                return nil
            }

            switch event.keyCode {
            case 49: // Spacebar -> Play / Pause
                self.playbackController.togglePlayPause()
                return nil

            case 0: // 'A' key -> Select All based on active section
                if isCommand || isControl {
                    if self.activeSection == .timeline {
                        var allIds: Set<UUID> = []
                        for track in self.timelineModel.videoTracks {
                            for clip in track.clips { allIds.insert(clip.id) }
                        }
                        for track in self.timelineModel.audioTracks {
                            for clip in track.clips { allIds.insert(clip.id) }
                        }
                        self.timelineModel.selectedClipIds = allIds
                        self.timelineVC.reloadTimelineUI()
                        DebugLogger.shared.log("Timeline: selezionate tutte le \(allIds.count) clip.", level: .info)
                        return nil
                    } else {
                        self.mediaPoolVC.selectAllMediaItems()
                        DebugLogger.shared.log("Media Pool: selezionati tutti gli elementi.", level: .info)
                        return nil
                    }
                }

            case 12: // 'Q' key -> Trim start to playhead (modalità senza scarto)
                self.timelineModel.trimClipStart(at: self.playbackController.currentTime)
                self.timelineVC.reloadTimelineUI()
                self.mediaPoolVC.refreshTimelineGrid()
                self.rebuildComposition()
                return nil

            case 13: // 'W' key -> Cmd+Option+W: Svuotamento spazi, oppure W: Trim fine senza scarto
                if isCommand && isOption {
                    self.timelineModel.closeGapsBetweenSelectedClips()
                    self.timelineVC.reloadTimelineUI()
                    self.mediaPoolVC.refreshTimelineGrid()
                    self.rebuildComposition()
                    return nil
                }
                self.timelineModel.trimClipEnd(at: self.playbackController.currentTime)
                self.timelineVC.reloadTimelineUI()
                self.mediaPoolVC.refreshTimelineGrid()
                self.rebuildComposition()
                return nil

            case 1, 11: // 'S' or 'B' key -> Split / Spezza at playhead
                self.timelineModel.splitClip(at: self.playbackController.currentTime)
                self.timelineVC.reloadTimelineUI()
                self.mediaPoolVC.refreshTimelineGrid()
                self.rebuildComposition()
                return nil

            case 45: // 'N' key -> Toggle Magnet Snapping (Resolve convention)
                self.timelineVC.onMagnetToggleClicked()
                return nil

            case 37: // 'L' key -> Toggle Link / Unlink if Cmd or Option pressed
                if isCommand || isOption {
                    self.timelineVC.onLinkToggleClicked()
                    return nil
                }

            case 35: // 'P' key -> Toggle Selection Follows Playhead if Option pressed
                if isOption {
                    self.timelineVC.onSelectionFollowsPlayheadClicked()
                    return nil
                }

            case 123: // Left Arrow -> Frame Back
                self.playbackController.step(by: -1)
                return nil

            case 124: // Right Arrow -> Frame Forward
                self.playbackController.step(by: 1)
                return nil

            case 126: // Up Arrow
                if isOption, let id = self.timelineModel.selectedClipId {
                    self.moveSelectedClipVertically(id: id, isMovingUp: true)
                    return nil
                }

            case 125: // Down Arrow
                if isOption, let id = self.timelineModel.selectedClipId {
                    self.moveSelectedClipVertically(id: id, isMovingUp: false)
                    return nil
                }

            case 51, 117: // Backspace / Delete -> Ripple delete (eliminazione con scarto)
                if self.timelineModel.selectedClipIds.isEmpty && self.timelineModel.isSelectionFollowsPlayhead {
                    self.timelineModel.updateSelectionAtPlayhead(time: self.playbackController.currentTime)
                }
                if !self.timelineModel.selectedClipIds.isEmpty {
                    self.timelineModel.removeSelectedClips()
                    self.timelineVC.reloadTimelineUI()
                    self.mediaPoolVC.refreshTimelineGrid()
                    self.rebuildComposition()
                    return nil
                }

            default:
                break
            }
            return event
        }
    }

    private func moveSelectedClipVertically(id: UUID, isMovingUp: Bool) {
        for track in timelineModel.videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                guard !track.isLocked else {
                    DebugLogger.shared.log("Traccia V\(track.id + 1) bloccata 🔒. Spostamento impedito.", level: .warning)
                    return
                }
                let targetTrack = isMovingUp ? (clip.trackIndex + 1) : (clip.trackIndex - 1)
                if targetTrack >= 0 && targetTrack < timelineModel.maxTracks {
                    timelineModel.ensureVideoTrack(id: targetTrack)
                    guard !timelineModel.videoTracks[targetTrack].isLocked else {
                        DebugLogger.shared.log("Traccia di destinazione V\(targetTrack + 1) bloccata 🔒. Spostamento impedito.", level: .warning)
                        return
                    }
                    timelineModel.commitMoveClip(id: id, toTrack: targetTrack, isVideo: true)
                    timelineVC.reloadTimelineUI()
                    mediaPoolVC.refreshTimelineGrid()
                    rebuildComposition()
                }
                return
            }
        }

        for track in timelineModel.audioTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                guard !track.isLocked else {
                    DebugLogger.shared.log("Traccia A\(track.id + 1) bloccata 🔒. Spostamento impedito.", level: .warning)
                    return
                }
                let targetTrack = isMovingUp ? (clip.trackIndex - 1) : (clip.trackIndex + 1)
                if targetTrack >= 0 && targetTrack < timelineModel.maxTracks {
                    timelineModel.ensureAudioTrack(id: targetTrack)
                    guard !timelineModel.audioTracks[targetTrack].isLocked else {
                        DebugLogger.shared.log("Traccia di destinazione A\(targetTrack + 1) bloccata 🔒. Spostamento impedito.", level: .warning)
                        return
                    }
                    timelineModel.commitMoveClip(id: id, toTrack: targetTrack, isVideo: false)
                    timelineVC.reloadTimelineUI()
                    rebuildComposition()
                }
                return
            }
        }
    }

    public func didActivateSection(_ section: FocusedSection) {
        self.activeSection = section
    }

    public func didSwitchActiveTimeline(to timeline: TimelineModel) {
        self.timelineModel = timeline
        self.timelineVC.switchModel(timeline)
        self.mediaPoolVC.timelineModel = timeline
        self.playerVC.updateAspectRatio(formatSize: timeline.format.size)
        self.mediaPoolVC.refreshTimelineGrid()
        self.rebuildComposition()
    }

    public func didSelectAddClipToTimeline(_ item: MediaItem) {
        timelineModel.appendClip(mediaItem: item)
        timelineVC.reloadTimelineUI()
        mediaPoolVC.refreshTimelineGrid()
        rebuildComposition()
    }

    public func didChangeMediaOrientation(_ item: MediaItem) {
        for trackIdx in 0..<timelineModel.videoTracks.count where !timelineModel.videoTracks[trackIdx].isLocked {
            for clipIdx in 0..<timelineModel.videoTracks[trackIdx].clips.count {
                if timelineModel.videoTracks[trackIdx].clips[clipIdx].mediaItem.url == item.url {
                    timelineModel.videoTracks[trackIdx].clips[clipIdx].orientation = item.orientation
                }
            }
        }
        timelineVC.reloadTimelineUI()
        mediaPoolVC.refreshTimelineGrid()
        rebuildComposition()
    }

    public func didSelectSeekToClip(_ clip: TimelineClip) {
        playbackController.seek(to: clip.timelineStart, frameAccurate: true)
        timelineVC.reloadTimelineUI()
    }

    public func didReorderTimelineFromGrid() {
        timelineVC.reloadTimelineUI()
        rebuildComposition()
    }

    public func didDeleteMediaItemFromPool(_ item: MediaItem) {
        timelineVC.reloadTimelineUI()
        rebuildComposition()
    }

    private func rebuildComposition() {
        let savedPlayhead = playbackController.currentTime
        rebuildTask?.cancel()

        let totalDur = timelineModel.totalDuration
        if CMTimeCompare(totalDur, .zero) <= 0 {
            playbackController.clear()
            playerVC.updateTimeDisplay()
            return
        }

        rebuildTask = Task {
            do {
                let playerItem = try await CompositionEngine.shared.createPlayerItem(from: timelineModel)
                if Task.isCancelled { return }
                let targetFPS = mediaPoolVC.mediaItems.first?.frameRate ?? 30.0

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if let playerItem = playerItem {
                        self.playbackController.load(item: playerItem, duration: totalDur, targetFPS: Double(targetFPS))
                        self.playbackController.seek(to: savedPlayhead, frameAccurate: true)
                    } else {
                        self.playbackController.clear()
                    }
                    self.playerVC.updateTimeDisplay()
                }
            } catch {
                if !Task.isCancelled {
                    DebugLogger.shared.log("ERRORE nella ricomposizione AVFoundation: \(error)", level: .error)
                    await MainActor.run {
                        self.playbackController.clear()
                    }
                }
            }
        }
    }
}
