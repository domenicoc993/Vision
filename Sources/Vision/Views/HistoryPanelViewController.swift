import AppKit

public final class HistoryPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public var onRestoreSnapshot: ((ProjectDocumentData) -> Void)?
    public var onJumpToHistory: ((Int) -> Void)?
    public var onPerformUndo: (() -> Void)?
    public var onPerformRedo: (() -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "Cronologia Azioni")
    private let countLabel = NSTextField(labelWithString: "")
    private let undoBtn = NSButton()
    private let redoBtn = NSButton()

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor

        // 1. Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(header)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .white
        header.addSubview(titleLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        header.addSubview(countLabel)

        // 2. Center Table View
        setupTableView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        // 3. Bottom Bar with Undo / Redo buttons
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(bottomBar)

        undoBtn.translatesAutoresizingMaskIntoConstraints = false
        undoBtn.title = "↩ Annulla (⌘Z)"
        undoBtn.bezelStyle = .rounded
        undoBtn.target = self
        undoBtn.action = #selector(onUndoClicked)
        bottomBar.addSubview(undoBtn)

        redoBtn.translatesAutoresizingMaskIntoConstraints = false
        redoBtn.title = "↪ Ripeti (⇧⌘Z)"
        redoBtn.bezelStyle = .rounded
        redoBtn.target = self
        redoBtn.action = #selector(onRedoClicked)
        bottomBar.addSubview(redoBtn)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),

            countLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 42),

            undoBtn.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
            undoBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            undoBtn.widthAnchor.constraint(equalToConstant: 145),

            redoBtn.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12),
            redoBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            redoBtn.widthAnchor.constraint(equalToConstant: 145)
        ])

        self.view = root
        reloadHistoryUI()
    }

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 28
        tableView.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1.0)
        tableView.headerView = nil
        tableView.target = self
        tableView.doubleAction = #selector(onRowDoubleClicked)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Action"))
        col.width = 320
        tableView.addTableColumn(col)
    }

    public func reloadHistoryUI() {
        tableView.reloadData()
        let total = HistoryManager.shared.pastEntries.count + 1 + HistoryManager.shared.futureEntries.count
        countLabel.stringValue = "\(total) stati registrati"
        undoBtn.isEnabled = HistoryManager.shared.canUndo
        redoBtn.isEnabled = HistoryManager.shared.canRedo

        // Scroll alla riga attiva
        let currentRow = HistoryManager.shared.pastEntries.count
        if currentRow < total {
            tableView.scrollRowToVisible(currentRow)
        }
    }

    @objc private func onUndoClicked() {
        onPerformUndo?()
        reloadHistoryUI()
    }

    @objc private func onRedoClicked() {
        onPerformRedo?()
        reloadHistoryUI()
    }

    @objc private func onRowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }

        let pastCount = HistoryManager.shared.pastEntries.count
        if row < pastCount {
            // Salta a uno stato passato aggiornando gli stack Undo/Redo
            if let onJump = onJumpToHistory {
                onJump(row)
            } else {
                let targetSnapshot = HistoryManager.shared.pastEntries[row].snapshot
                onRestoreSnapshot?(targetSnapshot)
            }
            reloadHistoryUI()
        } else if row == pastCount {
            // Già sullo stato corrente
        } else {
            // Stato futuro (redo multiplo fino a questa riga)
            let steps = row - pastCount
            for _ in 0..<steps {
                onPerformRedo?()
            }
            reloadHistoryUI()
        }
    }

    // MARK: - Table View Data Source & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return HistoryManager.shared.pastEntries.count + 1 + HistoryManager.shared.futureEntries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let pastCount = HistoryManager.shared.pastEntries.count

        let cellId = NSUserInterfaceItemIdentifier("HistoryCell")
        var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = cellId

            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            cell?.addSubview(iconView)
            cell?.imageView = iconView

            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.isBordered = false
            tf.drawsBackground = false
            cell?.addSubview(tf)
            cell?.textField = tf

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 8),
                iconView.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 14),
                iconView.heightAnchor.constraint(equalToConstant: 14),

                tf.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
            ])
        }

        if row < pastCount {
            let entry = HistoryManager.shared.pastEntries[row]
            cell?.imageView?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            cell?.imageView?.contentTintColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
            cell?.textField?.stringValue = "\(entry.title)  (\(entry.formattedTime))"
            cell?.textField?.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
            cell?.textField?.font = NSFont.systemFont(ofSize: 11)
        } else if row == pastCount {
            cell?.imageView?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            cell?.imageView?.contentTintColor = .systemCyan
            cell?.textField?.stringValue = "● \(HistoryManager.shared.currentTitle) (ATTUALE)"
            cell?.textField?.textColor = .systemCyan
            cell?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        } else {
            let futureOffset = row - pastCount - 1
            let futureIndex = HistoryManager.shared.futureEntries.count - 1 - futureOffset
            if futureIndex >= 0 && futureIndex < HistoryManager.shared.futureEntries.count {
                let entry = HistoryManager.shared.futureEntries[futureIndex]
                cell?.imageView?.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
                cell?.imageView?.contentTintColor = NSColor(calibratedWhite: 0.35, alpha: 1.0)
                cell?.textField?.stringValue = "\(entry.title)  (Annullato)"
                cell?.textField?.textColor = NSColor(calibratedWhite: 0.45, alpha: 1.0)
                cell?.textField?.font = NSFont.systemFont(ofSize: 11)
            }
        }

        return cell
    }
}
