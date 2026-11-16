import AppKit
import AVKit
import AVFoundation

public final class PlayerViewController: NSViewController {
    public let playerView = AVPlayerView()
    public private(set) var playbackController: PlaybackController

    private let playPauseButton = IconActionButton(toolTip: "Play / Pausa (Spazio)", isToggleMode: false)
    private let stepBackButton = IconActionButton(toolTip: "Passo indietro 1 frame (←)", isToggleMode: false)
    private let stepForwardButton = IconActionButton(toolTip: "Passo avanti 1 frame (→)", isToggleMode: false)
    private let timecodeLabel = NSTextField(labelWithString: "00:00:00:00")
    private let durationLabel = NSTextField(labelWithString: "/ 00:00:00:00")

    // LUT Hardware Accelerator Controls
    private let lutToggleButton = IconActionButton(toolTip: "LUT (Click: ON/OFF, Pressione lunga: Scegli LUT)")
    private var lutPopover: NSPopover?

    // Proxy Playback Controls
    private let proxyToggleButton = IconActionButton(toolTip: "Riproduzione Proxy")
    private let proxyBadgeLabel = NSTextField(labelWithString: "⚡ PROXY")
    public var onProxyToggled: (() -> Void)?

    // Full Screen Button
    private let fullScreenButton = IconActionButton(toolTip: "Schermo Intero (⌃F)", isToggleMode: false)
    private var fullScreenController: FullScreenPlayerWindowController?

    // Video Canvas Frame Box (with gray workspace around it)
    private let workspaceView = NSView()
    private let videoFrameBox = NSView()
    private var aspectConstraint: NSLayoutConstraint?

    public init(playbackController: PlaybackController) {
        self.playbackController = playbackController
        super.init(nibName: nil, bundle: nil)
    }

    public func switchPlaybackController(_ newController: PlaybackController) {
        self.playbackController = newController
        self.playerView.player = newController.player
        setupControllerBindings()
        updateTimeDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor

        // Workspace View
        workspaceView.translatesAutoresizingMaskIntoConstraints = false
        workspaceView.wantsLayer = true
        workspaceView.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1.0).cgColor
        root.addSubview(workspaceView)

        // Video Frame Box
        videoFrameBox.translatesAutoresizingMaskIntoConstraints = false
        videoFrameBox.wantsLayer = true
        videoFrameBox.layer?.backgroundColor = NSColor.black.cgColor
        videoFrameBox.layer?.borderWidth = 0.0
        videoFrameBox.layer?.shadowColor = NSColor.black.cgColor
        videoFrameBox.layer?.shadowOpacity = 0.6
        videoFrameBox.layer?.shadowOffset = CGSize(width: 0, height: -3)
        videoFrameBox.layer?.shadowRadius = 10
        workspaceView.addSubview(videoFrameBox)

        // Player View inside the frame box
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true
        playerView.player = playbackController.player
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.videoGravity = .resizeAspect

