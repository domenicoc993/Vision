import AppKit

/// Modal dialog displaying Vision keyboard shortcuts and interactive DaVinci Resolve Speed Editor command mapping.
public final class KeyboardShortcutsDialog: NSViewController, NSSearchFieldDelegate, NSWindowDelegate {
    private enum DialogTab: Int {
        case keyboard = 0
        case speedEditor = 1
    }

    private weak var modalPanel: NSPanel?
    private let tabSegmented = NSSegmentedControl(
        labels: ["Tastiera", "Speed Editor"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let searchField = NSSearchField()
    private let keyboardStageView = NSView()
    private let modifierSegmented = NSSegmentedControl(
        labels: KeyboardModifierFilter.allCases.map(\.rawValue),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let interactiveKeyboardView = InteractiveKeyboardView()
    private let inspectorCard = NSView()
    private let inspectorTitleLabel = NSTextField(labelWithString: "")
    private let inspectorBodyStack = NSStackView()
    private let clearKeyBtn = FlatButton(title: "Tutti i tasti")
    private let stageDivider = NSBox()

    private let speedEditorStageView = NSView()
    private let interactiveSpeedEditorView = InteractiveSpeedEditorView()
    private let seInspectorCard = NSView()
    private let seInspectorTitleLabel = NSTextField(labelWithString: "")
    private let seInspectorBodyStack = NSStackView()
    private let seClearBtn = FlatButton(title: "Tutti i tasti")
    private let seStageDivider = NSBox()

    private let contentStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "Nessuna scorciatoia trovata")
    private let resetDefaultsBtn = FlatButton(title: "Ripristina Default Speed Editor")

    private var scrollTopToKeyboardStageConstraint: NSLayoutConstraint?
    private var scrollTopToSpeedEditorStageConstraint: NSLayoutConstraint?

    private var activeTab: DialogTab = .keyboard
    private var activeModifierFilter: KeyboardModifierFilter = .all
    private var selectedKeyId: String? = nil
    private var selectedSpeedEditorElementId: String? = nil
    private weak var statusLabelRef: NSTextField?
    private weak var statusDotRef: NSView?
    private weak var lastKeyLabelRef: NSTextField?
    private weak var wheelSensValueLabelRef: NSTextField?
    private var rowBadgesByButton: [SpeedEditorButton: NSView] = [:]
    private var highlightedButton: SpeedEditorButton? = nil
    private var stateObserver: Any?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

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
                ShortcutEntry(keys: "⌘ E", description: "Esporta timeline attiva in Final Cut XML (.fcpxmld)"),
                ShortcutEntry(keys: "⌘ Z", description: "Annulla (Undo)"),
                ShortcutEntry(keys: "⇧ ⌘ Z / ⌘ Y", description: "Ripeti (Redo)"),
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
            title: "MONTAGGIO & SELEZIONE (TIMELINE)",
            entries: [
                ShortcutEntry(keys: "Q", description: "Trim inizio clip alla testina (Ripple)"),
                ShortcutEntry(keys: "W", description: "Trim fine clip alla testina (Ripple)"),
                ShortcutEntry(keys: "S / B", description: "Spezza clip alla testina (Blade)"),
                ShortcutEntry(keys: "1 / 2 / 3", description: "Assegna priorità clip (1 Hero, 2 Buona, 3 Filler)"),
                ShortcutEntry(keys: "0", description: "Rimuovi priorità dalla clip"),
                ShortcutEntry(keys: "M", description: "Aggiungi / rimuovi marcatore (o sbarra su traccia audio)"),
                ShortcutEntry(keys: "Trascina Pin / ⌫", description: "Sposta o elimina marcatore / beat marker su audio e video"),
                ShortcutEntry(keys: "⌥ M", description: "Pulisci tutti i marcatori sulla clip"),
                ShortcutEntry(keys: "⌥ ⌘ W", description: "Chiudi spazi (Close Gaps) tra clip selezionate"),
                ShortcutEntry(keys: "N", description: "Attiva / disattiva Magnet (Snapping)"),
                ShortcutEntry(keys: "L", description: "Blocca / sblocca clip (protetta in Auto-Fill)"),
                ShortcutEntry(keys: "⌘ L / ⌥ L", description: "Attiva / disattiva Link Audio/Video"),
                ShortcutEntry(keys: "⌥ P", description: "Attiva / disattiva Seleziona sotto testina"),
                ShortcutEntry(keys: "⌥ ↑ / ⌥ ↓", description: "Sposta clip tra tracce video/audio"),
                ShortcutEntry(keys: "⌫ / E (Selezione)", description: "Elimina clip (o Ripple Delete in Selezione / su gabbie)")
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
        )
    ]

    public static func showModal(relativeTo parentWindow: NSWindow? = nil) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 740, height: 560)
        panel.title = "Tastiera & Speed Editor"
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

