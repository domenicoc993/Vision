import AppKit
import Foundation
import CoreMedia
import AVFoundation

/// Modal studio for Beat & Rhythmic Cages generation (Timeline or Audio Clip target) and Auto-Fill from Selection.
public final class BeatAnalysisDialog: NSViewController, NSWindowDelegate {
    private enum TargetMode: Int {
        case timeline = 0
        case trackClip = 1
    }

    private let model: TimelineModel
    private let targetAudioClip: TimelineClip?
    private let hasSelectedAudioClip: Bool
    private weak var modalPanel: NSPanel?
    private var onModified: (() -> Void)?

    private var targetMode: TargetMode
    private var analysisResult: BeatAnalysisResult?
    private var isAnalyzing: Bool = false
    private var lastFeedbackStatus: (text: String, color: NSColor)?

    private let targetSegmented = NSSegmentedControl(
        labels: ["Timeline Globale", "Sul Brano"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let modeBannerView = NSView()
    private let modeBannerLabel = NSTextField(labelWithString: "")

    private let trackLabel = NSTextField(labelWithString: "")
    private let analyzeBtn = FlatButton(title: "Analizza Audio")
    private let statusIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let bpmResultLabel = NSTextField(labelWithString: "")
    private let modePopUp = NSPopUpButton()
    private let sensitivityLabel = NSTextField(labelWithString: "Sensibilità picchi:")
    private let sensitivitySlider = NSSlider(value: 0.45, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let sensitivityValueLabel = NSTextField(labelWithString: "Bilanciato (45%)")
    private let cagesPreviewLabel = NSTextField(labelWithString: "")

    private let clearTimelineBtn = FlatButton(title: "Pulisci Timeline")
    private let clearClipBtn = FlatButton(title: "Pulisci Brano")
    private let generateBtn = FlatButton(title: "Applica Gabbie")

    private let selectionPopUp = NSPopUpButton()
    private let autoFillStatusLabel = NSTextField(labelWithString: "")
    private let autoFillBtn = FlatButton(title: "Esegui Auto-Fill su V1")

    public static func showModal(
        for model: TimelineModel,
        relativeTo parentWindow: NSWindow? = nil,
        onModified: (() -> Void)? = nil
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 530, height: 575),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Montaggio Ritmico & Auto-Fill"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        panel.isFloatingPanel = true

        if let parent = parentWindow {
            let pf = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: pf.midX - panel.frame.width / 2,
                y: pf.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }

        let controller = BeatAnalysisDialog(model: model, panel: panel, onModified: onModified)
        panel.delegate = controller
        panel.contentViewController = controller
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }

    private init(model: TimelineModel, panel: NSPanel, onModified: (() -> Void)?) {
        self.model = model
        self.modalPanel = panel
        self.onModified = onModified

        var selectedAudio: TimelineClip? = nil
        for track in model.audioTracks {
            if let selected = track.clips.first(where: { model.selectedClipIds.contains($0.id) }) {
                selectedAudio = selected
                break
            }
        }

        var fallbackAudio: TimelineClip? = nil
        if selectedAudio == nil {
            for track in model.audioTracks {
                if let first = track.clips.first {
                    fallbackAudio = first
                    break
                }
            }
        }

        self.hasSelectedAudioClip = (selectedAudio != nil)
        self.targetAudioClip = selectedAudio ?? fallbackAudio
        self.targetMode = (selectedAudio != nil) ? .trackClip : .timeline

        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError() }

    private var currentTargetClip: TimelineClip? {
        guard let clip = targetAudioClip else { return nil }
        return model.audioClip(withId: clip.id) ?? clip
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 530, height: 575))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor
        self.view = root

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(header)

        let headerIcon = NSImageView()
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.image = Lucide.image(.wandSparkles, size: 18, color: .systemCyan)
        header.addSubview(headerIcon)

        let titleLabel = NSTextField(labelWithString: "Montaggio Ritmico Guidato dalla Musica")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        let headerDivider = NSBox()
        headerDivider.boxType = .separator
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerDivider)

        // Section 1: Beat & Gabbie Card
        let beatCard = makeCard()
        root.addSubview(beatCard)

