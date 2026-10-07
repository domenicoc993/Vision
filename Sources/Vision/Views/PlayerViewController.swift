import AppKit
import AVKit
import AVFoundation

public final class PlayerViewController: NSViewController {
    public let playerView = AVPlayerView()
    private let playbackController: PlaybackController

    private let playPauseButton = NSButton()
    private let stepBackButton = NSButton()
    private let stepForwardButton = NSButton()
    private let timecodeLabel = NSTextField(labelWithString: "00:00:00:00")
    private let durationLabel = NSTextField(labelWithString: "/ 00:00:00:00")
    private let statusLabel = NSTextField(labelWithString: "")

    // LUT Hardware Accelerator Controls
    private let lutToggleButton = NSButton()
    private let lutPresetPopUp = NSPopUpButton()

    // Full Screen Button
    private let fullScreenButton = NSButton()
    private var fullScreenController: FullScreenPlayerWindowController?

    // Video Canvas Frame Box (with gray workspace around it)
    private let workspaceView = NSView()
    private let videoFrameBox = NSView()
    private var aspectConstraint: NSLayoutConstraint?

    public init(playbackController: PlaybackController) {
        self.playbackController = playbackController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.17, alpha: 1.0).cgColor

        // Workspace View
        workspaceView.translatesAutoresizingMaskIntoConstraints = false
        workspaceView.wantsLayer = true
        workspaceView.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
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

        // Transport Bar
        let transportBar = NSView()
        transportBar.translatesAutoresizingMaskIntoConstraints = false
        transportBar.wantsLayer = true
        transportBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
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

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            leftStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            centerStack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])

        // Left Controls: Hardware-accelerated LUT Filter
        lutToggleButton.title = "🎨 LUT: OFF"
        lutToggleButton.bezelStyle = .rounded
        lutToggleButton.target = self
        lutToggleButton.action = #selector(onLUTToggleClicked)
        leftStack.addArrangedSubview(lutToggleButton)

        lutPresetPopUp.bezelStyle = .rounded
        lutPresetPopUp.target = self
        lutPresetPopUp.action = #selector(onLUTPresetChanged)
        for preset in LUTPreset.allCases {
            lutPresetPopUp.addItem(withTitle: preset.rawValue)
        }
        lutPresetPopUp.selectItem(withTitle: LUTEngine.shared.currentPreset.rawValue)
        leftStack.addArrangedSubview(lutPresetPopUp)

        // Center Controls: Step Back, Play/Pause, Step Forward, Timecode
        stepBackButton.image = NSImage(systemSymbolName: "backward.frame", accessibilityDescription: "Step Back")
        stepBackButton.bezelStyle = .texturedRounded
        stepBackButton.target = self
        stepBackButton.action = #selector(onStepBackClicked)
        centerStack.addArrangedSubview(stepBackButton)

        playPauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playPauseButton.bezelStyle = .texturedRounded
        playPauseButton.target = self
        playPauseButton.action = #selector(onPlayPauseClicked)
        centerStack.addArrangedSubview(playPauseButton)

        stepForwardButton.image = NSImage(systemSymbolName: "forward.frame", accessibilityDescription: "Step Forward")
        stepForwardButton.bezelStyle = .texturedRounded
        stepForwardButton.target = self
        stepForwardButton.action = #selector(onStepForwardClicked)
        centerStack.addArrangedSubview(stepForwardButton)

        timecodeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        centerStack.addArrangedSubview(timecodeLabel)

        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        centerStack.addArrangedSubview(durationLabel)

        // Right Controls: Status & Full-Screen Button (Control + F)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        rightStack.addArrangedSubview(statusLabel)

        fullScreenButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Schermo Intero (⌃F)")
        fullScreenButton.bezelStyle = .texturedRounded
        fullScreenButton.toolTip = "Schermo Intero (Control + F)"
        fullScreenButton.target = self
        fullScreenButton.action = #selector(toggleFullScreen)
        rightStack.addArrangedSubview(fullScreenButton)
    }

    private func setupControllerBindings() {
        playbackController.onTimeChanged = { [weak self] time in
            DispatchQueue.main.async {
                self?.timecodeLabel.stringValue = self?.playbackController.formattedCurrentTime ?? "00:00:00:00"
            }
        }

        playbackController.onPlayStateChanged = { [weak self] isPlaying in
            DispatchQueue.main.async {
                let iconName = isPlaying ? "pause.fill" : "play.fill"
                self?.playPauseButton.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Play/Pause")
            }
        }

        playbackController.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = status
            }
        }
    }

    private func setupLUTBindings() {
        updateLUTFilter()
        LUTEngine.shared.onLUTStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateLUTFilter()
                self?.updateLUTButtonTitle()
            }
        }
    }

    private func updateLUTButtonTitle() {
        lutToggleButton.title = LUTEngine.shared.isEnabled ? "🎨 LUT: ON" : "🎨 LUT: OFF"
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
        updateLUTButtonTitle()
        updateLUTFilter()
        DebugLogger.shared.log("Filtro LUT Hardware: \(LUTEngine.shared.isEnabled ? "ATTIVO (Accelerato Metal)" : "DISATTIVATO")", level: .info)
    }

    @objc private func onLUTPresetChanged() {
        guard let title = lutPresetPopUp.selectedItem?.title else { return }
        if title == LUTPreset.custom.rawValue {
            // Open .cube file panel
            let panel = NSOpenPanel()
            panel.allowedContentTypes = []
            panel.allowsOtherFileTypes = true
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.message = "Seleziona un file LUT .cube 3D"
            if panel.runModal() == .OK, let url = panel.url {
                if LUTEngine.shared.loadCustomCubeFile(from: url) {
                    LUTEngine.shared.isEnabled = true
                    DebugLogger.shared.log("LUT .cube caricato con successo: '\(url.lastPathComponent)'", level: .info)
                } else {
                    DebugLogger.shared.log("Impossibile caricare LUT .cube: formato non valido.", level: .error)
                }
            }
        } else if let preset = LUTPreset.allCases.first(where: { $0.rawValue == title }) {
            LUTEngine.shared.currentPreset = preset
            DebugLogger.shared.log("Preset LUT impostato: \(preset.rawValue)", level: .info)
        }
        updateLUTFilter()
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
}
