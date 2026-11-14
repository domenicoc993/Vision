import AppKit
import AVFoundation

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}


public final class SelectionViewController: NSViewController {
    public var playbackController = PlaybackController()
    public var mediaPoolVC: MediaPoolViewController!
    public var playerVC: PlayerViewController!

    public var currentSelection: SelectionModel? {
        didSet {
            rejectedStripView?.selectionModel = currentSelection
            analysisStripView?.selectionModel = currentSelection
            selectedStripView?.selectionModel = currentSelection
            updateHeaderUI()
            updateContainerWidth()
            rebuildCurrentComposition()
        }
    }

    public var activeStrip: SelectionStripType = .analysis {
        didSet {
            rejectedStripView?.isActiveStrip = (activeStrip == .rejected)
            analysisStripView?.isActiveStrip = (activeStrip == .analysis)
            selectedStripView?.isActiveStrip = (activeStrip == .selected)
            rebuildCurrentComposition()
        }
    }

    public var onActionRecorded: ((String) -> Void)?

    public var currentZoomPixelsPerSecond: Double = 50.0 {
        didSet {
            rejectedStripView?.pixelsPerSecond = currentZoomPixelsPerSecond
            analysisStripView?.pixelsPerSecond = currentZoomPixelsPerSecond
            selectedStripView?.pixelsPerSecond = currentZoomPixelsPerSecond
            updateContainerWidth()
        }
    }

    // Header Controls
    private let titleLabel = NSTextField(labelWithString: "SELEZIONE")
    private let selectionPopUp = NSPopUpButton()
    private let newSelectionBtn = NSButton()
    private let duplicateBtn = NSButton()
    private let zoomIconView = NSImageView()
    private let zoomSlider = NSSlider()
    private let statusInfoLabel = NSTextField(labelWithString: "")

    // Strip Views
    public private(set) var rejectedStripView: SelectionStripView!
    public private(set) var analysisStripView: SelectionStripView!
    public private(set) var selectedStripView: SelectionStripView!

    private let stripsScrollView = NSScrollView()
    private let stripsContainer = NSStackView()
    private var containerWidthConstraint: NSLayoutConstraint?

    private var rebuildTask: Task<Void, Never>?

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor

        // 1. Header Bar
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(header)
        setupHeader(in: header)

        // 2. Strips Views (3 strips: Rejected / Analysis / Selected)
        rejectedStripView = SelectionStripView(stripType: .rejected, playbackController: playbackController)
        analysisStripView = SelectionStripView(stripType: .analysis, playbackController: playbackController)
        selectedStripView = SelectionStripView(stripType: .selected, playbackController: playbackController)

        for strip in [rejectedStripView!, analysisStripView!, selectedStripView!] {
            strip.translatesAutoresizingMaskIntoConstraints = false
            let h = strip.heightAnchor.constraint(equalToConstant: 74)
            h.isActive = true
            strip.heightConstraint = h
            strip.pixelsPerSecond = currentZoomPixelsPerSecond

            strip.onStripClicked = { [weak self, weak strip] in
                guard let self = self, let s = strip else { return }
                self.activeStrip = s.stripType
            }

            strip.onPlayheadScrubbed = { [weak self] time in
                self?.seekAndSync(time: time)
            }

            strip.onClipMovedOrTrimmedWithTargetTime = { [weak self] targetTime in
                guard let self = self else { return }
                self.updateContainerWidth()
                if let t = targetTime {
                    self.seekAndSync(time: t)
                }
                self.rebuildCurrentComposition(seekToTime: targetTime)
                self.onActionRecorded?("Trim bordo clip")
            }

            strip.onClipMovedOrTrimmed = { [weak self] in
                self?.updateContainerWidth()
                self?.rebuildCurrentComposition()
                self?.onActionRecorded?("Trim bordo clip")
            }

            strip.onMinimizeToggled = { [weak self] in
                self?.view.needsLayout = true
                self?.stripsScrollView.layoutSubtreeIfNeeded()
            }
        }

        print(">>> adding to stripsContainer...")
        fflush(stdout)
        // 3. Strips Container Setup
        stripsContainer.orientation = .vertical
        stripsContainer.spacing = 6
        stripsContainer.alignment = .leading
        stripsContainer.translatesAutoresizingMaskIntoConstraints = false

        stripsContainer.addArrangedSubview(rejectedStripView)
        stripsContainer.addArrangedSubview(analysisStripView)
        stripsContainer.addArrangedSubview(selectedStripView)

