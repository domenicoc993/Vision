import AppKit

/// Finestra / modale Log & Diagnostica con ricerca live, filtro Speed Editor e copia negli appunti.
public final class DebugConsoleViewController: NSViewController, NSTextFieldDelegate, NSWindowDelegate {
    private static var activePanel: NSPanel?
    private static weak var activeController: DebugConsoleViewController?

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let telemetryLabel = NSTextField(labelWithString: "In attesa di eventi...")
    private let searchField = NSTextField()
    private let clearSearchBtn = NSButton()
    private let speedFilterBtn = FlatButton(title: "Solo Speed Editor")
    private let matchCountLabel = NSTextField(labelWithString: "")
    private let copyFilteredBtn = FlatButton(title: "Copia Log")
    private let copyReportBtn = FlatButton(title: "Copia Report")

    public var diagnosticProvider: (() -> String)?
    private var searchQuery: String = ""
    private var onlySpeedEditor: Bool = false
    private var logObserver: Any?
    private var stateObserver: Any?

    @discardableResult
    public static func showWindow(relativeTo parentWindow: NSWindow? = nil, diagnosticProvider: (() -> String)? = nil) -> DebugConsoleViewController {
        if let existingPanel = activePanel, let existingVC = activeController {
            existingVC.diagnosticProvider = diagnosticProvider
            existingVC.reloadLogsFromBuffer()
            existingVC.refreshHeaderTelemetry()
            existingPanel.makeKeyAndOrderFront(nil)
            return existingVC
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 620, height: 380)
        panel.title = "Log & Diagnostica Vision"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
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

        let controller = DebugConsoleViewController()
        controller.diagnosticProvider = diagnosticProvider
        panel.contentViewController = controller
        panel.delegate = controller
        activePanel = panel
        activeController = controller

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(controller.searchField)
        return controller
    }