        let beatSecTitle = NSTextField(labelWithString: "1. ANALISI BEAT & DESTINAZIONE GABBIE")
        beatSecTitle.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        beatSecTitle.textColor = .systemCyan
        beatSecTitle.translatesAutoresizingMaskIntoConstraints = false
        beatCard.addSubview(beatSecTitle)

        let destLabel = NSTextField(labelWithString: "Destinazione:")
        destLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        destLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
        destLabel.translatesAutoresizingMaskIntoConstraints = false
        beatCard.addSubview(destLabel)

        targetSegmented.translatesAutoresizingMaskIntoConstraints = false
        targetSegmented.target = self
        targetSegmented.action = #selector(onTargetModeChanged)
        targetSegmented.setEnabled(targetAudioClip != nil, forSegment: TargetMode.trackClip.rawValue)
        targetSegmented.selectedSegment = targetMode.rawValue
        beatCard.addSubview(targetSegmented)

        modeBannerView.translatesAutoresizingMaskIntoConstraints = false
        modeBannerView.wantsLayer = true
        modeBannerView.layer?.cornerRadius = 6
        modeBannerView.layer?.borderWidth = 1.0
        beatCard.addSubview(modeBannerView)

        modeBannerLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        modeBannerLabel.lineBreakMode = .byWordWrapping
        modeBannerLabel.maximumNumberOfLines = 2
        modeBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        modeBannerView.addSubview(modeBannerLabel)

        trackLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        trackLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
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

        modePopUp.bezelStyle = .rounded
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
        cagesPreviewLabel.lineBreakMode = .byWordWrapping
        cagesPreviewLabel.maximumNumberOfLines = 2
        cagesPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        beatCard.addSubview(cagesPreviewLabel)

        clearTimelineBtn.translatesAutoresizingMaskIntoConstraints = false
        clearTimelineBtn.target = self
        clearTimelineBtn.action = #selector(onClearTimelineClicked)
        beatCard.addSubview(clearTimelineBtn)

        clearClipBtn.translatesAutoresizingMaskIntoConstraints = false
        clearClipBtn.target = self
        clearClipBtn.action = #selector(onClearClipClicked)
        beatCard.addSubview(clearClipBtn)

        generateBtn.translatesAutoresizingMaskIntoConstraints = false
        generateBtn.target = self
        generateBtn.action = #selector(onGenerateClicked)
        generateBtn.isEnabled = false
        beatCard.addSubview(generateBtn)

        // Section 2: Auto-Fill Card
        let autoFillCard = makeCard()
        root.addSubview(autoFillCard)

        let afSecTitle = NSTextField(labelWithString: "2. AUTO-FILL DA SELEZIONE")
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

        autoFillStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        autoFillStatusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
        autoFillStatusLabel.lineBreakMode = .byWordWrapping
        autoFillStatusLabel.maximumNumberOfLines = 2
        autoFillStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        autoFillCard.addSubview(autoFillStatusLabel)

        autoFillBtn.translatesAutoresizingMaskIntoConstraints = false
        autoFillBtn.isAccentActive = true
        autoFillBtn.target = self
        autoFillBtn.action = #selector(onAutoFillClicked)
        autoFillCard.addSubview(autoFillBtn)

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

        NSLayoutConstraint.activate([
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
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // Card 1
            beatCard.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 14),
            beatCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            beatCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            beatSecTitle.topAnchor.constraint(equalTo: beatCard.topAnchor, constant: 12),
            beatSecTitle.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),

