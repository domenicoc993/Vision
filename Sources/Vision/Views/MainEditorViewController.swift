import AppKit
import AVFoundation
import UniformTypeIdentifiers

public final class MainEditorViewController: NSViewController, MediaPoolDelegate {
    private var timelineModel: TimelineModel = EditorProject.shared.activeTimeline
    private let playbackController = PlaybackController()

    private var mediaPoolVC: MediaPoolViewController!
    private var playerVC: PlayerViewController!
    private var timelineVC: TimelineViewController!

    private let mainSplit = NSSplitView()
    private let topSplit = NSSplitView()
    private let bottomNavBar = NSView()
    private let activeModePill = NSView()
    private let activeModeIconView = NSImageView()
    private let activeModeLabel = NSTextField(labelWithString: "")

    private var projectManagerWC: ProjectManagerWindowController?
    private var historyPopover: NSPopover?
    private var historyVC: HistoryPanelViewController?

    private let projectManagerBtn = IconActionButton(toolTip: "Project Manager (⌘O)", isToggleMode: false)
    private let autosaveStatusLabel = NSTextField(labelWithString: "● Salvato")
    private let historyBtn = IconActionButton(toolTip: "Cronologia Azioni (⌘Y)", isToggleMode: false)
    private let navUndoBtn = IconActionButton(toolTip: "Annulla (⌘Z)", isToggleMode: false)
    private let navRedoBtn = IconActionButton(toolTip: "Ripeti (⇧⌘Z)", isToggleMode: false)

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
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1.0).cgColor

        timelineModel = EditorProject.shared.activeTimeline

        mediaPoolVC = MediaPoolViewController()
        mediaPoolVC.delegate = self
        mediaPoolVC.timelineModel = timelineModel

        playerVC = PlayerViewController(playbackController: playbackController)
        playerVC.onProxyToggled = { [weak self] in
            self?.rebuildComposition()
        }

        timelineVC = TimelineViewController(model: timelineModel, playbackController: playbackController)
        timelineVC.onTimelineAction = { [weak self] title in
            guard let self = self else { return }
            self.mediaPoolVC.refreshTimelineGrid()
            self.mediaPoolVC.refreshMediaPoolDisplay()
            let skipRebuildPrefixes = ["Marcatore", "Rimuovi Marcatori", "Sposta Marcatore", "Sposta Beat Marker", "Sposta Sbarra", "Elimina Marcatore", "Elimina Sbarra", "Priorità", "Rimuovi Priorità", "Blocca Clip", "Sblocca Clip"]
            if !skipRebuildPrefixes.contains(where: { title.hasPrefix($0) }) {
                self.rebuildComposition()
            }
            HistoryManager.shared.record(title: title, project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
        }
        timelineVC.onTimelineModified = { [weak self] in
            self?.timelineVC.onTimelineAction?("Modifica Timeline")
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
        timelineVC.onExportFCPXML = { [weak self] in
            guard let self = self else { return }
            self.exportTimelineToFCPXML(self.timelineModel)
        }
        timelineVC.onImportDroppedURLsToTimeline = { [weak self] urls, atTime, trackIdx, isVideo in
            guard let self = self else { return }
            self.mediaPoolVC.importURLsForTimelineDrop(urls) { [weak self] loadedItems in
                guard let self = self, !loadedItems.isEmpty else { return }
                var currentT = atTime
                for item in loadedItems {
                    self.timelineModel.insertClip(
                        mediaItem: item,
                        atTime: currentT,
                        targetTrackIndex: trackIdx,
                        isTargetVideo: isVideo
                    )
                    currentT = CMTimeAdd(currentT, item.duration)
                }
                self.commitTimelineEdit(title: "Importa & Inserisci in Timeline")
            }
        }

        print(">>> loadView: setting up splits and views...")
        fflush(stdout)

        EditorProject.shared.onProjectChanged = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.mediaPoolVC.updateTimelinePopUp()
                self.mediaPoolVC.updateFolderPopUp()
                self.updateActiveTimelinePill()
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

        // Vertical Split: Top (Pool + Player) / Bottom (Timeline)
        timelineVC.view.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.isVertical = false
        mainSplit.dividerStyle = .paneSplitter
        mainSplit.translatesAutoresizingMaskIntoConstraints = false

        mainSplit.addArrangedSubview(topSplit)
        mainSplit.addArrangedSubview(timelineVC.view)

        setupBottomNavBar()

        root.addSubview(mainSplit)
        root.addSubview(bottomNavBar)

        let minMPWidth = mediaPoolVC.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        minMPWidth.priority = .defaultHigh
        let minPlayerWidth = playerVC.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 320)
        minPlayerWidth.priority = .defaultHigh
        let minTopHeight = topSplit.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        minTopHeight.priority = .defaultHigh
        let minBottomHeight = timelineVC.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
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

        self.view = root

        rebuildComposition()
        timelineVC.reloadTimelineUI()
        playerVC.updateAspectRatio(formatSize: timelineModel.format.size)
        setupInitialProject()
        setupKeyboardMonitor()

        DebugLogger.shared.log("Vision avviato. Scorciatoie: ⌃F (Schermo Intero), Spazio (Play/Pausa), 1/2/3/0 (Priorità), M/⌥M (Marcatori), Q/W/S (Trim/Spezza).", level: .info)
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
            guard event.window == self.view.window, NSApp.modalWindow == nil else { return event }

            if let firstResponder = self.view.window?.firstResponder, firstResponder is NSTextView {
                return event
            }

            let isOption = event.modifierFlags.contains(.option)
            let isCommand = event.modifierFlags.contains(.command)
            let isControl = event.modifierFlags.contains(.control)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // Control + F -> Fullscreen Viewer from ANYWHERE in the app
            if isControl && (event.keyCode == 3 || chars == "f") {
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

            // Priority tagging: 1 = Hero, 2 = Buona, 3 = Filler, 0 = Clear
            if !isCommand && !isControl && !isOption {
                var targetPriority: Int? = nil
                var matchedPriorityKey = false

                if chars == "1" || event.keyCode == 18 || event.keyCode == 83 {
                    targetPriority = 1
                    matchedPriorityKey = true
                } else if chars == "2" || event.keyCode == 19 || event.keyCode == 84 {
                    targetPriority = 2
                    matchedPriorityKey = true
                } else if chars == "3" || event.keyCode == 20 || event.keyCode == 85 {
                    targetPriority = 3
                    matchedPriorityKey = true
                } else if chars == "0" || event.keyCode == 29 || event.keyCode == 82 {
                    targetPriority = nil
                    matchedPriorityKey = true
                }

                if matchedPriorityKey {
                    let t = self.playbackController.accurateCurrentTime
                    let res = self.timelineModel.setClipPriority(targetPriority, at: t)
                    if res.updatedCount > 0 {
                        let label: String
                        switch targetPriority {
                        case 1: label = "Priorità 1 — Hero"
                        case 2: label = "Priorità 2 — Buona"
                        case 3: label = "Priorità 3 — Filler"
                        default: label = "Rimuovi Priorità"
                        }
                        self.commitTimelineEdit(title: label, rebuild: false)
                        DebugLogger.shared.log(res.summary, level: .info)
                    } else {
                        DebugLogger.shared.log("Seleziona una clip o posiziona la testina su una clip per assegnare la priorità (1/2/3/0).", level: .warning)
                    }
                    return nil
                }

                // 'M' -> Segna / rimuovi marcatore su clip audio/video under playhead or selected
                if chars == "m" || event.keyCode == 46 {
                    let markTime = self.playbackController.accurateCurrentTime
                    let res = self.timelineModel.toggleClipMarker(at: markTime)
                    if res.added > 0 || res.removed > 0 {
                        let title = res.added > 0 ? "Aggiungi Marcatore (M)" : "Rimuovi Marcatore (M)"
                        self.commitTimelineEdit(title: title, rebuild: false)
                        DebugLogger.shared.log("Marcatori (M): \(res.summary.joined(separator: " | "))", level: .info)
                    } else {
                        DebugLogger.shared.log("Nessuna clip sotto la testina o selezionata su cui segnare il marcatore (M).", level: .warning)
                    }
                    return nil
                }
            }

            if isOption && !isCommand && !isControl && (chars == "m" || event.keyCode == 46) {
                let markTime = self.playbackController.accurateCurrentTime
                let cleared = self.timelineModel.clearAllClipMarkers(at: markTime)
                if cleared > 0 {
                    self.commitTimelineEdit(title: "Rimuovi Marcatori Clip (⌥M)", rebuild: false)
                    DebugLogger.shared.log("Rimossi \(cleared) marcatori dalla clip.", level: .info)
                }
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

            case 12: // 'Q' key -> Trim start to playhead with playhead alignment
                if let targetTime = self.timelineModel.trimClipStart(at: self.playbackController.accurateCurrentTime) {
                    self.playbackController.seek(to: targetTime, frameAccurate: true)
                    self.commitTimelineEdit(title: "Trim Inizio Clip (Q)")
                }
                return nil

            case 13: // 'W' key -> Cmd+Option+W: Svuotamento spazi, oppure W: Trim fine
                if isCommand && isOption {
                    if self.timelineModel.closeGapsBetweenSelectedClips() {
                        self.commitTimelineEdit(title: "Chiudi Spazi (⌥⌘W)")
                    }
                    return nil
                }
                if self.timelineModel.trimClipEnd(at: self.playbackController.accurateCurrentTime) {
                    self.commitTimelineEdit(title: "Trim Fine Clip (W)")
                }
                return nil

            case 1, 11: // 'S' or 'B' key
                if isOption, self.timelineModel.selectedClipId != nil {
                    // Option + S -> Toggle 50% Slow Motion
                    self.timelineVC.onToggleSpeedClicked()
                    return nil
                }
                // S / B -> Spezza clip alla testina
                if self.timelineModel.splitClip(at: self.playbackController.accurateCurrentTime) {
                    self.commitTimelineEdit(title: "Spezza Clip (S)")
                }
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
                            if self.timelineModel.setClipSpan(clipId: selId, newSpan: clip.span - 1) {
                                self.commitTimelineEdit(title: "Riduci Span Gabbia (⌥-)")
                            }
                            break
                        }
                    }
                    return nil
                }

            case 45: // 'N' key -> Toggle Magnet Snapping (Resolve convention)
                self.timelineVC.onMagnetToggleClicked()
                return nil

            case 37: // 'L' key -> Toggle Link / Unlink if Cmd/Opt, otherwise Lock/Unlock selected clip
                if isCommand || isOption {
                    self.timelineVC.onLinkToggleClicked()
                    return nil
                }
                if !isControl {
                    let res = self.timelineModel.toggleSelectedClipsLock(at: self.playbackController.accurateCurrentTime)
                    if res.toggledCount > 0 {
                        let label = res.isNowLocked ? "Blocca Clip (L)" : "Sblocca Clip (L)"
                        self.commitTimelineEdit(title: label, rebuild: false)
                        DebugLogger.shared.log(res.isNowLocked ? "Clip bloccata 🔒 (protetta in Auto-Fill)" : "Clip sbloccata 🔓", level: .info)
                    } else {
                        DebugLogger.shared.log("Seleziona una clip o posiziona la testina su una clip per bloccarla/sbloccarla (L).", level: .warning)
                    }
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
                    if self.timelineModel.swapAdjacentCages(clipId: selId, direction: -1) {
                        self.commitTimelineEdit(title: "Scambia Gabbia Ritmica (←)")
                    }
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
                    if self.timelineModel.swapAdjacentCages(clipId: selId, direction: +1) {
                        self.commitTimelineEdit(title: "Scambia Gabbia Ritmica (→)")
                    }
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
                if self.timelineVC.deleteSelectedMarker() {
                    self.commitTimelineEdit(title: "Elimina Marcatore", rebuild: false)
                    return nil
                }
                if self.timelineModel.selectedClipIds.isEmpty && self.timelineModel.isSelectionFollowsPlayhead {
                    self.timelineModel.updateSelectionAtPlayhead(time: self.playbackController.currentTime)
                }
                // Se ci sono gabbie ritmate attive e una clip selezionata, usa Slot Ripple Delete!
                if let selId = self.timelineModel.selectedClipId, !self.timelineModel.activeCageIntervals().isEmpty {
                    if self.timelineModel.slotRippleDelete(clipId: selId) {
                        self.commitTimelineEdit(title: "Elimina Clip Ritmica")
                        return nil
                    }
                }
                if !self.timelineModel.selectedClipIds.isEmpty {
                    self.timelineModel.removeSelectedClips()
                    self.commitTimelineEdit(title: "Elimina Clip")
                    return nil
                }

            default:
                break
            }
            return event
        }
    }

    private func setupBottomNavBar() {
        bottomNavBar.translatesAutoresizingMaskIntoConstraints = false
        bottomNavBar.wantsLayer = true
        bottomNavBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor

        // Top subtle divider line
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
        bottomNavBar.addSubview(divider)

        // Center Active Timeline / Selection Pill
        activeModePill.wantsLayer = true
        activeModePill.layer?.cornerRadius = 6
        activeModePill.layer?.borderWidth = 1.0
        activeModePill.translatesAutoresizingMaskIntoConstraints = false

        activeModeIconView.translatesAutoresizingMaskIntoConstraints = false
        activeModeLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        activeModeLabel.lineBreakMode = .byTruncatingTail
        activeModeLabel.translatesAutoresizingMaskIntoConstraints = false

        activeModePill.addSubview(activeModeIconView)
        activeModePill.addSubview(activeModeLabel)
        bottomNavBar.addSubview(activeModePill)

        NSLayoutConstraint.activate([
            activeModeIconView.leadingAnchor.constraint(equalTo: activeModePill.leadingAnchor, constant: 10),
            activeModeIconView.centerYAnchor.constraint(equalTo: activeModePill.centerYAnchor),
            activeModeIconView.widthAnchor.constraint(equalToConstant: 14),
            activeModeIconView.heightAnchor.constraint(equalToConstant: 14),

            activeModeLabel.leadingAnchor.constraint(equalTo: activeModeIconView.trailingAnchor, constant: 6),
            activeModeLabel.trailingAnchor.constraint(equalTo: activeModePill.trailingAnchor, constant: -10),
            activeModeLabel.centerYAnchor.constraint(equalTo: activeModePill.centerYAnchor)
        ])

        // Left: Project Manager & Autosave Status
        projectManagerBtn.image = Lucide.template(.database, size: 16)
        projectManagerBtn.activeTintColor = .systemCyan
        projectManagerBtn.target = self
        projectManagerBtn.action = #selector(openProjectManager)
        projectManagerBtn.translatesAutoresizingMaskIntoConstraints = false
        projectManagerBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        projectManagerBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        autosaveStatusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        autosaveStatusLabel.textColor = NSColor.systemGreen.withAlphaComponent(0.85)
        autosaveStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView(views: [projectManagerBtn, autosaveStatusLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 10
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        bottomNavBar.addSubview(leftStack)

        // Right: Undo, Redo, History Panel
        navUndoBtn.image = Lucide.template(.undo2, size: 16)
        navUndoBtn.activeTintColor = .white
        navUndoBtn.target = self
        navUndoBtn.action = #selector(performUndoAction)
        navUndoBtn.isEnabled = false
        navUndoBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        navUndoBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        navRedoBtn.image = Lucide.template(.redo2, size: 16)
        navRedoBtn.activeTintColor = .white
        navRedoBtn.target = self
        navRedoBtn.action = #selector(performRedoAction)
        navRedoBtn.isEnabled = false
        navRedoBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        navRedoBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        historyBtn.image = Lucide.template(.history, size: 16)
        historyBtn.activeTintColor = .systemCyan
        historyBtn.target = self
        historyBtn.action = #selector(toggleHistoryPopover)
        historyBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        historyBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let rightStack = NSStackView(views: [navUndoBtn, navRedoBtn, historyBtn])
        rightStack.orientation = .horizontal
        rightStack.spacing = 10
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

            activeModePill.centerXAnchor.constraint(equalTo: bottomNavBar.centerXAnchor),
            activeModePill.centerYAnchor.constraint(equalTo: bottomNavBar.centerYAnchor),
            activeModePill.heightAnchor.constraint(equalToConstant: 26),
            activeModePill.widthAnchor.constraint(lessThanOrEqualToConstant: 440),

            rightStack.trailingAnchor.constraint(equalTo: bottomNavBar.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: bottomNavBar.centerYAnchor)
        ])

        updateActiveTimelinePill()
        updateHistoryNavButtons()
    }

    private func updateActiveTimelinePill() {
        if timelineModel.isSelection {
            activeModePill.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.16).cgColor
            activeModePill.layer?.borderColor = NSColor.systemPurple.withAlphaComponent(0.45).cgColor
            activeModeIconView.image = Lucide.image(.sparkles, size: 13, color: .systemPurple)
            activeModeLabel.textColor = NSColor(calibratedWhite: 0.94, alpha: 1.0)
            activeModeLabel.stringValue = "Selezione: \(timelineModel.name) (1V+1A) • Tasti 1/2/3 Priorità • M Marcatore"
        } else {
            activeModePill.layer?.backgroundColor = NSColor.systemCyan.withAlphaComponent(0.12).cgColor
            activeModePill.layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.32).cgColor
            activeModeIconView.image = Lucide.image(.clapperboard, size: 13, color: .systemCyan)
            activeModeLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
            activeModeLabel.stringValue = "Timeline: \(timelineModel.name)"
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
                if targetTrack >= 0 && targetTrack < timelineModel.maxVideoTracks {
                    timelineModel.ensureVideoTrack(id: targetTrack)
                    guard !timelineModel.videoTracks[targetTrack].isLocked else {
                        DebugLogger.shared.log("Traccia di destinazione V\(targetTrack + 1) bloccata 🔒. Spostamento impedito.", level: .warning)
                        return
                    }
                    timelineModel.commitMoveClip(id: id, toTrack: targetTrack, isVideo: true)
                    commitTimelineEdit(title: "Sposta Clip su V\(targetTrack + 1)")
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
                if targetTrack >= 0 && targetTrack < timelineModel.maxAudioTracks {
                    timelineModel.ensureAudioTrack(id: targetTrack)
                    guard !timelineModel.audioTracks[targetTrack].isLocked else {
                        DebugLogger.shared.log("Traccia di destinazione A\(targetTrack + 1) bloccata 🔒. Spostamento impedito.", level: .warning)
                        return
                    }
                    timelineModel.commitMoveClip(id: id, toTrack: targetTrack, isVideo: false)
                    commitTimelineEdit(title: "Sposta Clip su A\(targetTrack + 1)")
                }
                return
            }
        }
    }

    private func commitTimelineEdit(title: String, rebuild: Bool = true) {
        timelineVC.reloadTimelineUI()
        mediaPoolVC.refreshTimelineGrid()
        if rebuild {
            rebuildComposition()
        }
        HistoryManager.shared.record(title: title, project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
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
        self.updateActiveTimelinePill()
        self.rebuildComposition()
    }

    public func didImportTimelinesFromXML(_ timelines: [TimelineModel]) {
        guard !timelines.isEmpty else { return }
        EditorProject.shared.timelines.append(contentsOf: timelines)
        let firstIdx = EditorProject.shared.timelines.count - timelines.count
        EditorProject.shared.activeTimelineIndex = firstIdx
        let firstTL = EditorProject.shared.timelines[firstIdx]
        mediaPoolVC.refreshMediaPoolDisplay()
        didSwitchActiveTimeline(to: firstTL)
        HistoryManager.shared.record(title: "Importa XML", project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
    }

    public func didSelectAddClipToTimeline(_ item: MediaItem) {
        timelineModel.appendClip(mediaItem: item)
        commitTimelineEdit(title: "Aggiungi Clip in Timeline")
    }

    public func didChangeMediaOrientation(_ item: MediaItem) {
        for trackIdx in 0..<timelineModel.videoTracks.count where !timelineModel.videoTracks[trackIdx].isLocked {
            for clipIdx in 0..<timelineModel.videoTracks[trackIdx].clips.count {
                if timelineModel.videoTracks[trackIdx].clips[clipIdx].mediaItem.url == item.url {
                    timelineModel.videoTracks[trackIdx].clips[clipIdx].orientation = item.orientation
                }
            }
        }
        commitTimelineEdit(title: "Orientamento Media")
    }

    public func didSelectSeekToClip(_ clip: TimelineClip) {
        playbackController.seek(to: clip.timelineStart, frameAccurate: true)
        timelineVC.reloadTimelineUI()
    }

    public func didReorderTimelineFromGrid() {
        commitTimelineEdit(title: "Riordina Timeline da Griglia")
    }

    public func didDeleteMediaItemFromPool(_ item: MediaItem) {
        commitTimelineEdit(title: "Elimina Media dal Pool")
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

    public func didRequestExportTimelineToFCPXML(_ timeline: TimelineModel) {
        exportTimelineToFCPXML(timeline)
    }

    public func exportActiveTimelineToFCPXML() {
        exportTimelineToFCPXML(timelineModel)
    }

    public func exportTimelineToFCPXML(_ timeline: TimelineModel) {
        let savePanel = NSSavePanel()
        savePanel.title = "Esporta Final Cut Pro XML"
        savePanel.prompt = "Esporta"
        savePanel.canCreateDirectories = true
        savePanel.allowsOtherFileTypes = true
        let safeBaseName = timeline.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        savePanel.nameFieldStringValue = "\(safeBaseName).fcpxmld"

        // Custom minimal format picker accessory using VisionDropdownButton
        let accView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 38))
        let fmtLabel = NSTextField(labelWithString: "Formato:")
        fmtLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fmtLabel.translatesAutoresizingMaskIntoConstraints = false
        let fmtDropdown = VisionDropdownButton()
        fmtDropdown.translatesAutoresizingMaskIntoConstraints = false
        fmtDropdown.addItem(withTitle: "Bundle .fcpxmld (Final Cut Pro / Resolve)")
        fmtDropdown.addItem(withTitle: "File XML singolo (.fcpxml)")
        fmtDropdown.selectItem(at: 0)
        fmtDropdown.onSelectionChanged = { [weak savePanel] idx, _ in
            guard let savePanel = savePanel else { return }
            let cur = (savePanel.nameFieldStringValue as NSString).deletingPathExtension
            let cleanBase = cur.isEmpty ? safeBaseName : cur
            savePanel.nameFieldStringValue = idx == 0 ? "\(cleanBase).fcpxmld" : "\(cleanBase).fcpxml"
        }
        accView.addSubview(fmtLabel)
        accView.addSubview(fmtDropdown)
        NSLayoutConstraint.activate([
            fmtLabel.leadingAnchor.constraint(equalTo: accView.leadingAnchor, constant: 12),
            fmtLabel.centerYAnchor.constraint(equalTo: accView.centerYAnchor),
            fmtDropdown.leadingAnchor.constraint(equalTo: fmtLabel.trailingAnchor, constant: 10),
            fmtDropdown.trailingAnchor.constraint(equalTo: accView.trailingAnchor, constant: -12),
            fmtDropdown.centerYAnchor.constraint(equalTo: accView.centerYAnchor)
        ])
        savePanel.accessoryView = accView

        let runSave: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .OK, var targetURL = savePanel.url else { return }
            let isSingleXML = (fmtDropdown.selectedIndex == 1)
            let ext = targetURL.pathExtension.lowercased()
            if isSingleXML && ext != "fcpxml" && ext != "xml" {
                targetURL = targetURL.deletingPathExtension().appendingPathExtension("fcpxml")
            } else if !isSingleXML && ext != "fcpxmld" {
                targetURL = targetURL.deletingPathExtension().appendingPathExtension("fcpxmld")
            }

            do {
                let exportedURL = try FCPXMLExporter.exportTimeline(
                    timeline,
                    to: targetURL,
                    eventName: EditorProject.shared.projectName
                )
                let alert = NSAlert()
                alert.messageText = "Esportazione completata"
                alert.informativeText = "Timeline '\(timeline.name)' esportata nel formato Final Cut Pro XML in:\n\(exportedURL.path)"
                alert.addButton(withTitle: "Mostra nel Finder")
                alert.addButton(withTitle: "OK")
                let alertResp = alert.runModal()
                if alertResp == .alertFirstButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                }
            } catch {
                let errAlert = NSAlert()
                errAlert.alertStyle = .warning
                errAlert.messageText = "Errore durante l'esportazione FCPXML"
                errAlert.informativeText = error.localizedDescription
                errAlert.runModal()
                let _ = self
            }
        }

        if let win = view.window {
            savePanel.beginSheetModal(for: win, completionHandler: runSave)
        } else {
            runSave(savePanel.runModal())
        }
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
            hvc.onJumpToHistory = { [weak self] pastIndex in
                self?.performJumpToHistory(pastIndex: pastIndex)
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

    public func performJumpToHistory(pastIndex: Int) {
        if let snapshot = HistoryManager.shared.jumpTo(pastIndex: pastIndex, currentProject: EditorProject.shared, currentMediaItems: mediaPoolVC.mediaItems) {
            restoreProjectFromSnapshot(snapshot)
            DebugLogger.shared.log("Cronologia ripristinata a: \(HistoryManager.shared.currentTitle)", level: .info)
        }
    }

    public func restoreProjectFromSnapshot(_ snapshot: ProjectDocumentData) {
        let restoredMedia = snapshot.mediaItems.map { $0.toMediaItem() }
        EditorProject.shared.reset(with: snapshot, restoredMedia: restoredMedia)
        mediaPoolVC.setMediaItems(restoredMedia)
        self.timelineModel = EditorProject.shared.activeTimeline
        self.timelineVC.switchModel(self.timelineModel)
        self.mediaPoolVC.timelineModel = self.timelineModel
        self.mediaPoolVC.updateTimelinePopUp()
        self.mediaPoolVC.updateFolderPopUp()
        self.mediaPoolVC.refreshTimelineGrid()
        self.playerVC.updateAspectRatio(formatSize: self.timelineModel.format.size)
        self.updateActiveTimelinePill()
        self.rebuildComposition()
        self.view.window?.title = "Vision — \(EditorProject.shared.projectName)"
        updateHistoryNavButtons()
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
    }

    private func updateHistoryNavButtons() {
        navUndoBtn.isEnabled = HistoryManager.shared.canUndo
        navRedoBtn.isEnabled = HistoryManager.shared.canRedo
        let count = HistoryManager.shared.pastEntries.count
        historyBtn.toolTip = "Cronologia Azioni (\(count)) (⌘Y)"
    }
}
