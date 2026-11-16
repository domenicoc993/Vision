import AppKit
import UniformTypeIdentifiers
import CoreMedia
import AVFoundation

public enum FocusedSection {
    case timeline
    case mediaPool
}

public protocol MediaPoolDelegate: AnyObject {
    func didSelectAddClipToTimeline(_ item: MediaItem)
    func didChangeMediaOrientation(_ item: MediaItem)
    func didSelectSeekToClip(_ clip: TimelineClip)
    func didReorderTimelineFromGrid()
    func didActivateSection(_ section: FocusedSection)
    func didSwitchActiveTimeline(to timeline: TimelineModel)
    func didDeleteMediaItemFromPool(_ item: MediaItem)
    func didUpdateTimelineFormat(_ timeline: TimelineModel)
    func didImportTimelinesFromXML(_ timelines: [TimelineModel])
    func didRequestExportTimelineToFCPXML(_ timeline: TimelineModel)
}

public let kMediaItemPasteboardType = NSPasteboard.PasteboardType("com.vision.mediaitem.id")
public let kSelectionPasteboardType = NSPasteboard.PasteboardType("com.vision.selection.id")

final class DragDropContainerView: NSView {
    var onURLsDropped: (([URL]) -> Void)?
    var onMouseDown: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = MediaPoolViewController.extractFileURLs(from: sender.draggingPasteboard)
        if !urls.isEmpty || sender.draggingPasteboard.types?.contains(.fileURL) == true {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = MediaPoolViewController.extractFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onURLsDropped?(urls)
        return true
    }
}

final class ContextMenuTableView: NSTableView {
    var onRightClick: ((NSEvent, Int) -> Void)?
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        onRightClick?(event, row)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}

public enum MediaPoolListItem {
    case timeline(TimelineModel, index: Int)
    case media(MediaItem)
    case folder(MediaFolder)
}