        // Remove Apple Live Text / OCR / Visual Look Up icon (the "cosetto in basso")
        if #available(macOS 13.0, *) {
            playerView.allowsVideoFrameAnalysis = false
        }

        videoFrameBox.addSubview(playerView)

        // Floating Proxy Active Indicator Badge
        proxyBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        proxyBadgeLabel.wantsLayer = true
        proxyBadgeLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.0, green: 0.75, blue: 0.45, alpha: 0.9).cgColor
        proxyBadgeLabel.layer?.cornerRadius = 4
        proxyBadgeLabel.textColor = .white
        proxyBadgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        proxyBadgeLabel.alignment = .center
        proxyBadgeLabel.isHidden = !EditorProject.shared.isProxyPlaybackEnabled
        videoFrameBox.addSubview(proxyBadgeLabel)

        // Transport Bar
        let transportBar = NSView()
        transportBar.translatesAutoresizingMaskIntoConstraints = false
        transportBar.wantsLayer = true
        transportBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(transportBar)

        setupTransportBar(transportBar)

        // Setup Frame Box constraints with Aspect Ratio (default 16:9)
        let initialAspect: CGFloat = 1920.0 / 1080.0
        let aspect = videoFrameBox.widthAnchor.constraint(equalTo: videoFrameBox.heightAnchor, multiplier: initialAspect)
        self.aspectConstraint = aspect

        let wConstraint = videoFrameBox.widthAnchor.constraint(equalTo: workspaceView.widthAnchor, constant: -28)
        wConstraint.priority = .defaultLow
        let hConstraint = videoFrameBox.heightAnchor.constraint(equalTo: workspaceView.heightAnchor, constant: -28)
        hConstraint.priority = .defaultLow

        NSLayoutConstraint.activate([
            workspaceView.topAnchor.constraint(equalTo: root.topAnchor),
            workspaceView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            workspaceView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            workspaceView.bottomAnchor.constraint(equalTo: transportBar.topAnchor),

            videoFrameBox.centerXAnchor.constraint(equalTo: workspaceView.centerXAnchor),
            videoFrameBox.centerYAnchor.constraint(equalTo: workspaceView.centerYAnchor),
            videoFrameBox.leadingAnchor.constraint(greaterThanOrEqualTo: workspaceView.leadingAnchor, constant: 14),
            videoFrameBox.trailingAnchor.constraint(lessThanOrEqualTo: workspaceView.trailingAnchor, constant: -14),
            videoFrameBox.topAnchor.constraint(greaterThanOrEqualTo: workspaceView.topAnchor, constant: 14),
            videoFrameBox.bottomAnchor.constraint(lessThanOrEqualTo: workspaceView.bottomAnchor, constant: -14),
            wConstraint,
            hConstraint,
            aspect,

            playerView.topAnchor.constraint(equalTo: videoFrameBox.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: videoFrameBox.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: videoFrameBox.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: videoFrameBox.bottomAnchor),

            proxyBadgeLabel.topAnchor.constraint(equalTo: videoFrameBox.topAnchor, constant: 10),
            proxyBadgeLabel.leadingAnchor.constraint(equalTo: videoFrameBox.leadingAnchor, constant: 10),
            proxyBadgeLabel.widthAnchor.constraint(equalToConstant: 72),
            proxyBadgeLabel.heightAnchor.constraint(equalToConstant: 20),

            transportBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transportBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transportBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            transportBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        setupControllerBindings()
        setupLUTBindings()

        self.view = root
    }

    private func setupTransportBar(_ bar: NSView) {
        let leftStack = NSStackView()
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.orientation = .horizontal
        leftStack.spacing = 8
        leftStack.alignment = .centerY
        bar.addSubview(leftStack)

        let centerStack = NSStackView()
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerStack.orientation = .horizontal
        centerStack.spacing = 10
        centerStack.alignment = .centerY
        bar.addSubview(centerStack)

        let rightStack = NSStackView()
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.alignment = .centerY
        bar.addSubview(rightStack)

        leftStack.spacing = 4
        centerStack.spacing = 10
        rightStack.spacing = 12

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            leftStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: centerStack.leadingAnchor, constant: -12),

            centerStack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: centerStack.trailingAnchor, constant: 12)
        ])

        // Left Controls: Timecode & Duration
        timecodeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        leftStack.addArrangedSubview(timecodeLabel)

        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        leftStack.addArrangedSubview(durationLabel)

        // Center Controls: Step Back, Play/Pause, Step Forward
        stepBackButton.image = Lucide.template(.stepBack, size: 16)
        stepBackButton.activeTintColor = .white
        stepBackButton.target = self
        stepBackButton.action = #selector(onStepBackClicked)
        stepBackButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        stepBackButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        centerStack.addArrangedSubview(stepBackButton)

        playPauseButton.image = Lucide.template(.play, size: 18)
        playPauseButton.activeTintColor = .white
        playPauseButton.target = self
        playPauseButton.action = #selector(onPlayPauseClicked)
        playPauseButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        centerStack.addArrangedSubview(playPauseButton)

        stepForwardButton.image = Lucide.template(.stepForward, size: 16)
        stepForwardButton.activeTintColor = .white
        stepForwardButton.target = self
        stepForwardButton.action = #selector(onStepForwardClicked)
        stepForwardButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        stepForwardButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        centerStack.addArrangedSubview(stepForwardButton)

        // Right Controls: LUT (Palette), Proxy (Feather), Full Screen (Maximize-2)
        lutToggleButton.image = Lucide.template(.palette, size: 17)
        lutToggleButton.activeTintColor = .systemCyan
        lutToggleButton.target = self
        lutToggleButton.action = #selector(onLUTToggleClicked)
        lutToggleButton.onLongPress = { [weak self] in
            self?.presentLUTSelectorModal()
        }
        lutToggleButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        lutToggleButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        rightStack.addArrangedSubview(lutToggleButton)
        updateLUTButtonState()

        proxyToggleButton.image = Lucide.template(.feather, size: 17)
        proxyToggleButton.activeTintColor = .systemGreen
        proxyToggleButton.target = self
        proxyToggleButton.action = #selector(onProxyToggleClicked)
        proxyToggleButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        proxyToggleButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        rightStack.addArrangedSubview(proxyToggleButton)
        updateProxyUI()

        fullScreenButton.image = Lucide.template(.maximize2, size: 16)
        fullScreenButton.activeTintColor = .white
        fullScreenButton.target = self
        fullScreenButton.action = #selector(toggleFullScreen)
        fullScreenButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        fullScreenButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        rightStack.addArrangedSubview(fullScreenButton)
    }

    private func setupControllerBindings() {
        playbackController.addTimeObserver(self) { [weak self] _ in
            guard let self = self else { return }
            self.timecodeLabel.stringValue = self.playbackController.formattedCurrentTime
        }

        playbackController.addPlayStateObserver(self) { [weak self] isPlaying in
            let icon: LucideIcon = isPlaying ? .pause : .play
            self?.playPauseButton.image = Lucide.template(icon, size: 18)
        }

        let icon: LucideIcon = playbackController.isPlaying ? .pause : .play
        playPauseButton.image = Lucide.template(icon, size: 18)
    }

    private func setupLUTBindings() {
        updateLUTFilter()
        updateLUTButtonState()
        LUTEngine.shared.onLUTStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateLUTFilter()
                self?.updateLUTButtonState()
            }
        }
    }

    private func updateLUTButtonState() {
        lutToggleButton.isToggleActive = LUTEngine.shared.isEnabled
    }

    private func updateLUTFilter() {
        if let filter = LUTEngine.shared.activeFilter() {
            playerView.layer?.filters = [filter]
        } else {
            playerView.layer?.filters = []
        }
    }

    @objc private func onLUTToggleClicked() {
        LUTEngine.shared.isEnabled.toggle()
        updateLUTButtonState()
        updateLUTFilter()
        DebugLogger.shared.log("Filtro LUT Hardware: \(LUTEngine.shared.isEnabled ? "ATTIVO (Accelerato Metal)" : "DISATTIVATO")", level: .info)
    }

    private func presentLUTSelectorModal() {
        if let existing = lutPopover, existing.isShown {
            existing.performClose(nil)
            return
        }
        let vc = LUTSelectorPopoverController(
            onPresetSelected: { [weak self] preset in
                if preset == .custom {
                    self?.lutPopover?.performClose(nil)
                    self?.chooseCustomCubeFile()
                } else {
                    LUTEngine.shared.currentPreset = preset
                    LUTEngine.shared.isEnabled = true
                    self?.updateLUTButtonState()
                    self?.updateLUTFilter()
                    DebugLogger.shared.log("Preset LUT impostato: \(preset.rawValue)", level: .info)
                }
            },
            onToggleEnabled: { [weak self] enabled in
                LUTEngine.shared.isEnabled = enabled
                self?.updateLUTButtonState()
                self?.updateLUTFilter()
            }
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 280, height: 150)
        popover.show(relativeTo: lutToggleButton.bounds, of: lutToggleButton, preferredEdge: .maxY)
        self.lutPopover = popover
    }

    private func chooseCustomCubeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Seleziona un file LUT .cube 3D"
        if panel.runModal() == .OK, let url = panel.url {
            if LUTEngine.shared.loadCustomCubeFile(from: url) {
                LUTEngine.shared.isEnabled = true
                updateLUTButtonState()
                updateLUTFilter()
                DebugLogger.shared.log("LUT .cube caricato con successo: '\(url.lastPathComponent)'", level: .info)
            } else {
                DebugLogger.shared.log("Impossibile caricare LUT .cube: formato non valido.", level: .error)
            }
        }
    }

    @objc public func toggleFullScreen() {
        if let fs = fullScreenController, fs.window?.isVisible == true {
            fs.closeFullScreen()
            fullScreenController = nil
        } else {
            let fs = FullScreenPlayerWindowController(playbackController: playbackController)
            fs.showWindow(nil)
            self.fullScreenController = fs
            DebugLogger.shared.log("Viewer a schermo intero attivato (Control + F)", level: .info)
        }
    }

    public func setAspectRatio(width: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        let newRatio = width / height
        if let current = aspectConstraint {
            videoFrameBox.removeConstraint(current)
        }
        let newConstraint = videoFrameBox.widthAnchor.constraint(equalTo: videoFrameBox.heightAnchor, multiplier: newRatio)
        newConstraint.isActive = true
        self.aspectConstraint = newConstraint
        videoFrameBox.needsLayout = true
        workspaceView.layoutSubtreeIfNeeded()
        DebugLogger.shared.log("Aspect ratio riquadro aggiornato a: \(Int(width))x\(Int(height)) (ratio: \(String(format: "%.2f", newRatio)))", level: .info)
    }

    public func updateAspectRatio(formatSize: CGSize) {
        setAspectRatio(width: formatSize.width, height: formatSize.height)
    }

    public func updateTimeDisplay() {
        timecodeLabel.stringValue = playbackController.formattedCurrentTime
        durationLabel.stringValue = "/ \(playbackController.formattedDuration)"
    }

    @objc private func onPlayPauseClicked() {
        playbackController.togglePlayPause()
    }

    @objc private func onStepBackClicked() {
        playbackController.step(by: -1)
    }

    @objc private func onStepForwardClicked() {
        playbackController.step(by: 1)
    }

    public func updateProxyUI() {
        let isEnabled = EditorProject.shared.isProxyPlaybackEnabled
        proxyToggleButton.isToggleActive = isEnabled
        proxyBadgeLabel.isHidden = !isEnabled
    }

    @objc private func onProxyToggleClicked() {
        EditorProject.shared.isProxyPlaybackEnabled.toggle()
        updateProxyUI()
        DebugLogger.shared.log("Riproduzione Proxy: \(EditorProject.shared.isProxyPlaybackEnabled ? "ATTIVA ⚡ (File leggeri conformi)" : "DISATTIVA (File originali alta ris.)")", level: .info)
        onProxyToggled?()
    }
}

