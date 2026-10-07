import AppKit

public final class DebugConsoleViewController: NSViewController {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let telemetryLabel = NSTextField(labelWithString: "In attesa di eventi...")

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1.0).cgColor

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor
        root.addSubview(header)

        let titleLabel = NSTextField(labelWithString: "CONSOLE DI DEBUG & TELEMETRIA HARDWARE")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = .systemGreen
        header.addSubview(titleLabel)

        telemetryLabel.translatesAutoresizingMaskIntoConstraints = false
        telemetryLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        telemetryLabel.textColor = .secondaryLabelColor
        header.addSubview(telemetryLabel)

        let clearButton = NSButton()
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.title = "Pulisci"
        clearButton.bezelStyle = .inline
        clearButton.target = self
        clearButton.action = #selector(onClearClicked)
        header.addSubview(clearButton)

        // Text view for logs
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        root.addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        textView.textColor = NSColor.textColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            telemetryLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 16),
            telemetryLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        self.view = root

        setupLoggerListener()
    }

    private func setupLoggerListener() {
        // Load existing logs
        for entry in DebugLogger.shared.logs {
            appendLog(entry)
        }

        DebugLogger.shared.onLogAdded = { [weak self] entry in
            DispatchQueue.main.async {
                self?.appendLog(entry)
            }
        }
    }

    public func updateTelemetry(text: String) {
        telemetryLabel.stringValue = text
    }

    private func appendLog(_ entry: DebugLogger.LogEntry) {
        let color: NSColor
        switch entry.level {
        case .info: color = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        case .warning: color = NSColor.systemYellow
        case .error: color = NSColor.systemRed
        case .playback: color = NSColor.systemCyan
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]
        let attrStr = NSAttributedString(string: entry.formattedString + "\n", attributes: attrs)
        
        textView.textStorage?.append(attrStr)
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func onClearClicked() {
        textView.string = ""
        DebugLogger.shared.logs.removeAll()
    }
}
