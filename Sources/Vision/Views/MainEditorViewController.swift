import AppKit
import AVFoundation

public enum EditorMode {
    case selezione
    case montaggio
}

public final class MainEditorViewController: NSViewController, MediaPoolDelegate {
    private var timelineModel: TimelineModel = EditorProject.shared.activeTimeline
    private let playbackController = PlaybackController()

    public private(set) var currentMode: EditorMode = .montaggio
    private var mediaPoolVC: MediaPoolViewController!
    private var playerVC: PlayerViewController!
    private var timelineVC: TimelineViewController!
    private var selectionVC: SelectionViewController!

    private let mainSplit = NSSplitView()
    private let topSplit = NSSplitView()
    private let bottomWorkspaceContainer = NSView()
    private let bottomNavBar = NSView()
    private let btnSelezione = NSButton()
    private let btnMontaggio = NSButton()

    private var projectManagerWC: ProjectManagerWindowController?
    private var historyPopover: NSPopover?
    private var historyVC: HistoryPanelViewController?

    private let projectManagerBtn = NSButton()
    private let autosaveStatusLabel = NSTextField(labelWithString: "● Salvato")
    private let historyBtn = NSButton()
    private let navUndoBtn = NSButton()
    private let navRedoBtn = NSButton()

    private var activeSection: FocusedSection = .timeline
    private var rebuildTask: Task<Void, Never>?
    private var initialDocument: ProjectDocumentData?

