import AppKit

public enum GridCardItem: Equatable {
    case timeline(TimelineModel, index: Int)
    case selection(SelectionModel, index: Int)
    case folder(MediaFolder)
    case media(MediaItem)

    public static func == (lhs: GridCardItem, rhs: GridCardItem) -> Bool {
        switch (lhs, rhs) {
        case (.timeline(let t1, _), .timeline(let t2, _)):
            return t1.id == t2.id
        case (.selection(let s1, _), .selection(let s2, _)):
            return s1.id == s2.id
        case (.folder(let f1), .folder(let f2)):
            return f1.id == f2.id
        case (.media(let m1), .media(let m2)):
            return m1.id == m2.id
        default:
            return false
        }
    }

    public var id: UUID {
        switch self {
        case .timeline(let t, _): return t.id
        case .selection(let s, _): return s.id
        case .folder(let f): return f.id
        case .media(let m): return m.id
        }
    }
}

public final class MediaThumbnailCardView: NSView, NSDraggingSource {
    public let gridItem: GridCardItem
    public var sequenceNumber: Int = 1 {
        didSet {
            seqBadgeLabel.stringValue = "#\(sequenceNumber)"
        }
    }
    public var isSelected: Bool = false {
        didSet {
            updateBorder()
        }
    }

    public var onDoubleClicked: (() -> Void)?
    public var onSelected: ((NSEvent.ModifierFlags) -> Void)?
    public var onOrientationChanged: ((ClipOrientation) -> Void)?
    public var onMoveToFolder: ((UUID?) -> Void)?
    public var getAllSelectedItems: (() -> [MediaItem])?
    public var onInsertToTimeline: (() -> Void)?
    public var onDeleteFromPool: (() -> Void)?
    public var onOpenTimeline: ((TimelineModel, Int) -> Void)?
    public var onRenameTimeline: ((Int) -> Void)?
    public var onTimelineSettings: ((TimelineModel, Int) -> Void)?
    public var onDeleteTimeline: ((Int) -> Void)?
    public var onOpenSelection: ((SelectionModel, Int) -> Void)?
    public var onRenameSelection: ((SelectionModel) -> Void)?
    public var onDuplicateSelection: ((SelectionModel) -> Void)?
    public var onDeleteSelection: ((SelectionModel) -> Void)?
    public var onOpenFolder: ((MediaFolder) -> Void)?
    public var onRenameFolder: ((MediaFolder) -> Void)?
    public var onDeleteFolder: ((MediaFolder) -> Void)?
    public var onDropItemsIntoFolder: (([UUID], UUID) -> Void)?

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let durBadgeLabel = NSTextField(labelWithString: "")
    private let seqBadgeLabel = NSTextField(labelWithString: "#1")
    private let proxyBadgeBg = NSView()
    private let proxyBadgeLabel = NSTextField(labelWithString: "⚡ PROXY")
    private var isFolderDropTarget: Bool = false
    private var mouseDownLocation: NSPoint = .zero
    private var didMouseDownOnAlreadySelected: Bool = false

    public init(gridItem: GridCardItem, sequenceNumber: Int = 1) {
        self.gridItem = gridItem
        self.sequenceNumber = sequenceNumber
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
        layer?.cornerRadius = 6
        updateBorder()

        if case .folder = gridItem {
            registerForDraggedTypes([kMediaItemPasteboardType, .fileURL])
        }

        // Thumbnail / Icon Image
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        // Sequence Number Badge (#1, #2...) top-left
        let seqBadgeBg = NSView()
        seqBadgeBg.translatesAutoresizingMaskIntoConstraints = false
        seqBadgeBg.wantsLayer = true
        seqBadgeBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        seqBadgeBg.layer?.cornerRadius = 3
        addSubview(seqBadgeBg)

        seqBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        seqBadgeLabel.stringValue = "#\(sequenceNumber)"
        seqBadgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        seqBadgeLabel.textColor = .systemYellow
        seqBadgeBg.addSubview(seqBadgeLabel)

        // Duration / Subtitle Badge top-right
        let durBadgeBg = NSView()
        durBadgeBg.translatesAutoresizingMaskIntoConstraints = false
        durBadgeBg.wantsLayer = true
        durBadgeBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        durBadgeBg.layer?.cornerRadius = 3
        addSubview(durBadgeBg)

        durBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        durBadgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        durBadgeLabel.textColor = .white
        durBadgeBg.addSubview(durBadgeLabel)

        // Proxy Badge bottom-left of image
        proxyBadgeBg.translatesAutoresizingMaskIntoConstraints = false
        proxyBadgeBg.wantsLayer = true
        proxyBadgeBg.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.85).cgColor
        proxyBadgeBg.layer?.cornerRadius = 3
        proxyBadgeBg.isHidden = true
        addSubview(proxyBadgeBg)

        proxyBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        proxyBadgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .heavy)
        proxyBadgeLabel.textColor = .black
        proxyBadgeBg.addSubview(proxyBadgeLabel)

        // Title Label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            imageView.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -4),

            seqBadgeBg.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 4),
            seqBadgeBg.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 4),
            seqBadgeBg.heightAnchor.constraint(equalToConstant: 16),

            seqBadgeLabel.leadingAnchor.constraint(equalTo: seqBadgeBg.leadingAnchor, constant: 4),
            seqBadgeLabel.trailingAnchor.constraint(equalTo: seqBadgeBg.trailingAnchor, constant: -4),
            seqBadgeLabel.centerYAnchor.constraint(equalTo: seqBadgeBg.centerYAnchor),

            durBadgeBg.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -4),
            durBadgeBg.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 4),
            durBadgeBg.heightAnchor.constraint(equalToConstant: 16),

            durBadgeLabel.leadingAnchor.constraint(equalTo: durBadgeBg.leadingAnchor, constant: 4),
            durBadgeLabel.trailingAnchor.constraint(equalTo: durBadgeBg.trailingAnchor, constant: -4),
            durBadgeLabel.centerYAnchor.constraint(equalTo: durBadgeBg.centerYAnchor),

            proxyBadgeBg.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 4),
            proxyBadgeBg.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -4),
            proxyBadgeBg.heightAnchor.constraint(equalToConstant: 14),

            proxyBadgeLabel.leadingAnchor.constraint(equalTo: proxyBadgeBg.leadingAnchor, constant: 3),
            proxyBadgeLabel.trailingAnchor.constraint(equalTo: proxyBadgeBg.trailingAnchor, constant: -3),
            proxyBadgeLabel.centerYAnchor.constraint(equalTo: proxyBadgeBg.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            titleLabel.heightAnchor.constraint(equalToConstant: 16)
        ])

        configureContent()
    }

    private func updateBorder() {
        if isFolderDropTarget {
            layer?.borderColor = NSColor.systemOrange.cgColor
            layer?.borderWidth = 2.5
        } else if isSelected {
            layer?.borderColor = NSColor.systemCyan.cgColor
            layer?.borderWidth = 2.5
        } else {
            layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 1.0).cgColor
            layer?.borderWidth = 1.0
        }
    }

    private func configureContent() {
        switch gridItem {
        case .timeline(let tl, _):
            imageView.image = Lucide.image(.clapperboard, size: 40, color: .systemCyan)
            titleLabel.stringValue = tl.name
            titleLabel.textColor = .systemCyan
            durBadgeLabel.stringValue = "\(Int(tl.format.size.width))×\(Int(tl.format.size.height))"
            seqBadgeLabel.stringValue = "TL"
            proxyBadgeBg.isHidden = true

        case .selection(let sel, _):
            imageView.image = Lucide.image(.sparkles, size: 38, color: .systemPurple)
            titleLabel.stringValue = sel.name
            titleLabel.textColor = .systemPurple
            durBadgeLabel.stringValue = "\(sel.selectedClips.count) clip"
            seqBadgeLabel.stringValue = "SEL"
            proxyBadgeBg.isHidden = true

        case .folder(let f):
            imageView.image = Lucide.image(.folder, size: 40, color: .systemOrange)
            titleLabel.stringValue = f.name
            titleLabel.textColor = .systemOrange
            durBadgeLabel.stringValue = "\(f.itemIds.count) el."
            seqBadgeLabel.stringValue = "DIR"
            proxyBadgeBg.isHidden = true

        case .media(let m):
            titleLabel.stringValue = m.name
            titleLabel.textColor = .labelColor
            durBadgeLabel.stringValue = m.formattedDuration
            seqBadgeLabel.stringValue = "#\(sequenceNumber)"
            proxyBadgeBg.isHidden = !m.hasProxy

            if let thumb = m.thumbnail {
                imageView.image = thumb
            } else {
                imageView.image = Lucide.image(m.hasVideo ? .film : .music, size: 36, color: m.hasVideo ? .systemIndigo : .systemGreen)
            }
        }
    }

    // Drag-out handling (NSDraggingSource)
    public override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        if event.clickCount == 2 {
            onDoubleClicked?()
            return
        }

        let isMultiMod = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        if isSelected && !isMultiMod {
            didMouseDownOnAlreadySelected = true
        } else {
            didMouseDownOnAlreadySelected = false
            onSelected?(event.modifierFlags)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if didMouseDownOnAlreadySelected {
            didMouseDownOnAlreadySelected = false
            let upPoint = event.locationInWindow
            let dist = hypot(upPoint.x - mouseDownLocation.x, upPoint.y - mouseDownLocation.y)
            if dist <= 4.0 {
                onSelected?(event.modifierFlags)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        didMouseDownOnAlreadySelected = false

        let dragPoint = event.locationInWindow
        let dist = hypot(dragPoint.x - mouseDownLocation.x, dragPoint.y - mouseDownLocation.y)
        guard dist > 4.0 else { return }

        if case .selection(let sel, _) = gridItem {
            let pbItem = NSPasteboardItem()
            pbItem.setString(sel.id.uuidString, forType: kSelectionPasteboardType)
            let dragImage = Lucide.image(.sparkles, size: 32, color: .systemPurple)
            let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
            dragItem.setDraggingFrame(NSRect(origin: frame.origin, size: NSSize(width: 48, height: 48)), contents: dragImage)
            beginDraggingSession(with: [dragItem], event: event, source: self)
            return
        }

        // Only media clips and selections can be dragged out onto timeline or folders
        guard case .media(let item) = gridItem else { return }

        let itemsToDrag: [MediaItem]
        if let allSelected = getAllSelectedItems?(), !allSelected.isEmpty, allSelected.contains(where: { $0.id == item.id }) {
            itemsToDrag = allSelected
        } else {
            itemsToDrag = [item]
        }

        var dragItems: [NSDraggingItem] = []
        for (i, dItem) in itemsToDrag.enumerated() {
            let pbItem = NSPasteboardItem()
            pbItem.setString(dItem.id.uuidString, forType: kMediaItemPasteboardType)
            pbItem.setString(dItem.url.absoluteString, forType: .fileURL)
            pbItem.setString(dItem.url.path, forType: .string)

            let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
            let dragImage: NSImage
            if let thumb = dItem.thumbnail {
                dragImage = thumb
            } else {
                let img = NSImage(size: NSSize(width: 80, height: 60))
                img.lockFocus()
                NSColor.darkGray.setFill()
                NSRect(x: 0, y: 0, width: 80, height: 60).fill()
                img.unlockFocus()
                dragImage = img
            }

            let offsetOrigin = NSPoint(x: frame.origin.x + CGFloat(i * 10), y: frame.origin.y + CGFloat(i * 10))
            dragItem.setDraggingFrame(NSRect(origin: offsetOrigin, size: NSSize(width: 80, height: 60)), contents: dragImage)
            dragItems.append(dragItem)
        }

        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // Drag-in handling for Folder Cards (Dropping clips into folder)
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .folder = gridItem else { return [] }
        isFolderDropTarget = true
        updateBorder()
        return .move
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        guard case .folder = gridItem else { return }
        isFolderDropTarget = false
        updateBorder()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard case .folder(let f) = gridItem else { return false }
        isFolderDropTarget = false
        updateBorder()

        var ids: [UUID] = []
        let pboard = sender.draggingPasteboard
        if let pbItems = pboard.pasteboardItems {
            for pbItem in pbItems {
                if let str = pbItem.string(forType: kMediaItemPasteboardType), let uuid = UUID(uuidString: str) {
                    ids.append(uuid)
                }
            }
        }
        if !ids.isEmpty {
            onDropItemsIntoFolder?(ids, f.id)
            return true
        }
        return false
    }

    // Context Menu
    public override func menu(for event: NSEvent) -> NSMenu? {
        onSelected?(event.modifierFlags)

        switch gridItem {
        case .timeline(let tl, let idx):
            let menu = NSMenu(title: tl.name)
            let openItem = NSMenuItem(title: "▶️ Apri timeline", action: #selector(onOpenTLClicked), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = (tl, idx)
            menu.addItem(openItem)

            let settingsItem = NSMenuItem(title: "⚙️ Impostazioni timeline...", action: #selector(onSettingsTLClicked), keyEquivalent: "")
            settingsItem.target = self
            settingsItem.representedObject = (tl, idx)
            menu.addItem(settingsItem)

            let renameItem = NSMenuItem(title: "✏️ Rinomina timeline...", action: #selector(onRenameTLClicked), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = idx
            menu.addItem(renameItem)

            if EditorProject.shared.timelines.count > 1 {
                menu.addItem(NSMenuItem.separator())
                let delItem = NSMenuItem(title: "🗑️ Elimina timeline", action: #selector(onDeleteTLClicked), keyEquivalent: "")
                delItem.target = self
                delItem.representedObject = idx
                menu.addItem(delItem)
            }
            return menu

        case .selection(let sel, let idx):
            let menu = NSMenu(title: sel.name)
            let openItem = NSMenuItem(title: "✨ Apri in Modalità Selezione", action: #selector(onOpenSelClicked), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = (sel, idx)
            menu.addItem(openItem)

            let renameItem = NSMenuItem(title: "✏️ Rinomina selezione...", action: #selector(onRenameSelClicked), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = sel
            menu.addItem(renameItem)

            let dupItem = NSMenuItem(title: "📄 Duplica selezione", action: #selector(onDuplicateSelClicked), keyEquivalent: "")
            dupItem.target = self
            dupItem.representedObject = sel
            menu.addItem(dupItem)

            menu.addItem(NSMenuItem.separator())
            let delItem = NSMenuItem(title: "🗑️ Elimina selezione", action: #selector(onDeleteSelClicked), keyEquivalent: "")
            delItem.target = self
            delItem.representedObject = sel
            menu.addItem(delItem)
            return menu

        case .folder(let f):
            let menu = NSMenu(title: f.name)
            let openItem = NSMenuItem(title: "📂 Apri cartella", action: #selector(onOpenFolderClicked), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = f
            menu.addItem(openItem)

            let renameItem = NSMenuItem(title: "✏️ Rinomina cartella...", action: #selector(onRenameFolderClicked), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = f
            menu.addItem(renameItem)

            menu.addItem(NSMenuItem.separator())
            let delItem = NSMenuItem(title: "🗑️ Elimina cartella", action: #selector(onDeleteFolderClicked), keyEquivalent: "")
            delItem.target = self
            delItem.representedObject = f
            menu.addItem(delItem)
            return menu

        case .media(let item):
            let menu = NSMenu(title: "Opzioni")
            menu.addItem(withTitle: item.name, action: nil, keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())

            let insertItem = NSMenuItem(title: "➕ Inserisci in timeline", action: #selector(onInsertClicked), keyEquivalent: "")
            insertItem.target = self
            menu.addItem(insertItem)
            menu.addItem(NSMenuItem.separator())

            if item.hasVideo {
                let orientationMenu = NSMenu(title: "Orientamento")
                for orient in ClipOrientation.allCases {
                    let mItem = NSMenuItem(title: orient.rawValue, action: #selector(onSelectOrient(_:)), keyEquivalent: "")
                    mItem.target = self
                    mItem.representedObject = orient
                    if item.orientation == orient {
                        mItem.state = .on
                    }
                    orientationMenu.addItem(mItem)
                }
                let orientParent = NSMenuItem(title: "🔄 Orientamento clip", action: nil, keyEquivalent: "")
                orientParent.submenu = orientationMenu
                menu.addItem(orientParent)
            }

            if !EditorProject.shared.folders.isEmpty {
                let folderMenu = NSMenu(title: "Cartella")
                let rootItem = NSMenuItem(title: "Principale (Nessuna)", action: #selector(onSelectFolder(_:)), keyEquivalent: "")
                rootItem.target = self
                rootItem.representedObject = nil as UUID?
                folderMenu.addItem(rootItem)
                for f in EditorProject.shared.folders {
                    let fItem = NSMenuItem(title: f.name, action: #selector(onSelectFolder(_:)), keyEquivalent: "")
                    fItem.target = self
                    fItem.representedObject = f.id
                    folderMenu.addItem(fItem)
                }
                let parentFolderItem = NSMenuItem(title: "📁 Sposta in cartella", action: nil, keyEquivalent: "")
                parentFolderItem.submenu = folderMenu
                menu.addItem(parentFolderItem)
            }

            menu.addItem(NSMenuItem.separator())
            let deleteItem = NSMenuItem(title: "🗑️ Elimina dal Media Pool", action: #selector(onDeleteClicked), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)

            return menu
        }
    }

    @objc private func onOpenTLClicked(_ sender: NSMenuItem) {
        if let tuple = sender.representedObject as? (TimelineModel, Int) {
            onOpenTimeline?(tuple.0, tuple.1)
        }
    }

    @objc private func onSettingsTLClicked(_ sender: NSMenuItem) {
        if let tuple = sender.representedObject as? (TimelineModel, Int) {
            onTimelineSettings?(tuple.0, tuple.1)
        }
    }

    @objc private func onRenameTLClicked(_ sender: NSMenuItem) {
        if let idx = sender.representedObject as? Int {
            onRenameTimeline?(idx)
        }
    }

    @objc private func onDeleteTLClicked(_ sender: NSMenuItem) {
        if let idx = sender.representedObject as? Int {
            onDeleteTimeline?(idx)
        }
    }

    @objc private func onOpenSelClicked(_ sender: NSMenuItem) {
        if let tuple = sender.representedObject as? (SelectionModel, Int) {
            onOpenSelection?(tuple.0, tuple.1)
        }
    }

    @objc private func onRenameSelClicked(_ sender: NSMenuItem) {
        if let sel = sender.representedObject as? SelectionModel {
            onRenameSelection?(sel)
        }
    }

    @objc private func onDuplicateSelClicked(_ sender: NSMenuItem) {
        if let sel = sender.representedObject as? SelectionModel {
            onDuplicateSelection?(sel)
        }
    }

    @objc private func onDeleteSelClicked(_ sender: NSMenuItem) {
        if let sel = sender.representedObject as? SelectionModel {
            onDeleteSelection?(sel)
        }
    }

    @objc private func onOpenFolderClicked(_ sender: NSMenuItem) {
        if let f = sender.representedObject as? MediaFolder {
            onOpenFolder?(f)
        }
    }

    @objc private func onRenameFolderClicked(_ sender: NSMenuItem) {
        if let f = sender.representedObject as? MediaFolder {
            onRenameFolder?(f)
        }
    }

    @objc private func onDeleteFolderClicked(_ sender: NSMenuItem) {
        if let f = sender.representedObject as? MediaFolder {
            onDeleteFolder?(f)
        }
    }

    @objc private func onInsertClicked() {
        onInsertToTimeline?()
    }

    @objc private func onDeleteClicked() {
        onDeleteFromPool?()
    }

    @objc private func onSelectOrient(_ sender: NSMenuItem) {
        if let orient = sender.representedObject as? ClipOrientation {
            onOrientationChanged?(orient)
        }
    }

    @objc private func onSelectFolder(_ sender: NSMenuItem) {
        onMoveToFolder?(sender.representedObject as? UUID)
    }
}

public final class MediaThumbnailGridView: NSView {
    public var gridItems: [GridCardItem] = [] {
        didSet {
            rebuildGrid()
        }
    }

    public var mediaItems: [MediaItem] {
        get {
            gridItems.compactMap {
                if case .media(let m) = $0 { return m }
                return nil
            }
        }
        set {
            gridItems = newValue.map { .media($0) }
        }
    }

    public var selectedItemIds: Set<UUID> = [] {
        didSet {
            updateSelectionState()
        }
    }

    public var onClipDoubleClicked: ((MediaItem) -> Void)?
    public var onClipSelected: ((MediaItem, NSEvent.ModifierFlags) -> Void)?
    public var onOrientationChanged: ((MediaItem, ClipOrientation) -> Void)?
    public var onMoveItemToFolder: ((UUID, UUID?) -> Void)?
    public var onInsertToTimeline: ((MediaItem) -> Void)?
    public var onDeleteFromPool: ((MediaItem) -> Void)?
    public var onContextMenuRequested: ((NSEvent) -> NSMenu?)?
    public var onOpenTimeline: ((TimelineModel, Int) -> Void)?
    public var onRenameTimeline: ((Int) -> Void)?
    public var onTimelineSettings: ((TimelineModel, Int) -> Void)?
    public var onDeleteTimeline: ((Int) -> Void)?
    public var onOpenSelection: ((SelectionModel, Int) -> Void)?
    public var onRenameSelection: ((SelectionModel) -> Void)?
    public var onDuplicateSelection: ((SelectionModel) -> Void)?
    public var onDeleteSelection: ((SelectionModel) -> Void)?
    public var onOpenFolder: ((MediaFolder) -> Void)?
    public var onRenameFolder: ((MediaFolder) -> Void)?
    public var onDeleteFolder: ((MediaFolder) -> Void)?
    public var onDropItemsIntoFolder: (([UUID], UUID) -> Void)?

    public override func menu(for event: NSEvent) -> NSMenu? {
        return onContextMenuRequested?(event) ?? super.menu(for: event)
    }

    private var cardViews: [MediaThumbnailCardView] = []
    public let minCardWidth: CGFloat = 130
    public let currentCardHeight: CGFloat = 110
    public let spacing: CGFloat = 10
    public let margin: CGFloat = 12

    public override var isFlipped: Bool { true }

    public var onURLsDropped: (([URL]) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        registerForDraggedTypes([.fileURL, kMediaItemPasteboardType])
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pboard = sender.draggingPasteboard
        if let types = pboard.types, types.contains(.fileURL) || types.contains(kMediaItemPasteboardType) {
            return .copy
        }
        return []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pboard = sender.draggingPasteboard
        if let types = pboard.types, types.contains(.fileURL) || types.contains(kMediaItemPasteboardType) {
            return .copy
        }
        return []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onURLsDropped?(urls)
            return true
        }
        if let pbItems = pboard.pasteboardItems {
            var extracted: [URL] = []
            for item in pbItems {
                if let str = item.string(forType: .fileURL) {
                    let u = URL(string: str) ?? URL(fileURLWithPath: str)
                    extracted.append(u)
                }
            }
            if !extracted.isEmpty {
                onURLsDropped?(extracted)
                return true
            }
        }
        return false
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipView = superview as? NSClipView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSuperviewBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            updateLayoutForCurrentWidth()
        }
    }

    @objc private func handleSuperviewBoundsChanged() {
        updateLayoutForCurrentWidth()
    }

    public var calculatedTotalHeight: CGFloat {
        guard !gridItems.isEmpty else { return 240 }
        let width = bounds.width > 0 ? bounds.width : 320
        let availableWidth = max(minCardWidth, width - margin * 2)
        let cols = max(1, Int((availableWidth + spacing) / (minCardWidth + spacing)))
        let rows = (gridItems.count + cols - 1) / cols
        let height = margin * 2 + CGFloat(rows) * currentCardHeight + CGFloat(max(0, rows - 1)) * spacing + 30
        return max(240, height)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: bounds.width > 0 ? bounds.width : 320, height: calculatedTotalHeight)
    }

    public func updateLayoutForCurrentWidth() {
        guard let clipView = superview as? NSClipView ?? superview else { return }
        let targetWidth = max(240, clipView.bounds.width)
        if abs(frame.width - targetWidth) > 1 {
            frame.size.width = targetWidth
        }
        let targetHeight = calculatedTotalHeight
        if abs(frame.height - targetHeight) > 1 {
            frame.size.height = targetHeight
        }
        layoutCards()
    }

    private func rebuildGrid() {
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews.removeAll()

        for (index, item) in gridItems.enumerated() {
            let card = MediaThumbnailCardView(gridItem: item, sequenceNumber: index + 1)

            card.onSelected = { [weak self, weak card] modifiers in
                guard let self = self, let card = card else { return }
                let itemId = card.gridItem.id
                if modifiers.contains(.shift) {
                    if self.selectedItemIds.contains(itemId) {
                        self.selectedItemIds.remove(itemId)
                    } else {
                        self.selectedItemIds.insert(itemId)
                    }
                } else {
                    self.selectedItemIds = [itemId]
                }
                if case .media(let m) = card.gridItem {
                    self.onClipSelected?(m, modifiers)
                }
            }

            card.getAllSelectedItems = { [weak self] in
                guard let self = self else { return [] }
                return self.mediaItems.filter { self.selectedItemIds.contains($0.id) }
            }

            card.onDoubleClicked = { [weak self, weak card] in
                guard let self = self, let card = card else { return }
                switch card.gridItem {
                case .media(let m):
                    self.onClipDoubleClicked?(m)
                case .timeline(let tl, let idx):
                    self.onOpenTimeline?(tl, idx)
                case .selection(let sel, let idx):
                    self.onOpenSelection?(sel, idx)
                case .folder(let f):
                    self.onOpenFolder?(f)
                }
            }

            card.onOrientationChanged = { [weak self, weak card] orient in
                guard let self = self, let card = card else { return }
                if case .media(let m) = card.gridItem {
                    self.onOrientationChanged?(m, orient)
                }
            }

            card.onMoveToFolder = { [weak self, weak card] targetFolderId in
                guard let self = self, let card = card else { return }
                if case .media(let m) = card.gridItem {
                    self.onMoveItemToFolder?(m.id, targetFolderId)
                }
            }

            card.onInsertToTimeline = { [weak self, weak card] in
                guard let self = self, let card = card else { return }
                if case .media(let m) = card.gridItem {
                    self.onInsertToTimeline?(m)
                }
            }

            card.onDeleteFromPool = { [weak self, weak card] in
                guard let self = self, let card = card else { return }
                if case .media(let m) = card.gridItem {
                    self.onDeleteFromPool?(m)
                }
            }

            card.onOpenTimeline = { [weak self] tl, idx in
                self?.onOpenTimeline?(tl, idx)
            }
            card.onRenameTimeline = { [weak self] idx in
                self?.onRenameTimeline?(idx)
            }
            card.onTimelineSettings = { [weak self] tl, idx in
                self?.onTimelineSettings?(tl, idx)
            }
            card.onDeleteTimeline = { [weak self] idx in
                self?.onDeleteTimeline?(idx)
            }
            card.onOpenSelection = { [weak self] sel, idx in
                self?.onOpenSelection?(sel, idx)
            }
            card.onRenameSelection = { [weak self] sel in
                self?.onRenameSelection?(sel)
            }
            card.onDuplicateSelection = { [weak self] sel in
                self?.onDuplicateSelection?(sel)
            }
            card.onDeleteSelection = { [weak self] sel in
                self?.onDeleteSelection?(sel)
            }
            card.onOpenFolder = { [weak self] f in
                self?.onOpenFolder?(f)
            }
            card.onRenameFolder = { [weak self] f in
                self?.onRenameFolder?(f)
            }
            card.onDeleteFolder = { [weak self] f in
                self?.onDeleteFolder?(f)
            }
            card.onDropItemsIntoFolder = { [weak self] ids, fId in
                self?.onDropItemsIntoFolder?(ids, fId)
            }

            addSubview(card)
            cardViews.append(card)
        }

        updateSelectionState()
        updateLayoutForCurrentWidth()
    }

    private func updateSelectionState() {
        for card in cardViews {
            card.isSelected = selectedItemIds.contains(card.gridItem.id)
        }
    }

    private func layoutCards() {
        guard !cardViews.isEmpty else { return }
        let totalWidth = max(minCardWidth, bounds.width > 0 ? bounds.width : 320)
        let availableWidth = max(minCardWidth, totalWidth - margin * 2)

        let cols = max(1, Int((availableWidth + spacing) / (minCardWidth + spacing)))
        let cardWidth = (availableWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols)

        for (idx, card) in cardViews.enumerated() {
            let col = idx % cols
            let row = idx / cols
            let x = margin + CGFloat(col) * (cardWidth + spacing)
            let y = margin + CGFloat(row) * (currentCardHeight + spacing)
            card.frame = NSRect(x: x, y: y, width: cardWidth, height: currentCardHeight)
        }
    }
}