public final class MediaPoolViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
    public weak var delegate: MediaPoolDelegate?
    public var timelineModel: TimelineModel? {
        didSet {
            timelineGridView.timelineModel = timelineModel
            updateTrackPopUp()
        }
    }
    public private(set) var mediaItems: [MediaItem] = []

    public func setMediaItems(_ items: [MediaItem]) {
        self.mediaItems = items
        self.refreshMediaPoolDisplay()
    }

    public var displayedMediaItems: [MediaItem] {
        if let activeFId = EditorProject.shared.activeFolderId {
            guard let folder = EditorProject.shared.folders.first(where: { $0.id == activeFId }) else {
                return mediaItems
            }
            return mediaItems.filter { folder.itemIds.contains($0.id) }
        }
        return mediaItems
    }

    public var currentListItems: [MediaPoolListItem] {
        var items: [MediaPoolListItem] = []
        if EditorProject.shared.activeFolderId == nil {
            for (idx, tl) in EditorProject.shared.timelines.enumerated() {
                items.append(.timeline(tl, index: idx))
            }
        }
        for m in displayedMediaItems {
            items.append(.media(m))
        }
        if EditorProject.shared.activeFolderId == nil {
            for f in EditorProject.shared.folders {
                items.append(.folder(f))
            }
        }
        return items
    }

    public var selectedMediaItems: [MediaItem] {
        let selectedRows = contentTableView.selectedRowIndexes
        var items: [MediaItem] = []
        for idx in selectedRows where idx < currentListItems.count {
            if case .media(let m) = currentListItems[idx] {
                items.append(m)
            }
        }
        return items
    }

    public enum SidebarRow {
        case allFiles
        case folder(MediaFolder, Int)
    }

    public var sidebarRows: [SidebarRow] {
        var rows: [SidebarRow] = [.allFiles]
        for (idx, f) in EditorProject.shared.folders.enumerated() {
            rows.append(.folder(f, idx))
        }
        return rows
    }

    private enum ViewMode {
        case list
        case grid
    }
    private var currentViewMode: ViewMode = .list

    // Top Header Controls (Boxless Lucide Icons)
    private let mediaPoolTabBtn = IconActionButton(toolTip: "Media Pool")
    private let timelineGridTabBtn = IconActionButton(toolTip: "Timeline Grid")
    private let listModeBtn = IconActionButton(toolTip: "Vista Elenco (List)")
    private let gridModeBtn = IconActionButton(toolTip: "Vista Anteprime (Grid)")

    // Media Pool View Hierarchy
    private let mediaPoolContainer = NSView()
    private let splitView = NSSplitView()
    private var hasAppliedInitialSidebarWidth = false

    // Sidebar: Project & Folders
    private let sidebarContainer = NSView()
    private let sidebarTableView = ContextMenuTableView()
    private let sidebarScrollView = NSScrollView()

    // Content: Table & Grid
    private let contentContainer = NSView()
    private let contentTableView = ContextMenuTableView()
    private let contentTableScrollView = NSScrollView()
    private let gridView = MediaThumbnailGridView()
    private let gridScrollView = NSScrollView()
    private let emptyPlaceholderView = NSView()

    // Timeline Grid (Storyboard) Controls
    private let timelineGridContainer = NSView()
    public let timelineGridView = TimelineGridView()
    private let timelineGridScrollView = NSScrollView()
    private let trackPopUp = VisionDropdownButton()
    private let gridInfoLabel = NSTextField(labelWithString: "")

    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "m4b", "m4r", "aac", "alac", "flac", "aiff", "aif", "aifc", "caf",
        "ac3", "eac3", "opus", "ogg", "oga", "mp2", "mpa", "au", "snd", "wma"
    ]

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "mts", "m2ts", "prores", "webm", "3gp", "3g2", "mpg", "mpeg"
    ]

    public static let supportedMediaExtensions: Set<String> = audioExtensions.union(videoExtensions)

    public static func isSupportedMediaURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if supportedMediaExtensions.contains(ext) {
            return true
        }
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            return ut.conforms(to: .audiovisualContent) || ut.conforms(to: .audio) || ut.conforms(to: .movie) || ut.conforms(to: .video)
        }
        return false
    }

    public static func isAudioOnlyURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) {
            return true
        }
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            return ut.conforms(to: .audio) && !ut.conforms(to: .movie) && !ut.conforms(to: .video)
        }
        return false
    }

    public static func extractFileURLs(from pboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        var seenPaths: Set<String> = []
        func appendURL(_ url: URL?) {
            guard let url = url else { return }
            let path = url.standardizedFileURL.path
            guard !path.isEmpty, seenPaths.insert(path).inserted else { return }
            urls.append(url)
        }

        if let objs = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for u in objs { appendURL(u) }
        }
        if urls.isEmpty, let objs = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for u in objs where u.isFileURL { appendURL(u) }
        }
        if let legacyPaths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            for p in legacyPaths { appendURL(URL(fileURLWithPath: p)) }
        }
        if let pbItems = pboard.pasteboardItems {
            for item in pbItems {
                if let str = item.string(forType: .fileURL) ?? item.string(forType: .URL) {
                    if str.hasPrefix("file://") {
                        appendURL(URL(string: str))
                    } else if str.hasPrefix("/") {
                        appendURL(URL(fileURLWithPath: str))
                    }
                }
            }
        }
        return urls
    }

    private var supportedExtensions: Set<String> { Self.supportedMediaExtensions }

    public override func loadView() {
        let dropContainer = DragDropContainerView()
        dropContainer.wantsLayer = true
        dropContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1.0).cgColor
        dropContainer.onURLsDropped = { [weak self] urls in
            self?.processDroppedURLs(urls)
        }
        dropContainer.onMouseDown = { [weak self] in
            self?.delegate?.didActivateSection(.mediaPool)
        }

        // 1. Top Panel Header with Tabs (Left) and Flat View Mode Icons (Right)
        let topHeader = NSView()
        topHeader.translatesAutoresizingMaskIntoConstraints = false
        topHeader.wantsLayer = true
        topHeader.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        dropContainer.addSubview(topHeader)
        setupTopHeaderUI(topHeader)

        // 2. Setup Media Pool Container (Sidebar + Content SplitView)
        mediaPoolContainer.translatesAutoresizingMaskIntoConstraints = false
        dropContainer.addSubview(mediaPoolContainer)
        setupMediaPoolUI(in: mediaPoolContainer)

        // 3. Setup Timeline Grid (Storyboard) Container
        timelineGridContainer.translatesAutoresizingMaskIntoConstraints = false
        timelineGridContainer.isHidden = true
        dropContainer.addSubview(timelineGridContainer)
        setupTimelineGridUI(in: timelineGridContainer)

        NSLayoutConstraint.activate([
            topHeader.topAnchor.constraint(equalTo: dropContainer.topAnchor),
            topHeader.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            topHeader.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            topHeader.heightAnchor.constraint(equalToConstant: 38),

            mediaPoolContainer.topAnchor.constraint(equalTo: topHeader.bottomAnchor),
            mediaPoolContainer.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            mediaPoolContainer.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            mediaPoolContainer.bottomAnchor.constraint(equalTo: dropContainer.bottomAnchor),

            timelineGridContainer.topAnchor.constraint(equalTo: topHeader.bottomAnchor),
            timelineGridContainer.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            timelineGridContainer.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            timelineGridContainer.bottomAnchor.constraint(equalTo: dropContainer.bottomAnchor)
        ])

        refreshMediaPoolDisplay()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MediaItemProxyGenerated"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self,
                  let info = notif.userInfo,
                  let itemId = info["itemId"] as? UUID,
                  let proxyURL = info["proxyURL"] as? URL else { return }
            if let idx = self.mediaItems.firstIndex(where: { $0.id == itemId }) {
                self.mediaItems[idx].proxyURL = proxyURL
                self.refreshMediaPoolDisplay()
            }
        }

        self.view = dropContainer
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        if !hasAppliedInitialSidebarWidth && splitView.bounds.width > 300 {
            hasAppliedInitialSidebarWidth = true
            splitView.setPosition(155, ofDividerAt: 0)
        }
    }

    private func setupTopHeaderUI(_ topHeader: NSView) {
        let tabsStack = NSStackView()
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabsStack.orientation = .horizontal
        tabsStack.spacing = 10
        tabsStack.alignment = .centerY
        topHeader.addSubview(tabsStack)

        mediaPoolTabBtn.image = Lucide.template(.fileVideoCamera, size: 17)
        mediaPoolTabBtn.toolTip = "Media Pool"
        mediaPoolTabBtn.activeTintColor = .systemCyan
        mediaPoolTabBtn.isToggleActive = true
        mediaPoolTabBtn.target = self
        mediaPoolTabBtn.action = #selector(onMediaPoolTabClicked)
        mediaPoolTabBtn.widthAnchor.constraint(equalToConstant: 26).isActive = true
        mediaPoolTabBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        tabsStack.addArrangedSubview(mediaPoolTabBtn)

        timelineGridTabBtn.image = Lucide.template(.galleryHorizontalEnd, size: 17)
        timelineGridTabBtn.toolTip = "Timeline Grid"
        timelineGridTabBtn.activeTintColor = .systemCyan
        timelineGridTabBtn.isToggleActive = false
        timelineGridTabBtn.target = self
        timelineGridTabBtn.action = #selector(onTimelineGridTabClicked)
        timelineGridTabBtn.widthAnchor.constraint(equalToConstant: 26).isActive = true
        timelineGridTabBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        tabsStack.addArrangedSubview(timelineGridTabBtn)

        let viewModeStack = NSStackView()
        viewModeStack.translatesAutoresizingMaskIntoConstraints = false
        viewModeStack.orientation = .horizontal
        viewModeStack.spacing = 8
        viewModeStack.alignment = .centerY
        topHeader.addSubview(viewModeStack)

        listModeBtn.image = Lucide.template(.list, size: 16)
        listModeBtn.toolTip = "Vista Elenco (List)"
        listModeBtn.activeTintColor = .systemCyan
        listModeBtn.isToggleActive = true
        listModeBtn.target = self
        listModeBtn.action = #selector(onListModeClicked)
        listModeBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        listModeBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        viewModeStack.addArrangedSubview(listModeBtn)

        gridModeBtn.image = Lucide.template(.squarePlay, size: 16)
        gridModeBtn.toolTip = "Vista Anteprime (Grid)"
        gridModeBtn.activeTintColor = .systemCyan
        gridModeBtn.isToggleActive = false
        gridModeBtn.target = self
        gridModeBtn.action = #selector(onGridModeClicked)
        gridModeBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        gridModeBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        viewModeStack.addArrangedSubview(gridModeBtn)

        NSLayoutConstraint.activate([
            tabsStack.leadingAnchor.constraint(equalTo: topHeader.leadingAnchor, constant: 10),
            tabsStack.centerYAnchor.constraint(equalTo: topHeader.centerYAnchor),

            viewModeStack.trailingAnchor.constraint(equalTo: topHeader.trailingAnchor, constant: -10),
            viewModeStack.centerYAnchor.constraint(equalTo: topHeader.centerYAnchor)
        ])
    }

    private func setupMediaPoolUI(in container: NSView) {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        container.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        setupSidebarUI()
        splitView.addArrangedSubview(sidebarContainer)

        setupContentUI()
        splitView.addArrangedSubview(contentContainer)
    }

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 110
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return max(155, min(280, splitView.bounds.width - 180))
    }

    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let dividerThickness = splitView.dividerThickness
        let totalW = splitView.bounds.width
        let totalH = splitView.bounds.height
        guard totalW > 0, totalH > 0 else { return }

        let currentSidebarW = sidebarContainer.frame.width > 0 ? sidebarContainer.frame.width : 155
        let maxSidebarW = max(110, min(280, totalW - 180))
        let sidebarW = min(maxSidebarW, max(110, currentSidebarW))
        let contentW = max(0, totalW - sidebarW - dividerThickness)

        sidebarContainer.frame = NSRect(x: 0, y: 0, width: sidebarW, height: totalH)
        contentContainer.frame = NSRect(x: sidebarW + dividerThickness, y: 0, width: contentW, height: totalH)
    }

    private func setupSidebarUI() {
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor

        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarScrollView.documentView = sidebarTableView
        sidebarScrollView.borderType = .noBorder
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.hasHorizontalScroller = false
        sidebarScrollView.scrollerStyle = .overlay
        sidebarScrollView.autohidesScrollers = true
        sidebarScrollView.drawsBackground = false
        sidebarContainer.addSubview(sidebarScrollView)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarCol"))
        col.title = "Cartelle"
        sidebarTableView.addTableColumn(col)
        sidebarTableView.headerView = nil
        sidebarTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sidebarTableView.sizeLastColumnToFit()
        sidebarTableView.dataSource = self
        sidebarTableView.delegate = self
        sidebarTableView.doubleAction = #selector(onSidebarDoubleClicked)
        sidebarTableView.target = self
        sidebarTableView.backgroundColor = .clear
        sidebarTableView.selectionHighlightStyle = .regular
        sidebarTableView.registerForDraggedTypes([kMediaItemPasteboardType, .fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        sidebarTableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        sidebarTableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        sidebarTableView.onMouseDown = { [weak self] in
            self?.delegate?.didActivateSection(.mediaPool)
        }
        sidebarTableView.onRightClick = { [weak self] event, row in
            self?.showSidebarContextMenu(forRow: row, event: event)
        }

        NSLayoutConstraint.activate([
            sidebarScrollView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 4),
            sidebarScrollView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarScrollView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarScrollView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor)
        ])
    }

    private func setupContentUI() {
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor

        contentTableScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentTableScrollView.documentView = contentTableView
        contentTableScrollView.borderType = .noBorder
        contentTableScrollView.hasVerticalScroller = true
        contentTableScrollView.hasHorizontalScroller = false
        contentTableScrollView.scrollerStyle = .overlay
        contentTableScrollView.autohidesScrollers = true
        contentTableScrollView.drawsBackground = false
        contentContainer.addSubview(contentTableScrollView)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        colName.title = "Nome Clip"
        colName.width = 160
        contentTableView.addTableColumn(colName)

        let colDur = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Duration"))
        colDur.title = "Durata"
        colDur.width = 65
        contentTableView.addTableColumn(colDur)

        let colCodec = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Codec"))
        colCodec.title = "Formato"
        colCodec.width = 140
        contentTableView.addTableColumn(colCodec)

        contentTableView.dataSource = self
        contentTableView.delegate = self
        contentTableView.doubleAction = #selector(onTableRowDoubleClicked)
        contentTableView.target = self
        contentTableView.usesAlternatingRowBackgroundColors = false
        contentTableView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        contentTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        contentTableView.registerForDraggedTypes([kMediaItemPasteboardType, .fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        contentTableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        contentTableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        contentTableView.allowsMultipleSelection = true
        contentTableView.onMouseDown = { [weak self] in
            self?.delegate?.didActivateSection(.mediaPool)
        }
        contentTableView.onRightClick = { [weak self] event, row in
            self?.showContentContextMenu(forRow: row, event: event)
        }

        // Grid View Setup
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false
        gridScrollView.documentView = gridView
        gridScrollView.borderType = .noBorder
        gridScrollView.hasVerticalScroller = true
        gridScrollView.hasHorizontalScroller = false
        gridScrollView.scrollerStyle = .overlay
        gridScrollView.autohidesScrollers = true
        gridScrollView.drawsBackground = false
        gridScrollView.isHidden = true
        contentContainer.addSubview(gridScrollView)

        gridView.onClipDoubleClicked = { [weak self] item in
            self?.delegate?.didActivateSection(.mediaPool)
            self?.delegate?.didSelectAddClipToTimeline(item)
        }
        gridView.onClipSelected = { [weak self] item, modifiers in
            guard let self = self else { return }
            self.delegate?.didActivateSection(.mediaPool)
            if let idx = self.currentListItems.firstIndex(where: {
                if case .media(let m) = $0 { return m.id == item.id }
                return false
            }) {
                if modifiers.contains(.shift) {
                    var current = self.contentTableView.selectedRowIndexes
                    if current.contains(idx) {
                        current.remove(idx)
                    } else {
                        current.insert(idx)
                    }
                    self.contentTableView.selectRowIndexes(current, byExtendingSelection: false)
                } else {
                    self.contentTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                }
            }
        }
        gridView.onOrientationChanged = { [weak self] item, orient in
            if let idx = self?.mediaItems.firstIndex(where: { $0.id == item.id }) {
                self?.setClipOrientation(at: idx, orientation: orient)
            }
        }
        gridView.onMoveItemToFolder = { [weak self] itemId, targetFolderId in
            EditorProject.shared.moveItem(itemId, toFolder: targetFolderId)
            self?.refreshMediaPoolDisplay()
            DebugLogger.shared.log("Clip spostata nella cartella", level: .info)
        }
        gridView.onInsertToTimeline = { [weak self] item in
            self?.delegate?.didActivateSection(.mediaPool)
            self?.delegate?.didSelectAddClipToTimeline(item)
        }
        gridView.onDeleteFromPool = { [weak self] item in
            self?.deleteMediaItem(item)
        }
        gridView.onURLsDropped = { [weak self] urls in
            self?.processDroppedURLs(urls)
        }
        gridView.onDropURLsIntoFolder = { [weak self] urls, folderId in
            self?.processDroppedURLs(urls, targetFolderId: folderId)
        }
        gridView.onContextMenuRequested = { [weak self] event in
            self?.showGeneralContextMenu(event: event)
        }
        gridView.onOpenTimeline = { [weak self] tl, idx in
            self?.delegate?.didActivateSection(.mediaPool)
            EditorProject.shared.activeTimelineIndex = idx
            self?.delegate?.didSwitchActiveTimeline(to: tl)
            self?.refreshMediaPoolDisplay()
        }
        gridView.onRenameTimeline = { [weak self] idx in
            self?.showRenameTimelineDialog(timelineIndex: idx)
        }
        gridView.onDuplicateTimeline = { [weak self] idx in
            self?.duplicateTimeline(index: idx)
        }
        gridView.onTimelineSettings = { [weak self] tl, _ in
            self?.showTimelineSettingsDialog(for: tl)
        }
        gridView.onConvertToSelection = { [weak self] idx in
            self?.convertTimelineToSelection(index: idx)
        }
        gridView.onConvertToTimeline = { [weak self] idx in
            self?.convertSelectionToTimeline(index: idx)
        }
        gridView.onExportTimeline = { [weak self] tl, _ in
            self?.delegate?.didRequestExportTimelineToFCPXML(tl)
        }
        gridView.onDeleteTimeline = { [weak self] idx in
            self?.deleteTimeline(index: idx)
        }
        gridView.onOpenFolder = { [weak self] f in
            self?.delegate?.didActivateSection(.mediaPool)
            EditorProject.shared.activeFolderId = f.id
            self?.refreshMediaPoolDisplay()
        }
        gridView.onRenameFolder = { [weak self] f in
            self?.showRenameFolderDialog(folder: f)
        }
        gridView.onDeleteFolder = { [weak self] f in
            self?.deleteFolder(id: f.id)
        }
        gridView.onDropItemsIntoFolder = { [weak self] ids, fId in
            for id in ids {
                EditorProject.shared.moveItem(id, toFolder: fId)
            }
            self?.refreshMediaPoolDisplay()
            DebugLogger.shared.log("Clip spostate nella cartella (Grid drop)", level: .info)
        }

        setupEmptyPlaceholder(in: contentContainer)

        NSLayoutConstraint.activate([
            contentTableScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentTableScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentTableScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentTableScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            gridScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    private func setupTimelineGridUI(in container: NSView) {
        let subHeader = NSView()
        subHeader.translatesAutoresizingMaskIntoConstraints = false
        subHeader.wantsLayer = true
        subHeader.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        container.addSubview(subHeader)

        let trackLabel = NSTextField(labelWithString: "Traccia:")
        trackLabel.translatesAutoresizingMaskIntoConstraints = false
        trackLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        subHeader.addSubview(trackLabel)

        trackPopUp.translatesAutoresizingMaskIntoConstraints = false
        trackPopUp.target = self
        trackPopUp.action = #selector(onTrackPopUpChanged)
        subHeader.addSubview(trackPopUp)

        gridInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        gridInfoLabel.font = NSFont.systemFont(ofSize: 11)
        gridInfoLabel.textColor = .secondaryLabelColor
        subHeader.addSubview(gridInfoLabel)

        timelineGridScrollView.translatesAutoresizingMaskIntoConstraints = false
        timelineGridScrollView.documentView = timelineGridView
        timelineGridScrollView.hasVerticalScroller = true
        timelineGridScrollView.hasHorizontalScroller = false
        timelineGridScrollView.drawsBackground = false
        container.addSubview(timelineGridScrollView)

        timelineGridView.onClipSelected = { [weak self] clip in
            self?.delegate?.didActivateSection(.mediaPool)
            self?.delegate?.didSelectSeekToClip(clip)
        }
        timelineGridView.onReorderCommitted = { [weak self] in
            self?.delegate?.didReorderTimelineFromGrid()
            self?.updateTimelineGridInfo()
        }
        timelineGridView.onSectionActivated = { [weak self] in
            self?.delegate?.didActivateSection(.mediaPool)
        }

        NSLayoutConstraint.activate([
            subHeader.topAnchor.constraint(equalTo: container.topAnchor),
            subHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subHeader.heightAnchor.constraint(equalToConstant: 34),

            trackLabel.leadingAnchor.constraint(equalTo: subHeader.leadingAnchor, constant: 10),
            trackLabel.centerYAnchor.constraint(equalTo: subHeader.centerYAnchor),

            trackPopUp.leadingAnchor.constraint(equalTo: trackLabel.trailingAnchor, constant: 4),
            trackPopUp.centerYAnchor.constraint(equalTo: subHeader.centerYAnchor),
            trackPopUp.widthAnchor.constraint(equalToConstant: 75),

            gridInfoLabel.leadingAnchor.constraint(equalTo: trackPopUp.trailingAnchor, constant: 10),
            gridInfoLabel.centerYAnchor.constraint(equalTo: subHeader.centerYAnchor),

            timelineGridScrollView.topAnchor.constraint(equalTo: subHeader.bottomAnchor),
            timelineGridScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            timelineGridScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            timelineGridScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func setupEmptyPlaceholder(in container: NSView) {
        emptyPlaceholderView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyPlaceholderView)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        emptyPlaceholderView.addSubview(iconView)

        let label = NSTextField(labelWithString: "Trascina qui file video, audio o cartelle\n(Formati: MOV, MP4, ProRes, WAV, MP3, M4A, ecc.)")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = NSFont.systemFont(ofSize: 11)
        emptyPlaceholderView.addSubview(label)

        NSLayoutConstraint.activate([
            emptyPlaceholderView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyPlaceholderView.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            iconView.centerXAnchor.constraint(equalTo: emptyPlaceholderView.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: emptyPlaceholderView.topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: emptyPlaceholderView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: emptyPlaceholderView.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: emptyPlaceholderView.bottomAnchor)
        ])
    }

    // MARK: - Tab & View Mode Actions
    @objc private func onMediaPoolTabClicked() {
        delegate?.didActivateSection(.mediaPool)
        mediaPoolTabBtn.isToggleActive = true
        timelineGridTabBtn.isToggleActive = false
        listModeBtn.isHidden = false
        gridModeBtn.isHidden = false
        mediaPoolContainer.isHidden = false
        timelineGridContainer.isHidden = true
    }

    @objc private func onTimelineGridTabClicked() {
        delegate?.didActivateSection(.mediaPool)
        mediaPoolTabBtn.isToggleActive = false
        timelineGridTabBtn.isToggleActive = true
        listModeBtn.isHidden = true
        gridModeBtn.isHidden = true
        mediaPoolContainer.isHidden = true
        timelineGridContainer.isHidden = false
        refreshTimelineGrid()
        timelineGridView.updateLayoutForCurrentWidth()
    }

    @objc private func onListModeClicked() {
        delegate?.didActivateSection(.mediaPool)
        currentViewMode = .list
        listModeBtn.isToggleActive = true
        gridModeBtn.isToggleActive = false
        updateContentModeVisibility()
    }

    @objc private func onGridModeClicked() {
        delegate?.didActivateSection(.mediaPool)
        currentViewMode = .grid
        listModeBtn.isToggleActive = false
        gridModeBtn.isToggleActive = true
        updateContentModeVisibility()
    }

    private func updateContentModeVisibility() {
        let hasItems = !currentListItems.isEmpty
        emptyPlaceholderView.isHidden = hasItems

        if currentViewMode == .list {
            contentTableScrollView.isHidden = !hasItems
            gridScrollView.isHidden = true
            contentTableView.reloadData()
        } else {
            contentTableScrollView.isHidden = true
            gridScrollView.isHidden = !hasItems

            var items: [GridCardItem] = []
            if EditorProject.shared.activeFolderId == nil {
                for (idx, tl) in EditorProject.shared.timelines.enumerated() {
                    items.append(.timeline(tl, index: idx))
                }
            }
            for m in displayedMediaItems {
                items.append(.media(m))
            }
            if EditorProject.shared.activeFolderId == nil {
                for f in EditorProject.shared.folders {
                    items.append(.folder(f))
                }
            }
            gridView.gridItems = items

            let selectedRows = contentTableView.selectedRowIndexes
            let selectedIds = selectedRows.compactMap { (idx: Int) -> UUID? in
                if idx < currentListItems.count {
                    switch currentListItems[idx] {
                    case .media(let m): return m.id
                    case .timeline(let tl, _): return tl.id
                    case .folder(let f): return f.id
                    }
                }
                return nil
            }
            gridView.selectedItemIds = Set(selectedIds)
        }
    }

    public func refreshMediaPoolDisplay() {
        sidebarTableView.reloadData()
        updateSidebarSelection()
        contentTableView.reloadData()
        updateContentModeVisibility()
    }

    private func updateSidebarSelection() {
        if let activeFId = EditorProject.shared.activeFolderId,
           let idx = EditorProject.shared.folders.firstIndex(where: { $0.id == activeFId }) {
            sidebarTableView.selectRowIndexes(IndexSet(integer: idx + 1), byExtendingSelection: false)
        } else {
            sidebarTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // Compatibility methods for MainEditorViewController
    public func updateTimelinePopUp() {
        refreshMediaPoolDisplay()
    }

    public func updateFolderPopUp() {
        refreshMediaPoolDisplay()
    }

    public func selectAllMediaItems() {
        delegate?.didActivateSection(.mediaPool)
        if timelineGridContainer.isHidden {
            if currentViewMode == .list {
                contentTableView.selectAll(nil)
            } else {
                gridView.selectedItemIds = Set(displayedMediaItems.map(\.id))
            }
        } else {
            timelineGridView.selectAllClips()
        }
    }

    public func mediaItem(for id: UUID) -> MediaItem? {
        mediaItems.first(where: { $0.id == id })
    }

    public func mediaItem(for url: URL) -> MediaItem? {
        mediaItems.first(where: {
            $0.url == url ||
            $0.url.path == url.path ||
            $0.url.standardizedFileURL == url.standardizedFileURL
        })
    }

    // MARK: - Context Menus (Menu Contestuale)
    // MARK: - Context Menus (Custom Rounded VisionMenu + Lucide)
    private func generalContextMenuItems() -> [VisionMenuItem] {
        [
            .action(title: "Nuova cartella", icon: .folder, iconColor: .systemOrange) { [weak self] in
                self?.showNewFolderDialog()
            },
            .action(title: "Nuova timeline", icon: .clapperboard, iconColor: .systemCyan) { [weak self] in
                self?.showNewTimelineDialog()
            },
            .action(title: "Nuova selezione (1V+1A)", icon: .sparkles, iconColor: .systemPurple) { [weak self] in
                self?.showNewSelectionDialog()
            },
            .separator,
            .action(title: "Importa file / XML...", icon: .download) { [weak self] in
                self?.importFilesWithPanel()
            },
            .action(title: "Importa cartella...", icon: .folderInput) { [weak self] in
                self?.importFolderWithPanel()
            }
        ]
    }

    private func showGeneralContextMenu(event: NSEvent) {
        VisionMenu(items: generalContextMenuItems()).show(for: event, in: self.view)
    }

    private func showSidebarContextMenu(forRow row: Int, event: NSEvent) {
        var items: [VisionMenuItem]
        if row == 0 {
            items = generalContextMenuItems()
        } else if row > 0 && row - 1 < EditorProject.shared.folders.count {
            let folder = EditorProject.shared.folders[row - 1]
            items = [
                .header(folder.name),
                .action(title: "Apri cartella", icon: .folder, iconColor: .systemOrange) { [weak self] in
                    EditorProject.shared.activeFolderId = folder.id
                    self?.refreshMediaPoolDisplay()
                },
                .action(title: "Rinomina cartella...", icon: .pencil) { [weak self] in
                    self?.showRenameFolderDialog(folder: folder)
                },
                .separator,
                .action(title: "Elimina cartella", icon: .trash, isDestructive: true) { [weak self] in
                    self?.deleteFolder(id: folder.id)
                }
            ]
        } else {
            items = generalContextMenuItems()
        }
        VisionMenu(items: items).show(for: event, in: self.view)
    }

    private func showContentContextMenu(forRow row: Int, event: NSEvent) {
        guard row >= 0 && row < currentListItems.count else {
            showGeneralContextMenu(event: event)
            return
        }

        let item = currentListItems[row]
        var items: [VisionMenuItem] = []

        switch item {
        case .timeline(let timeline, let index):
            let kindTitle = timeline.isSelection ? "Selezione" : "Timeline"
            items.append(.header(timeline.name))
            items.append(.action(title: "Apri \(kindTitle)", icon: timeline.isSelection ? .sparkles : .play, iconColor: timeline.isSelection ? .systemPurple : .systemCyan) { [weak self] in
                guard index < EditorProject.shared.timelines.count else { return }
                EditorProject.shared.activeTimelineIndex = index
                let tl = EditorProject.shared.timelines[index]
                self?.delegate?.didSwitchActiveTimeline(to: tl)
                self?.refreshMediaPoolDisplay()
            })
            items.append(.action(title: "Impostazioni timeline...", icon: .settings2) { [weak self] in
                self?.showTimelineSettingsDialog(for: timeline)
            })
            items.append(.action(title: "Rinomina...", icon: .pencil) { [weak self] in
                self?.showRenameTimelineDialog(timelineIndex: index)
            })
            items.append(.action(title: "Duplica", icon: .copy) { [weak self] in
                self?.duplicateTimeline(index: index)
            })
            items.append(.action(title: "Esporta Final Cut XML (.fcpxmld)...", icon: .fileCode2, iconColor: .systemCyan) { [weak self] in
                self?.delegate?.didRequestExportTimelineToFCPXML(timeline)
            })
            items.append(.separator)
            if timeline.isSelection {
                items.append(.action(title: "Converti in Timeline normale", icon: .arrowLeftRight, iconColor: .systemCyan) { [weak self] in
                    self?.convertSelectionToTimeline(index: index)
                })
            } else {
                let canConvert = timeline.canConvertToSelection.allowed
                items.append(.action(
                    title: canConvert ? "Converti in Selezione (1V+1A)" : "Converti in Selezione (solo V1/A1)",
                    icon: .sparkles,
                    iconColor: .systemPurple,
                    isEnabled: canConvert
                ) { [weak self] in
                    self?.convertTimelineToSelection(index: index)
                })
            }
            if EditorProject.shared.timelines.count > 1 {
                items.append(.separator)
                items.append(.action(title: "Elimina", icon: .trash, isDestructive: true) { [weak self] in
                    self?.deleteTimeline(index: index)
                })
            }

        case .folder(let folder):
            items.append(.header(folder.name))
            items.append(.action(title: "Apri cartella", icon: .folder, iconColor: .systemOrange) { [weak self] in
                EditorProject.shared.activeFolderId = folder.id
                self?.refreshMediaPoolDisplay()
            })
            items.append(.action(title: "Rinomina cartella...", icon: .pencil) { [weak self] in
                self?.showRenameFolderDialog(folder: folder)
            })
            items.append(.separator)
            items.append(.action(title: "Elimina cartella", icon: .trash, isDestructive: true) { [weak self] in
                self?.deleteFolder(id: folder.id)
            })

        case .media(let media):
            items.append(.header(media.name))
            items.append(.action(title: "Inserisci in timeline", icon: .plus, iconColor: .systemCyan) { [weak self] in
                self?.delegate?.didSelectAddClipToTimeline(media)
            })

            if media.hasVideo {
                let orientChildren: [VisionMenuItem] = ClipOrientation.allCases.map { orient in
                    .action(title: orient.rawValue, isSelected: media.orientation == orient) { [weak self] in
                        if let idx = self?.mediaItems.firstIndex(where: { $0.id == media.id }) {
                            self?.setClipOrientation(at: idx, orientation: orient)
                        }
                    }
                }
                items.append(.submenu(title: "Orientamento clip", icon: .rotateCw, items: orientChildren))
            }

            var folderChildren: [VisionMenuItem] = [
                .action(title: "Principale (Nessuna)", icon: .layers) { [weak self] in
                    EditorProject.shared.moveItem(media.id, toFolder: nil)
                    self?.refreshMediaPoolDisplay()
                }
            ]
            for f in EditorProject.shared.folders {
                folderChildren.append(.action(title: f.name, icon: .folder, iconColor: .systemOrange) { [weak self] in
                    EditorProject.shared.moveItem(media.id, toFolder: f.id)
                    self?.refreshMediaPoolDisplay()
                })
            }
            items.append(.submenu(title: "Sposta in cartella", icon: .folderInput, items: folderChildren))

            items.append(.separator)
            items.append(.action(title: "Crea Nuova Selezione...", icon: .sparkles, iconColor: .systemPurple) { [weak self] in
                self?.createSelectionFromMedia(fallback: media)
            })
            items.append(.action(title: "Crea Proxy Video...", icon: .zap, iconColor: .systemTeal) { [weak self] in
                self?.generateProxyForMedia(fallback: media)
            })
            items.append(.separator)
            items.append(.action(title: "Elimina dal Media Pool", icon: .trash, isDestructive: true) { [weak self] in
                self?.deleteMediaItem(media)
            })
        }

        VisionMenu(items: items).show(for: event, in: self.view)
    }

    private func createSelectionFromMedia(fallback: MediaItem? = nil) {
        var chosen = selectedMediaItems
        if chosen.isEmpty, let m = fallback {
            chosen = [m]
        }
        let clipsToUse = chosen.isEmpty ? mediaItems : chosen
        guard !clipsToUse.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Nuova Selezione"
        alert.informativeText = "Inserisci un nome per la selezione di \(clipsToUse.count) clip:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = "Selezione \(EditorProject.shared.selectionTimelines.count + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newSel = EditorProject.shared.createSelection(name: name.isEmpty ? "Selezione" : name, clips: clipsToUse)
            refreshMediaPoolDisplay()
            delegate?.didSwitchActiveTimeline(to: newSel)
            DebugLogger.shared.log("Creata selezione '\(newSel.name)' con \(clipsToUse.count) clip dal Media Pool.", level: .info)
        }
    }

    private func generateProxyForMedia(fallback: MediaItem? = nil) {
        var chosen = selectedMediaItems
        if chosen.isEmpty, let m = fallback {
            chosen = [m]
        }
        let clipsToUse = chosen.isEmpty ? mediaItems : chosen
        guard !clipsToUse.isEmpty else { return }

        let dialog = ProxyGenerationDialog(mediaItems: clipsToUse) { [weak self] in
            DispatchQueue.main.async {
                self?.contentTableView.reloadData()
                self?.timelineGridView.reloadData()
            }
        }
        dialog.showWindow(nil)
    }

    @objc private func onSidebarDoubleClicked() {
        delegate?.didActivateSection(.mediaPool)
        let row = sidebarTableView.clickedRow
        guard row >= 0 && row < sidebarRows.count else { return }
        switch sidebarRows[row] {
        case .allFiles:
            showRenameProjectDialog()
        case .folder(let folder, _):
            showRenameFolderDialog(folder: folder)
        }
    }

    // MARK: - Dialogs & Mutations
    private func showNewFolderDialog() {
        delegate?.didActivateSection(.mediaPool)
        let alert = NSAlert()
        alert.messageText = "Nuova Cartella"
        alert.informativeText = "Inserisci il nome per la nuova cartella:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = "Cartella \(EditorProject.shared.folders.count + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let folder = EditorProject.shared.addFolder(name: name)
                EditorProject.shared.activeFolderId = folder.id
                refreshMediaPoolDisplay()
                DebugLogger.shared.log("Creata cartella: '\(folder.name)'", level: .info)
            }
        }
    }

    private func showRenameFolderDialog(folder: MediaFolder) {
        delegate?.didActivateSection(.mediaPool)
        let alert = NSAlert()
        alert.messageText = "Rinomina Cartella"
        alert.informativeText = "Nuovo nome per '\(folder.name)':"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = folder.name
        alert.accessoryView = input
        alert.addButton(withTitle: "Rinomina")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                EditorProject.shared.renameFolder(id: folder.id, newName: name)
                refreshMediaPoolDisplay()
            }
        }
    }

    private func deleteFolder(id: UUID) {
        EditorProject.shared.removeFolder(id: id)
        refreshMediaPoolDisplay()
    }

    private func showNewTimelineDialog() {
        delegate?.didActivateSection(.mediaPool)
        let alert = NSAlert()
        alert.messageText = "Nuova Timeline"
        alert.informativeText = "Inserisci il nome per la nuova timeline:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = "Timeline \(EditorProject.shared.timelines.count + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newTimeline = EditorProject.shared.addTimeline(name: name.isEmpty ? nil : name)
            refreshMediaPoolDisplay()
            delegate?.didSwitchActiveTimeline(to: newTimeline)
            DebugLogger.shared.log("Creata nuova timeline: '\(newTimeline.name)'", level: .info)
        }
    }

    private func showRenameTimelineDialog(timelineIndex: Int) {
        guard timelineIndex < EditorProject.shared.timelines.count else { return }
        let currentName = EditorProject.shared.timelines[timelineIndex].name
        let alert = NSAlert()
        alert.messageText = "Rinomina Timeline"
        alert.informativeText = "Nuovo nome per '\(currentName)':"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = currentName
        alert.accessoryView = input
        alert.addButton(withTitle: "Rinomina")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                EditorProject.shared.renameTimeline(index: timelineIndex, newName: name)
                refreshMediaPoolDisplay()
            }
        }
    }

    private func showNewSelectionDialog() {
        delegate?.didActivateSection(.mediaPool)
        let alert = NSAlert()
        alert.messageText = "Nuova Selezione"
        alert.informativeText = "Crea una timeline Selezione (max 1 traccia Video V1 e 1 traccia Audio A1):"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = "Selezione \(EditorProject.shared.selectionTimelines.count + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newSelection = EditorProject.shared.addTimeline(name: name.isEmpty ? nil : name, isSelection: true)
            refreshMediaPoolDisplay()
            delegate?.didSwitchActiveTimeline(to: newSelection)
            DebugLogger.shared.log("Creata nuova selezione: '\(newSelection.name)'", level: .info)
        }
    }

    private func duplicateTimeline(index: Int) {
        guard let copy = EditorProject.shared.duplicateTimeline(index: index) else { return }
        refreshMediaPoolDisplay()
        delegate?.didSwitchActiveTimeline(to: copy)
        DebugLogger.shared.log("Duplicata timeline '\(copy.name)'", level: .info)
    }

    private func convertTimelineToSelection(index: Int) {
        guard index >= 0 && index < EditorProject.shared.timelines.count else { return }
        let tl = EditorProject.shared.timelines[index]
        guard tl.convertToSelection() else {
            let alert = NSAlert()
            alert.messageText = "Conversione non disponibile"
            alert.informativeText = "La timeline '\(tl.name)' contiene clip su più tracce (V2+, A2+ o tracce secondarie). Per convertirla in Selezione deve avere clip solo su V1 e A1."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        refreshMediaPoolDisplay()
        if EditorProject.shared.activeTimeline.id == tl.id {
            delegate?.didSwitchActiveTimeline(to: tl)
        }
        DebugLogger.shared.log("Timeline '\(tl.name)' convertita in Selezione (1V+1A).", level: .info)
    }

    private func convertSelectionToTimeline(index: Int) {
        guard index >= 0 && index < EditorProject.shared.timelines.count else { return }
        let tl = EditorProject.shared.timelines[index]
        tl.convertToTimeline()
        refreshMediaPoolDisplay()
        if EditorProject.shared.activeTimeline.id == tl.id {
            delegate?.didSwitchActiveTimeline(to: tl)
        }
        DebugLogger.shared.log("Selezione '\(tl.name)' convertita in Timeline normale.", level: .info)
    }

    private func deleteTimeline(index: Int) {
        guard EditorProject.shared.timelines.count > 1 else { return }
        EditorProject.shared.removeTimeline(index: index)
        refreshMediaPoolDisplay()
        delegate?.didSwitchActiveTimeline(to: EditorProject.shared.activeTimeline)
    }

    private func showTimelineSettingsDialog(for timeline: TimelineModel) {
        delegate?.didActivateSection(.mediaPool)
        if let updatedFormat = TimelineSettingsDialog.runModal(for: timeline, on: view.window) {
            timeline.format = updatedFormat
            delegate?.didUpdateTimelineFormat(timeline)
            refreshMediaPoolDisplay()
            DebugLogger.shared.log("Impostazioni timeline '\(timeline.name)' aggiornate: \(updatedFormat.name) (\(updatedFormat.fps) fps)", level: .info)
        }
    }

    private func showRenameProjectDialog() {
        let alert = NSAlert()
        alert.messageText = "Rinomina Progetto"
        alert.informativeText = "Inserisci il nome del progetto:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = EditorProject.shared.projectName
        alert.accessoryView = input
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                EditorProject.shared.projectName = name
            }
        }
    }

    private func deleteMediaItem(_ item: MediaItem) {
        mediaItems.removeAll(where: { $0.id == item.id })
        for i in 0..<EditorProject.shared.folders.count {
            EditorProject.shared.folders[i].itemIds.remove(item.id)
        }
        for timeline in EditorProject.shared.timelines {
            timeline.markOrphans(forMediaId: item.id)
        }
        refreshMediaPoolDisplay()
        delegate?.didDeleteMediaItemFromPool(item)
        DebugLogger.shared.log("Clip '\(item.name)' eliminata dal Media Pool e contrassegnata come orfana.", level: .info)
    }

    private func importFilesWithPanel() {
        delegate?.didActivateSection(.mediaPool)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        var types: [UTType] = [
            UTType.movie, UTType.video, UTType.quickTimeMovie, UTType.mpeg4Movie,
            UTType.audio, UTType.mp3, UTType.wav, UTType.aiff, UTType.mpeg4Audio,
            UTType.xml
        ]
        if let fcpxml = UTType(filenameExtension: "fcpxml") { types.append(fcpxml) }
        if let fcpxmld = UTType(filenameExtension: "fcpxmld") { types.append(fcpxmld) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK {
            processDroppedURLs(panel.urls)
        }
    }

    private func importFolderWithPanel() {
        delegate?.didActivateSection(.mediaPool)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK {
            processDroppedURLs(panel.urls)
        }
    }

    private func setClipOrientation(at row: Int, orientation: ClipOrientation) {
        guard row >= 0 && row < mediaItems.count else { return }
        mediaItems[row].orientation = orientation
        refreshMediaPoolDisplay()
        delegate?.didChangeMediaOrientation(mediaItems[row])
    }

    public func processDroppedURLs(_ urls: [URL], targetFolderId: UUID? = nil) {
        var itemsToAdd: [URL] = []
        let fileManager = FileManager.default
        let resolvedFolderId = targetFolderId ?? EditorProject.shared.activeFolderId

        for url in urls {
            // FCPXML / .fcpxmld bundles appear as directories to FileManager, so check XML first
            if FCPXMLImporter.isSupportedXMLURL(url) {
                importFCPXML(url: url)
                continue
            }

            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    let folderName = url.lastPathComponent
                    let targetFolder: MediaFolder
                    if let existing = EditorProject.shared.folders.first(where: { $0.name == folderName }) {
                        targetFolder = existing
                    } else {
                        targetFolder = EditorProject.shared.addFolder(name: folderName)
                    }

                    do {
                        let contents = try fileManager.contentsOfDirectory(
                            at: url,
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles]
                        )
                        var folderMediaURLs: [URL] = []
                        for itemURL in contents {
                            var itemIsDir: ObjCBool = false
                            if fileManager.fileExists(atPath: itemURL.path, isDirectory: &itemIsDir), !itemIsDir.boolValue {
                                if Self.isSupportedMediaURL(itemURL) {
                                    folderMediaURLs.append(itemURL)
                                }
                            }
                        }
                        folderMediaURLs.sort(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                        importURLs(folderMediaURLs, targetFolderId: targetFolder.id)
                    } catch {}
                } else {
                    if Self.isSupportedMediaURL(url) {
                        itemsToAdd.append(url)
                    } else {
                        DebugLogger.shared.log("Formato non supportato per '\(url.lastPathComponent)' (estensione .\(url.pathExtension)).", level: .warning)
                    }
                }
            }
        }

        if !itemsToAdd.isEmpty {
            itemsToAdd.sort(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            importURLs(itemsToAdd, targetFolderId: resolvedFolderId)
        }
    }

    public func importFCPXML(url: URL) {
        let snapshotMedia = self.mediaItems
        let snapshotFolders = EditorProject.shared.folders
        Task {
            do {
                let result = try await FCPXMLImporter.importFromURL(
                    url,
                    existingMedia: snapshotMedia,
                    existingFolders: snapshotFolders
                )
                await MainActor.run {
                    if !result.newlyImportedMedia.isEmpty {
                        self.mediaItems.append(contentsOf: result.newlyImportedMedia)
                        for m in result.newlyImportedMedia {
                            AudioWaveformCache.shared.loadWaveform(for: m)
                        }
                    }

                    if let folder = result.createdFolder,
                       !EditorProject.shared.folders.contains(where: { $0.id == folder.id }) {
                        EditorProject.shared.folders.append(folder)
                        for itemId in result.folderItemIds {
                            EditorProject.shared.moveItem(itemId, toFolder: folder.id)
                        }
                    }

                    if !result.importedTimelines.isEmpty {
                        self.delegate?.didImportTimelinesFromXML(result.importedTimelines)
                    } else {
                        self.refreshMediaPoolDisplay()
                    }

                    DebugLogger.shared.log(
                        "Importato XML '\(url.lastPathComponent)': \(result.newMediaCount) nuove clip, \(result.relinkedCount) ricollegate, \(result.missingCount) offline, \(result.importedTimelines.count) selezioni/timeline.",
                        level: .info
                    )
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Errore Importazione XML"
                    alert.informativeText = "Impossibile importare '\(url.lastPathComponent)': \(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private func importURLs(_ urls: [URL], targetFolderId: UUID? = nil, completion: (([MediaItem]) -> Void)? = nil) {
        guard !urls.isEmpty else {
            completion?([])
            return
        }
        Task {
            var loadedOrExisting: [MediaItem] = []
            for url in urls {
                let stdPath = url.standardizedFileURL.path
                if let existing = await MainActor.run(body: {
                    self.mediaItems.first(where: { $0.url.standardizedFileURL.path == stdPath })
                }) {
                    loadedOrExisting.append(existing)
                    continue
                }
                do {
                    await CompositionEngine.shared.preloadMetadata(for: url)
                    let item = try await MediaItem.load(from: url)
                    let resolved: MediaItem = await MainActor.run {
                        if let existing = self.mediaItems.first(where: { $0.url.standardizedFileURL.path == stdPath }) {
                            return existing
                        } else {
                            self.mediaItems.append(item)
                            AudioWaveformCache.shared.loadWaveform(for: item)
                            if let fId = targetFolderId {
                                EditorProject.shared.moveItem(item.id, toFolder: fId)
                            }
                            self.refreshMediaPoolDisplay()
                            return item
                        }
                    }
                    loadedOrExisting.append(resolved)
                } catch {
                    DebugLogger.shared.log("Errore caricamento '\(url.lastPathComponent)': \(error.localizedDescription)", level: .error)
                }
            }
            let finalItems = loadedOrExisting
            await MainActor.run {
                completion?(finalItems)
            }
        }
    }

    public func importURLsForTimelineDrop(_ urls: [URL], completion: @escaping ([MediaItem]) -> Void) {
        let supported = urls.filter { Self.isSupportedMediaURL($0) }
        importURLs(supported, targetFolderId: EditorProject.shared.activeFolderId, completion: completion)
    }

    // MARK: - Timeline Grid Tab Logic
    private func updateTrackPopUp() {
        guard let model = timelineModel else { return }
        trackPopUp.setItems(model.videoTracks.map { $0.name })
        if model.videoTracks.count > timelineGridView.selectedTrackIndex {
            trackPopUp.selectItem(at: timelineGridView.selectedTrackIndex)
        }
        updateTimelineGridInfo()
    }

    @objc private func onTrackPopUpChanged() {
        let idx = trackPopUp.selectedIndex
        if idx >= 0 {
            timelineGridView.selectedTrackIndex = idx
            updateTimelineGridInfo()
        }
    }

    public func refreshTimelineGrid() {
        updateTrackPopUp()
        timelineGridView.reloadData()
        updateTimelineGridInfo()
    }

    private func updateTimelineGridInfo() {
        let clips = timelineGridView.currentClips
        var totalSec: Double = 0
        for c in clips {
            totalSec += CMTimeGetSeconds(c.duration)
        }
        let mins = Int(totalSec) / 60
        let secs = Int(totalSec) % 60
        gridInfoLabel.stringValue = "\(clips.count) clip in sequenza • Durata: \(String(format: "%02d:%02d", mins, secs))"
    }

    // MARK: - Table View Data Source & Delegate
    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == sidebarTableView {
            return sidebarRows.count
        } else {
            return currentListItems.count
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView else { return }
        delegate?.didActivateSection(.mediaPool)

        if tv == sidebarTableView {
            let row = tv.selectedRow
            guard row >= 0 && row < sidebarRows.count else { return }
            switch sidebarRows[row] {
            case .allFiles:
                EditorProject.shared.activeFolderId = nil
            case .folder(let f, _):
                EditorProject.shared.activeFolderId = f.id
            }
            contentTableView.reloadData()
            timelineGridView.reloadData()
            updateContentModeVisibility()
        } else if tv == contentTableView {
            let selectedRows = contentTableView.selectedRowIndexes
            let selectedIds = selectedRows.compactMap { (idx: Int) -> UUID? in
                if idx < currentListItems.count {
                    switch currentListItems[idx] {
                    case .media(let m): return m.id
                    case .timeline(let tl, _): return tl.id
                    case .folder(let f): return f.id
                    }
                }
                return nil
            }
            gridView.selectedItemIds = Set(selectedIds)
        }
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView == contentTableView, row < currentListItems.count else { return nil }
        let item = currentListItems[row]
        switch item {
        case .media(let m):
            let pbItem = NSPasteboardItem()
            pbItem.setString(m.id.uuidString, forType: kMediaItemPasteboardType)
            pbItem.setString(m.url.absoluteString, forType: .fileURL)
            pbItem.setString(m.url.path, forType: .string)
            return pbItem
        case .timeline(let tl, _) where tl.isSelection:
            let pbItem = NSPasteboardItem()
            pbItem.setString(tl.id.uuidString, forType: kSelectionPasteboardType)
            return pbItem
        default:
            return nil
        }
    }

    // MARK: - Drag and Drop into Folders (Sidebar & Content Table)
    public func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let (_, fileURLs) = extractDroppedResources(from: info)
        let isFinderFiles = !fileURLs.isEmpty || info.draggingPasteboard.types?.contains(.fileURL) == true

        if tableView == sidebarTableView {
            if row >= 0 && row < sidebarRows.count {
                if case .folder = sidebarRows[row] {
                    tableView.setDropRow(row, dropOperation: .on)
                    return isFinderFiles ? .copy : .move
                }
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return isFinderFiles ? .copy : []
        } else if tableView == contentTableView {
            if row >= 0 && row < currentListItems.count, case .folder = currentListItems[row] {
                tableView.setDropRow(row, dropOperation: .on)
                return isFinderFiles ? .copy : .move
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
                return isFinderFiles ? .copy : []
            }
        }
        return []
    }

    public func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let (clipIds, fileURLs) = extractDroppedResources(from: info)

        if tableView == sidebarTableView {
            var targetFolderId: UUID? = nil
            if row >= 0 && row < sidebarRows.count, case .folder(let f, _) = sidebarRows[row] {
                targetFolderId = f.id
            }
            if !clipIds.isEmpty {
                for id in clipIds {
                    EditorProject.shared.moveItem(id, toFolder: targetFolderId)
                }
                refreshMediaPoolDisplay()
                return true
            } else if !fileURLs.isEmpty {
                processDroppedURLs(fileURLs, targetFolderId: targetFolderId)
                return true
            }
        } else if tableView == contentTableView {
            var targetFolderId = EditorProject.shared.activeFolderId
            if row >= 0 && row < currentListItems.count, case .folder(let folder) = currentListItems[row] {
                targetFolderId = folder.id
            }
            if !clipIds.isEmpty {
                for id in clipIds {
                    EditorProject.shared.moveItem(id, toFolder: targetFolderId)
                }
                refreshMediaPoolDisplay()
                return true
            } else if !fileURLs.isEmpty {
                processDroppedURLs(fileURLs, targetFolderId: targetFolderId)
                return true
            }
        }
        return false
    }

    private func extractDroppedResources(from info: NSDraggingInfo) -> ([UUID], [URL]) {
        var ids: [UUID] = []
        var urls: [URL] = []
        let pboard = info.draggingPasteboard

        if let pbItems = pboard.pasteboardItems {
            for item in pbItems {
                if let str = item.string(forType: kMediaItemPasteboardType), let uuid = UUID(uuidString: str) {
                    ids.append(uuid)
                }
            }
        }

        for u in Self.extractFileURLs(from: pboard) {
            if let m = mediaItems.first(where: { $0.url.standardizedFileURL.path == u.standardizedFileURL.path }) {
                if !ids.contains(m.id) { ids.append(m.id) }
            } else if !urls.contains(u) {
                urls.append(u)
            }
        }

        return (ids, urls)
    }

    @objc private func onTableRowDoubleClicked() {
        delegate?.didActivateSection(.mediaPool)
        let row = contentTableView.clickedRow
        guard row >= 0 && row < currentListItems.count else { return }
        let item = currentListItems[row]

        switch item {
        case .timeline(let tl, let idx):
            EditorProject.shared.activeTimelineIndex = idx
            delegate?.didSwitchActiveTimeline(to: tl)
            refreshMediaPoolDisplay()
        case .media(let m):
            delegate?.didSelectAddClipToTimeline(m)
        case .folder(let f):
            EditorProject.shared.activeFolderId = f.id
            refreshMediaPoolDisplay()
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == sidebarTableView {
            guard row >= 0 && row < sidebarRows.count else { return nil }
            let item = sidebarRows[row]
            let cellId = NSUserInterfaceItemIdentifier("SidebarCell")
            var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView
            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellId

                let imgView = NSImageView()
                imgView.translatesAutoresizingMaskIntoConstraints = false
                cell?.addSubview(imgView)
                cell?.imageView = imgView

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.isBordered = false
                tf.drawsBackground = false
                tf.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                cell?.addSubview(tf)
                cell?.textField = tf

                NSLayoutConstraint.activate([
                    imgView.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                    imgView.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                    imgView.widthAnchor.constraint(equalToConstant: 16),
                    imgView.heightAnchor.constraint(equalToConstant: 16),

                    tf.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
                ])
            }

            switch item {
            case .allFiles:
                cell?.imageView?.image = Lucide.image(.layoutGrid, size: 14, color: .labelColor)
                cell?.textField?.stringValue = "Tutti i file (\(mediaItems.count))"
                cell?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                cell?.textField?.textColor = .labelColor
            case .folder(let f, _):
                cell?.imageView?.image = Lucide.image(.folder, size: 14, color: .systemOrange)
                cell?.textField?.stringValue = "\(f.name) (\(f.itemIds.count))"
                cell?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                cell?.textField?.textColor = .labelColor
            }
            return cell
        }

        // Content Table View
        guard row < currentListItems.count, let tableColumn = tableColumn else { return nil }
        let listItem = currentListItems[row]

        if tableColumn.identifier.rawValue == "Name" {
            let cellId = NSUserInterfaceItemIdentifier("ContentNameCell")
            var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView
            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellId

                let imgView = NSImageView()
                imgView.translatesAutoresizingMaskIntoConstraints = false
                cell?.addSubview(imgView)
                cell?.imageView = imgView

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.isBordered = false
                tf.drawsBackground = false
                tf.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                cell?.addSubview(tf)
                cell?.textField = tf

                NSLayoutConstraint.activate([
                    imgView.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                    imgView.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                    imgView.widthAnchor.constraint(equalToConstant: 16),
                    imgView.heightAnchor.constraint(equalToConstant: 16),

                    tf.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
                ])
            }

            switch listItem {
            case .timeline(let tl, _):
                if tl.isSelection {
                    cell?.imageView?.image = Lucide.image(.sparkles, size: 14, color: .systemPurple)
                    cell?.textField?.stringValue = tl.name
                    cell?.textField?.textColor = .systemPurple
                } else {
                    cell?.imageView?.image = Lucide.image(.clapperboard, size: 14, color: .systemCyan)
                    cell?.textField?.stringValue = tl.name
                    cell?.textField?.textColor = .systemCyan
                }
            case .media(let m):
                cell?.imageView?.image = Lucide.image(m.hasVideo ? .film : .music, size: 14, color: m.hasVideo ? .systemIndigo : .systemGreen)
                if m.hasProxy {
                    cell?.textField?.stringValue = "\(m.name) [P]"
                    cell?.textField?.textColor = .systemTeal
                } else {
                    cell?.textField?.stringValue = m.name
                    cell?.textField?.textColor = .labelColor
                }
            case .folder(let f):
                cell?.imageView?.image = Lucide.image(.folder, size: 14, color: .systemOrange)
                cell?.textField?.stringValue = f.name
                cell?.textField?.textColor = .systemOrange
            }
            return cell
        } else {
            let cellId = NSUserInterfaceItemIdentifier("ContentTextCell")
            var textField = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            if textField == nil {
                textField = NSTextField(labelWithString: "")
                textField?.identifier = cellId
                textField?.isBordered = false
                textField?.drawsBackground = false
                textField?.font = NSFont.systemFont(ofSize: 11)
            }

            switch tableColumn.identifier.rawValue {
            case "Duration":
                switch listItem {
                case .timeline(let tl, _):
                    let dur = CMTimeGetSeconds(tl.totalDuration)
                    let mins = Int(dur) / 60
                    let secs = Int(dur) % 60
                    textField?.stringValue = dur > 0 ? String(format: "%02d:%02d", mins, secs) : "--:--"
                    textField?.textColor = .secondaryLabelColor
                case .media(let m):
                    textField?.stringValue = m.formattedDuration
                    textField?.textColor = .labelColor
                case .folder(let f):
                    textField?.stringValue = "\(f.itemIds.count) el."
                    textField?.textColor = .secondaryLabelColor
                }
            case "Codec":
                switch listItem {
                case .timeline(let tl, _):
                    if tl.isSelection {
                        let count = tl.videoTracks.first?.clips.count ?? 0
                        textField?.stringValue = "Selezione (\(count) clip • 1V+1A)"
                    } else {
                        textField?.stringValue = "Timeline (\(tl.format.name))"
                    }
                    textField?.textColor = .secondaryLabelColor
                case .media(let m):
                    if m.hasVideo {
                        textField?.stringValue = "\(m.videoCodec) (\(Int(m.resolution.width))x\(Int(m.resolution.height)))"
                    } else {
                        textField?.stringValue = "Audio (\(m.audioTrackCount) ch)"
                    }
                    textField?.textColor = .labelColor
                case .folder:
                    textField?.stringValue = "Cartella"
                    textField?.textColor = .secondaryLabelColor
                }
            default:
                textField?.stringValue = ""
            }
            return textField
        }
    }
}