    public init(initialDocument: ProjectDocumentData? = nil) {
        self.initialDocument = initialDocument
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor

        timelineModel = EditorProject.shared.activeTimeline

        mediaPoolVC = MediaPoolViewController()
        mediaPoolVC.delegate = self
        mediaPoolVC.timelineModel = timelineModel

        playerVC = PlayerViewController(playbackController: playbackController)
        playerVC.onProxyToggled = { [weak self] in
            guard let self = self else { return }
            if self.currentMode == .selezione {
                self.selectionVC.rebuildCurrentComposition()
            } else {
                self.rebuildComposition()
            }
        }

        timelineVC = TimelineViewController(model: timelineModel, playbackController: playbackController)
        timelineVC.onTimelineModified = { [weak self] in
            guard let self = self else { return }
            self.mediaPoolVC.refreshTimelineGrid()
            self.rebuildComposition()
            HistoryManager.shared.record(title: "Modifica Timeline", project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
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

        selectionVC = SelectionViewController()
        selectionVC.mediaPoolVC = mediaPoolVC
        selectionVC.playerVC = playerVC
        selectionVC.onActionRecorded = { [weak self] actionTitle in
            guard let self = self else { return }
            HistoryManager.shared.record(title: actionTitle, project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
        }

        mediaPoolVC.onOpenSelectionInSelectionMode = { [weak self] sel in
            guard let self = self else { return }
            self.selectionVC.currentSelection = sel
            self.switchMode(to: .selezione)
        }

        print(">>> loadView: setting up splits and views...")
        fflush(stdout)

        EditorProject.shared.onProjectChanged = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.mediaPoolVC.updateTimelinePopUp()
                self.mediaPoolVC.updateFolderPopUp()
                self.selectionVC.updateHeaderUI()
                ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProjectSavedRealtime"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "it_IT")
            formatter.timeStyle = .medium
            let timeStr = formatter.string(from: Date())
            self.autosaveStatusLabel.stringValue = "● Salvato (\(timeStr))"
            self.autosaveStatusLabel.textColor = NSColor.systemGreen.withAlphaComponent(0.85)
        }

        HistoryManager.shared.onHistoryChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.historyVC?.reloadHistoryUI()
                self?.updateHistoryNavButtons()
            }
        }

        // Horizontal Split: Media Pool / Timeline Grid (left) | Player Viewer (right)
        topSplit.isVertical = true
        topSplit.dividerStyle = .thin
        topSplit.translatesAutoresizingMaskIntoConstraints = false

        topSplit.addArrangedSubview(mediaPoolVC.view)
        topSplit.addArrangedSubview(playerVC.view)

        // Bottom Workspace Container hosting Timeline and Selection Dual Strips
        bottomWorkspaceContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomWorkspaceContainer.addSubview(timelineVC.view)
        bottomWorkspaceContainer.addSubview(selectionVC.view)
        timelineVC.view.translatesAutoresizingMaskIntoConstraints = false
        selectionVC.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            timelineVC.view.topAnchor.constraint(equalTo: bottomWorkspaceContainer.topAnchor),
            timelineVC.view.leadingAnchor.constraint(equalTo: bottomWorkspaceContainer.leadingAnchor),
            timelineVC.view.trailingAnchor.constraint(equalTo: bottomWorkspaceContainer.trailingAnchor),
            timelineVC.view.bottomAnchor.constraint(equalTo: bottomWorkspaceContainer.bottomAnchor),

            selectionVC.view.topAnchor.constraint(equalTo: bottomWorkspaceContainer.topAnchor),
            selectionVC.view.leadingAnchor.constraint(equalTo: bottomWorkspaceContainer.leadingAnchor),
            selectionVC.view.trailingAnchor.constraint(equalTo: bottomWorkspaceContainer.trailingAnchor),
            selectionVC.view.bottomAnchor.constraint(equalTo: bottomWorkspaceContainer.bottomAnchor)
        ])

        // Vertical Split: Top (Pool + Player) / Bottom (Workspace: Timeline / Selection)
        mainSplit.isVertical = false
        mainSplit.dividerStyle = .paneSplitter
        mainSplit.translatesAutoresizingMaskIntoConstraints = false

        mainSplit.addArrangedSubview(topSplit)
        mainSplit.addArrangedSubview(bottomWorkspaceContainer)

        setupBottomNavBar()

        root.addSubview(mainSplit)
        root.addSubview(bottomNavBar)

        let minMPWidth = mediaPoolVC.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        minMPWidth.priority = .defaultHigh
        let minPlayerWidth = playerVC.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320)
        minPlayerWidth.priority = .defaultHigh
        let minTopHeight = topSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        minTopHeight.priority = .defaultHigh
        let minBottomHeight = bottomWorkspaceContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        minBottomHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: root.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: bottomNavBar.topAnchor),

            bottomNavBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomNavBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomNavBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomNavBar.heightAnchor.constraint(equalToConstant: 38),

            minMPWidth,
            minPlayerWidth,
            minTopHeight,
            minBottomHeight
        ])

        addChild(mediaPoolVC)
        addChild(playerVC)
        addChild(timelineVC)
        addChild(selectionVC)

        self.view = root

        switchMode(to: .montaggio)
        playerVC.updateAspectRatio(formatSize: timelineModel.format.size)
        setupInitialProject()
        setupKeyboardMonitor()

        DebugLogger.shared.log("Vision avviato. Modalità: 🎯 Selezione (⌘1) | ✂️ Montaggio (⌘2). Scorciatoie: ⌃F (Schermo Intero), Spazio (Play/Pause), Q (Trim Inizio), W (Trim Fine), S (Spezza), ↑/↓ (Sposta Scarti in Selezione).", level: .info)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let totalW = self.view.bounds.width
            let totalH = self.view.bounds.height
            if totalW > 500 {
                self.topSplit.setPosition(max(320, totalW * 0.42), ofDividerAt: 0)
            }
            if totalH > 400 {
                self.mainSplit.setPosition(max(280, (totalH - 38) * 0.52), ofDividerAt: 0)
            }
            self.view.window?.makeKeyAndOrderFront(nil)
            self.view.window?.orderFrontRegardless()
        }
    }

    private func setupKeyboardMonitor() {
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

            // Command + Z -> Undo, Command + Shift + Z -> Redo
            if isCommand && event.keyCode == 6 {
                if event.modifierFlags.contains(.shift) {
                    self.performRedo()
                } else {
                    self.performUndo()
                }
                return nil
            }

            // Command + Y -> Redo
            if isCommand && event.keyCode == 16 {
                self.performRedo()
                return nil
            }

            // Command + O -> Open Project Manager
            if isCommand && event.keyCode == 31 {
                self.openProjectManager()
                return nil
            }

            // Command + 1 -> Switch to Modalità Selezione
            if isCommand && event.keyCode == 18 {
                self.switchMode(to: .selezione)
                return nil
            }

            // Command + 2 -> Switch to Modalità Montaggio
            if isCommand && event.keyCode == 19 {
                self.switchMode(to: .montaggio)
                return nil
            }

            // Keyboard shortcuts routed based on active workspace mode
            if self.currentMode == .selezione {
                switch event.keyCode {
                case 49: // Spacebar -> Play / Pause
                    self.selectionVC.playbackController.togglePlayPause()
                    return nil

                case 126: // Up Arrow -> Move active clip to Scarti (↑)
                    self.selectionVC.handleUpArrow()
                    return nil

                case 125: // Down Arrow -> Restore active clip from Scarti into Selezione sorted by name (↓)
                    self.selectionVC.handleDownArrow()
                    return nil

                case 12: // 'Q' key -> Trim start to playhead (scarti portion goes to red strip, playhead aligns)
                    self.selectionVC.handleTrimStart()
                    return nil

                case 13: // 'W' key -> Trim end to playhead (scarti portion goes to red strip)
                    self.selectionVC.handleTrimEnd()
                    return nil

                case 1, 11: // 'S' or 'B' key -> Split clip into two blocks
                    self.selectionVC.handleSplit()
                    return nil

                case 123: // Left Arrow -> Step back 1 frame
                    self.selectionVC.playbackController.step(by: -1)
                    return nil

                case 124: // Right Arrow -> Step forward 1 frame
                    self.selectionVC.playbackController.step(by: 1)
                    return nil

                default:
                    break
                }
            } else {
                // Classic Montaggio Mode shortcuts
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

                case 12: // 'Q' key -> Trim start to playhead with playhead alignment
                    if let targetTime = self.timelineModel.trimClipStart(at: self.playbackController.currentTime) {
                        self.playbackController.seek(to: targetTime, frameAccurate: true)
                    }
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

                case 1, 11: // 'S' or 'B' key
                    if isOption, self.timelineModel.selectedClipId != nil {
                        // Option + S -> Toggle 50% Slow Motion
                        self.timelineVC.onToggleSpeedClicked()
                        return nil
                    }
                    // S / B -> Spezza clip alla testina
                    self.timelineModel.splitClip(at: self.playbackController.currentTime)
                    self.timelineVC.reloadTimelineUI()
                    self.mediaPoolVC.refreshTimelineGrid()
                    self.rebuildComposition()
                    return nil

                case 24: // '+' or '=' key
                    if isOption {
                        // Option + (+) -> Aumenta Span gabbia (1x -> 2x -> 3x)
                        self.timelineVC.onSpanClicked()
                        return nil
                    }

                case 27: // '-' key
                    if isOption, let selId = self.timelineModel.selectedClipId {
                        // Option + (-) -> Riduci Span gabbia
                        for track in self.timelineModel.videoTracks {
                            if let clip = track.clips.first(where: { $0.id == selId }), clip.span > 1 {
                                self.timelineModel.setClipSpan(clipId: selId, newSpan: clip.span - 1)
                                self.timelineVC.reloadTimelineUI()
                                self.rebuildComposition()
                                break
                            }
                        }
                        return nil
                    }

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

                case 123: // Left Arrow
                    if isOption, self.timelineModel.selectedClipId != nil {
                        // Option + Left -> Slip corpo clip indietro (-0.25s)
                        self.timelineVC.onSlipLeftClicked()
                        return nil
                    }
                    if isCommand, let selId = self.timelineModel.selectedClipId {
                        // Command + Left -> Scambia con la gabbia precedente
                        self.timelineModel.swapAdjacentCages(clipId: selId, direction: -1)
                        self.timelineVC.reloadTimelineUI()
                        self.rebuildComposition()
                        return nil
                    }
                    self.playbackController.step(by: -1)
                    return nil

                case 124: // Right Arrow
                    if isOption, self.timelineModel.selectedClipId != nil {
                        // Option + Right -> Slip corpo clip avanti (+0.25s)
                        self.timelineVC.onSlipRightClicked()
                        return nil
                    }
                    if isCommand, let selId = self.timelineModel.selectedClipId {
                        // Command + Right -> Scambia con la gabbia successiva
                        self.timelineModel.swapAdjacentCages(clipId: selId, direction: +1)
                        self.timelineVC.reloadTimelineUI()
                        self.rebuildComposition()
                        return nil
                    }
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

                case 51, 117: // Backspace / Delete
                    if self.timelineModel.selectedClipIds.isEmpty && self.timelineModel.isSelectionFollowsPlayhead {
                        self.timelineModel.updateSelectionAtPlayhead(time: self.playbackController.currentTime)
                    }
                    // Se ci sono gabbie ritmate e una clip selezionata, usa Slot Ripple Delete!
                    if let selId = self.timelineModel.selectedClipId, !self.timelineModel.rhythmicCages.isEmpty {
                        if self.timelineModel.slotRippleDelete(clipId: selId) {
                            self.timelineVC.reloadTimelineUI()
                            self.mediaPoolVC.refreshTimelineGrid()
                            self.rebuildComposition()
                            return nil
                        }
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
            }
            return event
        }
    }

    private func setupBottomNavBar() {
        bottomNavBar.translatesAutoresizingMaskIntoConstraints = false
        bottomNavBar.wantsLayer = true
        bottomNavBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1.0).cgColor

        // Top subtle divider line
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor
        bottomNavBar.addSubview(divider)

        // Center Mode Tabs
        btnSelezione.title = "🎯  Selezione  (⌘1)"
        btnSelezione.bezelStyle = .regularSquare
        btnSelezione.isBordered = false
        btnSelezione.wantsLayer = true
        btnSelezione.layer?.cornerRadius = 6
        btnSelezione.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        btnSelezione.target = self
        btnSelezione.action = #selector(onSelezioneTabClicked)

        btnMontaggio.title = "✂️  Montaggio  (⌘2)"
        btnMontaggio.bezelStyle = .regularSquare
        btnMontaggio.isBordered = false
        btnMontaggio.wantsLayer = true
        btnMontaggio.layer?.cornerRadius = 6
        btnMontaggio.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        btnMontaggio.target = self
        btnMontaggio.action = #selector(onMontaggioTabClicked)

        let centerStack = NSStackView(views: [btnSelezione, btnMontaggio])
        centerStack.orientation = .horizontal
        centerStack.spacing = 12
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        bottomNavBar.addSubview(centerStack)

        // Left: Project Manager & Autosave Status
        projectManagerBtn.title = "📁 Progetti"
        projectManagerBtn.bezelStyle = .rounded
        projectManagerBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        projectManagerBtn.target = self
        projectManagerBtn.action = #selector(openProjectManager)
        projectManagerBtn.translatesAutoresizingMaskIntoConstraints = false

        autosaveStatusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        autosaveStatusLabel.textColor = NSColor.systemGreen.withAlphaComponent(0.85)
        autosaveStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView(views: [projectManagerBtn, autosaveStatusLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        bottomNavBar.addSubview(leftStack)

        // Right: Undo, Redo, History Panel
        navUndoBtn.title = "↩"
        navUndoBtn.toolTip = "Annulla (⌘Z)"
        navUndoBtn.bezelStyle = .rounded
        navUndoBtn.target = self
        navUndoBtn.action = #selector(performUndoAction)
        navUndoBtn.isEnabled = false

        navRedoBtn.title = "↪"
        navRedoBtn.toolTip = "Ripeti (⇧⌘Z)"
        navRedoBtn.bezelStyle = .rounded
        navRedoBtn.target = self
        navRedoBtn.action = #selector(performRedoAction)
        navRedoBtn.isEnabled = false

        historyBtn.title = "🕒 Cronologia"
        historyBtn.bezelStyle = .rounded
        historyBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        historyBtn.target = self
        historyBtn.action = #selector(toggleHistoryPopover)

        let rightStack = NSStackView(views: [navUndoBtn, navRedoBtn, historyBtn])
        rightStack.orientation = .horizontal
        rightStack.spacing = 6
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        bottomNavBar.addSubview(rightStack)

        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: bottomNavBar.topAnchor),
            divider.leadingAnchor.constraint(equalTo: bottomNavBar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bottomNavBar.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            leftStack.leadingAnchor.constraint(equalTo: bottomNavBar.leadingAnchor, constant: 14),
            leftStack.centerYAnchor.constraint(equalTo: bottomNavBar.centerYAnchor),

            centerStack.centerXAnchor.constraint(equalTo: bottomNavBar.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: bottomNavBar.centerYAnchor),
            btnSelezione.widthAnchor.constraint(equalToConstant: 150),
            btnSelezione.heightAnchor.constraint(equalToConstant: 26),
            btnMontaggio.widthAnchor.constraint(equalToConstant: 150),
            btnMontaggio.heightAnchor.constraint(equalToConstant: 26),

            rightStack.trailingAnchor.constraint(equalTo: bottomNavBar.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: bottomNavBar.centerYAnchor)
        ])

        updateNavBarStyles()
        updateHistoryNavButtons()
    }

    private func updateNavBarStyles() {
        let activeBg = NSColor(calibratedRed: 0.16, green: 0.44, blue: 0.88, alpha: 1.0).cgColor
        let inactiveBg = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor

        if currentMode == .selezione {
            btnSelezione.layer?.backgroundColor = activeBg
            btnSelezione.contentTintColor = NSColor.white
            btnMontaggio.layer?.backgroundColor = inactiveBg
            btnMontaggio.contentTintColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        } else {
            btnMontaggio.layer?.backgroundColor = activeBg
            btnMontaggio.contentTintColor = NSColor.white
            btnSelezione.layer?.backgroundColor = inactiveBg
            btnSelezione.contentTintColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        }
    }

    public func switchMode(to mode: EditorMode) {
        currentMode = mode
        updateNavBarStyles()

        if mode == .selezione {
            timelineVC.view.isHidden = true
            selectionVC.view.isHidden = false
            playerVC.switchPlaybackController(selectionVC.playbackController)
            selectionVC.rebuildCurrentComposition()
            DebugLogger.shared.log("Modalità SELEZIONE attiva (Reportage Dual-Strip).", level: .info)
        } else {
            selectionVC.view.isHidden = true
            timelineVC.view.isHidden = false
            playerVC.switchPlaybackController(self.playbackController)
            rebuildComposition()
            timelineVC.reloadTimelineUI()
            DebugLogger.shared.log("Modalità MONTAGGIO attiva (Timeline multitraccia).", level: .info)
        }
    }

    @objc private func onSelezioneTabClicked() {
        switchMode(to: .selezione)
    }

    @objc private func onMontaggioTabClicked() {
        switchMode(to: .montaggio)
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

    public func didUpdateTimelineFormat(_ timeline: TimelineModel) {
        if timeline.id == timelineModel.id {
            playerVC.updateAspectRatio(formatSize: timeline.format.size)
            timelineVC.reloadTimelineUI()
            rebuildComposition()
        }
        HistoryManager.shared.record(title: "Impostazioni Timeline", project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        updateHistoryNavButtons()
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

    // MARK: - Project Manager & History Engine Integration
    private func setupInitialProject() {
        if let doc = initialDocument {
            restoreProjectFromSnapshot(doc)
            DebugLogger.shared.log("Progetto '\(doc.name)' caricato da database SQLite locale.", level: .info)
        } else {
            let existing = ProjectDatabase.shared.getAllProjects()
            if let first = existing.first, let doc = ProjectDatabase.shared.loadProjectDocument(id: first.id) {
                restoreProjectFromSnapshot(doc)
                DebugLogger.shared.log("Progetto '\(doc.name)' caricato da database SQLite locale.", level: .info)
            } else {
                ProjectDatabase.shared.saveProjectImmediately(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
            }
        }
        HistoryManager.shared.reset(withInitialTitle: "Progetto Aperto", project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        updateHistoryNavButtons()
    }

    @objc public func openProjectManager() {
        ProjectDatabase.shared.saveProjectImmediately(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        if projectManagerWC == nil {
            projectManagerWC = ProjectManagerWindowController()
            projectManagerWC?.onOpenProject = { [weak self] doc in
                guard let self = self else { return }
                ProjectDatabase.shared.saveProjectImmediately(project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
                self.restoreProjectFromSnapshot(doc)
                HistoryManager.shared.reset(withInitialTitle: "Progetto Aperto", project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
                self.updateHistoryNavButtons()
            }
            projectManagerWC?.onCreateNewProject = { [weak self] name in
                self?.createNewProject(name: name)
            }
        }
        projectManagerWC?.showModal(relativeTo: view.window)
    }

    private func createNewProject(name: String) {
        ProjectDatabase.shared.saveProjectImmediately(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        let newProj = EditorProject()
        newProj.projectName = name
        let blankDoc = ProjectDocumentData(project: newProj, mediaItems: [])
        ProjectDatabase.shared.saveProjectImmediately(project: newProj, mediaItems: [])
        restoreProjectFromSnapshot(blankDoc)
        HistoryManager.shared.reset(withInitialTitle: "Nuovo Progetto", project: EditorProject.shared, mediaItems: [])
        updateHistoryNavButtons()
        DebugLogger.shared.log("Nuovo progetto creato: '\(name)'.", level: .info)
    }

    @objc public func toggleHistoryPopover() {
        if historyPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            let hvc = HistoryPanelViewController()
            hvc.onRestoreSnapshot = { [weak self] snapshot in
                self?.restoreProjectFromSnapshot(snapshot)
            }
            hvc.onPerformUndo = { [weak self] in
                self?.performUndo()
            }
            hvc.onPerformRedo = { [weak self] in
                self?.performRedo()
            }
            popover.contentViewController = hvc
            self.historyPopover = popover
            self.historyVC = hvc
        }

        if historyPopover?.isShown == true {
            historyPopover?.close()
        } else {
            historyVC?.reloadHistoryUI()
            historyPopover?.show(relativeTo: historyBtn.bounds, of: historyBtn, preferredEdge: .maxY)
        }
    }

    @objc private func performUndoAction() {
        performUndo()
    }

    @objc private func performRedoAction() {
        performRedo()
    }

    public func performUndo() {
        if let snapshot = HistoryManager.shared.undo(currentProject: EditorProject.shared, currentMediaItems: mediaPoolVC.mediaItems) {
            restoreProjectFromSnapshot(snapshot)
            DebugLogger.shared.log("Undo eseguito: \(HistoryManager.shared.currentTitle)", level: .info)
        }
    }

    public func performRedo() {
        if let snapshot = HistoryManager.shared.redo(currentProject: EditorProject.shared, currentMediaItems: mediaPoolVC.mediaItems) {
            restoreProjectFromSnapshot(snapshot)
            DebugLogger.shared.log("Redo eseguito: \(HistoryManager.shared.currentTitle)", level: .info)
        }
    }

    public func restoreProjectFromSnapshot(_ snapshot: ProjectDocumentData) {
        let restoredMedia = snapshot.mediaItems.map { $0.toMediaItem() }
        EditorProject.shared.reset(with: snapshot, restoredMedia: restoredMedia)
        mediaPoolVC.setMediaItems(restoredMedia)
        mediaPoolVC.updateTimelinePopUp()
        mediaPoolVC.updateFolderPopUp()
        self.timelineModel = EditorProject.shared.activeTimeline
        self.timelineVC.switchModel(self.timelineModel)
        self.selectionVC.currentSelection = EditorProject.shared.activeSelection
        self.selectionVC.updateHeaderUI()
        self.rebuildComposition()
        if self.currentMode == .selezione {
            self.selectionVC.rebuildCurrentComposition()
        }
        self.view.window?.title = "Vision — \(EditorProject.shared.projectName)"
        updateHistoryNavButtons()
    }

    private func updateHistoryNavButtons() {
        navUndoBtn.isEnabled = HistoryManager.shared.canUndo
        navRedoBtn.isEnabled = HistoryManager.shared.canRedo
        let count = HistoryManager.shared.pastEntries.count
        historyBtn.title = "🕒 Cronologia (\(count))"
    }
}