            destLabel.topAnchor.constraint(equalTo: beatSecTitle.bottomAnchor, constant: 10),
            destLabel.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),

            targetSegmented.centerYAnchor.constraint(equalTo: destLabel.centerYAnchor),
            targetSegmented.leadingAnchor.constraint(equalTo: destLabel.trailingAnchor, constant: 10),
            targetSegmented.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),

            modeBannerView.topAnchor.constraint(equalTo: targetSegmented.bottomAnchor, constant: 10),
            modeBannerView.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),
            modeBannerView.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),

            modeBannerLabel.topAnchor.constraint(equalTo: modeBannerView.topAnchor, constant: 7),
            modeBannerLabel.bottomAnchor.constraint(equalTo: modeBannerView.bottomAnchor, constant: -7),
            modeBannerLabel.leadingAnchor.constraint(equalTo: modeBannerView.leadingAnchor, constant: 10),
            modeBannerLabel.trailingAnchor.constraint(equalTo: modeBannerView.trailingAnchor, constant: -10),

            trackLabel.topAnchor.constraint(equalTo: modeBannerView.bottomAnchor, constant: 10),
            trackLabel.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),
            trackLabel.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),

            analyzeBtn.topAnchor.constraint(equalTo: trackLabel.bottomAnchor, constant: 8),
            analyzeBtn.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),
            analyzeBtn.widthAnchor.constraint(equalToConstant: 128),
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

            clearTimelineBtn.topAnchor.constraint(equalTo: cagesPreviewLabel.bottomAnchor, constant: 12),
            clearTimelineBtn.leadingAnchor.constraint(equalTo: beatCard.leadingAnchor, constant: 14),
            clearTimelineBtn.bottomAnchor.constraint(equalTo: beatCard.bottomAnchor, constant: -12),
            clearTimelineBtn.widthAnchor.constraint(equalToConstant: 122),
            clearTimelineBtn.heightAnchor.constraint(equalToConstant: 26),

            clearClipBtn.centerYAnchor.constraint(equalTo: clearTimelineBtn.centerYAnchor),
            clearClipBtn.leadingAnchor.constraint(equalTo: clearTimelineBtn.trailingAnchor, constant: 8),
            clearClipBtn.widthAnchor.constraint(equalToConstant: 108),
            clearClipBtn.heightAnchor.constraint(equalToConstant: 26),

            generateBtn.centerYAnchor.constraint(equalTo: clearTimelineBtn.centerYAnchor),
            generateBtn.trailingAnchor.constraint(equalTo: beatCard.trailingAnchor, constant: -14),
            generateBtn.widthAnchor.constraint(equalToConstant: 176),
            generateBtn.heightAnchor.constraint(equalToConstant: 26),

            // Card 2
            autoFillCard.topAnchor.constraint(equalTo: beatCard.bottomAnchor, constant: 12),
            autoFillCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            autoFillCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            afSecTitle.topAnchor.constraint(equalTo: autoFillCard.topAnchor, constant: 12),
            afSecTitle.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),

            selLabel.topAnchor.constraint(equalTo: afSecTitle.bottomAnchor, constant: 10),
            selLabel.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),

            selectionPopUp.centerYAnchor.constraint(equalTo: selLabel.centerYAnchor),
            selectionPopUp.leadingAnchor.constraint(equalTo: selLabel.trailingAnchor, constant: 10),
            selectionPopUp.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),

            autoFillStatusLabel.topAnchor.constraint(equalTo: selectionPopUp.bottomAnchor, constant: 8),
            autoFillStatusLabel.leadingAnchor.constraint(equalTo: autoFillCard.leadingAnchor, constant: 14),
            autoFillStatusLabel.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),

            autoFillBtn.topAnchor.constraint(equalTo: autoFillStatusLabel.bottomAnchor, constant: 10),
            autoFillBtn.trailingAnchor.constraint(equalTo: autoFillCard.trailingAnchor, constant: -14),
            autoFillBtn.bottomAnchor.constraint(equalTo: autoFillCard.bottomAnchor, constant: -12),
            autoFillBtn.widthAnchor.constraint(equalToConstant: 168),
            autoFillBtn.heightAnchor.constraint(equalToConstant: 26),

            // Footer
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 44),

            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            closeBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 84),
            closeBtn.heightAnchor.constraint(equalToConstant: 26)
        ])

        populateSelectionPopUp()
        refreshUIState()
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

        // 1. Mode warning banner
        switch targetMode {
        case .trackClip:
            modeBannerView.layer?.backgroundColor = NSColor(calibratedRed: 0.24, green: 0.15, blue: 0.04, alpha: 1.0).cgColor
            modeBannerView.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.75).cgColor
            modeBannerLabel.textColor = .systemOrange
            if let clip = clip {
                let prefix = hasSelectedAudioClip
                    ? "MODALITÀ BRANO ATTIVA (clip selezionata)"
                    : "MODALITÀ BRANO ATTIVA"
                modeBannerLabel.stringValue = "\(prefix): segnerai i beat direttamente su '\(clip.mediaItem.name)'. Si sposteranno e taglieranno con il brano."
            } else {
                modeBannerLabel.stringValue = "MODALITÀ BRANO: nessun brano audio trovato in timeline."
            }
            generateBtn.title = "Segna Beat sul Brano"

        case .timeline:
            modeBannerView.layer?.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.22, alpha: 1.0).cgColor
            modeBannerView.layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.65).cgColor
            modeBannerLabel.textColor = .systemCyan
            modeBannerLabel.stringValue = "MODALITÀ TIMELINE ATTIVA: le gabbie verranno create sulla griglia globale della timeline."
            generateBtn.title = "Applica Gabbie su Timeline"
        }

        // 2. Target clip & scan status
        if let clip = clip {
            trackLabel.stringValue = "Brano audio: \(clip.mediaItem.name) (\(String(format: "%.1f", CMTimeGetSeconds(clip.duration)))s)"
        } else {
            trackLabel.stringValue = "Nessuna traccia audio in timeline"
        }

        analyzeBtn.isEnabled = (clip != nil && !isAnalyzing)
        clearTimelineBtn.isEnabled = !model.rhythmicCages.isEmpty
        clearClipBtn.isEnabled = (clip.map { !$0.beatMarkers.isEmpty } ?? false)
        clearClipBtn.isHidden = (clip == nil)

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
                generateBtn.isEnabled = (clip != nil)
                updateSensitivityUI()
                updateCagesPreview()
            } else {
                if lastFeedbackStatus == nil {
                    if clip == nil {
                        statusLabel.stringValue = "Inserisci prima un file audio su una traccia audio (A1)."
                        statusLabel.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
                    } else {
                        statusLabel.stringValue = "Scansione manuale: premi «Analizza Audio» per avviare Beat This!."
                        statusLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
                    }
                }

                var parts: [String] = []
                if !model.rhythmicCages.isEmpty {
                    let bpmStr = model.detectedBPM.map { " (\(Int($0.rounded())) BPM)" } ?? ""
                    parts.append("Timeline: \(model.rhythmicCages.count) gabbie\(bpmStr)")
                }
                if let clip = clip, !clip.beatMarkers.isEmpty {
                    let bpmStr = clip.beatBPM.map { " (\(Int($0.rounded())) BPM)" } ?? ""
                    parts.append("Brano: \(clip.beatMarkers.count) segni\(bpmStr)")
                }
                bpmResultLabel.stringValue = parts.isEmpty ? "Stato attuale: nessuna gabbia o segno salvato" : "Attivo — " + parts.joined(separator: "  •  ")
                modePopUp.isEnabled = false
                sensitivitySlider.isEnabled = false
                updateSensitivityUI()
                generateBtn.isEnabled = false
                cagesPreviewLabel.stringValue = clip != nil
                    ? "L'analisi neurale non parte automaticamente all'apertura. Avviala quando sei pronto."
                    : "Trascina una traccia musicale su A1, poi premi «Analizza Audio»."
            }
        }

        updateAutoFillState()
    }

    private func runNeuralAnalysis() {
        guard let clip = currentTargetClip, !isAnalyzing else { return }
        isAnalyzing = true
        analyzeBtn.isEnabled = false
        generateBtn.isEnabled = false
        modePopUp.isEnabled = false
        statusLabel.stringValue = "Analisi neurale Beat This! in corso..."
        statusLabel.textColor = .systemYellow
        statusIndicator.isHidden = false
        statusIndicator.startAnimation(nil)

        let sourceRange = CMTimeRange(start: clip.sourceIn, duration: clip.sourceDuration)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await AudioBeatDetector.shared.analyze(
                    url: clip.mediaItem.effectiveURL,
                    timeRange: sourceRange
                )
                DispatchQueue.main.async {
                    self.isAnalyzing = false
                    self.analysisResult = result
                    self.statusIndicator.stopAnimation(nil)
                    self.statusIndicator.isHidden = true
                    self.lastFeedbackStatus = ("Analisi completata", .systemGreen)
                    self.refreshUIState()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isAnalyzing = false
                    self.statusIndicator.stopAnimation(nil)
                    self.statusIndicator.isHidden = true
                    self.lastFeedbackStatus = ("Errore analisi: \(error.localizedDescription)", .systemRed)
                    self.refreshUIState()
                }
            }
        }
    }

    private func populateSelectionPopUp() {
        selectionPopUp.removeAllItems()
        let selections = EditorProject.shared.selections
        if selections.isEmpty {
            selectionPopUp.addItem(withTitle: "Nessuna selezione disponibile")
            selectionPopUp.isEnabled = false
        } else {
            selectionPopUp.isEnabled = true
            for sel in selections {
                selectionPopUp.addItem(withTitle: sel.name)
            }
            if let active = EditorProject.shared.activeSelection {
                selectionPopUp.selectItem(withTitle: active.name)
            }
        }
    }

    private var selectedSelectionModel: SelectionModel? {
        guard selectionPopUp.isEnabled, let title = selectionPopUp.selectedItem?.title else {
            return EditorProject.shared.activeSelection
        }
        return EditorProject.shared.selections.first(where: { $0.name == title }) ?? EditorProject.shared.activeSelection
    }

    private func effectiveAutoFillCages() -> (cages: [RhythmicCage], description: String) {
        if targetMode == .trackClip, let clip = currentTargetClip {
            let clipCages = model.cagesFromAudioClip(clip)
            if !clipCages.isEmpty {
                let bpmStr = clip.beatBPM.map { " (\(Int($0.rounded())) BPM)" } ?? ""
                return (clipCages, "\(clipCages.count) gabbie dal brano '\(clip.mediaItem.name)'\(bpmStr)")
            }
        }

        if !model.rhythmicCages.isEmpty {
            let bpmStr = model.detectedBPM.map { " (\(Int($0.rounded())) BPM)" } ?? ""
            return (model.rhythmicCages, "\(model.rhythmicCages.count) gabbie sulla timeline\(bpmStr)")
        }

        if let clip = currentTargetClip {
            let clipCages = model.cagesFromAudioClip(clip)
            if !clipCages.isEmpty {
                let bpmStr = clip.beatBPM.map { " (\(Int($0.rounded())) BPM)" } ?? ""
                return (clipCages, "\(clipCages.count) gabbie dal brano '\(clip.mediaItem.name)'\(bpmStr)")
            }
        }

        return ([], "0 gabbie disponibili")
    }

    private func updateAutoFillState() {
        let effective = effectiveAutoFillCages()
        guard let sel = selectedSelectionModel else {
            autoFillStatusLabel.stringValue = "Crea una Selezione (⌘1) con le clip da montare prima di usare Auto-Fill."
            autoFillStatusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
            autoFillBtn.isEnabled = false
            return
        }

        let approved = sel.selectedClips
        let source = !approved.isEmpty ? approved : sel.analysisClips
        let sourceKind = !approved.isEmpty ? "approvate (Verde)" : "in analisi (Blu)"

        if effective.cages.isEmpty {
            autoFillStatusLabel.stringValue = "Nessuna gabbia pronta • \(source.count) clip \(sourceKind) pronte. Analizza e applica le gabbie sopra."
            autoFillStatusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
            autoFillBtn.isEnabled = false
        } else if source.isEmpty {
            autoFillStatusLabel.stringValue = "\(effective.description) • nessuna clip nella selezione '\(sel.name)'."
            autoFillStatusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
            autoFillBtn.isEnabled = false
        } else {
            autoFillStatusLabel.stringValue = "\(effective.description) • \(source.count) clip \(sourceKind) da '\(sel.name)'."
            autoFillStatusLabel.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
            autoFillBtn.isEnabled = true
        }
    }

    private var currentSelectedMode: BeatIntervalMode {
        let idx = max(0, min(modePopUp.indexOfSelectedItem, BeatIntervalMode.allCases.count - 1))
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
        } else {
            tier = isAdaptive ? "Incisivo" : "Reattivo"
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

    private func buildTimelineCages(result: BeatAnalysisResult, clip: TimelineClip, mode: BeatIntervalMode) -> [RhythmicCage] {
        let sens = model.peakSensitivity
        let spd = clip.speed > 0 ? clip.speed : 1.0
        if abs(spd - 1.0) < 0.0001 {
            return AudioBeatDetector.shared.generateCages(
                from: result,
                mode: mode,
                startTimeOffset: clip.timelineStart,
                peakSensitivity: sens
            )
        }
        let base = AudioBeatDetector.shared.generateCages(
            from: result,
            mode: mode,
            startTimeOffset: .zero,
            peakSensitivity: sens
        )
        let tStart = CMTimeGetSeconds(clip.timelineStart)
        return base.map { cage in
            RhythmicCage(
                index: cage.index,
                startSeconds: tStart + cage.startSeconds / spd,
                durationSeconds: cage.durationSeconds / spd
            )
        }
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

        switch targetMode {
        case .timeline:
            let cages = buildTimelineCages(result: res, clip: clip, mode: mode)
            let avg = CMTimeGetSeconds(clip.duration) / Double(max(1, cages.count))
            cagesPreviewLabel.stringValue = "Verranno create \(cages.count) gabbie sulla timeline (durata media ~\(String(format: "%.2f", avg))s)."
        case .trackClip:
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
            cagesPreviewLabel.stringValue = "Verranno segnati \(markerCount) \(unit) (\(cages.count) intervalli, ~\(String(format: "%.2f", avg))s) sul brano."
        }
    }

    @objc private func onTargetModeChanged() {
        if let selected = TargetMode(rawValue: targetSegmented.selectedSegment) {
            if selected == .trackClip && targetAudioClip == nil {
                targetSegmented.selectedSegment = TargetMode.timeline.rawValue
                targetMode = .timeline
            } else {
                targetMode = selected
            }
        }
        refreshUIState()
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

    @objc private func onClearTimelineClicked() {
        model.clearTimelineCages()
        onModified?()
        lastFeedbackStatus = ("Gabbie sulla timeline rimosse.", .systemCyan)
        DebugLogger.shared.log("Gabbie ritmate sulla timeline pulite dal pannello Montaggio Ritmico.", level: .info)
        refreshUIState()
    }

    @objc private func onClearClipClicked() {
        guard let clip = currentTargetClip else { return }
        model.setAudioClipBeatMarkers(clipId: clip.id, markers: [], bpm: nil)
        onModified?()
        lastFeedbackStatus = ("Segni beat rimossi dal brano '\(clip.mediaItem.name)'.", .systemOrange)
        DebugLogger.shared.log("Segni beat rimossi dal brano '\(clip.mediaItem.name)'.", level: .info)
        refreshUIState()
    }

    @objc private func onGenerateClicked() {
        guard let res = analysisResult, let clip = currentTargetClip else { return }
        let mode = currentSelectedMode
        model.beatIntervalMode = mode
        model.peakSensitivity = max(0.0, min(1.0, sensitivitySlider.doubleValue))

        switch targetMode {
        case .timeline:
            let cages = buildTimelineCages(result: res, clip: clip, mode: mode)
            model.rhythmicCages = cages
            model.detectedBPM = res.bpm
            model.onModelChanged?()
            onModified?()
            lastFeedbackStatus = ("Applicate \(cages.count) gabbie sulla timeline.", .systemGreen)
            DebugLogger.shared.log("Struttura musicale creata sulla timeline: \(cages.count) gabbie a \(Int(res.bpm.rounded())) BPM.", level: .info)

        case .trackClip:
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
            model.setAudioClipBeatMarkers(clipId: clip.id, markers: markers, bpm: res.bpm)
            onModified?()
            lastFeedbackStatus = ("Segnati \(markers.count) punti su '\(clip.mediaItem.name)'.", .systemGreen)
            DebugLogger.shared.log("Segnati \(markers.count) punti sul brano '\(clip.mediaItem.name)' (\(Int(res.bpm.rounded())) BPM).", level: .info)
        }

        refreshUIState()
    }

    @objc private func onAutoFillClicked() {
        let effective = effectiveAutoFillCages()
        guard let sel = selectedSelectionModel, !effective.cages.isEmpty else { return }
        let sourceClips = !sel.selectedClips.isEmpty ? sel.selectedClips : sel.analysisClips
        guard !sourceClips.isEmpty else { return }

        let count = model.autoFillCages(with: sourceClips, targetTrackIndex: 0, overrideCages: effective.cages)
        onModified?()
        autoFillStatusLabel.stringValue = "Auto-Fill completato: \(count) clip inserite su V1 (\(effective.description))."
        autoFillStatusLabel.textColor = .systemGreen
    }

    @objc private func onCloseClicked() {
        modalPanel?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}