        // Make strips stretch to full container width
        NSLayoutConstraint.activate([
            rejectedStripView.leadingAnchor.constraint(equalTo: stripsContainer.leadingAnchor),
            rejectedStripView.trailingAnchor.constraint(equalTo: stripsContainer.trailingAnchor),

            analysisStripView.leadingAnchor.constraint(equalTo: stripsContainer.leadingAnchor),
            analysisStripView.trailingAnchor.constraint(equalTo: stripsContainer.trailingAnchor),

            selectedStripView.leadingAnchor.constraint(equalTo: stripsContainer.leadingAnchor),
            selectedStripView.trailingAnchor.constraint(equalTo: stripsContainer.trailingAnchor)
        ])

        containerWidthConstraint = stripsContainer.widthAnchor.constraint(equalToConstant: 1200)
        containerWidthConstraint?.isActive = true

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stripsContainer)

        stripsScrollView.translatesAutoresizingMaskIntoConstraints = false
        stripsScrollView.hasHorizontalScroller = true
        stripsScrollView.hasVerticalScroller = true
        stripsScrollView.drawsBackground = false
        stripsScrollView.automaticallyAdjustsContentInsets = false
        stripsScrollView.documentView = documentView
        root.addSubview(stripsScrollView)

        let heightConstraint = documentView.heightAnchor.constraint(greaterThanOrEqualTo: stripsScrollView.contentView.heightAnchor)
        heightConstraint.priority = .defaultLow

        NSLayoutConstraint.activate([
            stripsContainer.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 10),
            stripsContainer.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stripsContainer.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stripsContainer.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -10),
            heightConstraint,

            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),

            stripsScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            stripsScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stripsScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stripsScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        self.view = root

        if currentSelection == nil {
            if let first = EditorProject.shared.activeSelection {
                self.currentSelection = first
            } else if !EditorProject.shared.selections.isEmpty {
                self.currentSelection = EditorProject.shared.selections[0]
            }
        }

        activeStrip = .analysis

        playbackController.addTimeObserver(self) { [weak self] _ in
            guard let self = self else { return }
            switch self.activeStrip {
            case .rejected: self.rejectedStripView?.needsDisplay = true
            case .analysis: self.analysisStripView?.needsDisplay = true
            case .selected: self.selectedStripView?.needsDisplay = true
            }
        }
    }

    private func setupHeader(in header: NSView) {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = NSColor.white
        header.addSubview(titleLabel)

        selectionPopUp.translatesAutoresizingMaskIntoConstraints = false
        selectionPopUp.target = self
        selectionPopUp.action = #selector(onSelectionPopUpChanged)
        header.addSubview(selectionPopUp)

        newSelectionBtn.translatesAutoresizingMaskIntoConstraints = false
        newSelectionBtn.title = "+ Nuova Selezione"
        newSelectionBtn.bezelStyle = .rounded
        newSelectionBtn.target = self
        newSelectionBtn.action = #selector(onNewSelectionClicked)
        header.addSubview(newSelectionBtn)

        duplicateBtn.translatesAutoresizingMaskIntoConstraints = false
        duplicateBtn.title = "Duplica"
        duplicateBtn.bezelStyle = .rounded
        duplicateBtn.target = self
        duplicateBtn.action = #selector(onDuplicateClicked)
        header.addSubview(duplicateBtn)

        zoomIconView.translatesAutoresizingMaskIntoConstraints = false
        zoomIconView.image = Lucide.template(.zoomIn, size: 15)
        zoomIconView.contentTintColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        zoomIconView.toolTip = "Zoom"
        header.addSubview(zoomIconView)

        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.minValue = 15.0
        zoomSlider.maxValue = 160.0
        zoomSlider.doubleValue = currentZoomPixelsPerSecond
        zoomSlider.target = self
        zoomSlider.action = #selector(onZoomSliderChanged)
        header.addSubview(zoomSlider)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        statusInfoLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusInfoLabel.textColor = NSColor.lightGray
        statusInfoLabel.lineBreakMode = .byTruncatingTail
        statusInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addSubview(statusInfoLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            selectionPopUp.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            selectionPopUp.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            selectionPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),

            newSelectionBtn.leadingAnchor.constraint(equalTo: selectionPopUp.trailingAnchor, constant: 10),
            newSelectionBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            duplicateBtn.leadingAnchor.constraint(equalTo: newSelectionBtn.trailingAnchor, constant: 6),
            duplicateBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            zoomIconView.leadingAnchor.constraint(equalTo: duplicateBtn.trailingAnchor, constant: 14),
            zoomIconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            zoomIconView.widthAnchor.constraint(equalToConstant: 16),
            zoomIconView.heightAnchor.constraint(equalToConstant: 16),

            zoomSlider.leadingAnchor.constraint(equalTo: zoomIconView.trailingAnchor, constant: 6),
            zoomSlider.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            zoomSlider.widthAnchor.constraint(equalToConstant: 100),

            statusInfoLabel.leadingAnchor.constraint(equalTo: zoomSlider.trailingAnchor, constant: 16),
            statusInfoLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusInfoLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -14)
        ])
    }

    public func updateContainerWidth() {
        guard let sel = currentSelection else { return }
        let maxSec = CMTimeGetSeconds(sel.maxDuration)
        let visibleWidth = stripsScrollView.contentView.bounds.width
        let calcWidth = max(visibleWidth, CGFloat(maxSec * currentZoomPixelsPerSecond) + 48.0 + 300.0)

        containerWidthConstraint?.constant = calcWidth
        stripsContainer.needsLayout = true
        rejectedStripView?.needsDisplay = true
        analysisStripView?.needsDisplay = true
        selectedStripView?.needsDisplay = true
    }

    @objc private func onZoomSliderChanged() {
        currentZoomPixelsPerSecond = zoomSlider.doubleValue
    }

    public func updateHeaderUI() {
        selectionPopUp.removeAllItems()
        for sel in EditorProject.shared.selections {
            selectionPopUp.addItem(withTitle: sel.name)
        }
        if let sel = currentSelection {
            selectionPopUp.selectItem(withTitle: sel.name)
            titleLabel.stringValue = "SELEZIONE: \(sel.name)"
            let rejDur = String(format: "%.1fs", CMTimeGetSeconds(sel.totalRejectedDuration))
            let anaDur = String(format: "%.1fs", CMTimeGetSeconds(sel.totalAnalysisDuration))
            let selDur = String(format: "%.1fs", CMTimeGetSeconds(sel.totalSelectedDuration))
            statusInfoLabel.stringValue = "🔴 Scarti: \(sel.rejectedClips.count) (\(rejDur))  |  🔵 Da Analizzare: \(sel.analysisClips.count) (\(anaDur))  |  🟢 Selezionati: \(sel.selectedClips.count) (\(selDur))"
        } else {
            titleLabel.stringValue = "MODALITÀ SELEZIONE"
            statusInfoLabel.stringValue = "Nessuna selezione attiva. Seleziona clip nel Media Pool e clicca '+ Nuova Selezione'."
        }
    }

    @objc private func onSelectionPopUpChanged() {
        guard let title = selectionPopUp.selectedItem?.title else { return }
        if let found = EditorProject.shared.selections.first(where: { $0.name == title }) {
            self.currentSelection = found
        }
    }

    @objc public func onNewSelectionClicked() {
        let alert = NSAlert()
        alert.messageText = "Nuova Selezione"
        alert.informativeText = "Inserisci un nome per la selezione delle clip filtrate:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = "Selezione \(EditorProject.shared.selections.count + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosenClips = mediaPoolVC?.selectedMediaItems ?? []
            let clipsToUse = chosenClips.isEmpty ? (mediaPoolVC?.mediaItems ?? []) : chosenClips
            let newSel = EditorProject.shared.createSelection(name: name.isEmpty ? "Selezione" : name, clips: clipsToUse)
            self.currentSelection = newSel
            updateHeaderUI()
            DebugLogger.shared.log("Creata nuova Selezione: '\(newSel.name)' con \(newSel.analysisClips.count) clip da analizzare.", level: .info)
        }
    }

    @objc private func onDuplicateClicked() {
        guard let current = currentSelection else { return }
        if let copy = EditorProject.shared.duplicateSelection(id: current.id) {
            self.currentSelection = copy
            updateHeaderUI()
            DebugLogger.shared.log("Duplicata selezione: '\(copy.name)'.", level: .info)
        }
    }

    private func seekAndSync(time: CMTime) {
        playbackController.seek(to: time, frameAccurate: true)
        rejectedStripView?.needsDisplay = true
        analysisStripView?.needsDisplay = true
        selectedStripView?.needsDisplay = true
        playerVC?.updateTimeDisplay()
    }

    public func rebuildCurrentComposition(seekToTime: CMTime? = nil) {
        guard let sel = currentSelection else {
            playbackController.clear()
            return
        }

        rebuildTask?.cancel()
        let targetStrip = activeStrip
        let timeline = sel.makeTimelineModel(for: targetStrip)

        if CMTimeCompare(timeline.totalDuration, .zero) <= 0 {
            playbackController.clear()
            rejectedStripView?.needsDisplay = true
            analysisStripView?.needsDisplay = true
            selectedStripView?.needsDisplay = true
            updateHeaderUI()
            return
        }

        let desiredSeekTime = seekToTime ?? playbackController.currentTime

        rebuildTask = Task {
            do {
                let item = try await CompositionEngine.shared.createPlayerItem(from: timeline)
                if Task.isCancelled { return }
                let targetFPS = mediaPoolVC?.mediaItems.first?.frameRate ?? 30.0

                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if let item = item {
                        self.playbackController.load(
                            item: item,
                            duration: timeline.totalDuration,
                            targetFPS: Double(targetFPS),
                            seekToTime: desiredSeekTime
                        )
                    } else {
                        self.playbackController.clear()
                    }
                    self.updateContainerWidth()
                    self.rejectedStripView?.needsDisplay = true
                    self.analysisStripView?.needsDisplay = true
                    self.selectedStripView?.needsDisplay = true
                    self.updateHeaderUI()
                }
            } catch {
                DebugLogger.shared.log("Errore composizione Selezione: \(error)", level: .error)
            }
        }
    }

    // MARK: - Keyboard Actions for the 3 Strips
    public func handleUpArrow() {
        guard let sel = currentSelection else { return }

        if activeStrip == .analysis {
            // Da BLU a ROSSA: sposta la clip attiva sotto la testina negli SCARTI (↑)
            let time = playbackController.currentTime
            let timeSec = CMTimeGetSeconds(time)
            var runningSec: Double = 0
            var foundId: UUID? = nil
            for c in sel.analysisClips {
                let dur = CMTimeGetSeconds(c.duration)
                if timeSec >= runningSec && timeSec <= runningSec + dur {
                    foundId = c.id
                    break
                }
                runningSec += dur
            }
            if let id = foundId ?? sel.analysisClips.first?.id {
                sel.rejectClip(id: id)
                updateContainerWidth()
                rebuildCurrentComposition()
                onActionRecorded?("Sposta clip negli Scarti (↑)")
                DebugLogger.shared.log("Clip scartata e spostata nella striscia ROSSA degli Scarti (↑).", level: .info)
            }
        } else if activeStrip == .selected {
            // Da VERDE a BLU: rimuove dai Selezionati e rimette in Da Analizzare (↑)
            let time = playbackController.currentTime
            let timeSec = CMTimeGetSeconds(time)
            var runningSec: Double = 0
            var foundId: UUID? = nil
            for c in sel.selectedClips {
                let dur = CMTimeGetSeconds(c.duration)
                if timeSec >= runningSec && timeSec <= runningSec + dur {
                    foundId = c.id
                    break
                }
                runningSec += dur
            }
            if let id = foundId ?? sel.selectedClips.first?.id {
                sel.unapproveClip(id: id)
                updateContainerWidth()
                rebuildCurrentComposition()
                onActionRecorded?("Rimuovi clip da Selezionati (↑)")
                DebugLogger.shared.log("Clip rimossa dai Selezionati e rimessa in analisi (↑).", level: .info)
            }
        }
    }

    public func handleDownArrow() {
        guard let sel = currentSelection else { return }

        if activeStrip == .analysis {
            // Da BLU a VERDE: promuove la clip attiva sotto la testina nei SELEZIONATI (↓)
            let time = playbackController.currentTime
            let timeSec = CMTimeGetSeconds(time)
            var runningSec: Double = 0
            var foundId: UUID? = nil
            for c in sel.analysisClips {
                let dur = CMTimeGetSeconds(c.duration)
                if timeSec >= runningSec && timeSec <= runningSec + dur {
                    foundId = c.id
                    break
                }
                runningSec += dur
            }
            if let id = foundId ?? sel.analysisClips.first?.id {
                sel.approveClip(id: id)
                updateContainerWidth()
                rebuildCurrentComposition()
                onActionRecorded?("Approva clip in Selezionati (↓)")
                DebugLogger.shared.log("Clip approvata e spostata nella striscia VERDE dei Selezionati (↓).", level: .info)
            }
        } else if activeStrip == .rejected {
            // Da ROSSA a BLU: ripristina la clip dagli Scarti alla striscia di Analisi (↓)
            let time = playbackController.currentTime
            let timeSec = CMTimeGetSeconds(time)
            var runningSec: Double = 0
            var foundId: UUID? = nil
            for c in sel.rejectedClips {
                let dur = CMTimeGetSeconds(c.duration)
                if timeSec >= runningSec && timeSec <= runningSec + dur {
                    foundId = c.id
                    break
                }
                runningSec += dur
            }
            if let id = foundId ?? sel.rejectedClips.first?.id {
                sel.restoreFromRejected(id: id)
                updateContainerWidth()
                rebuildCurrentComposition()
                onActionRecorded?("Ripristina clip da Scarti (↓)")
                DebugLogger.shared.log("Clip recuperata dagli Scarti e riposizionata in ordine in Analisi (↓).", level: .info)
            }
        }
    }

    public func handleTrimStart() {
        // Trim Inizio (Q): la porzione scartata prima del taglio va in SCARTI (Rossa)
        guard let sel = currentSelection, activeStrip == .analysis else { return }
        let time = playbackController.currentTime
        let timeSec = CMTimeGetSeconds(time)

        var runningSec: Double = 0
        for c in sel.analysisClips {
            let dur = CMTimeGetSeconds(c.duration)
            if timeSec > runningSec && timeSec < runningSec + dur {
                let offsetSec = timeSec - runningSec
                let offset = CMTime(seconds: offsetSec, preferredTimescale: 600)
                sel.trimStart(clipId: c.id, atOffset: offset)
                
                // La testina si posiziona esattamente sul nuovo inizio della clip rimanente (runningSec)
                let targetTime = CMTime(seconds: runningSec, preferredTimescale: 600)
                seekAndSync(time: targetTime)
                updateContainerWidth()
                rebuildCurrentComposition(seekToTime: targetTime)
                onActionRecorded?("Trim Inizio clip (Q)")
                DebugLogger.shared.log("Trim Inizio (Q): porzione scartata aggiunta agli Scarti (Rossa).", level: .info)
                return
            }
            runningSec += dur
        }
    }

    public func handleTrimEnd() {
        // Trim Fine (W): la porzione dopo il taglio va in SCARTI (Rossa)
        guard let sel = currentSelection, activeStrip == .analysis else { return }
        let time = playbackController.currentTime
        let timeSec = CMTimeGetSeconds(time)

        var runningSec: Double = 0
        for c in sel.analysisClips {
            let dur = CMTimeGetSeconds(c.duration)
            if timeSec > runningSec && timeSec < runningSec + dur {
                let offsetSec = timeSec - runningSec
                let offset = CMTime(seconds: offsetSec, preferredTimescale: 600)
                sel.trimEnd(clipId: c.id, atOffset: offset)
                
                // La testina rimane sul punto di taglio appena effettuato
                let targetTime = CMTime(seconds: max(runningSec, timeSec - 0.04), preferredTimescale: 600)
                seekAndSync(time: targetTime)
                updateContainerWidth()
                rebuildCurrentComposition(seekToTime: targetTime)
                onActionRecorded?("Trim Fine clip (W)")
                DebugLogger.shared.log("Trim Fine (W): porzione scartata aggiunta agli Scarti (Rossa).", level: .info)
                return
            }
            runningSec += dur
        }
    }

    public func handleSplit() {
        // Spezza (S): divide la clip attiva in due blocchi in analisi
        guard let sel = currentSelection, activeStrip == .analysis else { return }
        let time = playbackController.currentTime
        let timeSec = CMTimeGetSeconds(time)

        var runningSec: Double = 0
        for c in sel.analysisClips {
            let dur = CMTimeGetSeconds(c.duration)
            if timeSec > runningSec && timeSec < runningSec + dur {
                let offsetSec = timeSec - runningSec
                let offset = CMTime(seconds: offsetSec, preferredTimescale: 600)
                sel.splitClip(clipId: c.id, atOffset: offset)
                updateContainerWidth()
                rebuildCurrentComposition()
                onActionRecorded?("Divisione clip (S)")
                DebugLogger.shared.log("Clip divisa in 2 blocchi indipendenti (S).", level: .info)
                return
            }
            runningSec += dur
        }
    }
}
