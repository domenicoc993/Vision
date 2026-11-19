import AppKit
import Foundation
import CoreMedia
import AVFoundation

/// Modal studio separato per Beat Finder (su clip audio da context menu) e Auto-Fill (dalla toolbar).
public final class BeatAnalysisDialog: NSViewController, NSWindowDelegate {
    public enum StudioMode {
        case beatFinder(targetClip: TimelineClip?)
        case autoFillOnly
    }

    private let model: TimelineModel
    private let studioMode: StudioMode
    private let currentPlayheadSeconds: Double
    private let targetAudioClip: TimelineClip?
    private weak var modalPanel: NSPanel?
    private var onModified: (() -> Void)?

    private var analysisResult: BeatAnalysisResult?
    private var isAnalyzing: Bool = false
    private var lastFeedbackStatus: (text: String, color: NSColor)?

    private let trackLabel = NSTextField(labelWithString: "")
    private let analyzeBtn = FlatButton(title: "Analizza Audio")
    private let statusIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let bpmResultLabel = NSTextField(labelWithString: "")
    private let modePopUp = VisionDropdownButton()
    private let sensitivityLabel = NSTextField(labelWithString: "Sensibilità picchi:")
    private let sensitivitySlider = NSSlider(value: 0.45, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let sensitivityValueLabel = NSTextField(labelWithString: "Bilanciato (45%)")
    private let cagesPreviewLabel = NSTextField(labelWithString: "")

    private let clearBeatBtn = FlatButton(title: "Pulisci Beat")
    private let clearAllBtn = FlatButton(title: "Pulisci Tutto")
    private let applyBeatsBtn = FlatButton(title: "Segna Beat")

    private let selectionPopUp = VisionDropdownButton()
    private let orderModePopUp = VisionDropdownButton()
    private let startModeSegmented = NSSegmentedControl(
        labels: ["Dalla prima gabbia", "Dalla testina in poi"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let autoFillStatusLabel = NSTextField(labelWithString: "")
    private let autoFillForecastLabel = NSTextField(labelWithString: "")
    private let autoFillBtn = FlatButton(title: "Esegui Auto-Fill su V1")

    /// Apre Beat Finder su una specifica traccia audio già su timeline (dal menu contestuale).
    public static func showBeatFinderModal(
        for model: TimelineModel,
        audioClip: TimelineClip,
        relativeTo parentWindow: NSWindow? = nil,
        onModified: (() -> Void)? = nil
    ) {
        presentPanel(
            model: model,
            mode: .beatFinder(targetClip: audioClip),
            playheadSeconds: 0.0,
            title: audioClip.mediaItem.name,
            size: NSSize(width: 510, height: 266),
            relativeTo: parentWindow,
            onModified: onModified
        )
    }

    /// Apre Auto-Fill Ritmico (rimane accessibile dalla toolbar timeline / Speed Editor).
    public static func showAutoFillModal(
        for model: TimelineModel,
        playheadSeconds: Double = 0.0,
        relativeTo parentWindow: NSWindow? = nil,
        onModified: (() -> Void)? = nil
    ) {
        presentPanel(
            model: model,
            mode: .autoFillOnly,
            playheadSeconds: playheadSeconds,
            title: "Auto-Fill Ritmico",
            size: NSSize(width: 525, height: 345),
            relativeTo: parentWindow,
            onModified: onModified
        )
    }

    public static func showModal(
        for model: TimelineModel,
        relativeTo parentWindow: NSWindow? = nil,
        onModified: (() -> Void)? = nil
    ) {
        showAutoFillModal(for: model, playheadSeconds: model.playheadSeconds, relativeTo: parentWindow, onModified: onModified)
    }

    private static var activeBeatFinderPanel: NSPanel?
    private static var activeBeatFinderController: BeatAnalysisDialog?

    private static func presentPanel(
        model: TimelineModel,
        mode: StudioMode,
        playheadSeconds: Double,
        title: String,
        size: NSSize,
        relativeTo parentWindow: NSWindow?,
        onModified: (() -> Void)?
    ) {
        let isModalSession: Bool
        switch mode {
        case .beatFinder:
            isModalSession = false
            activeBeatFinderPanel?.close()
            activeBeatFinderPanel = nil
            activeBeatFinderController = nil
        case .autoFillOnly:
            isModalSession = true
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false

        if let parent = parentWindow {
            let pf = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: pf.midX - panel.frame.width / 2,
                y: pf.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }

        let controller = BeatAnalysisDialog(
            model: model,
            studioMode: mode,
            playheadSeconds: playheadSeconds,
            panel: panel,
            isModalSession: isModalSession,
            onModified: onModified
        )
        panel.delegate = controller
        panel.contentViewController = controller

        if isModalSession {
            NSApp.runModal(for: panel)
            panel.orderOut(nil)
        } else {
            activeBeatFinderPanel = panel
            activeBeatFinderController = controller
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public static func makeBeatFinderController(
        for model: TimelineModel,
        audioClip: TimelineClip,
        onModified: (() -> Void)? = nil
    ) -> BeatAnalysisDialog {
        BeatAnalysisDialog(
            model: model,
            studioMode: .beatFinder(targetClip: audioClip),
            playheadSeconds: 0.0,
            panel: nil,
            isModalSession: false,
            onModified: onModified
        )
    }

    private let isModalSession: Bool

    private init(model: TimelineModel, studioMode: StudioMode, playheadSeconds: Double, panel: NSPanel?, isModalSession: Bool, onModified: (() -> Void)?) {
        self.model = model
        self.studioMode = studioMode
        self.currentPlayheadSeconds = max(0.0, playheadSeconds)
        self.modalPanel = panel
        self.isModalSession = isModalSession
        self.onModified = onModified

        switch studioMode {
        case .beatFinder(let explicitClip):
            self.targetAudioClip = explicitClip
        case .autoFillOnly:
            self.targetAudioClip = nil
        }

        super.init(nibName: nil, bundle: nil)

        if let target = self.targetAudioClip, let saved = target.mediaItem.beatAnalysis {
            self.analysisResult = saved.toBeatAnalysisResult(
                audioURL: target.mediaItem.effectiveURL,
                sourceStart: CMTimeGetSeconds(target.sourceIn),
                sourceDuration: CMTimeGetSeconds(target.sourceDuration)
            )
            self.lastFeedbackStatus = ("Analisi pronta", .systemCyan)
        }
    }

    public required init?(coder: NSCoder) { fatalError() }

    private var currentTargetClip: TimelineClip? {
        guard let clip = targetAudioClip else { return nil }
        return model.audioClip(withId: clip.id) ?? clip
    }

    public override func loadView() {
        let initialSize: NSSize
        switch studioMode {
        case .beatFinder: initialSize = NSSize(width: 510, height: 266)
        case .autoFillOnly: initialSize = NSSize(width: 525, height: 345)
        }
        let root = NSView(frame: NSRect(origin: .zero, size: initialSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor
        self.view = root

        // Footer
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(footer)

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerDivider)

        let closeBtn = FlatButton(title: "Chiudi", target: self, action: #selector(onCloseClicked))
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(closeBtn)

        var constraints: [NSLayoutConstraint] = [
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 44),

            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            closeBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 74),
            closeBtn.heightAnchor.constraint(equalToConstant: 26)
        ]

        let headerDivider = NSBox()
        if case .autoFillOnly = studioMode {
            let header = NSView()
            header.translatesAutoresizingMaskIntoConstraints = false
            header.wantsLayer = true
            header.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
            root.addSubview(header)

            let headerIcon = NSImageView()
            headerIcon.translatesAutoresizingMaskIntoConstraints = false
            headerIcon.image = Lucide.image(.sparkles, size: 18, color: .systemCyan)
            header.addSubview(headerIcon)

            let titleLabel = NSTextField(labelWithString: "Auto-Fill Ritmico da Selezione")
            titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            titleLabel.textColor = .white
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(titleLabel)

            headerDivider.boxType = .separator
            headerDivider.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(headerDivider)

            constraints.append(contentsOf: [
                header.topAnchor.constraint(equalTo: root.topAnchor),
                header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                header.heightAnchor.constraint(equalToConstant: 46),

                headerIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
                headerIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                headerIcon.widthAnchor.constraint(equalToConstant: 18),
                headerIcon.heightAnchor.constraint(equalToConstant: 18),

                titleLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 8),
                titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

                headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
                headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor)
            ])
        }

        switch studioMode {
        case .beatFinder:
            let beatCard = makeCard()
            root.addSubview(beatCard)

            trackLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            trackLabel.textColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
            trackLabel.lineBreakMode = .byTruncatingMiddle
            trackLabel.translatesAutoresizingMaskIntoConstraints = false
            beatCard.addSubview(trackLabel)

            analyzeBtn.translatesAutoresizingMaskIntoConstraints = false
            analyzeBtn.isAccentActive = true
            analyzeBtn.target = self
            analyzeBtn.action = #selector(onAnalyzeClicked)
            beatCard.addSubview(analyzeBtn)

            statusIndicator.style = .spinning
            statusIndicator.controlSize = .small
            statusIndicator.isHidden = true
            statusIndicator.translatesAutoresizingMaskIntoConstraints = false
            beatCard.addSubview(statusIndicator)

            statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            statusLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
            statusLabel.lineBreakMode = .byTruncatingTail
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            beatCard.addSubview(statusLabel)

            bpmResultLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            bpmResultLabel.textColor = .white
            bpmResultLabel.translatesAutoresizingMaskIntoConstraints = false
            beatCard.addSubview(bpmResultLabel)

            let modeLabel = NSTextField(labelWithString: "Ritmo di taglio:")
            modeLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            modeLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            modeLabel.translatesAutoresizingMaskIntoConstraints = false
            beatCard.addSubview(modeLabel)

            modePopUp.translatesAutoresizingMaskIntoConstraints = false
            modePopUp.target = self
            modePopUp.action = #selector(onModeChanged)
            for mode in BeatIntervalMode.allCases {
                modePopUp.addItem(withTitle: mode.rawValue)
            }
            if let savedIdx = BeatIntervalMode.allCases.firstIndex(of: model.beatIntervalMode) {
                modePopUp.selectItem(at: savedIdx)
            } else {
                modePopUp.selectItem(at: BeatIntervalMode.allCases.count - 1)
            }
            modePopUp.isEnabled = false
            beatCard.addSubview(modePopUp)

            sensitivityLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            sensitivityLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            sensitivityLabel.translatesAutoresizingMaskIntoConstraints = false
            beatCard.addSubview(sensitivityLabel)

            sensitivitySlider.doubleValue = model.peakSensitivity
            sensitivitySlider.isContinuous = true
            sensitivitySlider.translatesAutoresizingMaskIntoConstraints = false
            sensitivitySlider.target = self
            sensitivitySlider.action = #selector(onSensitivityChanged)
            sensitivitySlider.isEnabled = false
            beatCard.addSubview(sensitivitySlider)

            sensitivityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            sensitivityValueLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
            sensitivityValueLabel.alignment = .right
            sensitivityValueLabel.translatesAutoresizingMaskIntoConstraints = false
            beatCard.addSubview(sensitivityValueLabel)

            cagesPreviewLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            cagesPreviewLabel.textColor = NSColor(calibratedWhite: 0.62, alpha: 1.0)
            cagesPreviewLabel.lineBreakMode = .byTruncatingTail
            cagesPreviewLabel.maximumNumberOfLines = 1
            cagesPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
            beatCard.addSubview(cagesPreviewLabel)

            clearBeatBtn.translatesAutoresizingMaskIntoConstraints = false
            clearBeatBtn.target = self
            clearBeatBtn.action = #selector(onClearBeatClicked)
            footer.addSubview(clearBeatBtn)

            clearAllBtn.translatesAutoresizingMaskIntoConstraints = false
            clearAllBtn.target = self
            clearAllBtn.action = #selector(onClearAllClicked)
            footer.addSubview(clearAllBtn)

            applyBeatsBtn.translatesAutoresizingMaskIntoConstraints = false
            applyBeatsBtn.target = self
            applyBeatsBtn.action = #selector(onGenerateClicked)
            applyBeatsBtn.isEnabled = false
            footer.addSubview(applyBeatsBtn)

            constraints.append(contentsOf: [
                beatCard.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
                beatCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
                beatCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

                trackLabel.topAnchor.constraint(equalTo: beatCard.topAnchor, constant: 12),
                trackLabel.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),
                trackLabel.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),

                analyzeBtn.topAnchor.constraint(equalTo: trackLabel.bottomAnchor, constant: 8),
                analyzeBtn.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),
                analyzeBtn.widthAnchor.constraint(equalToConstant: 124),
                analyzeBtn.heightAnchor.constraint(equalToConstant: 24),

                statusIndicator.centerYAnchor.constraint(equalTo: analyzeBtn.centerYAnchor),
                statusIndicator.leadingAnchor.constraint(equalTo: analyzeBtn.trailingAnchor, constant: 10),

                statusLabel.centerYAnchor.constraint(equalTo: analyzeBtn.centerYAnchor),
                statusLabel.leadingAnchor.constraint(equalTo: statusIndicator.trailingAnchor, constant: 6),
                statusLabel.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),

                bpmResultLabel.topAnchor.constraint(equalTo: analyzeBtn.bottomAnchor, constant: 10),
                bpmResultLabel.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),
                bpmResultLabel.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),

                modeLabel.topAnchor.constraint(equalTo: bpmResultLabel.bottomAnchor, constant: 10),
                modeLabel.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),

                modePopUp.centerYAnchor.constraint(equalTo: modeLabel.centerYAnchor),
                modePopUp.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 10),
                modePopUp.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),

                sensitivityLabel.topAnchor.constraint(equalTo: modePopUp.bottomAnchor, constant: 10),
                sensitivityLabel.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),

                sensitivitySlider.centerYAnchor.constraint(equalTo: sensitivityLabel.centerYAnchor),
                sensitivitySlider.leadingAnchor.constraint(equalTo: sensitivityLabel.trailingAnchor, constant: 10),

                sensitivityValueLabel.centerYAnchor.constraint(equalTo: sensitivityLabel.centerYAnchor),
                sensitivityValueLabel.leadingAnchor.constraint(equalTo: sensitivitySlider.trailingAnchor, constant: 8),
                sensitivityValueLabel.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),
                sensitivityValueLabel.widthAnchor.constraint(equalToConstant: 110),

                cagesPreviewLabel.topAnchor.constraint(equalTo: sensitivityLabel.bottomAnchor, constant: 10),
                cagesPreviewLabel.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),
                cagesPreviewLabel.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),
                cagesPreviewLabel.bottomAnchor.constraint(equalTo: beatCard.bottomAnchor, constant: -12),

                clearBeatBtn.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
                clearBeatBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
                clearBeatBtn.widthAnchor.constraint(equalToConstant: 96),
                clearBeatBtn.heightAnchor.constraint(equalToConstant: 26),

                clearAllBtn.leadingAnchor.constraint(equalTo: clearBeatBtn.trailingAnchor, constant: 8),
                clearAllBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
                clearAllBtn.widthAnchor.constraint(equalToConstant: 100),
                clearAllBtn.heightAnchor.constraint(equalToConstant: 26),

                applyBeatsBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8),
                applyBeatsBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
                applyBeatsBtn.widthAnchor.constraint(equalToConstant: 104),
                applyBeatsBtn.heightAnchor.constraint(equalToConstant: 26)
            ])

        case .autoFillOnly:
            let autoFillCard = makeCard()
            root.addSubview(autoFillCard)

            let afSecTitle = NSTextField(labelWithString: "AUTO-FILL DA SELEZIONE SU V1")
            afSecTitle.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            afSecTitle.textColor = .systemCyan
            afSecTitle.translatesAutoresizingMaskIntoConstraints = false
            autoFillCard.addSubview(afSecTitle)

            let selLabel = NSTextField(labelWithString: "Sorgente:")
            selLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            selLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            selLabel.translatesAutoresizingMaskIntoConstraints = false
            autoFillCard.addSubview(selLabel)

            selectionPopUp.translatesAutoresizingMaskIntoConstraints = false
            selectionPopUp.target = self
            selectionPopUp.action = #selector(onSelectionChanged)
            autoFillCard.addSubview(selectionPopUp)

            let orderLabel = NSTextField(labelWithString: "Ordine:")
            orderLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            orderLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            orderLabel.translatesAutoresizingMaskIntoConstraints = false
            autoFillCard.addSubview(orderLabel)

            orderModePopUp.translatesAutoresizingMaskIntoConstraints = false
            orderModePopUp.target = self
            orderModePopUp.action = #selector(onOrderModeChanged)
            for mode in AutoFillOrderMode.allCases {
                orderModePopUp.addItem(withTitle: mode.rawValue)
            }
            orderModePopUp.selectItem(at: 0)
            autoFillCard.addSubview(orderModePopUp)

            let startLabel = NSTextField(labelWithString: "Inizio:")
            startLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            startLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            startLabel.translatesAutoresizingMaskIntoConstraints = false
            autoFillCard.addSubview(startLabel)

            let mins = Int(currentPlayheadSeconds) / 60
            let secs = Int(currentPlayheadSeconds) % 60
            startModeSegmented.setLabel("Dalla prima gabbia", forSegment: 0)
            startModeSegmented.setLabel(String(format: "Dalla testina (%02d:%02d)", mins, secs), forSegment: 1)
            startModeSegmented.selectedSegment = 0
            startModeSegmented.translatesAutoresizingMaskIntoConstraints = false
            startModeSegmented.target = self
            startModeSegmented.action = #selector(onStartModeChanged)
            autoFillCard.addSubview(startModeSegmented)

            autoFillStatusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            autoFillStatusLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 1.0)
            autoFillStatusLabel.lineBreakMode = .byWordWrapping
            autoFillStatusLabel.maximumNumberOfLines = 2
            autoFillStatusLabel.translatesAutoresizingMaskIntoConstraints = false
            autoFillCard.addSubview(autoFillStatusLabel)

            autoFillForecastLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            autoFillForecastLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
            autoFillForecastLabel.lineBreakMode = .byWordWrapping
            autoFillForecastLabel.maximumNumberOfLines = 2
            autoFillForecastLabel.translatesAutoresizingMaskIntoConstraints = false
            autoFillCard.addSubview(autoFillForecastLabel)

            autoFillBtn.translatesAutoresizingMaskIntoConstraints = false
            autoFillBtn.isAccentActive = true
            autoFillBtn.target = self
            autoFillBtn.action = #selector(onAutoFillClicked)
            autoFillCard.addSubview(autoFillBtn)

            constraints.append(contentsOf: [
                autoFillCard.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 14),
                autoFillCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                autoFillCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

                afSecTitle.topAnchor.constraint(equalTo: autoFillCard.topAnchor, constant: 12),
                afSecTitle.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),

                selLabel.topAnchor.constraint(equalTo: afSecTitle.bottomAnchor, constant: 12),
                selLabel.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),

                selectionPopUp.centerYAnchor.constraint(equalTo: selLabel.centerYAnchor),
                selectionPopUp.leadingAnchor.constraint(equalTo: selLabel.trailingAnchor, constant: 10),
                selectionPopUp.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),

                orderLabel.topAnchor.constraint(equalTo: selectionPopUp.bottomAnchor, constant: 10),
                orderLabel.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),

                orderModePopUp.centerYAnchor.constraint(equalTo: orderLabel.centerYAnchor),
                orderModePopUp.leadingAnchor.constraint(equalTo: selectionPopUp.leadingAnchor),
                orderModePopUp.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),

                startLabel.topAnchor.constraint(equalTo: orderModePopUp.bottomAnchor, constant: 10),
                startLabel.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),

                startModeSegmented.centerYAnchor.constraint(equalTo: startLabel.centerYAnchor),
                startModeSegmented.leadingAnchor.constraint(equalTo: selectionPopUp.leadingAnchor),
                startModeSegmented.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),

                autoFillStatusLabel.topAnchor.constraint(equalTo: startModeSegmented.bottomAnchor, constant: 12),
                autoFillStatusLabel.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),
                autoFillStatusLabel.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),

                autoFillForecastLabel.topAnchor.constraint(equalTo: autoFillStatusLabel.bottomAnchor, constant: 4),
                autoFillForecastLabel.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),
                autoFillForecastLabel.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),

                autoFillBtn.topAnchor.constraint(equalTo: autoFillForecastLabel.bottomAnchor, constant: 12),
                autoFillBtn.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),
                autoFillBtn.bottomAnchor.constraint(equalTo: autoFillCard.bottomAnchor, constant: -12),
                autoFillBtn.widthAnchor.constraint(equalToConstant: 176),
                autoFillBtn.heightAnchor.constraint(equalToConstant: 26)
            ])
        }

        NSLayoutConstraint.activate(constraints)

        if case .autoFillOnly = studioMode {
            populateSelectionPopUp()
            updateAutoFillState()
        } else {
            refreshUIState()
        }
    }

    private func makeCard() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        card.layer?.borderColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
        card.layer?.borderWidth = 1.0
        card.layer?.cornerRadius = 8
        return card
    }

    private func refreshUIState() {
        let clip = currentTargetClip

        if let clip = clip {
            trackLabel.stringValue = "\(clip.mediaItem.name) (\(String(format: "%.1f", CMTimeGetSeconds(clip.duration)))s)"
        } else {
            trackLabel.stringValue = "Nessuna traccia audio in timeline"
        }

        analyzeBtn.title = (analysisResult != nil) ? "Rianalizza Audio" : "Analizza Audio"
        analyzeBtn.isEnabled = (clip != nil && !isAnalyzing)

        let hasBeats = (clip.map { !$0.beatMarkers.isEmpty } ?? false) || !model.rhythmicCages.isEmpty
        let hasAnyMarkers = hasBeats || (clip.map { !$0.markers.isEmpty } ?? false)
        clearBeatBtn.isEnabled = hasBeats && !isAnalyzing
        clearAllBtn.isEnabled = hasAnyMarkers && !isAnalyzing

        if !isAnalyzing {
            if let feedback = lastFeedbackStatus {
                statusLabel.stringValue = feedback.text
                statusLabel.textColor = feedback.color
            }

            if let res = analysisResult {
                let dbPart = res.downbeatTimes.isEmpty ? "" : "  •  \(res.downbeatTimes.count) battute"
                let countPart: String
                if currentSelectedMode == .adaptiveDirector {
                    let c = res.selectAdaptiveCuts(sensitivity: model.peakSensitivity).count
                    countPart = "  •  \(c) tagli adattivi"
                } else {
                    let peakCount = res.selectStrongPeaks(sensitivity: model.peakSensitivity).count
                    countPart = "  •  \(peakCount) momenti forti"
                }
                bpmResultLabel.stringValue = "\(Int(res.bpm.rounded())) BPM  •  \(res.beatTimes.count) battiti\(dbPart)\(countPart)"
                modePopUp.isEnabled = true
                applyBeatsBtn.isEnabled = (clip != nil)
                applyBeatsBtn.isAccentActive = applyBeatsBtn.isEnabled
                updateSensitivityUI()
                updateCagesPreview()
            } else {
                if lastFeedbackStatus == nil {
                    if clip == nil {
                        statusLabel.stringValue = "Inserisci prima un brano su timeline."
                        statusLabel.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
                    } else {
                        statusLabel.stringValue = "Premi «Analizza Audio» per rilevare i beat."
                        statusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
                    }
                }

                var parts: [String] = []
                if let clip = clip {
                    if !clip.beatMarkers.isEmpty {
                        let bpmStr = clip.beatBPM.map { " (\(Int($0.rounded())) BPM)" } ?? ""
                        parts.append("\(clip.beatMarkers.count) beat salvati\(bpmStr)")
                    }
                    if !clip.markers.isEmpty {
                        parts.append("\(clip.markers.count) marcatori M")
                    }
                }
                bpmResultLabel.stringValue = parts.isEmpty ? "Nessun beat salvato sul brano" : "Sul brano: \(parts.joined(separator: "  •  "))"
                modePopUp.isEnabled = false
                sensitivitySlider.isEnabled = false
                updateSensitivityUI()
                applyBeatsBtn.isEnabled = false
                applyBeatsBtn.isAccentActive = false
                cagesPreviewLabel.stringValue = clip != nil
                    ? "I beat verranno salvati direttamente sulla clip audio."
                    : "Seleziona una clip audio su timeline."
            }
        } else {
            applyBeatsBtn.isEnabled = false
            applyBeatsBtn.isAccentActive = false
        }
    }

    private func runNeuralAnalysis() {
        guard let clip = currentTargetClip, !isAnalyzing else { return }
        isAnalyzing = true
        analyzeBtn.isEnabled = false
        applyBeatsBtn.isEnabled = false
        applyBeatsBtn.isAccentActive = false
        clearBeatBtn.isEnabled = false
        clearAllBtn.isEnabled = false
        modePopUp.isEnabled = false
        sensitivitySlider.isEnabled = false
        statusLabel.stringValue = "Analisi Beat This! in corso..."
        statusLabel.textColor = .systemYellow
        statusIndicator.isHidden = false
        statusIndicator.startAnimation(nil)
        view.needsDisplay = true
        modalPanel?.displayIfNeeded()

        let mediaItemId = clip.mediaItem.id
        let effectiveURL = clip.mediaItem.effectiveURL
        let clipSourceIn = CMTimeGetSeconds(clip.sourceIn)
        let clipSourceDur = CMTimeGetSeconds(clip.sourceDuration)

        Task { @MainActor [weak self] in
            do {
                let saved = try await Task.detached(priority: .userInitiated) {
                    let fullResult = try await AudioBeatDetector.shared.analyze(
                        url: effectiveURL,
                        timeRange: nil
                    )
                    return fullResult.toSavedBeatAnalysis()
                }.value
                EditorProject.shared.setBeatAnalysis(saved, forMediaItemId: mediaItemId)
                guard let self = self else { return }
                self.isAnalyzing = false
                self.analysisResult = saved.toBeatAnalysisResult(
                    audioURL: effectiveURL,
                    sourceStart: clipSourceIn,
                    sourceDuration: clipSourceDur
                )
                self.statusIndicator.stopAnimation(nil)
                self.statusIndicator.isHidden = true
                self.lastFeedbackStatus = ("Analisi completata e salvata", .systemGreen)
                self.refreshUIState()
                self.view.needsLayout = true
                self.view.layoutSubtreeIfNeeded()
                self.view.needsDisplay = true
                self.modalPanel?.displayIfNeeded()
            } catch {
                guard let self = self else { return }
                self.isAnalyzing = false
                self.statusIndicator.stopAnimation(nil)
                self.statusIndicator.isHidden = true
                self.lastFeedbackStatus = ("Errore analisi: \(error.localizedDescription)", .systemRed)
                self.refreshUIState()
                self.view.needsLayout = true
                self.view.layoutSubtreeIfNeeded()
                self.view.needsDisplay = true
                self.modalPanel?.displayIfNeeded()
            }
        }
    }

    private func populateSelectionPopUp() {
        selectionPopUp.removeAllItems()
        let selections = EditorProject.shared.selectionTimelines
        if selections.isEmpty {
            selectionPopUp.addItem(withTitle: "Nessuna selezione disponibile")
            selectionPopUp.isEnabled = false
        } else {
            selectionPopUp.isEnabled = true
            for sel in selections {
                selectionPopUp.addItem(withTitle: sel.name)
            }
            let active = EditorProject.shared.activeTimeline
            if active.isSelection {
                selectionPopUp.selectItem(withTitle: active.name)
            }
        }
    }

    private var selectedSelectionTimeline: TimelineModel? {
        let selections = EditorProject.shared.selectionTimelines
        guard selectionPopUp.isEnabled, let title = selectionPopUp.selectedTitle else {
            return selections.first
        }
        return selections.first(where: { $0.name == title }) ?? selections.first
    }

    private func effectiveAutoFillCages() -> (cages: [RhythmicCage], description: String) {
        let liveCages = model.activeCageIntervals()
        if !liveCages.isEmpty {
            let bpmStr = model.effectiveDetectedBPM.map { " (\(Int($0.rounded())) BPM)" } ?? ""
            return (liveCages, "\(liveCages.count) gabbie attive sulla timeline\(bpmStr)")
        }

        if !model.rhythmicCages.isEmpty {
            let bpmStr = model.detectedBPM.map { " (\(Int($0.rounded())) BPM)" } ?? ""
            return (model.rhythmicCages, "\(model.rhythmicCages.count) gabbie sulla timeline\(bpmStr)")
        }

        return ([], "0 gabbie disponibili")
    }

    private var activeStartPlayhead: Double? {
        startModeSegmented.selectedSegment == 1 ? currentPlayheadSeconds : nil
    }

    private func updateAutoFillState() {
        let effective = effectiveAutoFillCages()
        guard let sel = selectedSelectionTimeline else {
            autoFillStatusLabel.stringValue = "Crea una Selezione dal Media Pool (o converti una timeline 1V+1A) prima di usare Auto-Fill."
            autoFillStatusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
            autoFillForecastLabel.stringValue = ""
            autoFillBtn.isEnabled = false
            return
        }

        let videoClips = sel.videoTracks.first?.clips ?? []
        if effective.cages.isEmpty {
            autoFillStatusLabel.stringValue = "Nessuna gabbia pronta • \(videoClips.count) clip in '\(sel.name)'."
            autoFillStatusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
            autoFillForecastLabel.stringValue = "Fai clic destro su una traccia audio in timeline -> Beat Finder, o premi M per creare sbarre."
            autoFillForecastLabel.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
            autoFillBtn.isEnabled = false
            return
        }

        let forecast = model.previewAutoFill(
            withSelectionTimeline: sel,
            targetTrackIndex: 0,
            overrideCages: effective.cages,
            orderMode: currentOrderMode,
            startFromPlayhead: activeStartPlayhead
        )
        let prioInfo = (forecast.p2Count > 0 || forecast.p3Count > 0)
            ? " [P1:\(forecast.p1Count) • P2:\(forecast.p2Count) • P3:\(forecast.p3Count)]"
            : ""
        let startTag = activeStartPlayhead != nil ? " (da gabbia #\(forecast.startingCageNumber))" : ""
        let lockTag = forecast.lockedCagesCount > 0 ? ", \(forecast.lockedCagesCount) protette" : ""

        autoFillStatusLabel.stringValue = "Gabbie da riempire\(startTag): \(forecast.unlockedCagesCount) libere su \(forecast.totalTargetCages)\(lockTag)  •  Clip Selezione: \(forecast.selectionClipCount)\(prioInfo)"
        autoFillStatusLabel.textColor = .white

        if videoClips.isEmpty || forecast.unlockedCagesCount == 0 {
            autoFillForecastLabel.stringValue = videoClips.isEmpty
                ? "Nessuna clip video nella selezione '\(sel.name)'."
                : "Nessuna gabbia libera nel range selezionato."
            autoFillForecastLabel.textColor = .systemOrange
            autoFillBtn.isEnabled = false
        } else {
            var parts: [String] = []
            parts.append("\(forecast.predictedUniqueCount) uniche")
            if forecast.predictedSubsegmentCount > 0 {
                parts.append("\(forecast.predictedSubsegmentCount) sottospezzoni (Pass 2)")
            }
            if forecast.predictedEmptyCount > 0 {
                parts.append("\(forecast.predictedEmptyCount) resteranno vuote")
            }
            let summaryPrefix = forecast.predictedFilledCount == forecast.unlockedCagesCount
                ? "Copertura prevista: \(forecast.predictedFilledCount)/\(forecast.unlockedCagesCount) gabbie"
                : "Copertura parziale: \(forecast.predictedFilledCount)/\(forecast.unlockedCagesCount) gabbie"
            autoFillForecastLabel.stringValue = "\(summaryPrefix) (\(parts.joined(separator: " + ")))."
            autoFillForecastLabel.textColor = forecast.predictedEmptyCount > 0 ? .systemOrange : .systemCyan
            autoFillBtn.isEnabled = true
        }
    }

    private var currentSelectedMode: BeatIntervalMode {
        let idx = max(0, min(modePopUp.selectedIndex, BeatIntervalMode.allCases.count - 1))
        return BeatIntervalMode.allCases[idx]
    }

    private func updateSensitivityUI() {
        let sens = max(0.0, min(1.0, sensitivitySlider.doubleValue))
        model.peakSensitivity = sens
        let mode = currentSelectedMode
        let isAdaptive = (mode == .adaptiveDirector)
        let usesSensitivity = (mode == .dynamicTransients || isAdaptive)

        sensitivityLabel.stringValue = isAdaptive ? "Dinamica tagli:" : "Sensibilità picchi:"

        let pct = Int((sens * 100.0).rounded())
        let tier: String
        if sens < 0.28 {
            tier = isAdaptive ? "Disteso" : "Solo Clou"
        } else if sens < 0.68 {
            tier = "Bilanciato"
        } else if sens < 0.88 {
            tier = isAdaptive ? "Incisivo" : "Reattivo"
        } else {
            tier = isAdaptive ? "Frenetico" : "Massimo"
        }
        sensitivityValueLabel.stringValue = "\(tier) (\(pct)%)"

        let active = usesSensitivity && (analysisResult != nil) && !isAnalyzing
        sensitivitySlider.isEnabled = active
        sensitivityLabel.textColor = usesSensitivity
            ? NSColor(calibratedWhite: 0.78, alpha: 1.0)
            : NSColor(calibratedWhite: 0.42, alpha: 1.0)
        sensitivityValueLabel.textColor = active
            ? .systemOrange
            : NSColor(calibratedWhite: 0.45, alpha: 1.0)
    }

    private func updateCagesPreview() {
        guard let res = analysisResult, let clip = currentTargetClip else { return }
        let mode = currentSelectedMode
        model.beatIntervalMode = mode

        if mode == .dynamicTransients || mode == .adaptiveDirector {
            let dbPart = res.downbeatTimes.isEmpty ? "" : "  •  \(res.downbeatTimes.count) battute"
            if mode == .adaptiveDirector {
                let count = res.selectAdaptiveCuts(sensitivity: model.peakSensitivity).count
                bpmResultLabel.stringValue = "\(Int(res.bpm.rounded())) BPM  •  \(res.beatTimes.count) battiti\(dbPart)  •  \(count) tagli adattivi"
            } else {
                let peakCount = res.selectStrongPeaks(sensitivity: model.peakSensitivity).count
                bpmResultLabel.stringValue = "\(Int(res.bpm.rounded())) BPM  •  \(res.beatTimes.count) battiti\(dbPart)  •  \(peakCount) momenti forti"
            }
        }

        let cages = AudioBeatDetector.shared.generateCages(
            from: res,
            mode: mode,
            startTimeOffset: clip.sourceIn,
            peakSensitivity: model.peakSensitivity
        )
        let markerCount = cages.isEmpty ? 0 : cages.count + 1
        let avg = CMTimeGetSeconds(clip.duration) / Double(max(1, cages.count))
        let unit: String
        switch mode {
        case .dynamicTransients: unit = "picchi forti"
        case .adaptiveDirector: unit = "tagli adattivi"
        default: unit = "punti beat"
        }
        cagesPreviewLabel.stringValue = "Segnerà \(markerCount) \(unit) (\(cages.count) intervalli, ~\(String(format: "%.2f", avg))s) sul brano."
    }

    @objc private func onAnalyzeClicked() {
        runNeuralAnalysis()
    }

    @objc private func onModeChanged() {
        model.beatIntervalMode = currentSelectedMode
        updateSensitivityUI()
        updateCagesPreview()
    }

    @objc private func onSensitivityChanged() {
        updateSensitivityUI()
        updateCagesPreview()
    }

    @objc private func onSelectionChanged() {
        updateAutoFillState()
    }

    @objc private func onOrderModeChanged() {
        updateAutoFillState()
    }

    @objc private func onStartModeChanged() {
        updateAutoFillState()
    }

    @objc private func onClearBeatClicked() {
        if let clip = currentTargetClip, !clip.beatMarkers.isEmpty {
            model.setAudioClipBeatMarkers(clipId: clip.id, markers: [], bpm: nil)
        }
        if !model.rhythmicCages.isEmpty {
            model.clearTimelineCages()
        }
        onModified?()
        lastFeedbackStatus = ("Beat rimossi dal brano.", .systemOrange)
        DebugLogger.shared.log("Beat automatici rimossi dal brano '\(currentTargetClip?.mediaItem.name ?? "-")'.", level: .info)
        refreshUIState()
    }

    @objc private func onClearAllClicked() {
        if let clip = currentTargetClip {
            model.setAudioClipBeatMarkers(clipId: clip.id, markers: [], bpm: nil)
            _ = model.clearMarkers(clipId: clip.id)
        }
        if !model.rhythmicCages.isEmpty {
            model.clearTimelineCages()
        }
        onModified?()
        lastFeedbackStatus = ("Beat e marcatori rimossi dal brano.", .systemOrange)
        DebugLogger.shared.log("Pulizia completa beat e marcatori M su '\(currentTargetClip?.mediaItem.name ?? "-")'.", level: .info)
        refreshUIState()
    }

    @objc private func onGenerateClicked() {
        guard let res = analysisResult, let clip = currentTargetClip else { return }
        let mode = currentSelectedMode
        model.beatIntervalMode = mode
        model.peakSensitivity = max(0.0, min(1.0, sensitivitySlider.doubleValue))

        let sourceCages = AudioBeatDetector.shared.generateCages(
            from: res,
            mode: mode,
            startTimeOffset: clip.sourceIn,
            peakSensitivity: model.peakSensitivity
        )
        let sOut = CMTimeGetSeconds(clip.sourceOut)
        var markers: [Double] = sourceCages.map { min($0.startSeconds, sOut) }
        if let last = sourceCages.last {
            markers.append(min(last.endSeconds, sOut))
        }
        model.rhythmicCages = []
        model.detectedBPM = nil
        model.setAudioClipBeatMarkers(clipId: clip.id, markers: markers, bpm: res.bpm)
        onModified?()
        lastFeedbackStatus = ("Segnati \(markers.count) punti su '\(clip.mediaItem.name)'.", .systemGreen)
        DebugLogger.shared.log("Segnati \(markers.count) punti sul brano '\(clip.mediaItem.name)' (\(Int(res.bpm.rounded())) BPM).", level: .info)

        refreshUIState()
    }

    private var currentOrderMode: AutoFillOrderMode {
        let idx = max(0, min(orderModePopUp.selectedIndex, AutoFillOrderMode.allCases.count - 1))
        return AutoFillOrderMode.allCases[idx]
    }

    @objc private func onAutoFillClicked() {
        let effective = effectiveAutoFillCages()
        guard let sel = selectedSelectionTimeline, !effective.cages.isEmpty else { return }
        let sourceClips = sel.videoTracks.first?.clips ?? []
        guard !sourceClips.isEmpty else { return }

        let result = model.autoFillCagesDetailed(
            withSelectionTimeline: sel,
            targetTrackIndex: 0,
            overrideCages: effective.cages,
            orderMode: currentOrderMode,
            startFromPlayhead: activeStartPlayhead
        )
        onModified?()
        var detailParts = ["\(result.primaryUniqueCount) uniche"]
        if result.subsegmentCount > 0 { detailParts.append("\(result.subsegmentCount) sottospezzoni") }
        if result.lockedCagesCount > 0 { detailParts.append("\(result.lockedCagesCount) bloccate") }
        if result.movedAudioToA2 { detailParts.append("traccia audio -> A2") }
        if result.remainingEmptyCages > 0 { detailParts.append("\(result.remainingEmptyCages) vuote") }
        autoFillStatusLabel.stringValue = "Applicato: \(result.filledCount)/\(result.totalUnlockedCages) gabbie (\(detailParts.joined(separator: ", ")))."
        autoFillStatusLabel.textColor = result.filledCount > 0 ? .systemGreen : .systemOrange
        autoFillForecastLabel.stringValue = "Modalità Montaggio Gabbie ATTIVA in timeline (Riordina, Tab+Drag Slip, R / ⌘R Slow-Mo, E / ⌫ Scarto)."
        autoFillForecastLabel.textColor = .systemCyan
    }

    @objc private func onCloseClicked() {
        modalPanel?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        if let closedPanel = notification.object as? NSPanel, closedPanel === BeatAnalysisDialog.activeBeatFinderPanel {
            BeatAnalysisDialog.activeBeatFinderPanel = nil
            BeatAnalysisDialog.activeBeatFinderController = nil
        }
        if isModalSession {
            NSApp.stopModal()
        }
    }
}
