import AppKit

/// Modal dialog displaying all active Vision keyboard shortcuts grouped by context, with live search.
public final class KeyboardShortcutsDialog: NSViewController, NSSearchFieldDelegate, NSWindowDelegate {
    private weak var modalPanel: NSPanel?
    private let searchField = NSSearchField()
    private let contentStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Nessuna scorciatoia trovata")

    public struct ShortcutEntry {
        public let keys: String
        public let description: String
    }

    public struct ShortcutSection {
        public let title: String
        public let entries: [ShortcutEntry]
    }

    public static let sections: [ShortcutSection] = [
        ShortcutSection(
            title: "GENERALE",
            entries: [
                ShortcutEntry(keys: "⌘ O", description: "Apri Project Manager"),
                ShortcutEntry(keys: "⌘ Z", description: "Annulla (Undo)"),
                ShortcutEntry(keys: "⇧ ⌘ Z / ⌘ Y", description: "Ripeti (Redo)"),
                ShortcutEntry(keys: "⌘ 1", description: "Passa a modalità Selezione"),
                ShortcutEntry(keys: "⌘ 2", description: "Passa a modalità Montaggio"),
                ShortcutEntry(keys: "⌃ F", description: "Schermo intero Viewer"),
                ShortcutEntry(keys: "⌘ A", description: "Seleziona tutto nella sezione attiva")
            ]
        ),
        ShortcutSection(
            title: "RIPRODUZIONE",
            entries: [
                ShortcutEntry(keys: "Spazio", description: "Play / Pausa"),
                ShortcutEntry(keys: "← / →", description: "Passo indietro / avanti di 1 frame")
            ]
        ),
        ShortcutSection(
            title: "MODALITÀ MONTAGGIO (TIMELINE)",
            entries: [
                ShortcutEntry(keys: "Q", description: "Trim inizio clip alla testina (Ripple)"),
                ShortcutEntry(keys: "W", description: "Trim fine clip alla testina (Ripple)"),
                ShortcutEntry(keys: "S / B", description: "Spezza clip alla testina (Blade)"),
                ShortcutEntry(keys: "M", description: "Aggiungi / rimuovi marcatore su clip audio/video"),
                ShortcutEntry(keys: "⌥ M", description: "Pulisci tutti i marcatori sulla clip"),
                ShortcutEntry(keys: "⌥ ⌘ W", description: "Chiudi spazi (Close Gaps) tra clip selezionate"),
                ShortcutEntry(keys: "N", description: "Attiva / disattiva Magnet (Snapping)"),
                ShortcutEntry(keys: "⌘ L / ⌥ L", description: "Attiva / disattiva Link Audio/Video"),
                ShortcutEntry(keys: "⌥ P", description: "Attiva / disattiva Seleziona sotto testina"),
                ShortcutEntry(keys: "⌥ ↑ / ⌥ ↓", description: "Sposta clip tra tracce video/audio"),
                ShortcutEntry(keys: "⌫", description: "Elimina clip (o Ripple Delete su gabbie)")
            ]
        ),
        ShortcutSection(
            title: "GABBIE RITMATE",
            entries: [
                ShortcutEntry(keys: "⌥ S", description: "Alterna Slow Motion 50%"),
                ShortcutEntry(keys: "⌥ + / ⌥ −", description: "Espandi / riduci span gabbia (1x / 2x / 3x)"),
                ShortcutEntry(keys: "⌥ ← / ⌥ →", description: "Slip contenuto interno clip (±0.25s)"),
                ShortcutEntry(keys: "⌘ ← / ⌘ →", description: "Scambia clip tra gabbie adiacenti")
            ]
        ),
        ShortcutSection(
            title: "MODALITÀ SELEZIONE",
            entries: [
                ShortcutEntry(keys: "↑ / ↓", description: "Sposta in Scarti / Ripristina da Scarti"),
                ShortcutEntry(keys: "Q / W", description: "Trim inizio / fine (scarta parte tagliata)"),
                ShortcutEntry(keys: "S / B", description: "Spezza segmento nella selezione")
            ]
        )
    ]

    public static func showModal(relativeTo parentWindow: NSWindow? = nil) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 440, height: 400)
        panel.title = "Scorciatoie da Tastiera"
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

        let controller = KeyboardShortcutsDialog(panel: panel)
        panel.delegate = controller
        panel.contentViewController = controller
        panel.makeFirstResponder(controller.searchField)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }

    public init(panel: NSPanel? = nil) {
        self.modalPanel = panel
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 560))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor
        self.view = root

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(header)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = Lucide.image(.keyboard, size: 18, color: .systemCyan)
        header.addSubview(iconView)

        let headerTitle = NSTextField(labelWithString: "Scorciatoie da Tastiera")
        headerTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        headerTitle.textColor = .white
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Cerca comando o tasto (es. trim, ⌘, slip)..."
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(onSearchChanged)
        header.addSubview(searchField)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)

        let docView = NSView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(contentStack)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        emptyLabel.textColor = NSColor(calibratedWhite: 0.52, alpha: 1.0)
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

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

            iconView.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            headerTitle.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            headerTitle.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),

            searchField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            searchField.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

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

        rebuildContent(query: "")
    }

    public func controlTextDidChange(_ obj: Notification) {
        rebuildContent(query: searchField.stringValue)
    }

    @objc private func onSearchChanged() {
        rebuildContent(query: searchField.stringValue)
    }

    private func rebuildContent(query: String) {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for section in Self.sections {
            let matchingEntries: [ShortcutEntry]
            if trimmed.isEmpty || section.title.lowercased().contains(trimmed) {
                matchingEntries = section.entries
            } else {
                matchingEntries = section.entries.filter {
                    $0.description.lowercased().contains(trimmed) || $0.keys.lowercased().contains(trimmed)
                }
            }

            guard !matchingEntries.isEmpty else { continue }

            let sectionStack = NSStackView()
            sectionStack.orientation = .vertical
            sectionStack.alignment = .leading
            sectionStack.spacing = 6
            sectionStack.translatesAutoresizingMaskIntoConstraints = false

            let secLabel = NSTextField(labelWithString: section.title)
            secLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            secLabel.textColor = .systemCyan
            sectionStack.addArrangedSubview(secLabel)

            for entry in matchingEntries {
                let row = makeShortcutRow(entry)
                sectionStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
            }

            contentStack.addArrangedSubview(sectionStack)
            sectionStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        emptyLabel.isHidden = !contentStack.arrangedSubviews.isEmpty
    }

    private func makeShortcutRow(_ entry: ShortcutEntry) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = NSTextField(labelWithString: entry.description)
        descLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        descLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        let badgeContainer = NSView()
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor
        badgeContainer.layer?.borderColor = NSColor(calibratedWhite: 0.24, alpha: 1.0).cgColor
        badgeContainer.layer?.borderWidth = 1.0
        badgeContainer.layer?.cornerRadius = 4
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: entry.keys)
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        keyLabel.textColor = .white
        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(keyLabel)

        row.addSubview(descLabel)
        row.addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),

            badgeContainer.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            badgeContainer.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: 21),

            keyLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 7),
            keyLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -7),
            keyLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),

            descLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.leadingAnchor, constant: -10),
            descLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        return row
    }

    @objc private func onCloseClicked() {
        modalPanel?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}
