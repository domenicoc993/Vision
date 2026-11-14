import AppKit
import AVKit
import AVFoundation

public final class FullScreenPlayerWindowController: NSWindowController {
    private let playbackController: PlaybackController
    private let playerView = AVPlayerView()

    private let playPauseButton = IconActionButton(toolTip: "Play / Pausa (Spazio)", isToggleMode: false)
    private let stopButton = IconActionButton(toolTip: "Stop (Torna all'inizio)", isToggleMode: false)
    private let lutButton = IconActionButton(toolTip: "LUT (ON/OFF)")
    private let muteButton = IconActionButton(toolTip: "Audio / Muto")
    private let exitButton = IconActionButton(toolTip: "Esci da Schermo Intero (Esc / ⌃F)", isToggleMode: false)
    private let timeSlider = NSSlider()
    private let timecodeLabel = NSTextField(labelWithString: "00:00:00:00")
    private let durationLabel = NSTextField(labelWithString: "00:00:00:00")
    private let floatingBar = NSView()

    private var isMuted: Bool = false
    private var isScrubbing: Bool = false

    public init(playbackController: PlaybackController) {
        self.playbackController = playbackController

        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = NSWindow(
            contentRect: screenRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating

        super.init(window: window)

        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor

        // 1. Player View filling entire screen with layer hosting enabled for Metal LUT filters
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true
        playerView.player = playbackController.player
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.videoGravity = .resizeAspect
        if #available(macOS 13.0, *) {
            playerView.allowsVideoFrameAnalysis = false
        }
        contentView.addSubview(playerView)

        // 2. Floating Bottom Transport Bar
        floatingBar.translatesAutoresizingMaskIntoConstraints = false
        floatingBar.wantsLayer = true
        floatingBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        floatingBar.layer?.cornerRadius = 14
        floatingBar.layer?.borderColor = NSColor(calibratedWhite: 0.35, alpha: 0.8).cgColor
        floatingBar.layer?.borderWidth = 1.0
        contentView.addSubview(floatingBar)

        setupFloatingBarControls()

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            floatingBar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            floatingBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32),
            floatingBar.widthAnchor.constraint(equalToConstant: 780),
            floatingBar.heightAnchor.constraint(equalToConstant: 54)
        ])

        setupBindings()
    }

    private func setupFloatingBarControls() {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        floatingBar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: floatingBar.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: floatingBar.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: floatingBar.centerYAnchor)
        ])

        // Play/Pause icon
        let initialPlayIcon: LucideIcon = playbackController.isPlaying ? .pause : .play
        playPauseButton.image = Lucide.template(initialPlayIcon, size: 18)
        playPauseButton.activeTintColor = .white
        playPauseButton.target = self
        playPauseButton.action = #selector(onPlayPauseClicked)
        playPauseButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.addArrangedSubview(playPauseButton)

        // Stop icon
        stopButton.image = Lucide.template(.square, size: 15)
        stopButton.activeTintColor = .white
        stopButton.target = self
        stopButton.action = #selector(onStopClicked)
        stopButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        stopButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(stopButton)

        // Current Timecode
        timecodeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        timecodeLabel.textColor = .white
        stack.addArrangedSubview(timecodeLabel)

        // Time Slider / Barra del tempo
        timeSlider.minValue = 0
        timeSlider.maxValue = max(1.0, CMTimeGetSeconds(playbackController.duration))
        timeSlider.doubleValue = CMTimeGetSeconds(playbackController.currentTime)
        timeSlider.target = self
        timeSlider.action = #selector(onSliderScrubbed)
        timeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(timeSlider)

        // Duration Label
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.stringValue = playbackController.formattedDuration
        stack.addArrangedSubview(durationLabel)

        // Hardware Metal LUT Toggle
        lutButton.image = Lucide.template(.palette, size: 17)
        lutButton.activeTintColor = .systemCyan
        lutButton.isToggleActive = LUTEngine.shared.isEnabled
        lutButton.target = self
        lutButton.action = #selector(onLUTToggleClicked)
        lutButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        lutButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(lutButton)

        // Mute / Unmute audio icon
        isMuted = playbackController.player.isMuted
        muteButton.image = Lucide.template(isMuted ? .volumeX : .volume2, size: 17)
        muteButton.activeTintColor = .systemRed
        muteButton.inactiveTintColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        muteButton.isToggleActive = isMuted
        muteButton.target = self
        muteButton.action = #selector(onMuteClicked)
        muteButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        muteButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(muteButton)

        // Exit Fullscreen icon
        exitButton.image = Lucide.template(.minimize2, size: 16)
        exitButton.activeTintColor = .white
        exitButton.target = self
        exitButton.action = #selector(onExitClicked)
        exitButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        exitButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(exitButton)
    }

    private func setupBindings() {
        playbackController.addTimeObserver(self) { [weak self] time in
            guard let self = self, !self.isScrubbing else { return }
            self.timecodeLabel.stringValue = self.playbackController.formattedCurrentTime
            self.timeSlider.doubleValue = CMTimeGetSeconds(time)
        }

        playbackController.addPlayStateObserver(self) { [weak self] isPlaying in
            let icon: LucideIcon = isPlaying ? .pause : .play
            self?.playPauseButton.image = Lucide.template(icon, size: 18)
        }

        updateLUTFilter()
        LUTEngine.shared.onLUTStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.updateLUTFilter()
            }
        }
    }

    private func updateLUTFilter() {
        if let filter = LUTEngine.shared.activeFilter() {
            playerView.layer?.filters = [filter]
        } else {
            playerView.layer?.filters = []
        }
        lutButton.isToggleActive = LUTEngine.shared.isEnabled
    }

    @objc private func onLUTToggleClicked() {
        LUTEngine.shared.isEnabled.toggle()
        updateLUTFilter()
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        timeSlider.maxValue = max(1.0, CMTimeGetSeconds(playbackController.duration))
        timecodeLabel.stringValue = playbackController.formattedCurrentTime
        durationLabel.stringValue = playbackController.formattedDuration
        updateLUTFilter()

        // Handle escape / spacebar in fullscreen
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.isKeyWindow == true else { return event }

            if event.keyCode == 53 { // ESC
                self.closeFullScreen()
                return nil
            }
            if event.keyCode == 49 { // Spacebar
                self.playbackController.togglePlayPause()
                return nil
            }
            if event.modifierFlags.contains(.control) && event.keyCode == 3 { // Control + F
                self.closeFullScreen()
                return nil
            }
            return event
        }
    }

    @objc private func onPlayPauseClicked() {
        playbackController.togglePlayPause()
    }

    @objc private func onStopClicked() {
        playbackController.pause()
        playbackController.seek(to: .zero, frameAccurate: true)
    }

    @objc private func onSliderScrubbed() {
        isScrubbing = true
        let targetSec = timeSlider.doubleValue
        playbackController.seek(to: CMTime(seconds: targetSec, preferredTimescale: 600), frameAccurate: true)
        isScrubbing = false
    }

    @objc private func onMuteClicked() {
        isMuted.toggle()
        playbackController.player.isMuted = isMuted
        muteButton.image = Lucide.template(isMuted ? .volumeX : .volume2, size: 17)
        muteButton.isToggleActive = isMuted
    }

    @objc private func onExitClicked() {
        closeFullScreen()
    }

    public func closeFullScreen() {
        window?.orderOut(nil)
    }
}
