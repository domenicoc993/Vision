import AppKit
import Foundation

/// Dialog per consultare e ripristinare i backup incrementali (span 3 giorni) di un progetto.
public final class ProjectBackupDialog: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    public enum RestoreAction {
        case restoredCurrentProject(ProjectDocumentData)
        case createdNewProject(ProjectDocumentData)
    }

    private let projectRecord: ProjectRecord
    private let currentLiveDocumentProvider: (() -> ProjectDocumentData?)?
    private weak var modalPanel: NSPanel?
    private var onCompleted: ((RestoreAction) -> Void)?

    private var backups: [ProjectBackupRecord] = []

    private let infoLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Nessun backup salvato negli ultimi 3 giorni.")

    private let snapshotNowBtn = FlatButton(title: "Crea Backup Ora")
    private let restoreCopyBtn = FlatButton(title: "Ripristina come Nuovo")
    private let restoreBtn = FlatButton(title: "Ripristina Progetto")
    private let closeBtn = FlatButton(title: "Chiudi")

    @discardableResult
    public static func showModal(
        for project: ProjectRecord,
        relativeTo parentWindow: NSWindow? = nil,
        currentLiveDocumentProvider: (() -> ProjectDocumentData?)? = nil,
        onCompleted: ((RestoreAction) -> Void)? = nil
    ) -> RestoreAction? {
        let size = NSSize(width: 720, height: 420)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 620, height: 340)
        panel.title = "Backup Incrementali — \(project.name)"
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

        var resultAction: RestoreAction?
        let controller = ProjectBackupDialog(
            project: project,
            panel: panel,
            currentLiveDocumentProvider: currentLiveDocumentProvider
        ) { action in
            resultAction = action
            onCompleted?(action)
        }
        panel.delegate = controller
        panel.contentViewController = controller
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return resultAction
    }

    public static func makeControllerForTesting(
        for project: ProjectRecord,
        currentLiveDocumentProvider: (() -> ProjectDocumentData?)? = nil,
        onCompleted: ((RestoreAction) -> Void)? = nil
    ) -> ProjectBackupDialog {
        ProjectBackupDialog(
            project: project,
            panel: nil,
            currentLiveDocumentProvider: currentLiveDocumentProvider,
            onCompleted: onCompleted
        )
    }

    private init(
        project: ProjectRecord,
        panel: NSPanel?,
        currentLiveDocumentProvider: (() -> ProjectDocumentData?)?,
        onCompleted: ((RestoreAction) -> Void)?
    ) {
        self.projectRecord = project
        self.modalPanel = panel
        self.currentLiveDocumentProvider = currentLiveDocumentProvider
        self.onCompleted = onCompleted
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 720, height: 420)))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor
        self.view = root

        // Top info bar
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(header)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = Lucide.image(.history, size: 16, color: .systemCyan)
        header.addSubview(iconView)

        infoLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        infoLabel.textColor = NSColor(calibratedWhite: 0.82, alpha: 1.0)
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(infoLabel)

        let headerDivider = NSBox()
        headerDivider.boxType = .separator
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerDivider)

        // Table
        setupTableView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1.0)
        root.addSubview(scrollView)

        emptyLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        emptyLabel.textColor = NSColor(calibratedWhite: 0.48, alpha: 1.0)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

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

        snapshotNowBtn.translatesAutoresizingMaskIntoConstraints = false
        snapshotNowBtn.target = self
        snapshotNowBtn.action = #selector(onSnapshotNowClicked)
        footer.addSubview(snapshotNowBtn)

        restoreCopyBtn.translatesAutoresizingMaskIntoConstraints = false
        restoreCopyBtn.target = self
        restoreCopyBtn.action = #selector(onRestoreCopyClicked)
        footer.addSubview(restoreCopyBtn)

        restoreBtn.translatesAutoresizingMaskIntoConstraints = false
        restoreBtn.target = self
        restoreBtn.action = #selector(onRestoreOverwriteClicked)
        footer.addSubview(restoreBtn)

        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.target = self
        closeBtn.action = #selector(onCloseClicked)
        footer.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),

            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            infoLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            infoLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            infoLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 46),

            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            snapshotNowBtn.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14),
            snapshotNowBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            snapshotNowBtn.widthAnchor.constraint(equalToConstant: 124),
            snapshotNowBtn.heightAnchor.constraint(equalToConstant: 28),

            closeBtn.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            closeBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 74),
            closeBtn.heightAnchor.constraint(equalToConstant: 28),

            restoreBtn.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8),
            restoreBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            restoreBtn.widthAnchor.constraint(equalToConstant: 136),
            restoreBtn.heightAnchor.constraint(equalToConstant: 28),

            restoreCopyBtn.trailingAnchor.constraint(equalTo: restoreBtn.leadingAnchor, constant: -8),
            restoreCopyBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            restoreCopyBtn.widthAnchor.constraint(equalToConstant: 150),
            restoreCopyBtn.heightAnchor.constraint(equalToConstant: 28)
        ])

        reloadBackups()
    }

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 36
        tableView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        tableView.selectionHighlightStyle = .regular
        tableView.headerView = NSTableHeaderView()
        tableView.autoresizingMask = [.width, .height]

        let colDate = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Date"))
        colDate.title = "Data e Ora"
        colDate.width = 230
        tableView.addTableColumn(colDate)

        let colReason = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Reason"))
        colReason.title = "Origine"
        colReason.width = 120
        tableView.addTableColumn(colReason)

        let colSummary = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Summary"))
        colSummary.title = "Contenuto Snapshot"
        colSummary.width = 250
        tableView.addTableColumn(colSummary)

        let colSize = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        colSize.title = "Dim."
        colSize.width = 80
        tableView.addTableColumn(colSize)
    }

    public func reloadBackups() {
        backups = ProjectBackupManager.shared.listBackups(for: projectRecord.id)
        tableView.reloadData()

        emptyLabel.isHidden = !backups.isEmpty
        if !backups.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        infoLabel.stringValue = "\(backups.count) snapshot negli ultimi 3 giorni  •  Salvataggio automatico ogni 5 min mentre Vision è aperto"
        updateButtons()
    }

    private func updateButtons() {
        let row = tableView.selectedRow
        let valid = row >= 0 && row < backups.count
        restoreCopyBtn.isEnabled = valid
        restoreBtn.isEnabled = valid
        restoreBtn.isAccentActive = valid
    }

    private var selectedBackup: ProjectBackupRecord? {
        let row = tableView.selectedRow
        guard row >= 0 && row < backups.count else { return nil }
        return backups[row]
    }

    @objc private func onSnapshotNowClicked() {
        let liveDoc = currentLiveDocumentProvider?() ?? ProjectDatabase.shared.loadProjectDocument(id: projectRecord.id)
        guard let doc = liveDoc else { return }
        _ = ProjectBackupManager.shared.createBackupIfNeeded(
            document: doc,
            reason: "Manuale",
            force: true,
            synchronous: true
        )
        reloadBackups()
    }

    @objc private func onRestoreCopyClicked() {
        guard let record = selectedBackup else { return }
        guard let restored = ProjectBackupManager.shared.restoreBackupAsNewProject(record: record) else { return }
        onCompleted?(.createdNewProject(restored.document))
        modalPanel?.close()
    }

    @objc private func onRestoreOverwriteClicked() {
        guard let record = selectedBackup else { return }

        let performRestore = { [weak self] in
            guard let self = self else { return }
            let liveDoc = self.currentLiveDocumentProvider?()
            if let doc = ProjectBackupManager.shared.restoreBackupOverwritingProject(record: record, currentLiveDoc: liveDoc) {
                self.onCompleted?(.restoredCurrentProject(doc))
                self.modalPanel?.close()
            }
        }

        if let panel = modalPanel {
            let alert = NSAlert()
            alert.messageText = "Ripristinare '\(projectRecord.name)' al \(record.formattedDate)?"
            alert.informativeText = "Lo stato attuale verrà salvato come backup 'Pre-ripristino' prima di applicare lo snapshot selezionato."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Ripristina")
            alert.addButton(withTitle: "Annulla")
            alert.beginSheetModal(for: panel) { resp in
                if resp == .alertFirstButtonReturn {
                    performRestore()
                }
            }
        } else {
            performRestore()
        }
    }

    @objc private func onCloseClicked() {
        modalPanel?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        if modalPanel != nil {
            NSApp.stopModal()
        }
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        backups.count
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < backups.count, let colId = tableColumn?.identifier.rawValue else { return nil }
        let rec = backups[row]

        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail

        switch colId {
        case "Date":
            tf.stringValue = "\(rec.formattedDate) (\(rec.formattedRelative()))"
            tf.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: row == 0 ? .semibold : .regular)
            tf.textColor = row == 0 ? .white : NSColor(calibratedWhite: 0.85, alpha: 1.0)
        case "Reason":
            tf.stringValue = rec.reason
            tf.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            if rec.reason == "Pre-ripristino" {
                tf.textColor = .systemOrange
            } else if rec.reason == "Manuale" {
                tf.textColor = .systemCyan
            } else {
                tf.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
            }
        case "Summary":
            tf.stringValue = rec.formattedSummary
            tf.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
            tf.textColor = NSColor(calibratedWhite: 0.72, alpha: 1.0)
        case "Size":
            tf.stringValue = rec.formattedSize
            tf.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            tf.textColor = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        default:
            break
        }

        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
