import AppKit

public final class ProjectManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    public var onOpenProject: ((ProjectDocumentData) -> Void)?
    public var onCreateNewProject: ((String) -> Void)?
    public var onCloseWithoutProject: (() -> Void)?

    private var allProjects: [ProjectRecord] = []
    private var filteredProjects: [ProjectRecord] = []

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let openBtn = NSButton()
    private let duplicateBtn = NSButton()
    private let renameBtn = NSButton()
    private let deleteBtn = NSButton()
    private let closeBtn = NSButton()

    public init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 530),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.minSize = NSSize(width: 720, height: 420)
        win.title = "Project Manager — Vision"
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

        // 1. Top Header Bar
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        contentView.addSubview(headerView)

        let titleIcon = NSImageView()
        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        titleIcon.image = Lucide.image(.film, size: 22, color: .systemCyan)
        headerView.addSubview(titleIcon)

        let titleLabel = NSTextField(labelWithString: "Gestione Progetti")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .white
        headerView.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Database SQLite locale • Salvataggio continuo in tempo reale")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        headerView.addSubview(subtitleLabel)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Cerca progetti..."
        searchField.target = self
        searchField.action = #selector(onSearchChanged)
        headerView.addSubview(searchField)

        let newProjBtn = NSButton()
        newProjBtn.translatesAutoresizingMaskIntoConstraints = false
        newProjBtn.title = "+ Nuovo Progetto"
        newProjBtn.bezelStyle = .rounded
        newProjBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        newProjBtn.target = self
        newProjBtn.action = #selector(onNewProjectClicked)
        headerView.addSubview(newProjBtn)

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

        // 3. Bottom Action Bar
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        contentView.addSubview(bottomBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
        bottomBar.addSubview(statusLabel)

        let buttonStack = NSStackView()
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY
        bottomBar.addSubview(buttonStack)

        deleteBtn.title = "🗑️ Elimina"
        deleteBtn.bezelStyle = .rounded
        deleteBtn.target = self
        deleteBtn.action = #selector(onDeleteClicked)
        buttonStack.addArrangedSubview(deleteBtn)

        duplicateBtn.title = "📋 Duplica"
        duplicateBtn.bezelStyle = .rounded
        duplicateBtn.target = self
        duplicateBtn.action = #selector(onDuplicateClicked)
        buttonStack.addArrangedSubview(duplicateBtn)

        renameBtn.title = "✏️ Rinomina"
        renameBtn.bezelStyle = .rounded
        renameBtn.target = self
        renameBtn.action = #selector(onRenameClicked)
        buttonStack.addArrangedSubview(renameBtn)

        openBtn.title = "🚀 Apri Progetto"
        openBtn.bezelStyle = .rounded
        openBtn.keyEquivalent = "\r"
        openBtn.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        openBtn.target = self
        openBtn.action = #selector(onOpenClicked)
        buttonStack.addArrangedSubview(openBtn)

        closeBtn.title = "Chiudi"
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.target = self
        closeBtn.action = #selector(onCloseClicked)
        buttonStack.addArrangedSubview(closeBtn)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 58),

            titleIcon.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 18),
            titleIcon.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleIcon.widthAnchor.constraint(equalToConstant: 24),
            titleIcon.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: titleIcon.trailingAnchor, constant: 10),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            newProjBtn.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            newProjBtn.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            newProjBtn.heightAnchor.constraint(equalToConstant: 28),

            searchField.trailingAnchor.constraint(equalTo: newProjBtn.leadingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 200),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 48),

            statusLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            buttonStack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            buttonStack.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
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

        let colStatus = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Status"))
        colStatus.title = "Stato"
        colStatus.width = 85
        tableView.addTableColumn(colStatus)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        colName.title = "Nome Progetto"
        colName.width = 250
        tableView.addTableColumn(colName)

        let colRes = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Resolution"))
        colRes.title = "Formato"
        colRes.width = 150
        tableView.addTableColumn(colRes)

        let colTL = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Timelines"))
        colTL.title = "Timeline & Selezioni"
        colTL.width = 140
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
                emptyStateLabel.stringValue = "Nessun progetto nel database.\nFai clic su '+ Nuovo Progetto' in alto a destra per iniziare."
            } else {
                emptyStateLabel.stringValue = "Nessun progetto corrispondente a '\(searchField.stringValue)'"
            }
            emptyStateLabel.isHidden = false
        } else {
            emptyStateLabel.isHidden = true
        }

        // Auto-select currently active project if available, or first row
        if let activeIdx = filteredProjects.firstIndex(where: { $0.id == EditorProject.shared.projectId }) {
            tableView.selectRowIndexes(IndexSet(integer: activeIdx), byExtendingSelection: false)
        } else if !filteredProjects.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        statusLabel.stringValue = "Progetti salvati nel DB: \(allProjects.count)"
        updateButtonStates()
    }

    private func updateButtonStates() {
        let selectedRow = tableView.selectedRow
        let hasSelection = selectedRow >= 0 && selectedRow < filteredProjects.count
        openBtn.isEnabled = hasSelection
        duplicateBtn.isEnabled = hasSelection
        renameBtn.isEnabled = hasSelection

        if hasSelection {
            let p = filteredProjects[selectedRow]
            let isCurrent = p.id == EditorProject.shared.projectId
            deleteBtn.isEnabled = !isCurrent
        } else {
            deleteBtn.isEnabled = false
        }
    }

    @objc private func onSearchChanged() {
        applyFilter()
    }

    // MARK: - Actions
    @objc private func onOpenClicked() {
        let row = tableView.selectedRow
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

    @objc private func onDuplicateClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredProjects.count else { return }
        let p = filteredProjects[row]
        if let _ = ProjectDatabase.shared.duplicateProject(id: p.id) {
            reloadProjects()
        }
    }

    @objc private func onRenameClicked() {
        let row = tableView.selectedRow
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

    @objc private func onDeleteClicked() {
        let row = tableView.selectedRow
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

    @objc private func onCloseClicked() {
        closeModal(didOpenProject: false)
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
                icon.image = Lucide.image(.film, size: 16, color: .systemCyan)
                nameCell?.addSubview(icon)

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
        case "Status":
            cell?.textField?.stringValue = isCurrent ? "● ATTIVO" : "—"
            cell?.textField?.textColor = isCurrent ? NSColor.systemCyan : NSColor.tertiaryLabelColor
            cell?.textField?.font = NSFont.systemFont(ofSize: 10, weight: .bold)

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
