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
    private let activeModeLabel = NSTextField(labelWithString: "")

    private var projectManagerWC: ProjectManagerWindowController?
    private var historyPopover: NSPopover?
    private var historyVC: HistoryPanelViewController?

    private let projectManagerBtn = IconActionButton(toolTip: "Project Manager (⌘O)", isToggleMode: false)
    private let copyDebugBtn = NSButton()
    private let autosaveStatusLabel = NSTextField(labelWithString: "● Salvato")
    private let historyBtn = IconActionButton(toolTip: "Cronologia Azioni (⌘Y)", isToggleMode: false)
    private let navUndoBtn = IconActionButton(toolTip: "Annulla (⌘Z)", isToggleMode: false)
    private let navRedoBtn = IconActionButton(toolTip: "Ripeti (⇧⌘Z)", isToggleMode: false)
    private let keyboardBtn = IconActionButton(toolTip: "Scorciatoie da tastiera", isToggleMode: false)

    private var activeSection: FocusedSection = .timeline
    private var rebuildTask: Task<Void, Never>?
    private var initialDocument: ProjectDocumentData?
    private var jogFrameAccumulator: Double = 0
    private var lastJogEventTime: CFAbsoluteTime = 0
    private var lastWheelMode: SpeedEditorWheelMode = .jog

    private static let autosaveTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.timeStyle = .medium
        return formatter
    }()

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
        DebugLogger.shared.startPerformanceMonitoring()

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
            let skipRebuildPrefixes = ["Marcatore", "Rimuovi Marcatori", "Sposta Marcatore", "Sposta Beat Marker", "Sposta Sbarra", "Elimina Marcatore", "Elimina Sbarra", "Priorità", "Rimuovi Priorità", "Blocca Clip", "Sblocca Clip", "Beat Finder"]
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
        timelineVC.onSmartFilterChanged = { [weak self] in
            self?.rebuildComposition(preserveVisualSnapshot: false)
        }
        timelineVC.onLiveSlipPreview = { [weak self] in
            self?.rebuildComposition(preserveVisualSnapshot: true)
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
            let timeStr = Self.autosaveTimeFormatter.string(from: Date())
            self.autosaveStatusLabel.stringValue = "● Salvato (\(timeStr))"
            self.autosaveStatusLabel.textColor = NSColor.systemGreen.withAlphaComponent(0.85)
        }

        NotificationCenter.default.addObserver(
            forName: LUTEngine.stateChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.rebuildComposition(preserveVisualSnapshot: true)
            ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
        }

        playbackController.addTimeObserver(self) { [weak self] time in
            guard let self = self else { return }
            let sec = max(0.0, CMTimeGetSeconds(time))
            if abs(self.timelineModel.playheadSeconds - sec) > 0.005 {
                self.timelineModel.playheadSeconds = sec
                if !self.playbackController.isPlaying {
                    self.schedulePlayheadAutosave()
                }
            }
        }
        playbackController.addPlayStateObserver(self) { [weak self] isPlaying in
            guard let self = self else { return }
            if !isPlaying {
                self.timelineModel.playheadSeconds = max(0.0, CMTimeGetSeconds(self.playbackController.accurateCurrentTime))
                self.schedulePlayheadAutosave()
            }
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
        setupSpeedEditor()

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
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 48 {
                self.timelineVC.handleTabKeyStateChanged(isDown: false)
            }
            return event
        }

        // Keyboard monitor for professional editing shortcuts
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window == self.view.window, NSApp.modalWindow == nil else { return event }

            if let firstResponder = self.view.window?.firstResponder, firstResponder is NSTextView {
                return event
            }

            if event.keyCode == 48 {
                if !event.isARepeat {
                    self.timelineVC.handleTabKeyStateChanged(isDown: true)
                }
                return nil
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
                    if self.activeSection == .timeline || self.mediaPoolVC.isTimelineGridVisible {
                        var allIds: Set<UUID> = []
                        for track in self.timelineModel.videoTracks {
                            for clip in track.clips { allIds.insert(clip.id) }
                        }
                        for track in self.timelineModel.audioTracks {
                            for clip in track.clips { allIds.insert(clip.id) }
                        }
                        self.timelineModel.selectedClipIds = allIds
                        self.timelineVC.reloadTimelineUI()
                        self.mediaPoolVC.refreshTimelineGrid()
                        DebugLogger.shared.log("Timeline: selezionate tutte le \(allIds.count) clip.", level: .info)
                        return nil
                    } else {
                        self.mediaPoolVC.selectAllMediaItems()
                        DebugLogger.shared.log("Media Pool: selezionati tutti gli elementi.", level: .info)
                        return nil
                    }
                }

            case 7: // 'X' -> Taglia (⌘X / ⌃X)
                if (isCommand || isControl) && !isOption {
                    if self.performCut() { return nil }
                }

            case 8: // 'C' -> Copia (⌘C / ⌃C)
                if (isCommand || isControl) && !isOption {
                    if self.performCopy() { return nil }
                }

            case 9: // 'V' -> Incolla (⌘V / ⌃V)
                if (isCommand || isControl) && !isOption {
                    if self.performPaste() { return nil }
                }

            case 12: // 'Q' key -> Trim start to playhead with playhead alignment
                let editTime = self.timelineModel.isSmartFilterActive
                    ? self.timelineModel.realTimelineTime(forDisplayedTime: self.playbackController.accurateCurrentTime)
                    : self.playbackController.accurateCurrentTime
                if let targetTime = self.timelineModel.trimClipStart(at: editTime) {
                    let displayTarget = self.timelineModel.isSmartFilterActive
                        ? self.timelineModel.displayedTime(forRealTime: targetTime)
                        : targetTime
                    self.playbackController.setPlayheadForPendingReload(displayTarget)
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
                let editTime = self.timelineModel.isSmartFilterActive
                    ? self.timelineModel.realTimelineTime(forDisplayedTime: self.playbackController.accurateCurrentTime)
                    : self.playbackController.accurateCurrentTime
                if self.timelineModel.trimClipEnd(at: editTime) {
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
                let editTime = self.timelineModel.isSmartFilterActive
                    ? self.timelineModel.realTimelineTime(forDisplayedTime: self.playbackController.accurateCurrentTime)
                    : self.playbackController.accurateCurrentTime
                if self.timelineModel.splitClip(at: editTime) {
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
                if self.view.window?.firstResponder is NSTextView {
                    return event
                }
                if self.isMediaPoolFocusedForDeletion() {
                    if self.mediaPoolVC.deleteSelectedPoolItems(requireConfirmation: true) {
                        return nil
                    }
                    return event
                }
                if self.performBackspaceOrRippleDelete() {
                    return nil
                }

            case 14: // 'E' key -> In Selezione e Modalità Gabbie equivale a Backspace (Elimina con scarto)
                if !isCommand && !isControl && !isOption && (self.timelineModel.isSelection || self.timelineModel.isCageLockActive) {
                    if self.performBackspaceOrRippleDelete() {
                        return nil
                    }
                }

            case 15: // 'R' key -> Slow-Mo in gabbia (R) o Slow-Mo 2 gabbie (⌘R)
                if !isOption && !isControl && self.timelineModel.selectedClipId != nil {
                    if isCommand {
                        self.timelineVC.onToggleSlowMoMultiCageClicked()
                    } else {
                        self.timelineVC.onToggleSpeedClicked()
                    }
                    return nil
                }

            default:
                break
            }
            return event
        }
    }

    @discardableResult
    public func performCopy() -> Bool {
        let playhead = timelineModel.isSmartFilterActive
            ? timelineModel.realTimelineTime(forDisplayedTime: playbackController.accurateCurrentTime)
            : playbackController.accurateCurrentTime
        let count = timelineModel.copySelectedClips(atPlayhead: playhead)
        if count > 0 {
            DebugLogger.shared.log("Copiate \(count) clip negli appunti Vision.", level: .info)
            return true
        }
        DebugLogger.shared.log("Seleziona una o più clip o posiziona la testina su una clip per copiare.", level: .warning)
        return false
    }

    @discardableResult
    public func performCut() -> Bool {
        let playhead = timelineModel.isSmartFilterActive
            ? timelineModel.realTimelineTime(forDisplayedTime: playbackController.accurateCurrentTime)
            : playbackController.accurateCurrentTime
        if timelineModel.selectedClipIds.isEmpty {
            timelineModel.updateSelectionAtPlayhead(time: playhead)
        }
        let count = timelineModel.copySelectedClips(atPlayhead: playhead)
        guard count > 0 else {
            DebugLogger.shared.log("Nessuna clip selezionata da tagliare.", level: .warning)
            return false
        }
        if timelineModel.selectedClipIds.isEmpty {
            timelineModel.updateSelectionAtPlayhead(time: playhead)
        }
        timelineModel.removeSelectedClips()
        commitTimelineEdit(title: "Taglia Clip (\(count))")
        DebugLogger.shared.log("Tagliate \(count) clip negli appunti Vision.", level: .info)
        return true
    }

    @discardableResult
    public func performPaste() -> Bool {
        guard !VisionTimelineClipboard.shared.entries.isEmpty else {
            DebugLogger.shared.log("Appunti Vision vuoti: nulla da incollare.", level: .warning)
            return false
        }
        let rawPlayhead = playbackController.accurateCurrentTime
        let targetTime = timelineModel.isSmartFilterActive
            ? timelineModel.realTimelineTime(forDisplayedTime: rawPlayhead)
            : rawPlayhead
        let res = timelineModel.pasteClipboardClips(at: targetTime)
        if res.pastedCount > 0 {
            let displayEnd = timelineModel.isSmartFilterActive
                ? timelineModel.displayedTime(forRealTime: res.endTime)
                : res.endTime
            playbackController.setPlayheadForPendingReload(displayEnd)
            commitTimelineEdit(title: "Incolla Clip (\(res.pastedCount))")
            DebugLogger.shared.log("Incollate \(res.pastedCount) clip nella timeline attiva.", level: .info)
            return true
        }
        DebugLogger.shared.log("Impossibile incollare alla testina (traccia bloccata o protetta).", level: .warning)
        return false
    }

    private func isMediaPoolFocusedForDeletion() -> Bool {
        if activeSection == .mediaPool {
            return true
        }
        if let responderView = view.window?.firstResponder as? NSView {
            return responderView.isDescendant(of: mediaPoolVC.view)
        }
        return false
    }

    @discardableResult
    private func performBackspaceOrRippleDelete() -> Bool {
        if self.timelineVC.deleteSelectedMarker() {
            self.commitTimelineEdit(title: "Elimina Marcatore", rebuild: false)
            return true
        }
        if self.timelineModel.selectedClipIds.isEmpty && self.timelineModel.isSelectionFollowsPlayhead {
            self.timelineModel.updateSelectionAtPlayhead(time: self.playbackController.currentTime)
        }
        if let selId = self.timelineModel.selectedClipId, !self.timelineModel.activeCageIntervals().isEmpty {
            if self.timelineModel.slotRippleDelete(clipId: selId) {
                self.commitTimelineEdit(title: "Elimina Clip Ritmica")
                return true
            }
        }
        if !self.timelineModel.selectedClipIds.isEmpty {
            self.timelineModel.removeSelectedClips()
            self.commitTimelineEdit(title: "Elimina Clip")
            return true
        }
        return false
    }

    private func setupSpeedEditor() {
        let mgr = SpeedEditorManager.shared
        mgr.onCommandAction = { [weak self] action in
            guard NSApp.modalWindow == nil else { return }
            self?.executeCommand(action)
        }
        mgr.onWheelDelta = { [weak self] mode, delta in
            guard let self = self, NSApp.modalWindow == nil else { return }
            let sens = max(0.1, min(4.0, mgr.wheelSensitivity))
            let now = CFAbsoluteTimeGetCurrent()
            if mode != self.lastWheelMode {
                self.jogFrameAccumulator = 0
                self.lastWheelMode = mode
            }

            switch mode {
            case .jog:
                let tBefore = CMTimeGetSeconds(self.playbackController.currentTime)
                let accBefore = self.jogFrameAccumulator
                let frames = SpeedEditorManager.computeJogFrames(
                    delta: delta,
                    sensitivity: sens,
                    accumulator: &self.jogFrameAccumulator,
                    lastEventTime: &self.lastJogEventTime,
                    now: now
                )
                if frames != 0 {
                    self.playbackController.jog(byFrames: frames)
                }
                let tAfter = CMTimeGetSeconds(self.playbackController.currentTime)
                let durSec = CMTimeGetSeconds(self.playbackController.duration)
                let tlFps = self.timelineModel.format.fps
                let plFps = self.playbackController.fps
                DebugLogger.shared.log(
                    "[SPEED-JOG] delta=\(delta) sens=\(String(format: "%.2fx", sens)) (scale=\(String(format: "%.3f", SpeedEditorManager.effectiveWheelScale(for: sens)))) acc:\(String(format: "%.2f", accBefore))->\(String(format: "%.2f", self.jogFrameAccumulator)) frames=\(frames) | fps(tl=\(tlFps), pl=\(plFps)) dur=\(String(format: "%.1f", durSec))s | t:\(String(format: "%.3f", tBefore))->\(String(format: "%.3f", tAfter))s (\(String(format: "%+.3f", tAfter - tBefore))s)",
                    level: .playback
                )

            case .shuttle:
                // Valore assoluto [-4096 .. +4096] con deadzone al centro
                let deadzone: Double = 120.0
                let absRaw = Double(abs(delta))
                if absRaw < deadzone {
                    self.playbackController.setShuttleRate(0)
                    DebugLogger.shared.log("[SPEED-SHTL] raw=\(delta) sens=\(String(format: "%.2fx", sens)) rate=0.00x (deadzone)", level: .playback)
                } else {
                    let norm = min(1.0, (absRaw - deadzone) / (4096.0 - deadzone))
                    let curve = 0.25 + pow(norm, 1.65) * (7.75 * sens)
                    let signedRate = Float(delta >= 0 ? curve : -curve)
                    self.playbackController.setShuttleRate(signedRate)
                    DebugLogger.shared.log("[SPEED-SHTL] raw=\(delta) sens=\(String(format: "%.2fx", sens)) rate=\(String(format: "%.2fx", signedRate))", level: .playback)
                }

            case .scroll:
                let dx = SpeedEditorManager.computeScrollDelta(delta: delta, sensitivity: sens)
                self.timelineVC.scrollHorizontally(by: dx)
                DebugLogger.shared.log("[SPEED-SCRL] delta=\(delta) sens=\(String(format: "%.2fx", sens)) dx=\(String(format: "%.1f", dx))pt", level: .playback)
            }
        }
        mgr.start()
    }

    public func executeCommand(_ action: VisionCommandAction) {
        switch action {
        case .none:
            break
        case .playPause:
            playbackController.togglePlayPause()
        case .stepBack:
            playbackController.step(by: -1)
        case .stepForward:
            playbackController.step(by: 1)
        case .trimStart:
            let editTime = timelineModel.isSmartFilterActive
                ? timelineModel.realTimelineTime(forDisplayedTime: playbackController.accurateCurrentTime)
                : playbackController.accurateCurrentTime
            if let targetTime = timelineModel.trimClipStart(at: editTime) {
                let displayTarget = timelineModel.isSmartFilterActive
                    ? timelineModel.displayedTime(forRealTime: targetTime)
                    : targetTime
                playbackController.setPlayheadForPendingReload(displayTarget)
                commitTimelineEdit(title: "Trim Inizio Clip")
            }
        case .trimEnd:
            let editTime = timelineModel.isSmartFilterActive
                ? timelineModel.realTimelineTime(forDisplayedTime: playbackController.accurateCurrentTime)
                : playbackController.accurateCurrentTime
            if timelineModel.trimClipEnd(at: editTime) {
                commitTimelineEdit(title: "Trim Fine Clip")
            }
        case .splitClip:
            let editTime = timelineModel.isSmartFilterActive
                ? timelineModel.realTimelineTime(forDisplayedTime: playbackController.accurateCurrentTime)
                : playbackController.accurateCurrentTime
            if timelineModel.splitClip(at: editTime) {
                commitTimelineEdit(title: "Spezza Clip")
            }
        case .rippleDelete:
            _ = performBackspaceOrRippleDelete()
        case .closeGaps:
            if timelineModel.closeGapsBetweenSelectedClips() {
                commitTimelineEdit(title: "Chiudi Spazi")
            }
        case .toggleMarker:
            let res = timelineModel.toggleClipMarker(at: playbackController.accurateCurrentTime)
            if res.added > 0 || res.removed > 0 {
                commitTimelineEdit(title: res.added > 0 ? "Aggiungi Marcatore (M)" : "Rimuovi Marcatore (M)", rebuild: false)
            }
        case .clearMarkers:
            let cleared = timelineModel.clearAllClipMarkers(at: playbackController.accurateCurrentTime)
            if cleared > 0 {
                commitTimelineEdit(title: "Rimuovi Marcatori Clip", rebuild: false)
            }
        case .toggleSlowMotion:
            if timelineModel.selectedClipId != nil {
                timelineVC.onToggleSpeedClicked()
            }
        case .toggleLock:
            let res = timelineModel.toggleSelectedClipsLock(at: playbackController.accurateCurrentTime)
            if res.toggledCount > 0 {
                commitTimelineEdit(title: res.isNowLocked ? "Blocca Clip (L)" : "Sblocca Clip (L)", rebuild: false)
            }
        case .toggleLink:
            timelineVC.onLinkToggleClicked()
        case .toggleSnap:
            timelineVC.onMagnetToggleClicked()
        case .toggleSelectionFollowsPlayhead:
            timelineVC.onSelectionFollowsPlayheadClicked()
        case .priority1, .priority2, .priority3, .priorityClear:
            let p: Int? = (action == .priority1 ? 1 : (action == .priority2 ? 2 : (action == .priority3 ? 3 : nil)))
            let res = timelineModel.setClipPriority(p, at: playbackController.accurateCurrentTime)
            if res.updatedCount > 0 {
                commitTimelineEdit(title: action.displayTitle, rebuild: false)
            }
        case .slipLeft:
            if timelineModel.selectedClipId != nil { timelineVC.onSlipLeftClicked() }
        case .slipRight:
            if timelineModel.selectedClipId != nil { timelineVC.onSlipRightClicked() }
        case .spanUp:
            if timelineModel.selectedClipId != nil { timelineVC.onSpanClicked() }
        case .spanDown:
            if let selId = timelineModel.selectedClipId {
                for track in timelineModel.videoTracks {
                    if let clip = track.clips.first(where: { $0.id == selId }), clip.span > 1 {
                        if timelineModel.setClipSpan(clipId: selId, newSpan: clip.span - 1) {
                            commitTimelineEdit(title: "Riduci Span Gabbia")
                        }
                        break
                    }
                }
            }
        case .swapLeft:
            if let selId = timelineModel.selectedClipId, timelineModel.swapAdjacentCages(clipId: selId, direction: -1) {
                commitTimelineEdit(title: "Scambia Gabbia (←)")
            }
        case .swapRight:
            if let selId = timelineModel.selectedClipId, timelineModel.swapAdjacentCages(clipId: selId, direction: +1) {
                commitTimelineEdit(title: "Scambia Gabbia (→)")
            }
        case .moveClipUp:
            if let id = timelineModel.selectedClipId { moveSelectedClipVertically(id: id, isMovingUp: true) }
        case .moveClipDown:
            if let id = timelineModel.selectedClipId { moveSelectedClipVertically(id: id, isMovingUp: false) }
        case .toggleFullScreen:
            playerVC.toggleFullScreen()
        case .undo:
            performUndo()
        case .redo:
            performRedo()
        case .openRhythmicStudio:
            timelineVC.onRhythmicStudioClicked()
        case .wheelModeJog, .wheelModeShuttle, .wheelModeScroll:
            break
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

        // Center Mode Pill ("Montaggio" without icon)
        activeModePill.wantsLayer = true
        activeModePill.layer?.cornerRadius = 6
        activeModePill.layer?.borderWidth = 1.0
        activeModePill.translatesAutoresizingMaskIntoConstraints = false

        activeModeLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        activeModeLabel.lineBreakMode = .byTruncatingTail
        activeModeLabel.translatesAutoresizingMaskIntoConstraints = false

        activeModePill.addSubview(activeModeLabel)
        bottomNavBar.addSubview(activeModePill)

        NSLayoutConstraint.activate([
            activeModeLabel.leadingAnchor.constraint(equalTo: activeModePill.leadingAnchor, constant: 12),
            activeModeLabel.trailingAnchor.constraint(equalTo: activeModePill.trailingAnchor, constant: -12),
            activeModeLabel.centerYAnchor.constraint(equalTo: activeModePill.centerYAnchor)
        ])

        // Left: Project Manager, Red Copy Debug Button & Autosave Status
        projectManagerBtn.image = Lucide.template(.database, size: 16)
        projectManagerBtn.activeTintColor = .systemCyan
        projectManagerBtn.target = self
        projectManagerBtn.action = #selector(openProjectManager)
        projectManagerBtn.translatesAutoresizingMaskIntoConstraints = false
        projectManagerBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        projectManagerBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        copyDebugBtn.wantsLayer = true
        copyDebugBtn.isBordered = false
        copyDebugBtn.title = "Log"
        copyDebugBtn.image = Lucide.image(.fileCode2, size: 11, color: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.72, alpha: 1.0))
        copyDebugBtn.imagePosition = .imageLeading
        copyDebugBtn.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        copyDebugBtn.contentTintColor = NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.75, alpha: 1.0)
        copyDebugBtn.toolTip = "Apri modale Log & Diagnostica con ricerca"
        copyDebugBtn.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.24).cgColor
        copyDebugBtn.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.65).cgColor
        copyDebugBtn.layer?.borderWidth = 1.0
        copyDebugBtn.layer?.cornerRadius = 5
        copyDebugBtn.translatesAutoresizingMaskIntoConstraints = false
        copyDebugBtn.target = self
        copyDebugBtn.action = #selector(onCopyDebugClicked)
        copyDebugBtn.widthAnchor.constraint(equalToConstant: 58).isActive = true
        copyDebugBtn.heightAnchor.constraint(equalToConstant: 22).isActive = true

        autosaveStatusLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        autosaveStatusLabel.textColor = NSColor.systemGreen.withAlphaComponent(0.85)
        autosaveStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView(views: [projectManagerBtn, copyDebugBtn, autosaveStatusLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 10
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        bottomNavBar.addSubview(leftStack)

        // Right: Undo, Redo, History Panel, Keyboard Shortcuts
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

        keyboardBtn.image = Lucide.template(.keyboard, size: 16)
        keyboardBtn.activeTintColor = .white
        keyboardBtn.target = self
        keyboardBtn.action = #selector(onKeyboardShortcutsClicked)
        keyboardBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        keyboardBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let rightStack = NSStackView(views: [navUndoBtn, navRedoBtn, historyBtn, keyboardBtn])
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
        activeModePill.layer?.backgroundColor = NSColor.systemCyan.withAlphaComponent(0.12).cgColor
        activeModePill.layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.32).cgColor
        activeModeLabel.textColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        activeModeLabel.stringValue = "Montaggio"
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
        if timelineModel.isSelectionFollowsPlayhead {
            timelineModel.updateSelectionAtPlayhead(time: playbackController.currentTime)
        }
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

    private var playheadAutosaveWorkItem: DispatchWorkItem?

    private func schedulePlayheadAutosave() {
        playheadAutosaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
        }
        playheadAutosaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    public func saveCurrentStateImmediately() {
        timelineModel.playheadSeconds = max(0.0, CMTimeGetSeconds(playbackController.accurateCurrentTime))
        let doc = ProjectDocumentData(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        ProjectDatabase.shared.saveDocumentImmediately(doc)
        _ = ProjectBackupManager.shared.createBackupIfNeeded(
            document: doc,
            reason: "Chiusura app",
            synchronous: true
        )
    }

    public func didSwitchActiveTimeline(to timeline: TimelineModel) {
        self.timelineModel.playheadSeconds = max(0.0, CMTimeGetSeconds(playbackController.accurateCurrentTime))
        self.timelineModel = timeline
        self.activeSection = .timeline
        let restoredTime = CMTime(seconds: max(0.0, timeline.playheadSeconds), preferredTimescale: 600)
        self.playbackController.setPlayheadForPendingReload(restoredTime)
        self.timelineVC.switchModel(timeline)
        self.mediaPoolVC.timelineModel = timeline
        self.playerVC.updateAspectRatio(formatSize: timeline.format.size)
        self.mediaPoolVC.refreshTimelineGrid()
        self.updateActiveTimelinePill()
        self.rebuildComposition(preserveVisualSnapshot: false)
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
    }

    public func didRenameTimeline(_ timeline: TimelineModel) {
        if self.timelineModel.id == timeline.id {
            self.timelineVC.reloadTimelineUI()
        }
        HistoryManager.shared.record(title: "Rinomina Timeline", project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
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

    public func didDeleteMediaItemsFromPool(_ items: [MediaItem]) {
        let title = items.count > 1 ? "Elimina \(items.count) Media dal Pool" : "Elimina Media dal Pool"
        commitTimelineEdit(title: title)
    }

    public func didDeleteTimelinesFromPool(activeChanged: Bool, deletedCount: Int) {
        let newActive = EditorProject.shared.activeTimeline
        if activeChanged || self.timelineModel.id != newActive.id {
            didSwitchActiveTimeline(to: newActive)
        } else {
            self.mediaPoolVC.refreshTimelineGrid()
        }
        let title = deletedCount > 1 ? "Elimina \(deletedCount) Timeline dal Pool" : "Elimina Timeline dal Pool"
        HistoryManager.shared.record(title: title, project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        updateHistoryNavButtons()
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
    }

    public func didUpdateTimelineFormat(_ timeline: TimelineModel) {
        if timeline.id == timelineModel.id {
            playerVC.updateAspectRatio(formatSize: timeline.format.size)
            timelineVC.reloadTimelineUI()
            rebuildComposition()
        }
        HistoryManager.shared.record(title: "Impostazioni Timeline", project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        updateHistoryNavButtons()
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
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

    private func rebuildComposition(preserveVisualSnapshot: Bool = true) {
        let savedPlayhead = playbackController.currentTime
        rebuildTask?.cancel()

        let playbackModel = timelineModel.isSmartFilterActive ? timelineModel.compactedFilteredModel() : timelineModel
        let totalDur = playbackModel.totalDuration
        if CMTimeCompare(totalDur, .zero) <= 0 {
            playbackController.clear()
            playerVC.updateTimeDisplay()
            return
        }

        rebuildTask = Task {
            do {
                let playerItem = try await CompositionEngine.shared.createPlayerItem(from: playbackModel)
                if Task.isCancelled { return }
                let targetFPS = mediaPoolVC.mediaItems.first?.frameRate ?? 30.0

                var holdCGImage: CGImage? = nil
                if preserveVisualSnapshot, let item = playerItem {
                    let asset = item.asset
                    let vComp = item.videoComposition
                    let clampMax = max(.zero, CMTimeSubtract(totalDur, CMTime(value: 1, timescale: 30)))
                    let queryTime = CMTimeClampToRange(savedPlayhead, range: CMTimeRange(start: .zero, duration: clampMax))
                    holdCGImage = await Task.detached(priority: .userInitiated) {
                        let gen = AVAssetImageGenerator(asset: asset)
                        gen.videoComposition = vComp
                        gen.appliesPreferredTrackTransform = true
                        gen.requestedTimeToleranceBefore = .zero
                        gen.requestedTimeToleranceAfter = .zero
                        gen.maximumSize = CGSize(width: 1280, height: 720)
                        return try? gen.copyCGImage(at: queryTime, actualTime: nil)
                    }.value
                }
                if Task.isCancelled { return }

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if let playerItem = playerItem {
                        self.playbackController.load(
                            item: playerItem,
                            duration: totalDur,
                            targetFPS: Double(targetFPS),
                            seekToTime: savedPlayhead,
                            visualHoldImage: holdCGImage
                        )
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

        let initialBackupDoc = ProjectDocumentData(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        ProjectBackupManager.shared.createBackupIfNeeded(document: initialBackupDoc, reason: "Apertura")
        ProjectBackupManager.shared.startPeriodicBackups { [weak self] in
            guard let self = self else { return nil }
            self.timelineModel.playheadSeconds = max(0.0, CMTimeGetSeconds(self.playbackController.accurateCurrentTime))
            return ProjectDocumentData(project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
        }
    }

    @objc private func onCopyDebugClicked() {
        DebugConsoleViewController.showWindow(relativeTo: view.window) { [weak self] in
            guard let self = self else { return "" }
            return DebugLogger.shared.buildDiagnosticReport(
                activeTimeline: self.timelineModel,
                playerStatus: self.playbackController.isPlaying ? "Playing" : "Paused @ \(self.playbackController.formattedCurrentTime) (fps=\(self.playbackController.fps))",
                mediaPoolCount: self.mediaPoolVC.mediaItems.count
            )
        }
    }

    @objc private func onKeyboardShortcutsClicked() {
        KeyboardShortcutsDialog.showModal(relativeTo: view.window)
    }

    @objc public func openProjectManager() {
        timelineModel.playheadSeconds = max(0.0, CMTimeGetSeconds(playbackController.accurateCurrentTime))
        let currentDoc = ProjectDocumentData(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        ProjectDatabase.shared.saveDocumentImmediately(currentDoc)
        ProjectBackupManager.shared.createBackupIfNeeded(document: currentDoc, reason: "Checkpoint")
        if projectManagerWC == nil {
            projectManagerWC = ProjectManagerWindowController()
            projectManagerWC?.activeLiveDocumentProvider = { [weak self] in
                guard let self = self else { return nil }
                self.timelineModel.playheadSeconds = max(0.0, CMTimeGetSeconds(self.playbackController.accurateCurrentTime))
                return ProjectDocumentData(project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
            }
            projectManagerWC?.onOpenProject = { [weak self] doc in
                guard let self = self else { return }
                if doc.id != EditorProject.shared.projectId {
                    let prevDoc = ProjectDocumentData(project: EditorProject.shared, mediaItems: self.mediaPoolVC.mediaItems)
                    ProjectDatabase.shared.saveDocumentImmediately(prevDoc)
                    ProjectBackupManager.shared.createBackupIfNeeded(document: prevDoc, reason: "Cambio progetto")
                }
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
        let prevDoc = ProjectDocumentData(project: EditorProject.shared, mediaItems: mediaPoolVC.mediaItems)
        ProjectDatabase.shared.saveDocumentImmediately(prevDoc)
        ProjectBackupManager.shared.createBackupIfNeeded(document: prevDoc, reason: "Cambio progetto")
        let newProj = EditorProject()
        newProj.projectName = name
        let blankDoc = ProjectDocumentData(project: newProj, mediaItems: [])
        ProjectDatabase.shared.saveDocumentImmediately(blankDoc)
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
        LUTEngine.shared.applySavedProjectState(enabled: snapshot.lutEnabled, presetRaw: snapshot.lutPreset, customPath: snapshot.lutCustomPath)
        mediaPoolVC.setMediaItems(restoredMedia)
        self.timelineModel = EditorProject.shared.activeTimeline
        let savedPlayhead = CMTime(seconds: max(0.0, self.timelineModel.playheadSeconds), preferredTimescale: 600)
        self.playbackController.setPlayheadForPendingReload(savedPlayhead)
        self.timelineVC.switchModel(self.timelineModel)
        self.mediaPoolVC.timelineModel = self.timelineModel
        self.mediaPoolVC.updateTimelinePopUp()
        self.mediaPoolVC.updateFolderPopUp()
        self.mediaPoolVC.refreshTimelineGrid()
        self.playerVC.updateAspectRatio(formatSize: self.timelineModel.format.size)
        self.updateActiveTimelinePill()
        self.rebuildComposition(preserveVisualSnapshot: false)
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