private final class LUTSelectorPopoverController: NSViewController {
    private let onPresetSelected: (LUTPreset) -> Void
    private let onToggleEnabled: (Bool) -> Void
    private let enabledSwitch = NSSwitch()
    private let presetPopUp = VisionDropdownButton()

    init(
        onPresetSelected: @escaping (LUTPreset) -> Void,
        onToggleEnabled: @escaping (Bool) -> Void
    ) {
        self.onPresetSelected = onPresetSelected
        self.onToggleEnabled = onToggleEnabled
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 150))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1.0).cgColor
        self.view = root

        let header = NSTextField(labelWithString: "Seleziona LUT")
        header.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .white
        header.translatesAutoresizingMaskIntoConstraints = false

        enabledSwitch.state = LUTEngine.shared.isEnabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(onSwitchChanged)
        enabledSwitch.controlSize = .small
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false

        let presetLbl = NSTextField(labelWithString: "Profilo colore / 3D .cube")
        presetLbl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        presetLbl.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
        presetLbl.translatesAutoresizingMaskIntoConstraints = false

        for preset in LUTPreset.allCases {
            presetPopUp.addItem(withTitle: preset.rawValue)
        }
        presetPopUp.selectItem(withTitle: LUTEngine.shared.currentPreset.rawValue)
        presetPopUp.target = self
        presetPopUp.action = #selector(onPopUpChanged)
        presetPopUp.translatesAutoresizingMaskIntoConstraints = false

        let loadCubeBtn = FlatButton(title: "Carica file .cube...", target: self, action: #selector(onLoadCubeClicked))
        loadCubeBtn.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(enabledSwitch)
        root.addSubview(presetLbl)
        root.addSubview(presetPopUp)
        root.addSubview(loadCubeBtn)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            enabledSwitch.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            enabledSwitch.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            presetLbl.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            presetLbl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            presetPopUp.topAnchor.constraint(equalTo: presetLbl.bottomAnchor, constant: 6),
            presetPopUp.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            presetPopUp.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            loadCubeBtn.topAnchor.constraint(equalTo: presetPopUp.bottomAnchor, constant: 12),
            loadCubeBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            loadCubeBtn.heightAnchor.constraint(equalToConstant: 24),
            loadCubeBtn.widthAnchor.constraint(equalToConstant: 130)
        ])
    }

    @objc private func onSwitchChanged() {
        onToggleEnabled(enabledSwitch.state == .on)
    }

    @objc private func onPopUpChanged() {
        guard let title = presetPopUp.selectedTitle,
              let preset = LUTPreset.allCases.first(where: { $0.rawValue == title }) else { return }
        onPresetSelected(preset)
        enabledSwitch.state = LUTEngine.shared.isEnabled ? .on : .off
    }

    @objc private func onLoadCubeClicked() {
        onPresetSelected(.custom)
    }
}
