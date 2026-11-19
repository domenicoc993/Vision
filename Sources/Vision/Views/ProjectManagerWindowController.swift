import AppKit

private final class ProjectListTableView: NSTableView {
    var onRightClickRow: ((Int, NSEvent) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        onRightClickRow?(row, event)
    }
}

public final class ProjectManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate {
    public var onOpenProject: ((ProjectDocumentData) -> Void)?
    public var onCreateNewProject: ((String) -> Void)?
    public var onCloseWithoutProject: (() -> Void)?
    public var activeLiveDocumentProvider: (() -> ProjectDocumentData?)?

    private var allProjects: [ProjectRecord] = []
    private var filteredProjects: [ProjectRecord] = []

    private let searchBtn = IconActionButton(toolTip: "Cerca progetti", isToggleMode: true)
    private let searchField = NSTextField()
    private var searchWidthConstraint: NSLayoutConstraint!
    private var isSearchExpanded: Bool = false

    private let newProjectBtn = IconActionButton(toolTip: "Nuovo Progetto", isToggleMode: false)
    private let tableView = ProjectListTableView()
    private let scrollView = NSScrollView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let backupBtn = FlatButton(title: "Backup (3g)...")
    private let openBtn = FlatButton(title: "Apri Progetto")

    public init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.minSize = NSSize(width: 680, height: 400)
        win.title = "Progetti — Vision"
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1.0)
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
        setupUI()
        reloadProjects()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showModal(relativeTo parentWindow: NSWindow? = nil) {
        guard let window = self.window else { return }
        reloadProjects()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor

        // 1. Minimal Top Header Bar (Search toggle + expandable borderless search + '+' action)
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        contentView.addSubview(headerView)

        let headerBorder = NSView()
        headerBorder.translatesAutoresizingMaskIntoConstraints = false
        headerBorder.wantsLayer = true
        headerBorder.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
        headerView.addSubview(headerBorder)

        searchBtn.translatesAutoresizingMaskIntoConstraints = false
        searchBtn.image = Lucide.template(.search, size: 15)
        searchBtn.activeTintColor = .systemCyan
        searchBtn.inactiveTintColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
        searchBtn.target = self
        searchBtn.action = #selector(onToggleSearchClicked)
        headerView.addSubview(searchBtn)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        searchField.textColor = .white
        searchField.placeholderString = "Cerca progetti..."
        searchField.delegate = self
        searchField.isHidden = true
        searchField.alphaValue = 0.0
        headerView.addSubview(searchField)

        newProjectBtn.translatesAutoresizingMaskIntoConstraints = false
        newProjectBtn.image = Lucide.template(.plus, size: 17)
        newProjectBtn.activeTintColor = .white
        newProjectBtn.inactiveTintColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        newProjectBtn.target = self
        newProjectBtn.action = #selector(onNewProjectClicked)
        headerView.addSubview(newProjectBtn)

        // 2. Center Table View
        setupTableView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        contentView.addSubview(scrollView)

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
        emptyStateLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyStateLabel.isEditable = false
        emptyStateLabel.isSelectable = false
        emptyStateLabel.drawsBackground = false
        emptyStateLabel.isHidden = true
        contentView.addSubview(emptyStateLabel)

        // 3. Minimal Bottom Bar (Open Action only — window close via macOS traffic light)
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        contentView.addSubview(bottomBar)

        let bottomBorder = NSView()
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor
        bottomBar.addSubview(bottomBorder)

        backupBtn.translatesAutoresizingMaskIntoConstraints = false
        backupBtn.image = Lucide.template(.history, size: 13)
        backupBtn.imagePosition = .imageLeading
        backupBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        backupBtn.target = self
        backupBtn.action = #selector(onBackupsClicked)
        bottomBar.addSubview(backupBtn)

        openBtn.translatesAutoresizingMaskIntoConstraints = false
        openBtn.image = Lucide.template(.play, size: 13)
        openBtn.imagePosition = .imageLeading
        openBtn.isAccentActive = true
        openBtn.keyEquivalent = "\r"
        openBtn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        openBtn.target = self
        openBtn.action = #selector(onOpenClicked)
        bottomBar.addSubview(openBtn)

        searchWidthConstraint = searchField.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),

            headerBorder.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerBorder.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            headerBorder.heightAnchor.constraint(equalToConstant: 1),

            searchBtn.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            searchBtn.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            searchBtn.widthAnchor.constraint(equalToConstant: 26),
            searchBtn.heightAnchor.constraint(equalToConstant: 26),

            searchField.leadingAnchor.constraint(equalTo: searchBtn.trailingAnchor, constant: 6),
            searchField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            searchWidthConstraint,

            newProjectBtn.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            newProjectBtn.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            newProjectBtn.widthAnchor.constraint(equalToConstant: 28),
            newProjectBtn.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 46),

            bottomBorder.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            bottomBorder.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),

            backupBtn.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
            backupBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            backupBtn.widthAnchor.constraint(equalToConstant: 146),
            backupBtn.heightAnchor.constraint(equalToConstant: 28),

            openBtn.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -14),
            openBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            openBtn.widthAnchor.constraint(equalToConstant: 132),
            openBtn.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 38
        tableView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        tableView.selectionHighlightStyle = .regular
        tableView.doubleAction = #selector(onOpenClicked)
        tableView.target = self
        tableView.headerView = NSTableHeaderView()
        tableView.autoresizingMask = [.width, .height]
        tableView.onRightClickRow = { [weak self] row, event in
            self?.presentContextMenu(forRow: row, event: event)
        }

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        colName.title = "Nome Progetto"
        colName.width = 290
        tableView.addTableColumn(colName)

        let colRes = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Resolution"))
        colRes.title = "Formato"
        colRes.width = 150
        tableView.addTableColumn(colRes)

        let colTL = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Timelines"))
        colTL.title = "Timeline & Selezioni"
        colTL.width = 150
        tableView.addTableColumn(colTL)

        let colClips = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Clips"))
        colClips.title = "Materiali"
        colClips.width = 90
        tableView.addTableColumn(colClips)

        let colDate = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Date"))
        colDate.title = "Ultima Modifica"
        colDate.width = 140
        tableView.addTableColumn(colDate)
    }

    public func reloadProjects() {
        allProjects = ProjectDatabase.shared.getAllProjects()
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredProjects = allProjects
        } else {
            filteredProjects = allProjects.filter { $0.name.lowercased().contains(query) }
        }
        tableView.reloadData()

        if filteredProjects.isEmpty {
            if searchField.stringValue.isEmpty {
                emptyStateLabel.stringValue = "Nessun progetto salvato.\nFai clic su + in alto a destra per iniziare."
            } else {
                emptyStateLabel.stringValue = "Nessun progetto corrispondente a '\(searchField.stringValue)'"
            }
            emptyStateLabel.isHidden = false
        } else {
            emptyStateLabel.isHidden = true
        }

        if let activeIdx = filteredProjects.firstIndex(where: { $0.id == EditorProject.shared.projectId }) {
            tableView.selectRowIndexes(IndexSet(integer: activeIdx), byExtendingSelection: false)
        } else if !filteredProjects.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        updateButtonStates()
    }

    private func updateButtonStates() {
        let selectedRow = tableView.selectedRow
        let valid = selectedRow >= 0 && selectedRow < filteredProjects.count
        openBtn.isEnabled = valid
        backupBtn.isEnabled = valid
        if valid {
            let count = ProjectBackupManager.shared.backupCount(for: filteredProjects[selectedRow].id)
            backupBtn.title = count > 0 ? "Backup (\(count))..." : "Backup (3g)..."
        } else {
            backupBtn.title = "Backup (3g)..."
        }
    }

    @objc private func onToggleSearchClicked() {
        setSearchExpanded(!isSearchExpanded)
    }

    private func setSearchExpanded(_ expanded: Bool) {
        isSearchExpanded = expanded
        searchBtn.isToggleActive = expanded
        if expanded {
            searchField.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                searchWidthConstraint.constant = 240
                searchField.alphaValue = 1.0
                window?.contentView?.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.searchField)
            }
        } else {
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                applyFilter()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.allowsImplicitAnimation = true
                searchWidthConstraint.constant = 0
                searchField.alphaValue = 0.0
                window?.contentView?.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                guard let self, !self.isSearchExpanded else { return }
                self.searchField.isHidden = true
            }
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            setSearchExpanded(false)
            return true
        }
        return false
    }

    private func presentContextMenu(forRow row: Int, event: NSEvent) {
        guard row >= 0 && row < filteredProjects.count else { return }
        let p = filteredProjects[row]
        let isCurrent = p.id == EditorProject.shared.projectId

        let backupCount = ProjectBackupManager.shared.backupCount(for: p.id)
        let backupTitle = backupCount > 0 ? "Cronologia Backup (\(backupCount))..." : "Cronologia Backup (3 giorni)..."

        let items: [VisionMenuItem] = [
            .action(title: "Apri Progetto", icon: .play, iconColor: .systemCyan) { [weak self] in
                self?.openProject(at: row)
            },
            .action(title: backupTitle, icon: .history, iconColor: .systemCyan) { [weak self] in
                self?.showBackups(at: row)
            },
            .separator,
            .action(title: "Rinomina", icon: .pencil) { [weak self] in
                self?.renameProject(at: row)
            },
            .action(title: "Duplica", icon: .copy) { [weak self] in
                self?.duplicateProject(at: row)
            },
            .separator,
            .action(
                title: "Elimina",
                icon: .trash,
                isEnabled: !isCurrent,
                isDestructive: true
            ) { [weak self] in
                self?.deleteProject(at: row)
            }
        ]
        VisionMenu(items: items).show(for: event, in: tableView)
    }

    // MARK: - Actions
    @objc private func onBackupsClicked() {
        showBackups(at: tableView.selectedRow)
    }

    private func showBackups(at row: Int) {
        guard row >= 0 && row < filteredProjects.count else { return }
        let target = filteredProjects[row]
        let liveProvider: (() -> ProjectDocumentData?)? = { [weak self] in
            if let liveDoc = self?.activeLiveDocumentProvider?(), liveDoc.id == target.id {
                return liveDoc
            }
            return nil
        }

        ProjectBackupDialog.showModal(
            for: target,
            relativeTo: self.window,
            currentLiveDocumentProvider: liveProvider
        ) { [weak self] action in
            guard let self = self else { return }
            switch action {
            case .restoredCurrentProject(let restoredDoc):
                self.onOpenProject?(restoredDoc)
                self.closeModal(didOpenProject: true)
            case .createdNewProject(let newDoc):
                self.reloadProjects()
                if let idx = self.filteredProjects.firstIndex(where: { $0.id == newDoc.id }) {
                    self.tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                    self.tableView.scrollRowToVisible(idx)
                }
            }
        }
        updateButtonStates()
    }

    @objc private func onOpenClicked() {
        openProject(at: tableView.selectedRow)
    }

    private func openProject(at row: Int) {
        guard row >= 0 && row < filteredProjects.count else { return }
        let targetRecord = filteredProjects[row]

        if let doc = ProjectDatabase.shared.loadProjectDocument(id: targetRecord.id) {
            onOpenProject?(doc)
            closeModal(didOpenProject: true)
        }
    }

    @objc private func onNewProjectClicked() {
        let alert = NSAlert()
        alert.messageText = "Nuovo Progetto"
        alert.informativeText = "Inserisci il nome per il nuovo progetto:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = "Progetto \(allProjects.count + 1)"
        alert.accessoryView = input

        if let win = self.window {
            alert.beginSheetModal(for: win) { [weak self] response in
                guard let self = self else { return }
                if response == .alertFirstButtonReturn {
                    let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        self.onCreateNewProject?(name)
                        self.closeModal(didOpenProject: true)
                    }
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    onCreateNewProject?(name)
                    closeModal(didOpenProject: true)
                }
            }
        }
    }

    private func duplicateProject(at row: Int) {
        guard row >= 0 && row < filteredProjects.count else { return }
        let p = filteredProjects[row]
        if let _ = ProjectDatabase.shared.duplicateProject(id: p.id) {
            reloadProjects()
        }
    }

    private func renameProject(at row: Int) {
        guard row >= 0 && row < filteredProjects.count else { return }
        let p = filteredProjects[row]

        let alert = NSAlert()
        alert.messageText = "Rinomina Progetto"
        alert.informativeText = "Inserisci il nuovo nome:"
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Annulla")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = p.name
        alert.accessoryView = input

        if let win = self.window {
            alert.beginSheetModal(for: win) { [weak self] response in
                guard let self = self else { return }
                if response == .alertFirstButtonReturn {
                    let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !newName.isEmpty {
                        ProjectDatabase.shared.renameProject(id: p.id, newName: newName)
                        if p.id == EditorProject.shared.projectId {
                            EditorProject.shared.projectName = newName
                        }
                        self.reloadProjects()
                    }
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty {
                    ProjectDatabase.shared.renameProject(id: p.id, newName: newName)
                    if p.id == EditorProject.shared.projectId {
                        EditorProject.shared.projectName = newName
                    }
                    reloadProjects()
                }
            }
        }
    }

    private func deleteProject(at row: Int) {
        guard row >= 0 && row < filteredProjects.count else { return }
        let p = filteredProjects[row]
        guard p.id != EditorProject.shared.projectId else { return }

        let alert = NSAlert()
        alert.messageText = "Eliminare '\(p.name)'?"
        alert.informativeText = "Questa azione eliminerà definitivamente il progetto dal database."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Elimina")
        alert.addButton(withTitle: "Annulla")

        if let win = self.window {
            alert.beginSheetModal(for: win) { [weak self] response in
                guard let self = self else { return }
                if response == .alertFirstButtonReturn {
                    ProjectDatabase.shared.deleteProject(id: p.id)
                    self.reloadProjects()
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                ProjectDatabase.shared.deleteProject(id: p.id)
                reloadProjects()
            }
        }
    }

    private func closeModal(didOpenProject: Bool = false) {
        if let sheetParent = window?.sheetParent {
            sheetParent.endSheet(window!)
        }
        window?.orderOut(nil)
        if !didOpenProject {
            onCloseWithoutProject?()
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeModal(didOpenProject: false)
        return false
    }

    // MARK: - Table View Data Source & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredProjects.count
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < filteredProjects.count, let column = tableColumn else { return nil }
        let p = filteredProjects[row]
        let isCurrent = p.id == EditorProject.shared.projectId

        let colId = column.identifier.rawValue

        if colId == "Name" {
            let nameCellId = NSUserInterfaceItemIdentifier("ProjCell_NameWithIcon")
            var nameCell = tableView.makeView(withIdentifier: nameCellId, owner: nil) as? NSTableCellView
            if nameCell == nil {
                nameCell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: column.width, height: 38))
                nameCell?.identifier = nameCellId

                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.image = Lucide.template(.film, size: 16)
                nameCell?.addSubview(icon)
                nameCell?.imageView = icon

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.isBordered = false
                tf.drawsBackground = false
                tf.lineBreakMode = .byTruncatingTail
                nameCell?.addSubview(tf)
                nameCell?.textField = tf

                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: nameCell!.leadingAnchor, constant: 8),
                    icon.centerYAnchor.constraint(equalTo: nameCell!.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),

                    tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                    tf.trailingAnchor.constraint(equalTo: nameCell!.trailingAnchor, constant: -8),
                    tf.centerYAnchor.constraint(equalTo: nameCell!.centerYAnchor)
                ])
            }
            nameCell?.imageView?.contentTintColor = isCurrent ? NSColor.systemCyan : NSColor(calibratedWhite: 0.60, alpha: 1.0)
            nameCell?.textField?.stringValue = p.name
            nameCell?.textField?.textColor = isCurrent ? NSColor.systemCyan : NSColor.white
            nameCell?.textField?.font = NSFont.systemFont(ofSize: 12, weight: isCurrent ? .bold : .medium)
            return nameCell
        }

        let cellId = NSUserInterfaceItemIdentifier("ProjCell_\(colId)")
        var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: column.width, height: 38))
            cell?.identifier = cellId
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.isBordered = false
            tf.drawsBackground = false
            tf.lineBreakMode = .byTruncatingTail
            cell?.addSubview(tf)
            cell?.textField = tf

            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
            ])
        }

        switch colId {
        case "Resolution":
            cell?.textField?.stringValue = p.formattedResolution
            cell?.textField?.textColor = NSColor.secondaryLabelColor
            cell?.textField?.font = NSFont.systemFont(ofSize: 11)

        case "Timelines":
            cell?.textField?.stringValue = "\(p.timelinesCount) TL  •  \(p.selectionsCount) Sel."
            cell?.textField?.textColor = NSColor.secondaryLabelColor
            cell?.textField?.font = NSFont.systemFont(ofSize: 11)

        case "Clips":
            cell?.textField?.stringValue = "\(p.mediaCount) clip"
            cell?.textField?.textColor = NSColor.secondaryLabelColor
            cell?.textField?.font = NSFont.systemFont(ofSize: 11)

        case "Date":
            cell?.textField?.stringValue = p.formattedDate
            cell?.textField?.textColor = NSColor.tertiaryLabelColor
            cell?.textField?.font = NSFont.systemFont(ofSize: 11)

        default:
            break
        }

        return cell
    }
}
