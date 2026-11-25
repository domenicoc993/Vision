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
    public var hasAnyProxyProvider: (() -> Bool)?

    // Full Screen Button
    private let fullScreenButton = IconActionButton(toolTip: "Schermo Intero (⌘F)", isToggleMode: false)
    private var fullScreenController: FullScreenPlayerWindowController?

    // Video Canvas Frame Box (with gray workspace around it) + Zoom/Pan support
    private let workspaceView = NSView()
    private let videoFrameBox = NSView()
    private let zoomHostView = NSView()
    private let freezeFrameOverlay = NSView()
    private let interactionOverlay = ViewerZoomInteractionView()
    private let zoomButton = FlatButton(title: "Adatta ▾")
    private var zoomMenu: VisionMenu?
    private var currentAspectRatio: CGFloat = 1920.0 / 1080.0

    // Dual-Frame Slip Preview Overlay (Tab + Drag) — nello spazio di un singolo frame normale, zero resize/flicker
    private let slipPreviewContainer = NSView()
    private let slipHeaderLabel = NSTextField(labelWithString: "")
    private let slipInCanvasView = NSView()
    private let slipOutCanvasView = NSView()
    private let slipInTimeLabel = NSTextField(labelWithString: "IN")
    private let slipOutTimeLabel = NSTextField(labelWithString: "OUT")
    private var slipGenerator: AVAssetImageGenerator?
    private var slipGeneratorURL: URL?
    private var slipRequestToken: Int = 0
    private var isSlipDecodeInFlight: Bool = false
    private var pendingSlipRequest: (url: URL, inSec: Double, outSec: Double, fps: Double)?

    // Source Clip Preview Overlay (click su una clip nel Media Pool)
    public private(set) var isSourcePreviewActive: Bool = false
    public private(set) var sourcePreviewMediaId: UUID? = nil
    private let sourcePreviewContainer = NSView()
    private let sourcePlayerView = AVPlayerView()
    private let sourceAudioPlaceholder = NSTextField(labelWithString: "♫ Audio Clip")
    private let sourceTitlePill = NSView()
    private let sourceTitleLabel = NSTextField(labelWithString: "")
    private let sourceCloseButton = FlatButton(title: "✕")
    private let sourceScrubBar = SourceClipScrubBar()
    private var sourcePlayer: AVPlayer?
    private var sourceTimeObserver: Any?
    private var sourceEndObserver: Any?
    private var isScrubbingSourceBar: Bool = false

    public private(set) var isZoomFitMode: Bool = true
    public private(set) var zoomScale: CGFloat = 1.0
    private var zoomPanOffset: CGPoint = .zero

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
        workspaceView.layer?.masksToBounds = true
        root.addSubview(workspaceView)

        // Video Frame Box (frame managed dynamically by viewer zoom & pan so the canvas itself resizes and moves)
        videoFrameBox.translatesAutoresizingMaskIntoConstraints = true
        videoFrameBox.autoresizingMask = []
        videoFrameBox.wantsLayer = true
        videoFrameBox.layer?.backgroundColor = NSColor.black.cgColor
        videoFrameBox.layer?.masksToBounds = true
        videoFrameBox.layer?.borderWidth = 0.0
        videoFrameBox.layer?.shadowColor = NSColor.black.cgColor
        videoFrameBox.layer?.shadowOpacity = 0.6
        videoFrameBox.layer?.shadowOffset = CGSize(width: 0, height: -3)
        videoFrameBox.layer?.shadowRadius = 10
        workspaceView.addSubview(videoFrameBox)

        // Host filling videoFrameBox
        zoomHostView.wantsLayer = true
        zoomHostView.translatesAutoresizingMaskIntoConstraints = false
        videoFrameBox.addSubview(zoomHostView)

        // Player View inside zoomHostView
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

        zoomHostView.addSubview(playerView)

        // Still-frame layer overlay holds trimmed frame across AVPlayerItem reloads without affecting Auto Layout size
        freezeFrameOverlay.translatesAutoresizingMaskIntoConstraints = false
        freezeFrameOverlay.wantsLayer = true
        freezeFrameOverlay.layer?.backgroundColor = NSColor.black.cgColor
        freezeFrameOverlay.layer?.contentsGravity = .resizeAspect
        freezeFrameOverlay.layer?.masksToBounds = true
        freezeFrameOverlay.isHidden = true
        zoomHostView.addSubview(freezeFrameOverlay)

        // Interactive overlay across entire workspace for mouse scroll zoom & canvas grab pan
        interactionOverlay.translatesAutoresizingMaskIntoConstraints = false
        interactionOverlay.onScrollZoom = { [weak self] deltaY, pointInView, isPrecise in
            self?.handleScrollZoom(deltaY: deltaY, anchorPoint: pointInView, isPrecise: isPrecise)
        }
        interactionOverlay.onPanDelta = { [weak self] dx, dy in
            self?.handlePanDelta(dx: dx, dy: dy)
        }
        interactionOverlay.onDoubleClickReset = { [weak self] in
            self?.setViewerZoomFit()
        }
        workspaceView.addSubview(interactionOverlay)

        setupSlipPreviewOverlay()
        videoFrameBox.addSubview(slipPreviewContainer)

        setupSourcePreviewOverlay()
        workspaceView.addSubview(sourcePreviewContainer)
        workspaceView.addSubview(sourceTitlePill)
        workspaceView.addSubview(sourceCloseButton)
        workspaceView.addSubview(sourceScrubBar)

        // Floating Proxy Active Indicator Badge (top-right inside workspace)
        proxyBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        proxyBadgeLabel.wantsLayer = true
        proxyBadgeLabel.layer?.backgroundColor = NSColor(calibratedRed: 0.0, green: 0.75, blue: 0.45, alpha: 0.9).cgColor
        proxyBadgeLabel.layer?.cornerRadius = 4
        proxyBadgeLabel.textColor = .white
        proxyBadgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        proxyBadgeLabel.alignment = .center
        proxyBadgeLabel.isHidden = true
        workspaceView.addSubview(proxyBadgeLabel)

        // Top-left Viewer Zoom Dropdown Button inside workspaceView
        zoomButton.translatesAutoresizingMaskIntoConstraints = false
        zoomButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        zoomButton.toolTip = "Zoom Viewer (Scroll: Zoom, Trascina: Sposta, Z / Doppio click: Adatta)"
        zoomButton.target = self
        zoomButton.action = #selector(onZoomDropdownClicked)
        workspaceView.addSubview(zoomButton)

        // Transport Bar
        let transportBar = NSView()
        transportBar.translatesAutoresizingMaskIntoConstraints = false
        transportBar.wantsLayer = true
        transportBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(transportBar)

        setupTransportBar(transportBar)

        NSLayoutConstraint.activate([
            workspaceView.topAnchor.constraint(equalTo: root.topAnchor),
            workspaceView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            workspaceView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            workspaceView.bottomAnchor.constraint(equalTo: transportBar.topAnchor),

            zoomHostView.topAnchor.constraint(equalTo: videoFrameBox.topAnchor),
            zoomHostView.leadingAnchor.constraint(equalTo: videoFrameBox.leadingAnchor),
            zoomHostView.trailingAnchor.constraint(equalTo: videoFrameBox.trailingAnchor),
            zoomHostView.bottomAnchor.constraint(equalTo: videoFrameBox.bottomAnchor),

            playerView.topAnchor.constraint(equalTo: zoomHostView.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: zoomHostView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: zoomHostView.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: zoomHostView.bottomAnchor),

            freezeFrameOverlay.topAnchor.constraint(equalTo: zoomHostView.topAnchor),
            freezeFrameOverlay.leadingAnchor.constraint(equalTo: zoomHostView.leadingAnchor),
            freezeFrameOverlay.trailingAnchor.constraint(equalTo: zoomHostView.trailingAnchor),
            freezeFrameOverlay.bottomAnchor.constraint(equalTo: zoomHostView.bottomAnchor),

            interactionOverlay.topAnchor.constraint(equalTo: workspaceView.topAnchor),
            interactionOverlay.leadingAnchor.constraint(equalTo: workspaceView.leadingAnchor),
            interactionOverlay.trailingAnchor.constraint(equalTo: workspaceView.trailingAnchor),
            interactionOverlay.bottomAnchor.constraint(equalTo: workspaceView.bottomAnchor),

            slipPreviewContainer.topAnchor.constraint(equalTo: videoFrameBox.topAnchor),
            slipPreviewContainer.leadingAnchor.constraint(equalTo: videoFrameBox.leadingAnchor),
            slipPreviewContainer.trailingAnchor.constraint(equalTo: videoFrameBox.trailingAnchor),
            slipPreviewContainer.bottomAnchor.constraint(equalTo: videoFrameBox.bottomAnchor),

            sourcePreviewContainer.topAnchor.constraint(equalTo: workspaceView.topAnchor),
            sourcePreviewContainer.leadingAnchor.constraint(equalTo: workspaceView.leadingAnchor),
            sourcePreviewContainer.trailingAnchor.constraint(equalTo: workspaceView.trailingAnchor),
            sourcePreviewContainer.bottomAnchor.constraint(equalTo: sourceScrubBar.topAnchor, constant: -4),

            sourceTitlePill.topAnchor.constraint(equalTo: workspaceView.topAnchor, constant: 10),
            sourceTitlePill.leadingAnchor.constraint(equalTo: workspaceView.leadingAnchor, constant: 10),
            sourceTitlePill.trailingAnchor.constraint(lessThanOrEqualTo: sourceCloseButton.leadingAnchor, constant: -10),
            sourceTitlePill.heightAnchor.constraint(equalToConstant: 24),

            sourceCloseButton.topAnchor.constraint(equalTo: workspaceView.topAnchor, constant: 10),
            sourceCloseButton.trailingAnchor.constraint(equalTo: workspaceView.trailingAnchor, constant: -10),
            sourceCloseButton.widthAnchor.constraint(equalToConstant: 26),
            sourceCloseButton.heightAnchor.constraint(equalToConstant: 24),

            sourceScrubBar.leadingAnchor.constraint(equalTo: workspaceView.leadingAnchor, constant: 10),
            sourceScrubBar.trailingAnchor.constraint(equalTo: workspaceView.trailingAnchor, constant: -10),
            sourceScrubBar.bottomAnchor.constraint(equalTo: workspaceView.bottomAnchor, constant: -8),
            sourceScrubBar.heightAnchor.constraint(equalToConstant: 30),

            proxyBadgeLabel.topAnchor.constraint(equalTo: workspaceView.topAnchor, constant: 10),
            proxyBadgeLabel.trailingAnchor.constraint(equalTo: workspaceView.trailingAnchor, constant: -10),
            proxyBadgeLabel.widthAnchor.constraint(equalToConstant: 72),
            proxyBadgeLabel.heightAnchor.constraint(equalToConstant: 20),

            zoomButton.topAnchor.constraint(equalTo: workspaceView.topAnchor, constant: 10),
            zoomButton.leadingAnchor.constraint(equalTo: workspaceView.leadingAnchor, constant: 10),
            zoomButton.heightAnchor.constraint(equalToConstant: 24),
            zoomButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),

            transportBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transportBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transportBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            transportBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        setupControllerBindings()
        setupLUTBindings()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MediaItemProxyGenerated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateProxyUI()
            }
        }

        self.view = root
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        applyZoomHostLayout()
    }

    // MARK: - Viewer Zoom & Pan Controls

    public func setViewerZoomFit() {
        isZoomFitMode = true
        zoomScale = 1.0
        zoomPanOffset = .zero
        interactionOverlay.isPanEnabled = false
        updateZoomButtonTitle()
        applyZoomHostLayout()
    }

    public func setViewerZoom(scale: CGFloat) {
        let clamped = max(0.5, min(6.0, scale))
        isZoomFitMode = false
        zoomScale = clamped
        interactionOverlay.isPanEnabled = true
        updateZoomButtonTitle()
        applyZoomHostLayout()
    }

    private func handleScrollZoom(deltaY: CGFloat, anchorPoint: CGPoint, isPrecise: Bool) {
        guard abs(deltaY) > 0.001 else { return }
        let oldScale = isZoomFitMode ? 1.0 : zoomScale
        let factor = isPrecise ? exp(deltaY * 0.009) : exp(deltaY * 0.08)
        let newScale = max(0.5, min(6.0, oldScale * factor))

        let wsSize = workspaceView.bounds.size
        if wsSize.width > 0, wsSize.height > 0, oldScale > 0 {
            let ratio = newScale / oldScale
            let dx = anchorPoint.x - wsSize.width * 0.5 - zoomPanOffset.x
            let dy = anchorPoint.y - wsSize.height * 0.5 - zoomPanOffset.y
            zoomPanOffset.x += dx * (1.0 - ratio)
            zoomPanOffset.y += dy * (1.0 - ratio)
        }

        isZoomFitMode = false
        zoomScale = newScale
        interactionOverlay.isPanEnabled = true
        updateZoomButtonTitle()
        applyZoomHostLayout()
    }

    private func handlePanDelta(dx: CGFloat, dy: CGFloat) {
        guard !isZoomFitMode else { return }
        zoomPanOffset.x += dx
        zoomPanOffset.y += dy
        applyZoomHostLayout()
    }

    private func updateZoomButtonTitle() {
        if isZoomFitMode {
            zoomButton.title = "Adatta ▾"
            zoomButton.isAccentActive = false
        } else {
            let pct = Int((zoomScale * 100.0).rounded())
            zoomButton.title = "\(pct)% ▾"
            zoomButton.isAccentActive = (abs(zoomScale - 1.0) > 0.01)
        }
    }

    private func applyZoomHostLayout() {
        let wsSize = workspaceView.bounds.size
        guard wsSize.width > 0, wsSize.height > 0 else { return }

        let availW = max(1.0, wsSize.width - 28.0)
        let availH = max(1.0, wsSize.height - 28.0)
        let ratio = max(0.1, currentAspectRatio)
        let fitW: CGFloat
        let fitH: CGFloat
        if (availW / availH) > ratio {
            fitH = availH
            fitW = fitH * ratio
        } else {
            fitW = availW
            fitH = fitW / ratio
        }

        let s = isZoomFitMode ? 1.0 : zoomScale
        let w = fitW * s
        let h = fitH * s

        if isZoomFitMode {
            zoomPanOffset = .zero
        } else {
            let maxPanX = abs(w - wsSize.width) * 0.5
            let maxPanY = abs(h - wsSize.height) * 0.5
            zoomPanOffset.x = max(-maxPanX, min(maxPanX, zoomPanOffset.x))
            zoomPanOffset.y = max(-maxPanY, min(maxPanY, zoomPanOffset.y))
        }

        let x = (wsSize.width - w) * 0.5 + zoomPanOffset.x
        let y = (wsSize.height - h) * 0.5 + zoomPanOffset.y
        videoFrameBox.frame = CGRect(x: x, y: y, width: w, height: h)
        videoFrameBox.layoutSubtreeIfNeeded()
    }

    @objc private func onZoomDropdownClicked() {
        let presets: [(title: String, scale: CGFloat)] = [
            ("50%", 0.5),
            ("100%", 1.0),
            ("150%", 1.5),
            ("200%", 2.0),
            ("300%", 3.0),
            ("400%", 4.0)
        ]

        var items: [VisionMenuItem] = [
            .action(
                title: "Adatta",
                icon: .maximize2,
                isSelected: isZoomFitMode
            ) { [weak self] in
                self?.setViewerZoomFit()
            },
            .separator
        ]

        for preset in presets {
            let isSelected = !isZoomFitMode && abs(zoomScale - preset.scale) < 0.03
            items.append(.action(
                title: preset.title,
                isSelected: isSelected
            ) { [weak self] in
                self?.setViewerZoom(scale: preset.scale)
            })
        }

        let menu = VisionMenu(items: items)
        self.zoomMenu = menu
        menu.show(below: zoomButton, minWidth: 135)
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
            let formatted = self.playbackController.formattedCurrentTime
            if self.timecodeLabel.stringValue != formatted {
                self.timecodeLabel.stringValue = formatted
            }
        }

        playbackController.addPlayStateObserver(self) { [weak self] isPlaying in
            let icon: LucideIcon = isPlaying ? .pause : .play
            self?.playPauseButton.image = Lucide.template(icon, size: 18)
        }

        let icon: LucideIcon = playbackController.isPlaying ? .pause : .play
        playPauseButton.image = Lucide.template(icon, size: 18)

        playbackController.addWillReplaceItemObserver(self) { [weak self] cgImage in
            guard let self = self else { return }
            if let cg = cgImage {
                self.freezeFrameOverlay.layer?.contents = cg
                self.freezeFrameOverlay.isHidden = false
            } else {
                // Keep previous held frame if already showing; otherwise hold black until seek finishes so frame 0 never flashes
                self.freezeFrameOverlay.isHidden = false
            }
        }
        playbackController.addReadyFrameObserver(self) { [weak self] in
            self?.freezeFrameOverlay.isHidden = true
            self?.freezeFrameOverlay.layer?.contents = nil
        }
    }

    private func setupLUTBindings() {
        updateLUTFilter()
        updateLUTButtonState()
        NotificationCenter.default.addObserver(
            forName: LUTEngine.stateChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateLUTFilter()
            self?.updateLUTButtonState()
        }
    }

    private func updateLUTButtonState() {
        lutToggleButton.isToggleActive = LUTEngine.shared.isEnabled
    }

    private static let lutCIContext: CIContext = {
        // Must match VisionLUTCompositor (CompositionEngine) working space so Media Pool Source Preview & Timeline Player render identical LUT colors
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private static let renderColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private func applyLUTToPlayerItemIfNeeded(_ playerItem: AVPlayerItem, hasVideo: Bool) {
        guard hasVideo, let lutParams = LUTEngine.shared.currentLUTParameters() else {
            playerItem.videoComposition = nil
            return
        }
        let vComp = AVVideoComposition(asset: playerItem.asset) { request in
            let src = request.sourceImage
            let filtered = LUTEngine.apply(lutParams, to: src.clampedToExtent()).cropped(to: src.extent)
            request.finish(with: filtered, context: Self.lutCIContext)
        }
        playerItem.videoComposition = vComp
    }

    private func applyLUTToCGImageIfNeeded(_ cgImage: CGImage) -> CGImage {
        guard let lutParams = LUTEngine.shared.currentLUTParameters() else { return cgImage }
        let ci = CIImage(cgImage: cgImage)
        let filtered = LUTEngine.apply(lutParams, to: ci.clampedToExtent()).cropped(to: ci.extent)
        return Self.lutCIContext.createCGImage(filtered, from: ci.extent, format: .RGBA8, colorSpace: Self.renderColorSpace) ?? cgImage
    }

    private func updateLUTFilter() {
        // Timeline rendering executes cleanly in CompositionEngine GPU VisionLUTCompositor (never layer?.filters on AVPlayerView).
        if !(playerView.layer?.filters?.isEmpty ?? true) {
            playerView.layer?.filters = []
        }
        if !(freezeFrameOverlay.layer?.filters?.isEmpty ?? true) {
            freezeFrameOverlay.layer?.filters = []
        }
        if isSourcePreviewActive, let srcItem = sourcePlayer?.currentItem {
            applyLUTToPlayerItemIfNeeded(srcItem, hasVideo: !sourcePlayerView.isHidden)
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
        popover.contentSize = NSSize(width: 300, height: 155)
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
        self.currentAspectRatio = newRatio
        applyZoomHostLayout()
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
        hideSourcePreview()
        playbackController.togglePlayPause()
    }

    @objc private func onStepBackClicked() {
        hideSourcePreview()
        playbackController.step(by: -1)
    }

    @objc private func onStepForwardClicked() {
        hideSourcePreview()
        playbackController.step(by: 1)
    }

    public func updateProxyUI() {
        let hasAnyProxy = hasAnyProxyProvider?() ?? false
        proxyToggleButton.isHidden = !hasAnyProxy
        let isEnabled = hasAnyProxy && EditorProject.shared.isProxyPlaybackEnabled
        proxyToggleButton.isToggleActive = EditorProject.shared.isProxyPlaybackEnabled
        proxyBadgeLabel.isHidden = !isEnabled || isSourcePreviewActive
    }

    private func setupSlipPreviewOverlay() {
        slipPreviewContainer.translatesAutoresizingMaskIntoConstraints = false
        slipPreviewContainer.wantsLayer = true
        slipPreviewContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.98).cgColor
        slipPreviewContainer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        slipPreviewContainer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        slipPreviewContainer.isHidden = true

        slipHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        slipHeaderLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        slipHeaderLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        slipHeaderLabel.alignment = .center
        slipHeaderLabel.lineBreakMode = .byTruncatingMiddle
        slipHeaderLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        func makeFramePanel(
            canvasView: NSView,
            badgeLabel: NSTextField,
            accentColor: NSColor
        ) -> NSView {
            let box = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.black.cgColor
            box.layer?.cornerRadius = 4
            box.layer?.borderWidth = 1.2
            box.layer?.borderColor = accentColor.withAlphaComponent(0.75).cgColor
            box.layer?.masksToBounds = true
            box.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            box.setContentCompressionResistancePriority(.init(1), for: .vertical)

            canvasView.translatesAutoresizingMaskIntoConstraints = false
            canvasView.wantsLayer = true
            canvasView.layer?.backgroundColor = NSColor.black.cgColor
            canvasView.layer?.contentsGravity = .resizeAspect
            canvasView.layer?.masksToBounds = true
            canvasView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            canvasView.setContentCompressionResistancePriority(.init(1), for: .vertical)
            box.addSubview(canvasView)

            let pill = NSView()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.86).cgColor
            pill.layer?.cornerRadius = 3
            pill.layer?.borderWidth = 0.8
            pill.layer?.borderColor = accentColor.withAlphaComponent(0.65).cgColor
            box.addSubview(pill)

            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
            badgeLabel.textColor = accentColor
            pill.addSubview(badgeLabel)

            NSLayoutConstraint.activate([
                canvasView.topAnchor.constraint(equalTo: box.topAnchor),
                canvasView.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                canvasView.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                canvasView.bottomAnchor.constraint(equalTo: box.bottomAnchor),

                pill.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
                pill.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
                badgeLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
                badgeLabel.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
                badgeLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
                badgeLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5)
            ])
            return box
        }

        let inPanel = makeFramePanel(
            canvasView: slipInCanvasView,
            badgeLabel: slipInTimeLabel,
            accentColor: NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.55, alpha: 1.0)
        )
        let outPanel = makeFramePanel(
            canvasView: slipOutCanvasView,
            badgeLabel: slipOutTimeLabel,
            accentColor: NSColor(calibratedRed: 1.0, green: 0.65, blue: 0.20, alpha: 1.0)
        )

        let stack = NSStackView(views: [inPanel, outPanel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        stack.setContentCompressionResistancePriority(.init(1), for: .vertical)

        slipPreviewContainer.addSubview(slipHeaderLabel)
        slipPreviewContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            slipHeaderLabel.topAnchor.constraint(equalTo: slipPreviewContainer.topAnchor, constant: 4),
            slipHeaderLabel.leadingAnchor.constraint(equalTo: slipPreviewContainer.leadingAnchor, constant: 8),
            slipHeaderLabel.trailingAnchor.constraint(equalTo: slipPreviewContainer.trailingAnchor, constant: -8),

            stack.topAnchor.constraint(equalTo: slipHeaderLabel.bottomAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: slipPreviewContainer.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: slipPreviewContainer.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: slipPreviewContainer.bottomAnchor, constant: -4)
        ])
    }

    private func formatSlipTimecode(_ seconds: Double, fps: Double) -> String {
        let safeSec = max(0.0, seconds)
        let safeFps = max(1.0, fps)
        let totalFrames = Int((safeSec * safeFps).rounded())
        let fpsInt = max(1, Int(safeFps.rounded()))
        let ff = totalFrames % fpsInt
        let totalSecs = totalFrames / fpsInt
        let ss = totalSecs % 60
        let mm = (totalSecs / 60) % 60
        let hh = totalSecs / 3600
        if hh > 0 {
            return String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)
        }
        return String(format: "%02d:%02d:%02d", mm, ss, ff)
    }

    public func showSlipDualPreview(url: URL, inSeconds: Double, outSeconds: Double, fps: Double, clipName: String) {
        if isSourcePreviewActive {
            hideSourcePreview()
        }
        let wasHidden = slipPreviewContainer.isHidden
        let urlChanged = slipGeneratorURL != url
        if urlChanged || wasHidden {
            slipGenerator?.cancelAllCGImageGeneration()
            isSlipDecodeInFlight = false
            pendingSlipRequest = nil
            if urlChanged {
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 960, height: 540)
                let tol = CMTime(seconds: 0.04, preferredTimescale: 600)
                gen.requestedTimeToleranceBefore = tol
                gen.requestedTimeToleranceAfter = tol
                slipGenerator = gen
                slipGeneratorURL = url
                slipInCanvasView.layer?.contents = nil
                slipOutCanvasView.layer?.contents = nil
            }
        }

        slipPreviewContainer.isHidden = false
        let inTC = formatSlipTimecode(inSeconds, fps: fps)
        let outTC = formatSlipTimecode(outSeconds, fps: fps)
        slipHeaderLabel.stringValue = "SLIP — \(clipName)"
        slipInTimeLabel.stringValue = "IN \(inTC)"
        slipOutTimeLabel.stringValue = "OUT \(outTC)"

        if isSlipDecodeInFlight {
            pendingSlipRequest = (url: url, inSec: inSeconds, outSec: outSeconds, fps: fps)
            return
        }
        startSlipDecode(url: url, inSeconds: inSeconds, outSeconds: outSeconds, fps: fps)
    }

    private func startSlipDecode(url: URL, inSeconds: Double, outSeconds: Double, fps: Double) {
        guard let gen = slipGenerator, slipGeneratorURL == url, !slipPreviewContainer.isHidden else { return }
        isSlipDecodeInFlight = true
        slipRequestToken &+= 1
        let token = slipRequestToken

        let frameStep = 0.5 / max(1.0, fps)
        let reqInSec = max(0.0, inSeconds)
        let reqOutSec = max(reqInSec, outSeconds - frameStep)
        let inCM = CMTime(seconds: reqInSec, preferredTimescale: 600)
        let outCM = CMTime(seconds: reqOutSec, preferredTimescale: 600)

        var remaining = 2
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: inCM), NSValue(time: outCM)]) { [weak self] requestedTime, cgImage, _, result, _ in
            let processedCG: CGImage? = (result == .succeeded) ? cgImage.map { self?.applyLUTToCGImageIfNeeded($0) ?? $0 } : nil
            let isStart = abs(CMTimeGetSeconds(requestedTime) - reqInSec) <= abs(CMTimeGetSeconds(requestedTime) - reqOutSec)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.slipRequestToken == token, !self.slipPreviewContainer.isHidden, let cg = processedCG {
                    if isStart {
                        self.slipInCanvasView.layer?.contents = cg
                    } else {
                        self.slipOutCanvasView.layer?.contents = cg
                    }
                }
                remaining -= 1
                if remaining <= 0, self.slipRequestToken == token {
                    self.isSlipDecodeInFlight = false
                    if let next = self.pendingSlipRequest {
                        self.pendingSlipRequest = nil
                        if !self.slipPreviewContainer.isHidden {
                            self.startSlipDecode(url: next.url, inSeconds: next.inSec, outSeconds: next.outSec, fps: next.fps)
                        }
                    }
                }
            }
        }
    }

    public func hideSlipDualPreview() {
        slipRequestToken &+= 1
        isSlipDecodeInFlight = false
        pendingSlipRequest = nil
        slipGenerator?.cancelAllCGImageGeneration()
        slipPreviewContainer.isHidden = true
    }

    @objc private func onProxyToggleClicked() {
        EditorProject.shared.isProxyPlaybackEnabled.toggle()
        updateProxyUI()
        DebugLogger.shared.log("Riproduzione Proxy: \(EditorProject.shared.isProxyPlaybackEnabled ? "ATTIVA ⚡ (File leggeri conformi)" : "DISATTIVA (File originali alta ris.)")", level: .info)
        onProxyToggled?()
    }

    // MARK: - Media Pool Source Clip Preview

    private func setupSourcePreviewOverlay() {
        sourcePreviewContainer.translatesAutoresizingMaskIntoConstraints = false
        sourcePreviewContainer.wantsLayer = true
        sourcePreviewContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1.0).cgColor
        sourcePreviewContainer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        sourcePreviewContainer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        sourcePreviewContainer.isHidden = true

        sourcePlayerView.translatesAutoresizingMaskIntoConstraints = false
        sourcePlayerView.wantsLayer = true
        sourcePlayerView.controlsStyle = .none
        sourcePlayerView.showsFullScreenToggleButton = false
        sourcePlayerView.videoGravity = .resizeAspect
        if #available(macOS 13.0, *) {
            sourcePlayerView.allowsVideoFrameAnalysis = false
        }
        sourcePreviewContainer.addSubview(sourcePlayerView)

        sourceAudioPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        sourceAudioPlaceholder.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        sourceAudioPlaceholder.textColor = .systemGreen
        sourceAudioPlaceholder.alignment = .center
        sourceAudioPlaceholder.isHidden = true
        sourcePreviewContainer.addSubview(sourceAudioPlaceholder)

        sourceTitlePill.translatesAutoresizingMaskIntoConstraints = false
        sourceTitlePill.wantsLayer = true
        sourceTitlePill.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.88).cgColor
        sourceTitlePill.layer?.cornerRadius = 5
        sourceTitlePill.layer?.borderWidth = 1.0
        sourceTitlePill.layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.45).cgColor
        sourceTitlePill.isHidden = true

        sourceTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceTitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        sourceTitleLabel.textColor = .white
        sourceTitleLabel.lineBreakMode = .byTruncatingMiddle
        sourceTitlePill.addSubview(sourceTitleLabel)

        sourceCloseButton.translatesAutoresizingMaskIntoConstraints = false
        sourceCloseButton.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        sourceCloseButton.toolTip = "Chiudi anteprima clip"
        sourceCloseButton.target = self
        sourceCloseButton.action = #selector(onCloseSourcePreviewClicked)
        sourceCloseButton.isHidden = true

        sourceScrubBar.translatesAutoresizingMaskIntoConstraints = false
        sourceScrubBar.isHidden = true
        sourceScrubBar.onTogglePlayPause = { [weak self] in
            self?.toggleSourcePlayPause()
        }
        sourceScrubBar.onScrubSeconds = { [weak self] sec, isStart in
            guard let self = self, let player = self.sourcePlayer else { return }
            if isStart {
                self.isScrubbingSourceBar = true
                player.pause()
                self.sourceScrubBar.setPlayingState(false)
            }
            let target = CMTime(seconds: max(0.0, sec), preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        sourceScrubBar.onScrubEnded = { [weak self] in
            self?.isScrubbingSourceBar = false
        }

        NSLayoutConstraint.activate([
            sourcePlayerView.topAnchor.constraint(equalTo: sourcePreviewContainer.topAnchor),
            sourcePlayerView.leadingAnchor.constraint(equalTo: sourcePreviewContainer.leadingAnchor),
            sourcePlayerView.trailingAnchor.constraint(equalTo: sourcePreviewContainer.trailingAnchor),
            sourcePlayerView.bottomAnchor.constraint(equalTo: sourcePreviewContainer.bottomAnchor),

            sourceAudioPlaceholder.centerXAnchor.constraint(equalTo: sourcePreviewContainer.centerXAnchor),
            sourceAudioPlaceholder.centerYAnchor.constraint(equalTo: sourcePreviewContainer.centerYAnchor),

            sourceTitleLabel.leadingAnchor.constraint(equalTo: sourceTitlePill.leadingAnchor, constant: 8),
            sourceTitleLabel.trailingAnchor.constraint(equalTo: sourceTitlePill.trailingAnchor, constant: -8),
            sourceTitleLabel.centerYAnchor.constraint(equalTo: sourceTitlePill.centerYAnchor)
        ])
    }

    @objc private func onCloseSourcePreviewClicked() {
        hideSourcePreview()
    }

    public func showSourcePreview(item: MediaItem, usedRangesInTimeline: [(start: Double, end: Double)]) {
        if !slipPreviewContainer.isHidden {
            hideSlipDualPreview()
        }
        cleanupSourcePlayerObservers()

        let durSec = max(0.05, CMTimeGetSeconds(item.duration))
        let playerItem = AVPlayerItem(url: item.effectiveURL)
        applyLUTToPlayerItemIfNeeded(playerItem, hasVideo: item.hasVideo)
        let player = AVPlayer(playerItem: playerItem)
        sourcePlayer = player
        sourcePlayerView.player = player

        sourcePreviewMediaId = item.id
        isSourcePreviewActive = true
        sourcePreviewContainer.isHidden = false
        sourceTitlePill.isHidden = false
        sourceCloseButton.isHidden = false
        sourceScrubBar.isHidden = false
        sourceAudioPlaceholder.isHidden = item.hasVideo
        sourcePlayerView.isHidden = !item.hasVideo
        zoomButton.isHidden = true
        proxyBadgeLabel.isHidden = true

        sourceTitleLabel.stringValue = "Sorgente: \(item.name)"
        sourceScrubBar.configure(duration: durSec, current: 0.0, usedRanges: usedRangesInTimeline, isPlaying: false)

        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)
        sourceTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, self.isSourcePreviewActive, !self.isScrubbingSourceBar else { return }
            let sec = max(0.0, CMTimeGetSeconds(time))
            self.sourceScrubBar.updateCurrentTime(sec)
        }
        sourceEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let p = self.sourcePlayer else { return }
            p.pause()
            p.seek(to: .zero)
            self.sourceScrubBar.setPlayingState(false)
            self.sourceScrubBar.updateCurrentTime(0.0)
        }
    }

    public func updateSourceUsedRanges(_ ranges: [(start: Double, end: Double)], forMediaId mediaId: UUID) {
        guard isSourcePreviewActive, sourcePreviewMediaId == mediaId else { return }
        sourceScrubBar.updateUsedRanges(ranges)
    }

    public func toggleSourcePlayPause() {
        guard isSourcePreviewActive, let player = sourcePlayer else { return }
        if player.rate > 0.01 {
            player.pause()
            sourceScrubBar.setPlayingState(false)
        } else {
            player.play()
            sourceScrubBar.setPlayingState(true)
        }
    }

    public func hideSourcePreview() {
        guard isSourcePreviewActive else { return }
        cleanupSourcePlayerObservers()
        sourcePlayer?.pause()
        sourcePlayer?.replaceCurrentItem(with: nil)
        sourcePlayerView.player = nil
        sourcePlayer = nil
        isSourcePreviewActive = false
        sourcePreviewMediaId = nil
        isScrubbingSourceBar = false
        sourcePreviewContainer.isHidden = true
        sourceTitlePill.isHidden = true
        sourceCloseButton.isHidden = true
        sourceScrubBar.isHidden = true
        zoomButton.isHidden = false
        updateProxyUI()
    }

    private func cleanupSourcePlayerObservers() {
        if let obs = sourceTimeObserver, let player = sourcePlayer {
            player.removeTimeObserver(obs)
        }
        sourceTimeObserver = nil
        if let endObs = sourceEndObserver {
            NotificationCenter.default.removeObserver(endObs)
        }
        sourceEndObserver = nil
    }
}