    deinit {
        if let obs = stateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        if let m = keyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = keyUpMonitor { NSEvent.removeMonitor(m) }
    }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 760))
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

        let headerTitle = NSTextField(labelWithString: "Tastiera & Speed Editor")
        headerTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        headerTitle.textColor = .white
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)

        tabSegmented.translatesAutoresizingMaskIntoConstraints = false
        tabSegmented.selectedSegment = activeTab.rawValue
        tabSegmented.target = self
        tabSegmented.action = #selector(onTabChanged)
        header.addSubview(tabSegmented)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Cerca comando o tasto (es. trim, ⌘, slip, RIPL DEL)..."
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(onSearchChanged)
        header.addSubview(searchField)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        // Interactive SVG Keyboard Stage (shown when activeTab == .keyboard)
        setupKeyboardStage()
        root.addSubview(keyboardStageView)

        // Interactive SVG Speed Editor Stage (shown when activeTab == .speedEditor)
        setupSpeedEditorStage()
        speedEditorStageView.isHidden = true
        root.addSubview(speedEditorStageView)

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
        contentStack.spacing = 14
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

        resetDefaultsBtn.translatesAutoresizingMaskIntoConstraints = false
        resetDefaultsBtn.target = self
        resetDefaultsBtn.action = #selector(onResetSpeedEditorDefaultsClicked)
        resetDefaultsBtn.isHidden = true
        footer.addSubview(resetDefaultsBtn)

        let closeBtn = FlatButton(title: "Chiudi", target: self, action: #selector(onCloseClicked))
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(closeBtn)

        let toKbdStage = scrollView.topAnchor.constraint(equalTo: keyboardStageView.bottomAnchor)
        let toSEStage = scrollView.topAnchor.constraint(equalTo: speedEditorStageView.bottomAnchor)
        toSEStage.isActive = false
        self.scrollTopToKeyboardStageConstraint = toKbdStage
        self.scrollTopToSpeedEditorStageConstraint = toSEStage

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            iconView.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            headerTitle.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            headerTitle.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),

            tabSegmented.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            tabSegmented.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),

            searchField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            searchField.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            keyboardStageView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            keyboardStageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            keyboardStageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            speedEditorStageView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            speedEditorStageView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            speedEditorStageView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            toKbdStage,
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 12),
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

            resetDefaultsBtn.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            resetDefaultsBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            resetDefaultsBtn.widthAnchor.constraint(equalToConstant: 210),
            resetDefaultsBtn.heightAnchor.constraint(equalToConstant: 26),

            closeBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            closeBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 84),
            closeBtn.heightAnchor.constraint(equalToConstant: 26)
        ])

        stateObserver = NotificationCenter.default.addObserver(
            forName: SpeedEditorManager.stateChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSpeedEditorLiveStatus()
        }

        installKeyboardMonitors()
        refreshKeyInspector()
        refreshSpeedEditorInspector()
        rebuildContent(query: "")
    }

    private func setupKeyboardStage() {
        keyboardStageView.translatesAutoresizingMaskIntoConstraints = false
        keyboardStageView.wantsLayer = true
        keyboardStageView.layer?.backgroundColor = NSColor(calibratedWhite: 0.068, alpha: 1.0).cgColor

        let filterBar = NSView()
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        keyboardStageView.addSubview(filterBar)

        modifierSegmented.translatesAutoresizingMaskIntoConstraints = false
        modifierSegmented.controlSize = .small
        modifierSegmented.selectedSegment = 0
        modifierSegmented.target = self
        modifierSegmented.action = #selector(onModifierFilterChanged)
        filterBar.addSubview(modifierSegmented)

        let legendStack = NSStackView()
        legendStack.orientation = .horizontal
        legendStack.spacing = 12
        legendStack.alignment = .centerY
        legendStack.translatesAutoresizingMaskIntoConstraints = false
        legendStack.addArrangedSubview(makeLegendItem(color: .systemCyan, text: "Tasto diretto"))
        legendStack.addArrangedSubview(makeLegendItem(color: .systemOrange, text: "Con modificatore"))
        filterBar.addSubview(legendStack)

        interactiveKeyboardView.translatesAutoresizingMaskIntoConstraints = false
        interactiveKeyboardView.onKeyClicked = { [weak self] keyId in
            guard let self = self else { return }
            self.selectedKeyId = (self.selectedKeyId == keyId) ? nil : keyId
            self.interactiveKeyboardView.selectedKeyId = self.selectedKeyId
            self.refreshKeyInspector()
            self.rebuildContent(query: self.searchField.stringValue)
        }
        interactiveKeyboardView.onModifierFilterToggled = { [weak self] modFilter in
            guard let self = self else { return }
            let next: KeyboardModifierFilter = (self.activeModifierFilter == modFilter) ? .all : modFilter
            self.applyModifierFilter(next)
        }
        keyboardStageView.addSubview(interactiveKeyboardView)

        inspectorCard.translatesAutoresizingMaskIntoConstraints = false
        inspectorCard.wantsLayer = true
        inspectorCard.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1.0).cgColor
        inspectorCard.layer?.borderColor = NSColor(calibratedWhite: 0.21, alpha: 1.0).cgColor
        inspectorCard.layer?.borderWidth = 1.0
        inspectorCard.layer?.cornerRadius = 7
        keyboardStageView.addSubview(inspectorCard)

        inspectorTitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        inspectorTitleLabel.textColor = .white
        inspectorTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        inspectorCard.addSubview(inspectorTitleLabel)

        clearKeyBtn.translatesAutoresizingMaskIntoConstraints = false
        clearKeyBtn.target = self
        clearKeyBtn.action = #selector(onClearKeySelectionClicked)
        clearKeyBtn.isHidden = true
        inspectorCard.addSubview(clearKeyBtn)

        inspectorBodyStack.orientation = .vertical
        inspectorBodyStack.alignment = .leading
        inspectorBodyStack.spacing = 4
        inspectorBodyStack.translatesAutoresizingMaskIntoConstraints = false
        inspectorCard.addSubview(inspectorBodyStack)

        stageDivider.boxType = .separator
        stageDivider.translatesAutoresizingMaskIntoConstraints = false
        keyboardStageView.addSubview(stageDivider)

        let aspect = interactiveKeyboardView.svgAspectRatio
        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: keyboardStageView.topAnchor, constant: 10),
            filterBar.leadingAnchor.constraint(equalTo: keyboardStageView.leadingAnchor, constant: 18),
            filterBar.trailingAnchor.constraint(equalTo: keyboardStageView.trailingAnchor, constant: -18),
            filterBar.heightAnchor.constraint(equalToConstant: 24),

            modifierSegmented.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor),
            modifierSegmented.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),

            legendStack.trailingAnchor.constraint(equalTo: filterBar.trailingAnchor),
            legendStack.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),

            interactiveKeyboardView.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 8),
            interactiveKeyboardView.leadingAnchor.constraint(equalTo: keyboardStageView.leadingAnchor, constant: 16),
            interactiveKeyboardView.trailingAnchor.constraint(equalTo: keyboardStageView.trailingAnchor, constant: -16),
            interactiveKeyboardView.heightAnchor.constraint(equalTo: interactiveKeyboardView.widthAnchor, multiplier: 1.0 / aspect),

            inspectorCard.topAnchor.constraint(equalTo: interactiveKeyboardView.bottomAnchor, constant: 8),
            inspectorCard.leadingAnchor.constraint(equalTo: keyboardStageView.leadingAnchor, constant: 16),
            inspectorCard.trailingAnchor.constraint(equalTo: keyboardStageView.trailingAnchor, constant: -16),

            inspectorTitleLabel.topAnchor.constraint(equalTo: inspectorCard.topAnchor, constant: 8),
            inspectorTitleLabel.leadingAnchor.constraint(equalTo: inspectorCard.leadingAnchor, constant: 12),
            inspectorTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearKeyBtn.leadingAnchor, constant: -8),

            clearKeyBtn.centerYAnchor.constraint(equalTo: inspectorTitleLabel.centerYAnchor),
            clearKeyBtn.trailingAnchor.constraint(equalTo: inspectorCard.trailingAnchor, constant: -10),
            clearKeyBtn.widthAnchor.constraint(equalToConstant: 88),
            clearKeyBtn.heightAnchor.constraint(equalToConstant: 20),

            inspectorBodyStack.topAnchor.constraint(equalTo: inspectorTitleLabel.bottomAnchor, constant: 6),
            inspectorBodyStack.leadingAnchor.constraint(equalTo: inspectorCard.leadingAnchor, constant: 12),
            inspectorBodyStack.trailingAnchor.constraint(equalTo: inspectorCard.trailingAnchor, constant: -12),
            inspectorBodyStack.bottomAnchor.constraint(equalTo: inspectorCard.bottomAnchor, constant: -8),

            stageDivider.topAnchor.constraint(equalTo: inspectorCard.bottomAnchor, constant: 10),
            stageDivider.leadingAnchor.constraint(equalTo: keyboardStageView.leadingAnchor),
            stageDivider.trailingAnchor.constraint(equalTo: keyboardStageView.trailingAnchor),
            stageDivider.bottomAnchor.constraint(equalTo: keyboardStageView.bottomAnchor)
        ])
    }

    private func makeLegendItem(color: NSColor, text: String) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        lbl.textColor = NSColor(calibratedWhite: 0.68, alpha: 1.0)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        wrap.addSubview(dot)
        wrap.addSubview(lbl)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            lbl.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            lbl.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            lbl.topAnchor.constraint(equalTo: wrap.topAnchor),
            lbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)
        ])
        return wrap
    }

    private func installKeyboardMonitors() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self, self.activeTab == .keyboard, event.window == self.view.window else { return event }
            let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
            self.interactiveKeyboardView.physicalPressedFlags = relevant
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.activeTab == .keyboard, event.window == self.view.window else { return event }
            // Keep typing inside the search field unobstructed unless it's not active
            if let fr = self.view.window?.firstResponder, fr is NSTextView {
                return event
            }
            if let keyId = KeyboardShortcutCatalog.keyId(for: event) {
                self.interactiveKeyboardView.physicalPressedKeyId = keyId
                if KeyboardShortcutCatalog.modifierRole(for: keyId) == nil {
                    self.selectedKeyId = keyId
                    self.interactiveKeyboardView.selectedKeyId = keyId
                    self.refreshKeyInspector()
                    self.rebuildContent(query: self.searchField.stringValue)
                }
            }
            return event
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self, self.activeTab == .keyboard, event.window == self.view.window else { return event }
            self.interactiveKeyboardView.physicalPressedKeyId = nil
            return event
        }
    }

    @objc private func onModifierFilterChanged() {
        let idx = modifierSegmented.selectedSegment
        guard idx >= 0 && idx < KeyboardModifierFilter.allCases.count else { return }
        applyModifierFilter(KeyboardModifierFilter.allCases[idx])
    }

    private func applyModifierFilter(_ filter: KeyboardModifierFilter) {
        activeModifierFilter = filter
        if let idx = KeyboardModifierFilter.allCases.firstIndex(of: filter) {
            modifierSegmented.selectedSegment = idx
        }
        interactiveKeyboardView.modifierFilter = filter
        refreshKeyInspector()
        rebuildContent(query: searchField.stringValue)
    }

    @objc private func onClearKeySelectionClicked() {
        selectedKeyId = nil
        interactiveKeyboardView.selectedKeyId = nil
        refreshKeyInspector()
        rebuildContent(query: searchField.stringValue)
    }

    private func refreshKeyInspector() {
        for v in inspectorBodyStack.arrangedSubviews {
            inspectorBodyStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        guard let keyId = selectedKeyId else {
            clearKeyBtn.isHidden = true
            inspectorTitleLabel.stringValue = "Clicca un tasto sulla tastiera per ispezionare i comandi assegnati (clicca ⌘ / ⌥ / ⌃ per filtrare)"
            inspectorTitleLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            let hintLbl = NSTextField(labelWithString: activeModifierFilter == .all
                ? "Suggerimento: tieni premuto ⌘, ⌥ o ⌃ sulla tastiera del Mac per illuminare le combinazioni in tempo reale."
                : "Filtro attivo: \(activeModifierFilter.rawValue) — clicca di nuovo il modificatore o scegli \"Tutti\" per vedere tutte le scorciatoie.")
            hintLbl.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            hintLbl.textColor = NSColor(calibratedWhite: 0.56, alpha: 1.0)
            inspectorBodyStack.addArrangedSubview(hintLbl)
            return
        }

        clearKeyBtn.isHidden = false
        let keyTitle = KeyboardShortcutCatalog.displayName(for: keyId)
        let matching = KeyboardShortcutCatalog.bindings(for: keyId, modifierFilter: activeModifierFilter)
        inspectorTitleLabel.stringValue = "Tasto selezionato: \(keyTitle)"
        inspectorTitleLabel.textColor = .systemCyan

        if matching.isEmpty {
            let noneLbl = NSTextField(labelWithString: activeModifierFilter == .all
                ? "Nessun comando Vision assegnato a questo tasto."
                : "Nessun comando assegnato a questo tasto con filtro \(activeModifierFilter.rawValue).")
            noneLbl.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
            noneLbl.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
            inspectorBodyStack.addArrangedSubview(noneLbl)
        } else {
            for binding in matching {
                let line = NSStackView()
                line.orientation = .horizontal
                line.spacing = 8
                line.alignment = .centerY

                let badge = NSView()
                badge.wantsLayer = true
                badge.layer?.backgroundColor = NSColor.systemCyan.withAlphaComponent(0.18).cgColor
                badge.layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.75).cgColor
                badge.layer?.borderWidth = 1.0
                badge.layer?.cornerRadius = 4
                badge.translatesAutoresizingMaskIntoConstraints = false

                let badgeLbl = NSTextField(labelWithString: binding.keysLabel)
                badgeLbl.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
                badgeLbl.textColor = .white
                badgeLbl.translatesAutoresizingMaskIntoConstraints = false
                badge.addSubview(badgeLbl)
                NSLayoutConstraint.activate([
                    badge.heightAnchor.constraint(equalToConstant: 19),
                    badgeLbl.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
                    badgeLbl.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
                    badgeLbl.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
                ])

                let descLbl = NSTextField(labelWithString: "\(binding.description)  •  \(binding.section.capitalized)")
                descLbl.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
                descLbl.textColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
                line.addArrangedSubview(badge)
                line.addArrangedSubview(descLbl)
                inspectorBodyStack.addArrangedSubview(line)
            }
        }
    }

    private func setupSpeedEditorStage() {
        speedEditorStageView.translatesAutoresizingMaskIntoConstraints = false
        speedEditorStageView.wantsLayer = true
        speedEditorStageView.layer?.backgroundColor = NSColor(calibratedWhite: 0.068, alpha: 1.0).cgColor

        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        speedEditorStageView.addSubview(topBar)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(dot)
        self.statusDotRef = dot

        let stLabel = NSTextField(labelWithString: SpeedEditorManager.shared.connectionStatusText)
        stLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        stLabel.textColor = .white
        stLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(stLabel)
        self.statusLabelRef = stLabel

        let lastLabel = NSTextField(labelWithString: "")
        lastLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        lastLabel.textColor = .systemCyan
        lastLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(lastLabel)
        self.lastKeyLabelRef = lastLabel

        let legendStack = NSStackView()
        legendStack.orientation = .horizontal
        legendStack.spacing = 12
        legendStack.alignment = .centerY
        legendStack.translatesAutoresizingMaskIntoConstraints = false
        legendStack.addArrangedSubview(makeLegendItem(color: .systemCyan, text: "Tap singolo"))
        legendStack.addArrangedSubview(makeLegendItem(color: .systemOrange, text: "Double Tap"))
        topBar.addSubview(legendStack)

        interactiveSpeedEditorView.translatesAutoresizingMaskIntoConstraints = false
        interactiveSpeedEditorView.onElementSelected = { [weak self] elemId in
            guard let self = self else { return }
            self.selectedSpeedEditorElementId = (self.selectedSpeedEditorElementId == elemId) ? nil : elemId
            self.interactiveSpeedEditorView.selectedElementId = self.selectedSpeedEditorElementId
            self.refreshSpeedEditorInspector()
            self.rebuildContent(query: self.searchField.stringValue)
        }
        speedEditorStageView.addSubview(interactiveSpeedEditorView)

        seInspectorCard.translatesAutoresizingMaskIntoConstraints = false
        seInspectorCard.wantsLayer = true
        seInspectorCard.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1.0).cgColor
        seInspectorCard.layer?.borderColor = NSColor(calibratedWhite: 0.21, alpha: 1.0).cgColor
        seInspectorCard.layer?.borderWidth = 1.0
        seInspectorCard.layer?.cornerRadius = 7
        speedEditorStageView.addSubview(seInspectorCard)

        seInspectorTitleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        seInspectorTitleLabel.textColor = .white
        seInspectorTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        seInspectorCard.addSubview(seInspectorTitleLabel)

        seClearBtn.translatesAutoresizingMaskIntoConstraints = false
        seClearBtn.target = self
        seClearBtn.action = #selector(onClearSpeedEditorSelectionClicked)
        seClearBtn.isHidden = true
        seInspectorCard.addSubview(seClearBtn)

        seInspectorBodyStack.orientation = .vertical
        seInspectorBodyStack.alignment = .leading
        seInspectorBodyStack.spacing = 6
        seInspectorBodyStack.translatesAutoresizingMaskIntoConstraints = false
        seInspectorCard.addSubview(seInspectorBodyStack)

        seStageDivider.boxType = .separator
        seStageDivider.translatesAutoresizingMaskIntoConstraints = false
        speedEditorStageView.addSubview(seStageDivider)

        let aspect = interactiveSpeedEditorView.svgAspectRatio
        let prefWidthConstraint = interactiveSpeedEditorView.widthAnchor.constraint(equalToConstant: 500)
        prefWidthConstraint.priority = .defaultLow

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: speedEditorStageView.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: speedEditorStageView.leadingAnchor, constant: 18),
            topBar.trailingAnchor.constraint(equalTo: speedEditorStageView.trailingAnchor, constant: -18),
            topBar.heightAnchor.constraint(equalToConstant: 22),

            dot.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),

            stLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            stLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            lastLabel.leadingAnchor.constraint(equalTo: stLabel.trailingAnchor, constant: 12),
            lastLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            lastLabel.trailingAnchor.constraint(lessThanOrEqualTo: legendStack.leadingAnchor, constant: -12),

            legendStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            legendStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            interactiveSpeedEditorView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            interactiveSpeedEditorView.centerXAnchor.constraint(equalTo: speedEditorStageView.centerXAnchor),
            interactiveSpeedEditorView.leadingAnchor.constraint(greaterThanOrEqualTo: speedEditorStageView.leadingAnchor, constant: 16),
            interactiveSpeedEditorView.trailingAnchor.constraint(lessThanOrEqualTo: speedEditorStageView.trailingAnchor, constant: -16),
            interactiveSpeedEditorView.heightAnchor.constraint(lessThanOrEqualToConstant: 315),
            interactiveSpeedEditorView.heightAnchor.constraint(equalTo: interactiveSpeedEditorView.widthAnchor, multiplier: 1.0 / aspect),
            prefWidthConstraint,

            seInspectorCard.topAnchor.constraint(equalTo: interactiveSpeedEditorView.bottomAnchor, constant: 8),
            seInspectorCard.leadingAnchor.constraint(equalTo: speedEditorStageView.leadingAnchor, constant: 16),
            seInspectorCard.trailingAnchor.constraint(equalTo: speedEditorStageView.trailingAnchor, constant: -16),

            seInspectorTitleLabel.topAnchor.constraint(equalTo: seInspectorCard.topAnchor, constant: 8),
            seInspectorTitleLabel.leadingAnchor.constraint(equalTo: seInspectorCard.leadingAnchor, constant: 12),
            seInspectorTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: seClearBtn.leadingAnchor, constant: -8),

            seClearBtn.centerYAnchor.constraint(equalTo: seInspectorTitleLabel.centerYAnchor),
            seClearBtn.trailingAnchor.constraint(equalTo: seInspectorCard.trailingAnchor, constant: -10),
            seClearBtn.widthAnchor.constraint(equalToConstant: 88),
            seClearBtn.heightAnchor.constraint(equalToConstant: 20),

            seInspectorBodyStack.topAnchor.constraint(equalTo: seInspectorTitleLabel.bottomAnchor, constant: 6),
            seInspectorBodyStack.leadingAnchor.constraint(equalTo: seInspectorCard.leadingAnchor, constant: 12),
            seInspectorBodyStack.trailingAnchor.constraint(equalTo: seInspectorCard.trailingAnchor, constant: -12),
            seInspectorBodyStack.bottomAnchor.constraint(equalTo: seInspectorCard.bottomAnchor, constant: -8),

            seStageDivider.topAnchor.constraint(equalTo: seInspectorCard.bottomAnchor, constant: 8),
            seStageDivider.leadingAnchor.constraint(equalTo: speedEditorStageView.leadingAnchor),
            seStageDivider.trailingAnchor.constraint(equalTo: speedEditorStageView.trailingAnchor),
            seStageDivider.bottomAnchor.constraint(equalTo: speedEditorStageView.bottomAnchor)
        ])
    }

    @objc private func onClearSpeedEditorSelectionClicked() {
        selectedSpeedEditorElementId = nil
        interactiveSpeedEditorView.selectedElementId = nil
        refreshSpeedEditorInspector()
        rebuildContent(query: searchField.stringValue)
    }

    private func makeActionPopUp(for button: SpeedEditorButton, isDoubleTap: Bool) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
        popup.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        popup.tag = Int(button.rawValue)
        popup.target = self
        popup.action = isDoubleTap ? #selector(onSpeedEditorDoubleTapActionChanged(_:)) : #selector(onSpeedEditorActionChanged(_:))

        let mgr = SpeedEditorManager.shared
        let current = isDoubleTap ? mgr.doubleTapAction(for: button) : mgr.action(for: button)
        var selectedIdx = 0
        for (idx, act) in VisionCommandAction.allCases.enumerated() {
            popup.addItem(withTitle: act.displayTitle)
            popup.lastItem?.representedObject = act.rawValue
            if act == current {
                selectedIdx = idx
            }
        }
        popup.selectItem(at: selectedIdx)
        return popup
    }

    private func makeWheelControlsRow(compact: Bool) -> NSStackView {
        let mgr = SpeedEditorManager.shared
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = compact ? 10 : 12
        row.alignment = .centerY

        let modeLbl = NSTextField(labelWithString: compact ? "Search Dial:" : "Modalità:")
        modeLbl.font = NSFont.systemFont(ofSize: compact ? 11 : 11.5, weight: .medium)
        modeLbl.textColor = NSColor(calibratedWhite: compact ? 0.68 : 0.78, alpha: 1.0)

        let wheelSeg = NSSegmentedControl(
            labels: compact ? ["JOG", "SHTL", "SCRL"] : ["JOG (Frame)", "SHTL (Shuttle)", "SCRL (Scroll)"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onWheelModeSegmentChanged(_:))
        )
        wheelSeg.controlSize = .small
        switch mgr.currentWheelMode {
        case .jog: wheelSeg.selectedSegment = 0
        case .shuttle: wheelSeg.selectedSegment = 1
        case .scroll: wheelSeg.selectedSegment = 2
        }

        let sensLbl = NSTextField(labelWithString: "Sensibilità:")
        sensLbl.font = NSFont.systemFont(ofSize: compact ? 11 : 11.5, weight: .medium)
        sensLbl.textColor = NSColor(calibratedWhite: compact ? 0.68 : 0.78, alpha: 1.0)

        let sensSlider = NSSlider(
            value: mgr.wheelSensitivity,
            minValue: 0.1,
            maxValue: 4.0,
            target: self,
            action: #selector(onWheelSensitivityChanged(_:))
        )
        sensSlider.controlSize = .small
        sensSlider.isContinuous = true
        sensSlider.widthAnchor.constraint(equalToConstant: compact ? 140 : 170).isActive = true

        let valLbl = NSTextField(labelWithString: String(format: "%.1fx", mgr.wheelSensitivity))
        valLbl.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        valLbl.textColor = .systemCyan
        valLbl.alignment = .left
        valLbl.widthAnchor.constraint(equalToConstant: 36).isActive = true
        self.wheelSensValueLabelRef = valLbl

        row.addArrangedSubview(modeLbl)
        row.addArrangedSubview(wheelSeg)
        row.addArrangedSubview(sensLbl)
        row.addArrangedSubview(sensSlider)
        row.addArrangedSubview(valLbl)
        return row
    }

    private func refreshSpeedEditorInspector() {
        for v in seInspectorBodyStack.arrangedSubviews {
            seInspectorBodyStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        guard let elemId = selectedSpeedEditorElementId else {
            seClearBtn.isHidden = true
            seInspectorTitleLabel.stringValue = "Clicca un tasto o la ghiera sullo Speed Editor per mappare Tap singolo e Double Tap"
            seInspectorTitleLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            seInspectorBodyStack.addArrangedSubview(makeWheelControlsRow(compact: true))
            return
        }

        seClearBtn.isHidden = false

        if elemId == InteractiveSpeedEditorView.searchDialSVGId {
            seInspectorTitleLabel.stringValue = "Search Dial (Ghiera Jog / Shuttle / Scroll)"
            seInspectorTitleLabel.textColor = .systemCyan
            seInspectorBodyStack.addArrangedSubview(makeWheelControlsRow(compact: false))
            return
        }

        guard let btn = SpeedEditorButton.fromSVGId(elemId) else { return }
        var title = "Tasto Speed Editor: \(btn.label)"
        if let sec = btn.secondaryHardwareLabel {
            title += "   (etichetta hardware 2ª funzione: \(sec))"
        }
        seInspectorTitleLabel.stringValue = title
        seInspectorTitleLabel.textColor = .systemCyan

        let controlsRow = NSStackView()
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 12
        controlsRow.alignment = .centerY
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        let tapLbl = NSTextField(labelWithString: "Tap singolo:")
        tapLbl.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        tapLbl.textColor = .systemCyan
        let tapPopup = makeActionPopUp(for: btn, isDoubleTap: false)
        tapPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let dtLbl = NSTextField(labelWithString: "Double Tap:")
        dtLbl.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        dtLbl.textColor = .systemOrange
        let dtPopup = makeActionPopUp(for: btn, isDoubleTap: true)
        dtPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        controlsRow.addArrangedSubview(tapLbl)
        controlsRow.addArrangedSubview(tapPopup)
        controlsRow.addArrangedSubview(dtLbl)
        controlsRow.addArrangedSubview(dtPopup)
        seInspectorBodyStack.addArrangedSubview(controlsRow)
        controlsRow.widthAnchor.constraint(equalTo: seInspectorBodyStack.widthAnchor).isActive = true
    }

    @objc private func onTabChanged() {
        if let selected = DialogTab(rawValue: tabSegmented.selectedSegment) {
            activeTab = selected
        }
        let isKeyboard = (activeTab == .keyboard)
        keyboardStageView.isHidden = !isKeyboard
        speedEditorStageView.isHidden = isKeyboard
        scrollTopToKeyboardStageConstraint?.isActive = isKeyboard
        scrollTopToSpeedEditorStageConstraint?.isActive = !isKeyboard
        resetDefaultsBtn.isHidden = isKeyboard
        if !isKeyboard {
            refreshSpeedEditorLiveStatus()
            refreshSpeedEditorInspector()
            let mgr = SpeedEditorManager.shared
            DebugLogger.shared.log("[SPEED-UI] Tab Speed Editor aperto | mode=\(mgr.currentWheelMode.rawValue) sens=\(String(format: "%.2fx", mgr.wheelSensitivity)) connected=\(mgr.isConnected) auth=\(mgr.isAuthenticated)", level: .info)
        }
        rebuildContent(query: searchField.stringValue)
    }

    public func switchToTab(_ index: Int) {
        tabSegmented.selectedSegment = index
        onTabChanged()
    }

    public func selectSpeedEditorElement(_ svgId: String?) {
        selectedSpeedEditorElementId = svgId
        interactiveSpeedEditorView.selectedElementId = svgId
        refreshSpeedEditorInspector()
        rebuildContent(query: searchField.stringValue)
    }

    public var speedEditorDiagramView: InteractiveSpeedEditorView {
        interactiveSpeedEditorView
    }

    public func selectKeyForInspection(_ keyId: String?) {
        selectedKeyId = keyId
        interactiveKeyboardView.selectedKeyId = keyId
        refreshKeyInspector()
        rebuildContent(query: searchField.stringValue)
    }

    public var keyboardDiagramView: InteractiveKeyboardView {
        interactiveKeyboardView
    }

    public func controlTextDidChange(_ obj: Notification) {
        let q = searchField.stringValue
        if !q.isEmpty && selectedKeyId != nil {
            selectedKeyId = nil
            interactiveKeyboardView.selectedKeyId = nil
            refreshKeyInspector()
        }
        if !q.isEmpty && selectedSpeedEditorElementId != nil {
            selectedSpeedEditorElementId = nil
            interactiveSpeedEditorView.selectedElementId = nil
            refreshSpeedEditorInspector()
        }
        interactiveKeyboardView.searchQuery = q
        interactiveSpeedEditorView.searchQuery = q
        rebuildContent(query: q)
    }

    @objc private func onSearchChanged() {
        let q = searchField.stringValue
        if !q.isEmpty && selectedKeyId != nil {
            selectedKeyId = nil
            interactiveKeyboardView.selectedKeyId = nil
            refreshKeyInspector()
        }
        if !q.isEmpty && selectedSpeedEditorElementId != nil {
            selectedSpeedEditorElementId = nil
            interactiveSpeedEditorView.selectedElementId = nil
            refreshSpeedEditorInspector()
        }
        interactiveKeyboardView.searchQuery = q
        interactiveSpeedEditorView.searchQuery = q
        rebuildContent(query: q)
    }

    private func rebuildContent(query: String) {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowBadgesByButton.removeAll()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch activeTab {
        case .keyboard:
            buildKeyboardTabContent(query: trimmed)
        case .speedEditor:
            buildSpeedEditorTabContent(query: trimmed)
        }

        emptyLabel.isHidden = !contentStack.arrangedSubviews.isEmpty
    }

    // MARK: - Keyboard Shortcuts Tab

    private func buildKeyboardTabContent(query: String) {
        for sectionTitle in KeyboardShortcutCatalog.orderedSections {
            let matchingBindings = KeyboardShortcutCatalog.bindings.filter { binding in
                guard binding.section == sectionTitle else { return false }
                guard binding.matches(modifierFilter: activeModifierFilter) else { return false }
                if let selKey = selectedKeyId, !binding.primaryKeyIds.contains(selKey) {
                    return false
                }
                return binding.matches(query: query)
            }

            guard !matchingBindings.isEmpty else { continue }

            let sectionStack = NSStackView()
            sectionStack.orientation = .vertical
            sectionStack.alignment = .leading
            sectionStack.spacing = 6
            sectionStack.translatesAutoresizingMaskIntoConstraints = false

            let secLabel = NSTextField(labelWithString: sectionTitle)
            secLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            secLabel.textColor = .systemCyan
            sectionStack.addArrangedSubview(secLabel)

            for binding in matchingBindings {
                let row = makeShortcutBindingRow(binding)
                sectionStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
            }

            contentStack.addArrangedSubview(sectionStack)
            sectionStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    // MARK: - DaVinci Resolve Speed Editor Mapping Tab

    private func buildSpeedEditorTabContent(query: String) {
        let mgr = SpeedEditorManager.shared
        let selectedButton = selectedSpeedEditorElementId.flatMap { SpeedEditorButton.fromSVGId($0) }

        let orderedGroups = [
            "Trasporto & Search Dial",
            "Taglio, Trim & Slip",
            "Inserimento & Transizioni",
            "Camera, Modalità & Controlli"
        ]

        // Table Header Row
        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        let hKey = NSTextField(labelWithString: "TASTO HARDWARE")
        let hTap = NSTextField(labelWithString: "TAP SINGOLO")
        let hDouble = NSTextField(labelWithString: "DOUBLE TAP")
        for lbl in [hKey, hTap, hDouble] {
            lbl.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
            lbl.textColor = NSColor(calibratedWhite: 0.52, alpha: 1.0)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addSubview(lbl)
        }
        NSLayoutConstraint.activate([
            headerRow.heightAnchor.constraint(equalToConstant: 16),
            hKey.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            hKey.widthAnchor.constraint(equalToConstant: 146),
            hKey.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            hTap.leadingAnchor.constraint(equalTo: hKey.trailingAnchor, constant: 10),
            hTap.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            hDouble.leadingAnchor.constraint(equalTo: hTap.trailingAnchor, constant: 10),
            hDouble.widthAnchor.constraint(equalTo: hTap.widthAnchor),
            hDouble.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            hDouble.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor)
        ])

        var addedHeader = false

        for group in orderedGroups {
            let groupButtons = SpeedEditorButton.allCases.filter { btn in
                guard btn.groupTitle == group else { return false }
                if let selBtn = selectedButton, selBtn != btn { return false }
                if query.isEmpty || group.lowercased().contains(query) { return true }
                let tapTitle = mgr.action(for: btn).displayTitle.lowercased()
                let dtTitle = mgr.doubleTapAction(for: btn).displayTitle.lowercased()
                let secLbl = btn.secondaryHardwareLabel?.lowercased() ?? ""
                return btn.label.lowercased().contains(query)
                    || secLbl.contains(query)
                    || tapTitle.contains(query)
                    || dtTitle.contains(query)
            }
            guard !groupButtons.isEmpty else { continue }

            if !addedHeader {
                contentStack.addArrangedSubview(headerRow)
                headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
                addedHeader = true
            }

            let secStack = NSStackView()
            secStack.orientation = .vertical
            secStack.alignment = .leading
            secStack.spacing = 6
            secStack.translatesAutoresizingMaskIntoConstraints = false

            let secLabel = NSTextField(labelWithString: group.uppercased())
            secLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            secLabel.textColor = .systemCyan
            secStack.addArrangedSubview(secLabel)

            for btn in groupButtons {
                let row = makeSpeedEditorMappingRow(btn)
                secStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: secStack.widthAnchor).isActive = true
            }

            contentStack.addArrangedSubview(secStack)
            secStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func makeSpeedEditorMappingRow(_ button: SpeedEditorButton) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let badge = ClickableShortcutRowView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.borderWidth = 1.0
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.onClick = { [weak self] in
            guard let self = self else { return }
            self.selectedSpeedEditorElementId = button.svgId
            self.interactiveSpeedEditorView.selectedElementId = button.svgId
            self.refreshSpeedEditorInspector()
            self.rebuildContent(query: self.searchField.stringValue)
        }
        rowBadgesByButton[button] = badge
        let isSelectedOrLit = (highlightedButton == button) || (selectedSpeedEditorElementId == button.svgId)
        styleHardwareBadge(badge, isHighlighted: isSelectedOrLit)

        let labelText = button.secondaryHardwareLabel != nil
            ? "\(button.label) · \(button.secondaryHardwareLabel!)"
            : button.label
        let badgeLabel = NSTextField(labelWithString: labelText)
        badgeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.lineBreakMode = .byTruncatingTail
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)

        let tapPopup = makeActionPopUp(for: button, isDoubleTap: false)
        let dtPopup = makeActionPopUp(for: button, isDoubleTap: true)

        row.addSubview(badge)
        row.addSubview(tapPopup)
        row.addSubview(dtPopup)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 26),

            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 146),
            badge.heightAnchor.constraint(equalToConstant: 22),

            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: badge.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.trailingAnchor, constant: -6),

            tapPopup.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            tapPopup.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            dtPopup.leadingAnchor.constraint(equalTo: tapPopup.trailingAnchor, constant: 10),
            dtPopup.widthAnchor.constraint(equalTo: tapPopup.widthAnchor),
            dtPopup.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            dtPopup.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        return row
    }

    private func styleHardwareBadge(_ badge: NSView, isHighlighted: Bool) {
        if isHighlighted {
            badge.layer?.backgroundColor = NSColor.systemCyan.withAlphaComponent(0.28).cgColor
            badge.layer?.borderColor = NSColor.systemCyan.cgColor
        } else {
            badge.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor
            badge.layer?.borderColor = NSColor(calibratedWhite: 0.25, alpha: 1.0).cgColor
        }
    }

    private func refreshSpeedEditorLiveStatus() {
        let mgr = SpeedEditorManager.shared
        statusLabelRef?.stringValue = mgr.connectionStatusText
        statusDotRef?.layer?.backgroundColor = (mgr.isConnected && mgr.isAuthenticated)
            ? NSColor.systemGreen.cgColor
            : (mgr.isConnected ? NSColor.systemOrange.cgColor : NSColor(calibratedWhite: 0.45, alpha: 1.0).cgColor)

        if let lastBtn = mgr.lastPressedButton {
            highlightedButton = lastBtn
            let modeTag = mgr.lastPressWasDoubleTap ? " (Double Tap)" : ""
            let executed = mgr.lastPressWasDoubleTap ? mgr.doubleTapAction(for: lastBtn) : mgr.action(for: lastBtn)
            lastKeyLabelRef?.stringValue = "Ultimo tasto: \(lastBtn.label)\(modeTag) → \(executed.displayTitle)"
            for (btn, badge) in rowBadgesByButton {
                let lit = (btn == lastBtn) || (selectedSpeedEditorElementId == btn.svgId)
                styleHardwareBadge(badge, isHighlighted: lit)
            }
        } else {
            lastKeyLabelRef?.stringValue = "Premi un tasto sullo Speed Editor o selezionalo sopra"
        }

        interactiveSpeedEditorView.highlightedButton = mgr.lastPressedButton
        interactiveSpeedEditorView.needsDisplay = true
        if activeTab == .speedEditor {
            refreshSpeedEditorInspector()
        }
    }

    @objc private func onSpeedEditorActionChanged(_ sender: NSPopUpButton) {
        guard let rawCode = UInt16(exactly: sender.tag),
              let btn = SpeedEditorButton(rawValue: rawCode),
              let rawAct = sender.selectedItem?.representedObject as? String,
              let act = VisionCommandAction(rawValue: rawAct) else { return }
        SpeedEditorManager.shared.setAction(act, for: btn)
        rebuildContent(query: searchField.stringValue)
    }

    @objc private func onSpeedEditorDoubleTapActionChanged(_ sender: NSPopUpButton) {
        guard let rawCode = UInt16(exactly: sender.tag),
              let btn = SpeedEditorButton(rawValue: rawCode),
              let rawAct = sender.selectedItem?.representedObject as? String,
              let act = VisionCommandAction(rawValue: rawAct) else { return }
        SpeedEditorManager.shared.setDoubleTapAction(act, for: btn)
        rebuildContent(query: searchField.stringValue)
    }

    @objc private func onWheelModeSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: SpeedEditorManager.shared.setWheelMode(.jog)
        case 1: SpeedEditorManager.shared.setWheelMode(.shuttle)
        case 2: SpeedEditorManager.shared.setWheelMode(.scroll)
        default: break
        }
    }

    @objc private func onWheelSensitivityChanged(_ sender: NSSlider) {
        let clamped = max(0.1, min(4.0, sender.doubleValue))
        SpeedEditorManager.shared.wheelSensitivity = clamped
        wheelSensValueLabelRef?.stringValue = String(format: "%.1fx", clamped)
        DebugLogger.shared.log("[SPEED-UI] Slider sensibilità -> \(String(format: "%.2fx", clamped)) (rawSlider=\(String(format: "%.3f", sender.doubleValue)))", level: .info)
    }

    @objc private func onResetSpeedEditorDefaultsClicked() {
        SpeedEditorManager.shared.resetMappingsToDefaults()
        refreshSpeedEditorInspector()
        rebuildContent(query: searchField.stringValue)
    }

    private func makeShortcutBindingRow(_ binding: KeyboardShortcutBinding) -> NSView {
        let row = ClickableShortcutRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let isHighlighted = (selectedKeyId != nil && binding.primaryKeyIds.contains(selectedKeyId!))
        row.setHighlighted(isHighlighted)
        row.onClick = { [weak self] in
            guard let self = self, let primaryKey = binding.primaryKeyIds.first else { return }
            self.selectedKeyId = primaryKey
            self.interactiveKeyboardView.selectedKeyId = primaryKey
            self.refreshKeyInspector()
            self.rebuildContent(query: self.searchField.stringValue)
        }

        let descLabel = NSTextField(labelWithString: binding.description)
        descLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        descLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        let badgeContainer = NSView()
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor
        badgeContainer.layer?.borderColor = (isHighlighted ? NSColor.systemCyan : NSColor(calibratedWhite: 0.24, alpha: 1.0)).cgColor
        badgeContainer.layer?.borderWidth = 1.0
        badgeContainer.layer?.cornerRadius = 4
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: binding.keysLabel)
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        keyLabel.textColor = .white
        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(keyLabel)

        row.addSubview(descLabel)
        row.addSubview(badgeContainer)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),

            badgeContainer.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            badgeContainer.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badgeContainer.heightAnchor.constraint(equalToConstant: 21),

            keyLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 7),
            keyLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -7),
            keyLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),

            descLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
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

private final class ClickableShortcutRowView: NSView {
    var onClick: (() -> Void)?
    private var trackingRef: NSTrackingArea?
    private var highlighted: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setHighlighted(_ flag: Bool) {
        highlighted = flag
        layer?.backgroundColor = flag ? NSColor.systemCyan.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
        if !highlighted {
            layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1.0).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        setHighlighted(highlighted)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