    deinit {
        if let obs = logObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = stateObserver { NotificationCenter.default.removeObserver(obs) }
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 560))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.115, alpha: 1.0).cgColor
        root.addSubview(header)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = Lucide.image(.fileCode2, size: 16, color: .systemCyan)
        header.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "Log & Diagnostica")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        header.addSubview(titleLabel)

        telemetryLabel.translatesAutoresizingMaskIntoConstraints = false
        telemetryLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        telemetryLabel.textColor = .secondaryLabelColor
        telemetryLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(telemetryLabel)

        copyFilteredBtn.translatesAutoresizingMaskIntoConstraints = false
        copyFilteredBtn.isAccentActive = true
        copyFilteredBtn.target = self
        copyFilteredBtn.action = #selector(onCopyFilteredClicked)
        header.addSubview(copyFilteredBtn)

        copyReportBtn.translatesAutoresizingMaskIntoConstraints = false
        copyReportBtn.target = self
        copyReportBtn.action = #selector(onCopyReportClicked)
        header.addSubview(copyReportBtn)

        let clearButton = FlatButton(title: "Pulisci", target: self, action: #selector(onClearClicked))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(clearButton)

        // Search Strip
        let searchBar = NSView()
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.wantsLayer = true
        searchBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor
        root.addSubview(searchBar)

        let searchIcon = NSImageView()
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = Lucide.template(.search, size: 13)
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchBar.addSubview(searchIcon)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 12, weight: .light)
        searchField.textColor = .white
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.lineBreakMode = .byTruncatingTail
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Cerca nei log (es. SPEED, JOG, HID, FPS, ERROR)...",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .light),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        searchField.delegate = self
        searchBar.addSubview(searchField)

        clearSearchBtn.translatesAutoresizingMaskIntoConstraints = false
        clearSearchBtn.isBordered = false
        clearSearchBtn.title = "✕"
        clearSearchBtn.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        clearSearchBtn.contentTintColor = .tertiaryLabelColor
        clearSearchBtn.isHidden = true
        clearSearchBtn.target = self
        clearSearchBtn.action = #selector(onClearSearchClicked)
        searchBar.addSubview(clearSearchBtn)

        speedFilterBtn.translatesAutoresizingMaskIntoConstraints = false
        speedFilterBtn.target = self
        speedFilterBtn.action = #selector(onToggleSpeedFilterClicked)
        searchBar.addSubview(speedFilterBtn)

        matchCountLabel.translatesAutoresizingMaskIntoConstraints = false
        matchCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        matchCountLabel.textColor = .secondaryLabelColor
        matchCountLabel.alignment = .right
        searchBar.addSubview(matchCountLabel)

        let headerDivider = NSBox()
        headerDivider.boxType = .separator
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerDivider)

        let searchDivider = NSBox()
        searchDivider.boxType = .separator
        searchDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchDivider)

        // Log text area
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.068, alpha: 1.0)
        scrollView.documentView = textView
        root.addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(calibratedWhite: 0.068, alpha: 1.0)
        textView.textColor = NSColor.textColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

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
            header.heightAnchor.constraint(equalToConstant: 42),

            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            telemetryLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            telemetryLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            telemetryLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyFilteredBtn.leadingAnchor, constant: -10),

            clearButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 66),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            copyReportBtn.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            copyReportBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyReportBtn.widthAnchor.constraint(equalToConstant: 102),
            copyReportBtn.heightAnchor.constraint(equalToConstant: 24),

            copyFilteredBtn.trailingAnchor.constraint(equalTo: copyReportBtn.leadingAnchor, constant: -8),
            copyFilteredBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyFilteredBtn.widthAnchor.constraint(equalToConstant: 86),
            copyFilteredBtn.heightAnchor.constraint(equalToConstant: 24),

            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            searchBar.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 32),

            searchIcon.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 13),
            searchIcon.heightAnchor.constraint(equalToConstant: 13),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: clearSearchBtn.leadingAnchor, constant: -6),

            clearSearchBtn.trailingAnchor.constraint(equalTo: matchCountLabel.leadingAnchor, constant: -8),
            clearSearchBtn.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            clearSearchBtn.widthAnchor.constraint(equalToConstant: 18),
            clearSearchBtn.heightAnchor.constraint(equalToConstant: 18),

            matchCountLabel.trailingAnchor.constraint(equalTo: speedFilterBtn.leadingAnchor, constant: -10),
            matchCountLabel.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),

            speedFilterBtn.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -14),
            speedFilterBtn.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            speedFilterBtn.widthAnchor.constraint(equalToConstant: 128),
            speedFilterBtn.heightAnchor.constraint(equalToConstant: 22),

            searchDivider.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            searchDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: searchDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),

            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            closeBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 80),
            closeBtn.heightAnchor.constraint(equalToConstant: 24)
        ])

        self.view = root

        refreshHeaderTelemetry()
        reloadLogsFromBuffer()
        setupLoggerListener()
    }

    public func windowWillClose(_ notification: Notification) {
        if DebugConsoleViewController.activeController === self {
            DebugConsoleViewController.activePanel = nil
            DebugConsoleViewController.activeController = nil
        }
    }

    public var currentDisplayedLogText: String {
        textView.string
    }

    public func setFilterForTesting(query: String, onlySpeedEditor: Bool = false) {
        self.searchQuery = query
        self.searchField.stringValue = query
        self.onlySpeedEditor = onlySpeedEditor
        self.speedFilterBtn.isAccentActive = onlySpeedEditor
        self.clearSearchBtn.isHidden = query.isEmpty
        reloadLogsFromBuffer()
    }

    private func setupLoggerListener() {
        logObserver = NotificationCenter.default.addObserver(
            forName: DebugLogger.didAddLogNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let entry = note.userInfo?["entry"] as? DebugLogger.LogEntry else { return }
            self.appendLogIfMatches(entry)
            self.refreshHeaderTelemetry()
        }

        stateObserver = NotificationCenter.default.addObserver(
            forName: SpeedEditorManager.stateChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHeaderTelemetry()
        }
    }

    private func refreshHeaderTelemetry() {
        let se = SpeedEditorManager.shared
        let total = DebugLogger.shared.logs.count
        telemetryLabel.stringValue = "SE: \(se.currentWheelMode.rawValue) (\(String(format: "%.2fx", se.wheelSensitivity))) • \(total) log"
    }

    public func updateTelemetry(text: String) {
        telemetryLabel.stringValue = text
    }

    private func entryMatchesFilter(_ entry: DebugLogger.LogEntry) -> Bool {
        if onlySpeedEditor && !entry.message.localizedCaseInsensitiveContains("SPEED") {
            return false
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty && !entry.formattedString.localizedCaseInsensitiveContains(q) {
            return false
        }
        return true
    }

    private func attributedLine(for entry: DebugLogger.LogEntry) -> NSAttributedString {
        let color: NSColor
        switch entry.level {
        case .info: color = NSColor(calibratedWhite: 0.86, alpha: 1.0)
        case .warning: color = NSColor.systemYellow
        case .error: color = NSColor.systemRed
        case .playback: color = NSColor.systemCyan
        case .perf: color = NSColor.systemOrange
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]
        return NSAttributedString(string: entry.formattedString + "\n", attributes: attrs)
    }

    private func reloadLogsFromBuffer() {
        let matching = DebugLogger.shared.logs.filter { entryMatchesFilter($0) }
        let combined = NSMutableAttributedString()
        for entry in matching {
            combined.append(attributedLine(for: entry))
        }
        textView.textStorage?.setAttributedString(combined)
        matchCountLabel.stringValue = "\(matching.count) / \(DebugLogger.shared.logs.count) righe"
        textView.scrollToEndOfDocument(nil)
    }

    private func appendLogIfMatches(_ entry: DebugLogger.LogEntry) {
        if entryMatchesFilter(entry) {
            let wasNearBottom = scrollView.verticalScroller?.floatValue ?? 1.0 >= 0.96
            textView.textStorage?.append(attributedLine(for: entry))
            if wasNearBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }
        let matchingCount = DebugLogger.shared.logs.reduce(0) { $0 + (entryMatchesFilter($1) ? 1 : 0) }
        matchCountLabel.stringValue = "\(matchingCount) / \(DebugLogger.shared.logs.count) righe"
    }

    public func controlTextDidChange(_ obj: Notification) {
        if let tf = obj.object as? NSTextField, tf === searchField {
            searchQuery = tf.stringValue
            clearSearchBtn.isHidden = searchQuery.isEmpty
            reloadLogsFromBuffer()
        }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !searchQuery.isEmpty {
                searchQuery = ""
                searchField.stringValue = ""
                clearSearchBtn.isHidden = true
                reloadLogsFromBuffer()
                return true
            }
        }
        return false
    }

    @objc private func onClearSearchClicked() {
        searchQuery = ""
        searchField.stringValue = ""
        clearSearchBtn.isHidden = true
        reloadLogsFromBuffer()
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func onToggleSpeedFilterClicked() {
        onlySpeedEditor.toggle()
        speedFilterBtn.isAccentActive = onlySpeedEditor
        reloadLogsFromBuffer()
    }

    @objc private func onCopyFilteredClicked() {
        let se = SpeedEditorManager.shared
        let header = "=== VISION LOG FILTRATI (mode=\(se.currentWheelMode.rawValue) sens=\(String(format: "%.2fx", se.wheelSensitivity)) connected=\(se.isConnected) auth=\(se.isAuthenticated)) ===\n"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(header + textView.string, forType: .string)

        copyFilteredBtn.title = "Copiato ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyFilteredBtn.title = "Copia Log"
        }
    }

    @objc private func onCopyReportClicked() {
        let report = diagnosticProvider?() ?? DebugLogger.shared.buildDiagnosticReport(activeTimeline: nil, playerStatus: nil, mediaPoolCount: 0)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)

        copyReportBtn.title = "Copiato ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyReportBtn.title = "Copia Report"
        }
    }

    @objc private func onClearClicked() {
        textView.string = ""
        DebugLogger.shared.logs.removeAll()
        matchCountLabel.stringValue = "0 / 0 righe"
        refreshHeaderTelemetry()
    }

    @objc private func onCloseClicked() {
        view.window?.performClose(nil)
    }
}