private final class SourceClipScrubBar: NSView {
    var onTogglePlayPause: (() -> Void)?
    var onScrubSeconds: ((Double, Bool) -> Void)?
    var onScrubEnded: (() -> Void)?

    private var totalDuration: Double = 1.0
    private var currentSeconds: Double = 0.0
    private var usedRanges: [(start: Double, end: Double)] = []
    private var isPlaying: Bool = false
    private var isDraggingTrack: Bool = false

    private let playButton = IconActionButton(toolTip: "Riproduci / Pausa clip originale (Spazio)", isToggleMode: false)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.90).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor(calibratedWhite: 0.24, alpha: 0.9).cgColor

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.image = Lucide.template(.play, size: 13)
        playButton.activeTintColor = .white
        playButton.target = self
        playButton.action = #selector(onPlayClicked)
        addSubview(playButton)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        timeLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        timeLabel.alignment = .right
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 20),
            playButton.heightAnchor.constraint(equalToConstant: 20),

            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 82)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func onPlayClicked() {
        onTogglePlayPause?()
    }

    func configure(duration: Double, current: Double, usedRanges: [(start: Double, end: Double)], isPlaying: Bool) {
        self.totalDuration = max(0.05, duration)
        self.currentSeconds = max(0.0, min(self.totalDuration, current))
        self.usedRanges = usedRanges
        setPlayingState(isPlaying)
        updateTimeLabel()
        needsDisplay = true
    }

    func updateCurrentTime(_ sec: Double) {
        currentSeconds = max(0.0, min(totalDuration, sec))
        updateTimeLabel()
        needsDisplay = true
    }

    func updateUsedRanges(_ ranges: [(start: Double, end: Double)]) {
        self.usedRanges = ranges
        needsDisplay = true
    }

    func setPlayingState(_ playing: Bool) {
        isPlaying = playing
        playButton.image = Lucide.template(playing ? .pause : .play, size: 13)
    }

    private func formatMMSS(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded(.down)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func updateTimeLabel() {
        timeLabel.stringValue = "\(formatMMSS(currentSeconds)) / \(formatMMSS(totalDuration))"
    }

    private var trackRect: CGRect {
        let startX: CGFloat = 32
        let endX = max(startX + 40, bounds.width - 96)
        return CGRect(x: startX, y: (bounds.height - 6) * 0.5, width: endX - startX, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let tr = trackRect
        guard tr.width > 8 else { return }

        // Traccia base dell'intera clip originale
        ctx.setFillColor(NSColor(calibratedWhite: 0.24, alpha: 1.0).cgColor)
        ctx.addPath(CGPath(roundedRect: tr, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()

        // Evidenzia le parti attualmente presenti nella timeline attiva
        for seg in usedRanges {
            let s = max(0.0, min(totalDuration, seg.start))
            let e = max(s, min(totalDuration, seg.end))
            guard e > s + 0.005 else { continue }
            let x1 = tr.minX + CGFloat(s / totalDuration) * tr.width
            let x2 = tr.minX + CGFloat(e / totalDuration) * tr.width
            let w = max(3.0, x2 - x1)
            let hlRect = CGRect(x: x1, y: tr.minY - 1, width: min(tr.maxX - x1, w), height: tr.height + 2)
            ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.92).cgColor)
            ctx.addPath(CGPath(roundedRect: hlRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
        }

        // Posizione corrente (testina sorgente)
        let frac = max(0.0, min(1.0, currentSeconds / totalDuration))
        let px = tr.minX + CGFloat(frac) * tr.width
        ctx.setFillColor(NSColor.white.cgColor)
        let cursorRect = CGRect(x: px - 1.5, y: tr.minY - 4, width: 3, height: tr.height + 8)
        ctx.addPath(CGPath(roundedRect: cursorRect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.fillPath()
    }

    private func secondsAtPoint(_ pt: CGPoint) -> Double {
        let tr = trackRect
        guard tr.width > 1 else { return 0 }
        let norm = max(0.0, min(1.0, Double((pt.x - tr.minX) / tr.width)))
        return norm * totalDuration
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let hitZone = trackRect.insetBy(dx: -4, dy: -8)
        guard hitZone.contains(pt) else {
            super.mouseDown(with: event)
            return
        }
        isDraggingTrack = true
        let sec = secondsAtPoint(pt)
        updateCurrentTime(sec)
        onScrubSeconds?(sec, true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingTrack else {
            super.mouseDragged(with: event)
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        let sec = secondsAtPoint(pt)
        updateCurrentTime(sec)
        onScrubSeconds?(sec, false)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingTrack {
            isDraggingTrack = false
            onScrubEnded?()
        } else {
            super.mouseUp(with: event)
        }
    }
}

private final class ViewerZoomInteractionView: NSView {
    var onScrollZoom: ((CGFloat, CGPoint, Bool) -> Void)?
    var onPanDelta: ((CGFloat, CGFloat) -> Void)?
    var onDoubleClickReset: (() -> Void)?
    var isPanEnabled: Bool = false {
        didSet {
            if isPanEnabled != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    private var isDraggingPan = false
    private var lastDragScreenPoint: CGPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isPanEnabled {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let dy = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        if abs(dy) > 0.001 {
            onScrollZoom?(dy, local, event.hasPreciseScrollingDeltas)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClickReset?()
            return
        }
        guard isPanEnabled else {
            super.mouseDown(with: event)
            return
        }
        isDraggingPan = true
        lastDragScreenPoint = NSEvent.mouseLocation
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingPan else {
            super.mouseDragged(with: event)
            return
        }
        let cur = NSEvent.mouseLocation
        let dx = cur.x - lastDragScreenPoint.x
        let dy = cur.y - lastDragScreenPoint.y
        lastDragScreenPoint = cur
        onPanDelta?(dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingPan {
            isDraggingPan = false
            if isPanEnabled {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }
        super.mouseUp(with: event)
    }
}

private final class LUTSelectorPopoverController: NSViewController {
    private let onPresetSelected: (LUTPreset) -> Void
    private let onToggleEnabled: (Bool) -> Void
    private let enabledSwitch = NSSwitch()
    private let presetPopUp = VisionDropdownButton()
    private let removeCustomBtn = FlatButton(title: "Rimuovi")

    private enum DropdownEntry {
        case preset(LUTPreset)
        case customLink(SavedCustomLUT)
    }
    private var dropdownEntries: [DropdownEntry] = []

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 155))
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

        presetPopUp.target = self
        presetPopUp.action = #selector(onPopUpChanged)
        presetPopUp.translatesAutoresizingMaskIntoConstraints = false
        reloadPresetPopUp()

        removeCustomBtn.target = self
        removeCustomBtn.action = #selector(onRemoveCustomClicked)
        removeCustomBtn.translatesAutoresizingMaskIntoConstraints = false

        let loadCubeBtn = FlatButton(title: "Carica file .cube...", target: self, action: #selector(onLoadCubeClicked))
        loadCubeBtn.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(enabledSwitch)
        root.addSubview(presetLbl)
        root.addSubview(presetPopUp)
        root.addSubview(removeCustomBtn)
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

            removeCustomBtn.topAnchor.constraint(equalTo: presetPopUp.bottomAnchor, constant: 12),
            removeCustomBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            removeCustomBtn.heightAnchor.constraint(equalToConstant: 24),
            removeCustomBtn.widthAnchor.constraint(equalToConstant: 82),

            loadCubeBtn.topAnchor.constraint(equalTo: presetPopUp.bottomAnchor, constant: 12),
            loadCubeBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            loadCubeBtn.heightAnchor.constraint(equalToConstant: 24),
            loadCubeBtn.widthAnchor.constraint(equalToConstant: 136)
        ])
    }

    private func reloadPresetPopUp() {
        presetPopUp.removeAllItems()
        dropdownEntries.removeAll()

        for preset in LUTPreset.allCases where preset != .custom {
            presetPopUp.addItem(withTitle: preset.rawValue)
            dropdownEntries.append(.preset(preset))
        }
        for custom in LUTEngine.shared.customLUTs {
            presetPopUp.addItem(withTitle: "★ \(custom.name)")
            dropdownEntries.append(.customLink(custom))
        }

        let engine = LUTEngine.shared
        var selectedIdx = 0
        if engine.currentPreset == .custom, let activePath = engine.activeCustomLUTPath,
           let cIdx = dropdownEntries.firstIndex(where: {
               if case .customLink(let item) = $0 { return item.path == activePath }
               return false
           }) {
            selectedIdx = cIdx
        } else if let pIdx = dropdownEntries.firstIndex(where: {
            if case .preset(let p) = $0 { return p == engine.currentPreset }
            return false
        }) {
            selectedIdx = pIdx
        }

        if !dropdownEntries.isEmpty {
            presetPopUp.selectItem(at: selectedIdx)
        }
        removeCustomBtn.isHidden = (engine.currentPreset != .custom || engine.activeCustomLUTPath == nil)
    }

    @objc private func onSwitchChanged() {
        onToggleEnabled(enabledSwitch.state == .on)
    }

    @objc private func onPopUpChanged() {
        let idx = presetPopUp.selectedIndex
        guard idx >= 0 && idx < dropdownEntries.count else { return }
        switch dropdownEntries[idx] {
        case .preset(let preset):
            onPresetSelected(preset)
        case .customLink(let saved):
            if LUTEngine.shared.selectCustomLUT(path: saved.path) {
                LUTEngine.shared.isEnabled = true
            } else {
                DebugLogger.shared.log("File LUT .cube non trovato: '\(saved.name)'. Rimosso dalla lista.", level: .warning)
                reloadPresetPopUp()
            }
        }
        enabledSwitch.state = LUTEngine.shared.isEnabled ? .on : .off
        removeCustomBtn.isHidden = (LUTEngine.shared.currentPreset != .custom || LUTEngine.shared.activeCustomLUTPath == nil)
    }

    @objc private func onRemoveCustomClicked() {
        guard let activePath = LUTEngine.shared.activeCustomLUTPath else { return }
        LUTEngine.shared.removeCustomLUT(path: activePath)
        reloadPresetPopUp()
        enabledSwitch.state = LUTEngine.shared.isEnabled ? .on : .off
    }

    @objc private func onLoadCubeClicked() {
        onPresetSelected(.custom)
    }
}
