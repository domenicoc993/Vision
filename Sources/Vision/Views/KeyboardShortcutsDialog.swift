import AppKit

/// Floating popover displaying all active Vision keyboard shortcuts grouped by context.
public final class KeyboardShortcutsDialog: NSViewController {
    private static var activePopover: NSPopover?

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

    public static func toggle(relativeTo anchorView: NSView) {
        if let existing = activePopover, existing.isShown {
            existing.performClose(nil)
            activePopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = KeyboardShortcutsDialog()
        popover.contentSize = NSSize(width: 470, height: 500)
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        activePopover = popover
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 500))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor
        self.view = root

        let headerTitle = NSTextField(labelWithString: "Scorciatoie da Tastiera")
        headerTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        headerTitle.textColor = .white
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerTitle)

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

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(contentStack)

        for section in Self.sections {
            let sectionStack = NSStackView()
            sectionStack.orientation = .vertical
            sectionStack.alignment = .leading
            sectionStack.spacing = 6
            sectionStack.translatesAutoresizingMaskIntoConstraints = false

            let secLabel = NSTextField(labelWithString: section.title)
            secLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            secLabel.textColor = .systemCyan
            sectionStack.addArrangedSubview(secLabel)

            for entry in section.entries {
                let row = makeShortcutRow(entry)
                sectionStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
            }

            contentStack.addArrangedSubview(sectionStack)
            sectionStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            headerTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            headerTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            divider.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -14)
        ])
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
        badgeContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.21, alpha: 1.0).cgColor
        badgeContainer.layer?.borderColor = NSColor(calibratedWhite: 0.34, alpha: 1.0).cgColor
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
}
