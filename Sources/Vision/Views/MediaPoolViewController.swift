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
    func didSelectAddClipsToTimeline(_ items: [MediaItem])
    func didSelectMediaItemForSourcePreview(_ item: MediaItem)
    func didChangeMediaOrientation(_ item: MediaItem)
    func didSelectSeekToClip(_ clip: TimelineClip)
    func didChangeSelectionFromGrid()
    func didReorderTimelineFromGrid()
    func didActivateSection(_ section: FocusedSection)
    func didSwitchActiveTimeline(to timeline: TimelineModel)
    func didDeleteMediaItemsFromPool(_ items: [MediaItem])
    func didDeleteTimelinesFromPool(activeChanged: Bool, deletedCount: Int)
    func didUpdateTimelineFormat(_ timeline: TimelineModel)
    func didImportTimelinesFromXML(_ timelines: [TimelineModel])
    func didRequestExportTimelineToFCPXML(_ timeline: TimelineModel)
    func didRenameTimeline(_ timeline: TimelineModel)
    func didRenameMediaItem(_ item: MediaItem)
    func didRelinkMediaItems(_ updatedItems: [MediaItem])
    func didToggleTimelineGridExpanded(_ isExpanded: Bool)
    func didRequestClipContextMenuFromGrid(_ clip: TimelineClip, event: NSEvent, sourceView: NSView, extraItems: [VisionMenuItem])
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
    var onSingleClickRow: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
        let pt = convert(event.locationInWindow, from: nil)
        let hitRow = self.row(at: pt)
        if event.clickCount == 1 && hitRow >= 0 && selectedRowIndexes.count == 1 && selectedRowIndexes.contains(hitRow) {
            onSingleClickRow?(hitRow)
        }
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

public enum SmartFolderKind: String, CaseIterable {
    case video = "Video"
    case audio = "Audio"
    case timelines = "Timeline"
    case selections = "Selezioni"
    case musicLibrary = "Libreria musicale"
}

public enum MediaPoolListItem {
    case timeline(TimelineModel, index: Int)
    case media(MediaItem)
    case folder(MediaFolder)
    case musicTrack(MusicLibraryTrack)

    public var deletableId: UUID? {
        switch self {
        case .timeline(let tl, _): return tl.id
        case .media(let m): return m.id
        case .folder(let f): return f.id
        case .musicTrack: return nil
        }
    }
}

public enum SidebarRow {
    case projectRoot
    case folder(MediaFolder, Int)
    case smart(SmartFolderKind)
    case smartVideoFPS(fps: Double, label: String, count: Int)
}

public final class MediaPoolViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate, NSTextFieldDelegate {
    public weak var delegate: MediaPoolDelegate?
    public var activeSmartFolder: SmartFolderKind? = nil
    public var activeSmartVideoFPSLabel: String? = nil
    private var isSmartVideoExpanded: Bool = false

    /// Multi-selezione cartelle stile DaVinci Resolve ("Progetto" root = `isProjectRootSelected`).
    public private(set) var isProjectRootSelected: Bool = true
    public private(set) var selectedFolderIds: Set<UUID> = []

    /// Testo di ricerca/filtro corrente nell'ambito selezionato.
    public var searchQuery: String = "" {
        didSet {
            if searchField.stringValue != searchQuery {
                searchField.stringValue = searchQuery
            }
            refreshContentOnly()
        }
    }

    private enum ContentSortKey: String {
        case name
        case duration
        case resolution
        case fileFormat
        case codec
        case fps
        case usage
        case title
        case artist
        case album
        case genre
    }
    private var sortKey: ContentSortKey = .name
    private var sortAscending: Bool = true
    private var isShowingMusicColumns: Bool = false
    private var isApplyingSortDescriptors: Bool = false
    private var folderSortPreferences: [String: (key: ContentSortKey, ascending: Bool)] = [:]
    private var activeProxyDialog: ProxyGenerationDialog?
    private var cachedMediaUsage: [UUID: (current: Int, total: Int)] = [:]

    public var isTimelineGridVisible: Bool {
        !timelineGridContainer.isHidden
    }

    public var timelineModel: TimelineModel? {
        didSet {
            timelineGridView.timelineModel = timelineModel
            updateTrackPopUp()
            refreshUsageCache()
        }
    }
    public private(set) var mediaItems: [MediaItem] = []

    public func setMediaItems(_ items: [MediaItem]) {
        self.mediaItems = items
        self.refreshMediaPoolDisplay()
    }

    /// Item nella root "Progetto" (file in nessuna cartella).
    private var unfiledMediaItems: [MediaItem] {
        let filedIds = EditorProject.shared.allFolderItemIds
        return mediaItems.filter { !filedIds.contains($0.id) }
    }

    private func currentSortScopeKey() -> String {
        if let smart = activeSmartFolder {
            if smart == .video, let fpsLbl = activeSmartVideoFPSLabel {
                return "smart_video_\(fpsLbl)"
            }
            return "smart_\(smart.rawValue)"
        }
        if selectedFolderIds.count == 1 && !isProjectRootSelected, let fId = selectedFolderIds.first {
            return "folder_\(fId.uuidString)"
        }
        if selectedFolderIds.isEmpty || (isProjectRootSelected && selectedFolderIds.isEmpty) {
            return "root"
        }
        let sortedIds = selectedFolderIds.map(\.uuidString).sorted().joined(separator: "_")
        return "multi_\(isProjectRootSelected ? "root_" : "")\(sortedIds)"
    }

    private func loadSortStateForCurrentScope() {
        let isMusic = (activeSmartFolder == .musicLibrary)
        let defaultKey: ContentSortKey = isMusic ? .title : .name
        let scopeKey = currentSortScopeKey()

        if let cached = folderSortPreferences[scopeKey] {
            let validForMusic: Set<ContentSortKey> = [.title, .artist, .album, .genre, .duration]
            let validForPool: Set<ContentSortKey> = [.name, .duration, .resolution, .fileFormat, .codec, .fps, .usage]
            if isMusic ? validForMusic.contains(cached.key) : validForPool.contains(cached.key) {
                sortKey = cached.key
                sortAscending = cached.ascending
            } else {
                sortKey = defaultKey
                sortAscending = true
            }
        } else if !isMusic, activeSmartFolder == nil, selectedFolderIds.count == 1, !isProjectRootSelected,
                  let fId = selectedFolderIds.first,
                  let folder = EditorProject.shared.folders.first(where: { $0.id == fId }),
                  let savedKey = folder.sortColumnKey,
                  let parsedKey = ContentSortKey(rawValue: savedKey),
                  [.name, .duration, .resolution, .fileFormat, .codec, .fps, .usage].contains(parsedKey) {
            sortKey = parsedKey
            sortAscending = folder.sortAscending ?? true
            folderSortPreferences[scopeKey] = (sortKey, sortAscending)
        } else {
            sortKey = defaultKey
            sortAscending = true
        }
        applySortDescriptorToContentTableHeader()
    }

    private func saveSortStateForCurrentScope(key: ContentSortKey, ascending: Bool) {
        let scopeKey = currentSortScopeKey()
        folderSortPreferences[scopeKey] = (key, ascending)
        if activeSmartFolder == nil, selectedFolderIds.count == 1, !isProjectRootSelected,
           let fId = selectedFolderIds.first,
           let idx = EditorProject.shared.folders.firstIndex(where: { $0.id == fId }) {
            EditorProject.shared.folders[idx].sortColumnKey = key.rawValue
            EditorProject.shared.folders[idx].sortAscending = ascending
            ProjectDatabase.shared.scheduleRealtimeAutosave(project: EditorProject.shared, mediaItems: mediaItems)
        }
    }

    private func applySortDescriptorToContentTableHeader() {
        isApplyingSortDescriptors = true
        defer { isApplyingSortDescriptors = false }
        let descKey: String
        switch sortKey {
        case .name: descKey = "name"
        case .duration: descKey = "duration"
        case .resolution: descKey = "resolution"
        case .fileFormat: descKey = "fileFormat"
        case .codec: descKey = "codec"
        case .fps: descKey = "fps"
        case .usage: descKey = "usage"
        case .title: descKey = "title"
        case .artist: descKey = "artist"
        case .album: descKey = "album"
        case .genre: descKey = "genre"
        }
        contentTableView.sortDescriptors = [NSSortDescriptor(key: descKey, ascending: sortAscending)]
    }

    private func countMediaOccurrences(in timeline: TimelineModel) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        var countedLinkGroups: Set<UUID> = []
        for track in timeline.videoTracks {
            for clip in track.clips {
                counts[clip.mediaItem.id, default: 0] += 1
                if let lId = clip.linkGroupId {
                    countedLinkGroups.insert(lId)
                }
            }
        }
        for track in timeline.audioTracks {
            for clip in track.clips {
                if let lId = clip.linkGroupId, countedLinkGroups.contains(lId) {
                    continue
                }
                counts[clip.mediaItem.id, default: 0] += 1
            }
        }
        return counts
    }

    private func refreshUsageCache() {
        let currentCounts = timelineModel.map { countMediaOccurrences(in: $0) } ?? [:]
        var totalCounts: [UUID: Int] = [:]
        for tl in EditorProject.shared.timelines {
            let tlCounts = countMediaOccurrences(in: tl)
            for (id, count) in tlCounts {
                totalCounts[id, default: 0] += count
            }
        }
        var combined: [UUID: (current: Int, total: Int)] = [:]
        for item in mediaItems {
            let cur = currentCounts[item.id] ?? 0
            let tot = totalCounts[item.id] ?? 0
            combined[item.id] = (cur, tot)
        }
        cachedMediaUsage = combined
    }

    private func usageText(for mediaId: UUID) -> (text: String, isActive: Bool) {
        let info = cachedMediaUsage[mediaId] ?? (0, 0)
        if info.current == 0 && info.total == 0 {
            return ("", false)
        }
        if info.current == info.total {
            return ("\(info.current)", info.current > 0)
        }
        return ("\(info.current)/\(info.total)", info.current > 0)
    }

    private func formatExtensionLabel(for m: MediaItem) -> String {
        let ext = m.url.pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return m.hasVideo ? "VIDEO" : "AUDIO"
    }

    private func sortedMediaItems(_ raw: [MediaItem]) -> [MediaItem] {
        return raw.sorted { a, b in
            let cmp: ComparisonResult
            switch sortKey {
            case .name, .title, .artist, .album, .genre:
                cmp = a.name.localizedStandardCompare(b.name)
            case .duration:
                let da = CMTimeGetSeconds(a.duration)
                let db = CMTimeGetSeconds(b.duration)
                let safeA = da.isFinite ? da : 0
                let safeB = db.isFinite ? db : 0
                if abs(safeA - safeB) > 0.0001 {
                    cmp = safeA < safeB ? .orderedAscending : .orderedDescending
                } else {
                    cmp = .orderedSame
                }
            case .resolution:
                let pxA = a.hasVideo ? Int(a.resolution.width * a.resolution.height) : -1
                let pxB = b.hasVideo ? Int(b.resolution.width * b.resolution.height) : -1
                cmp = pxA < pxB ? .orderedAscending : (pxA > pxB ? .orderedDescending : .orderedSame)
            case .fileFormat:
                cmp = formatExtensionLabel(for: a).localizedStandardCompare(formatExtensionLabel(for: b))
            case .codec:
                let ca = a.hasVideo ? a.videoCodec : "Audio \(a.audioTrackCount)ch"
                let cb = b.hasVideo ? b.videoCodec : "Audio \(b.audioTrackCount)ch"
                cmp = ca.localizedStandardCompare(cb)
            case .fps:
                let fa = a.hasVideo ? a.frameRate : -1
                let fb = b.hasVideo ? b.frameRate : -1
                cmp = fa < fb ? .orderedAscending : (fa > fb ? .orderedDescending : .orderedSame)
            case .usage:
                let ua = cachedMediaUsage[a.id] ?? (0, 0)
                let ub = cachedMediaUsage[b.id] ?? (0, 0)
                if ua.current != ub.current {
                    cmp = ua.current < ub.current ? .orderedAscending : .orderedDescending
                } else if ua.total != ub.total {
                    cmp = ua.total < ub.total ? .orderedAscending : .orderedDescending
                } else {
                    cmp = .orderedSame
                }
            }
            if cmp == .orderedSame {
                let nameCmp = a.name.localizedStandardCompare(b.name)
                if nameCmp == .orderedSame {
                    return a.id.uuidString < b.id.uuidString
                }
                return nameCmp == .orderedAscending
            }
            return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }
    }

    private func sortedTimelineEntries(_ raw: [(timeline: TimelineModel, index: Int)]) -> [(timeline: TimelineModel, index: Int)] {
        return raw.sorted { a, b in
            let cmp: ComparisonResult
            switch sortKey {
            case .name, .title, .artist, .album, .genre, .usage:
                cmp = a.timeline.name.localizedStandardCompare(b.timeline.name)
            case .duration:
                let da = CMTimeGetSeconds(a.timeline.totalDuration)
                let db = CMTimeGetSeconds(b.timeline.totalDuration)
                let safeA = da.isFinite ? da : 0
                let safeB = db.isFinite ? db : 0
                if abs(safeA - safeB) > 0.0001 {
                    cmp = safeA < safeB ? .orderedAscending : .orderedDescending
                } else {
                    cmp = .orderedSame
                }
            case .resolution:
                let pa = a.timeline.isSelection ? 0 : Int(a.timeline.format.size.width * a.timeline.format.size.height)
                let pb = b.timeline.isSelection ? 0 : Int(b.timeline.format.size.width * b.timeline.format.size.height)
                cmp = pa < pb ? .orderedAscending : (pa > pb ? .orderedDescending : .orderedSame)
            case .fileFormat:
                let fa = a.timeline.isSelection ? "Selezione" : "Timeline"
                let fb = b.timeline.isSelection ? "Selezione" : "Timeline"
                cmp = fa.localizedStandardCompare(fb)
            case .codec:
                let ca = a.timeline.format.name
                let cb = b.timeline.format.name
                cmp = ca.localizedStandardCompare(cb)
            case .fps:
                let fa = a.timeline.isSelection ? -1 : a.timeline.format.fps
                let fb = b.timeline.isSelection ? -1 : b.timeline.format.fps
                cmp = fa < fb ? .orderedAscending : (fa > fb ? .orderedDescending : .orderedSame)
            }
            if cmp == .orderedSame {
                return a.timeline.name.localizedStandardCompare(b.timeline.name) == .orderedAscending
            }
            return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
        }
    }

    public var displayedMediaItems: [MediaItem] {
        let filtered: [MediaItem]
        if let smart = activeSmartFolder {
            switch smart {
            case .video:
                if let targetLabel = activeSmartVideoFPSLabel {
                    filtered = mediaItems.filter { $0.hasVideo && $0.frameRate > 0 && TimelineModel.formatFPSLabel($0.frameRate) == targetLabel }
                } else {
                    filtered = mediaItems.filter { $0.hasVideo }
                }
            case .audio:
                filtered = mediaItems.filter { $0.hasAudio && !$0.hasVideo }
            case .timelines, .selections, .musicLibrary:
                return []
            }
            return sortedMediaItems(filtered)
        }

        if selectedFolderIds.isEmpty {
            // Root "Progetto": soli file che non stanno in nessuna cartella
            return sortedMediaItems(unfiledMediaItems)
        }

        let includeRoot = isProjectRootSelected
        let filedIds = EditorProject.shared.allFolderItemIds
        var allowedIds = Set<UUID>()
        for f in EditorProject.shared.folders where selectedFolderIds.contains(f.id) {
            allowedIds.formUnion(f.itemIds)
        }

        filtered = mediaItems.filter { item in
            if allowedIds.contains(item.id) { return true }
            if includeRoot && !filedIds.contains(item.id) { return true }
            return false
        }
        return sortedMediaItems(filtered)
    }

    public var currentListItems: [MediaPoolListItem] {
        var items: [MediaPoolListItem] = []
        if let smart = activeSmartFolder {
            switch smart {
            case .video, .audio:
                for m in displayedMediaItems { items.append(.media(m)) }
            case .timelines:
                let tlEntries = EditorProject.shared.timelines.enumerated().compactMap { (idx, tl) -> (timeline: TimelineModel, index: Int)? in
                    tl.isSelection ? nil : (tl, idx)
                }
                for entry in sortedTimelineEntries(tlEntries) {
                    items.append(.timeline(entry.timeline, index: entry.index))
                }
            case .selections:
                let selEntries = EditorProject.shared.timelines.enumerated().compactMap { (idx, tl) -> (timeline: TimelineModel, index: Int)? in
                    tl.isSelection ? (tl, idx) : nil
                }
                for entry in sortedTimelineEntries(selEntries) {
                    items.append(.timeline(entry.timeline, index: entry.index))
                }
            case .musicLibrary:
                var tracks = MusicLibraryManager.shared.tracks
                tracks.sort { a, b in
                    let cmp: ComparisonResult
                    switch sortKey {
                    case .title, .name, .resolution, .fileFormat, .codec, .fps, .usage:
                        cmp = a.displayTitle.localizedStandardCompare(b.displayTitle)
                    case .artist:
                        cmp = (a.artist ?? "").localizedStandardCompare(b.artist ?? "")
                    case .album:
                        cmp = (a.album ?? "").localizedStandardCompare(b.album ?? "")
                    case .genre:
                        cmp = (a.genre ?? "").localizedStandardCompare(b.genre ?? "")
                    case .duration:
                        let da = a.durationSeconds ?? 0
                        let db = b.durationSeconds ?? 0
                        cmp = da < db ? .orderedAscending : (da > db ? .orderedDescending : .orderedSame)
                    }
                    if cmp == .orderedSame {
                        return a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
                    }
                    return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
                for tr in tracks {
                    items.append(.musicTrack(tr))
                }
            }
            return applySearchFilter(to: items)
        }

        let showRootItems = selectedFolderIds.isEmpty || isProjectRootSelected

        // Le cartelle sono sempre al top
        var foldersToShow: [MediaFolder] = []
        if showRootItems {
            foldersToShow = EditorProject.shared.childFolders(of: nil)
        } else if selectedFolderIds.count == 1, let onlyId = selectedFolderIds.first {
            foldersToShow = EditorProject.shared.childFolders(of: onlyId)
        }
        foldersToShow.sort { a, b in
            let cmp = a.name.localizedStandardCompare(b.name)
            if sortKey == .name {
                return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            }
            return cmp == .orderedAscending
        }
        for f in foldersToShow {
            items.append(.folder(f))
        }

        if showRootItems {
            let tlEntries = EditorProject.shared.timelines.enumerated().map { (timeline: $0.element, index: $0.offset) }
            for entry in sortedTimelineEntries(tlEntries) {
                items.append(.timeline(entry.timeline, index: entry.index))
            }
        }

        for m in displayedMediaItems {
            items.append(.media(m))
        }

        return applySearchFilter(to: items)
    }

    private func applySearchFilter(to items: [MediaPoolListItem]) -> [MediaPoolListItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let foldedTokens = trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !foldedTokens.isEmpty else { return items }

        return items.filter { listItem in
            switch listItem {
            case .musicTrack(let tr):
                return tr.matchesSearchTokens(foldedTokens)
            case .media(let m):
                let resStr = "\(Int(m.resolution.width))x\(Int(m.resolution.height))"
                let hay = "\(m.name) \(m.videoCodec) \(resStr) \(m.hasVideo ? "video" : "audio")"
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return foldedTokens.allSatisfy { hay.contains($0) }
            case .timeline(let tl, _):
                let kindStr = tl.isSelection ? "selezione" : "timeline"
                let hay = "\(tl.name) \(kindStr) \(tl.format.name)"
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return foldedTokens.allSatisfy { hay.contains($0) }
            case .folder(let f):
                let hay = f.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return foldedTokens.allSatisfy { hay.contains($0) }
            }
        }
    }

    /// Programmatic selection helper (usato anche nei test automatici per multi-selezione Resolve-style).
    public func selectSidebarBins(includeProjectRoot: Bool, folderIds: Set<UUID>) {
        activeSmartFolder = nil
        activeSmartVideoFPSLabel = nil
        isProjectRootSelected = includeProjectRoot || folderIds.isEmpty
        selectedFolderIds = folderIds
        EditorProject.shared.activeFolderId = folderIds.count == 1 && !includeProjectRoot ? folderIds.first : folderIds.first
        loadSortStateForCurrentScope()
        refreshMediaPoolDisplay()
    }

    public func selectSmartFolder(_ kind: SmartFolderKind) {
        activeSmartFolder = kind
        activeSmartVideoFPSLabel = nil
        isProjectRootSelected = false
        selectedFolderIds.removeAll()
        EditorProject.shared.activeFolderId = nil
        loadSortStateForCurrentScope()
        refreshMediaPoolDisplay()
    }

    public var selectedMediaItems: [MediaItem] {
        let list = currentListItems
        if currentViewMode == .grid && timelineGridContainer.isHidden {
            let ids = gridView.selectedItemIds
            return list.compactMap { entry in
                if case .media(let m) = entry, ids.contains(m.id) {
                    return m
                }
                return nil
            }
        }
        let selectedRows = contentTableView.selectedRowIndexes
        var items: [MediaItem] = []
        for idx in selectedRows where idx < list.count {
            if case .media(let m) = list[idx] {
                items.append(m)
            }
        }
        return items
    }

    public var selectedMusicTracks: [MusicLibraryTrack] {
        let selectedRows = contentTableView.selectedRowIndexes
        var tracks: [MusicLibraryTrack] = []
        for idx in selectedRows where idx < currentListItems.count {
            if case .musicTrack(let tr) = currentListItems[idx] {
                tracks.append(tr)
            }
        }
        return tracks
    }

    public var folderSidebarRows: [SidebarRow] {
        var rows: [SidebarRow] = [.projectRoot]
        for (f, depth) in EditorProject.shared.flattenedFoldersWithDepth() {
            rows.append(.folder(f, depth))
        }
        return rows
    }

    private var videoFPSBuckets: [(fps: Double, label: String, count: Int)] {
        var map: [String: (fps: Double, count: Int)] = [:]
        for item in mediaItems where item.hasVideo && item.frameRate > 0 {
            let lbl = TimelineModel.formatFPSLabel(item.frameRate)
            if let existing = map[lbl] {
                map[lbl] = (existing.fps, existing.count + 1)
            } else {
                map[lbl] = (Double(item.frameRate), 1)
            }
        }
        return map.map { (fps: $0.value.fps, label: $0.key, count: $0.value.count) }
            .sorted { $0.fps < $1.fps }
    }

    public var smartSidebarRows: [SidebarRow] {
        var rows: [SidebarRow] = []
        for kind in SmartFolderKind.allCases {
            rows.append(.smart(kind))
            if kind == .video && isSmartVideoExpanded {
                for bucket in videoFPSBuckets {
                    rows.append(.smartVideoFPS(fps: bucket.fps, label: bucket.label, count: bucket.count))
                }
            }
        }
        return rows
    }

    private enum ViewMode {
        case list
        case grid
    }
    private var currentViewMode: ViewMode = .list

    // Top Header Controls (Single Switch Buttons — Boxless Lucide Icons)
    private let poolTabSwitchBtn = IconActionButton(toolTip: "Media Pool (clicca per passare a Timeline Grid)")
    private let gridExpandToggleBtn = IconActionButton(toolTip: "Espandi Timeline Grid verticalmente sulla sinistra")
    private var isGridExpanded: Bool = false
    private let viewModeSwitchBtn = IconActionButton(toolTip: "Vista Elenco (clicca per Anteprime)")
    private let viewModeDivider = NSView()
    private let searchToggleBtn = IconActionButton(toolTip: "Cerca nel Media Pool")
    private let gridHeaderStack = NSStackView()

    // Media Pool View Hierarchy
    private let mediaPoolContainer = NSView()
    private let splitView = NSSplitView()
    private var hasAppliedInitialSidebarWidth = false

    // Sidebar: Project & Folders (Top) + Smart Divider & Smart Folders (Bottom)
    private let sidebarContainer = NSView()
    private let sidebarTableView = ContextMenuTableView()
    private let sidebarScrollView = NSScrollView()
    private let smartSectionView = NSView()
    private var smartSectionHeightConstraint: NSLayoutConstraint?
    private let smartTableView = ContextMenuTableView()
    private let smartScrollView = NSScrollView()

    // Content: Search Filter Bar + Table & Grid
    private let contentContainer = NSView()
    private let searchBarContainer = NSView()
    private let searchLeadingIcon = NSImageView()
    private let searchField = NSTextField()
    private let searchCountLabel = NSTextField(labelWithString: "")
    private let searchClearBtn = NSButton()
    private var searchBarHeightConstraint: NSLayoutConstraint?
    public private(set) var isSearchBarOpen: Bool = false
    private let contentTableView = ContextMenuTableView()
    private let contentTableScrollView = NSScrollView()
    private let gridView = MediaThumbnailGridView()
    private let gridScrollView = NSScrollView()
    private let emptyPlaceholderView = NSView()
    private let emptyPlaceholderLabel = NSTextField(labelWithString: "Trascina qui file video, audio o cartelle\n(Formati: MOV, MP4, ProRes, WAV, MP3, M4A, ecc.)")

    // Timeline Grid (Storyboard) Controls
    private let timelineGridContainer = NSView()
    public let timelineGridView = TimelineGridView()
    private let timelineGridScrollView = NSScrollView()
    private let trackPopUp = VisionDropdownButton()
    private let gridInfoLabel = NSTextField(labelWithString: "")
    private let gridSizeIcon = NSImageView()
    private let gridSizeSlider = VisionSlider(value: 1.0, minValue: 0.75, maxValue: 1.25, defaultValue: 1.0)

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

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MediaItemBeatAnalysisUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self,
                  let info = notif.userInfo,
                  let itemId = info["itemId"] as? UUID else { return }
            let analysis = info["beatAnalysis"] as? SavedBeatAnalysis
            if let idx = self.mediaItems.firstIndex(where: { $0.id == itemId }) {
                self.mediaItems[idx].beatAnalysis = analysis
            }
        }

        NotificationCenter.default.addObserver(
            forName: MusicLibraryManager.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMediaPoolDisplay()
        }

        NotificationCenter.default.addObserver(
            forName: ThumbnailCache.thumbnailReadyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.activeSmartFolder == .musicLibrary, self.currentViewMode == .list else { return }
            self.contentTableView.reloadData()
        }

        self.view = dropContainer
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        if !hasAppliedInitialSidebarWidth && splitView.bounds.width > 300 {
            hasAppliedInitialSidebarWidth = true
            splitView.setPosition(155, ofDividerAt: 0)
        }
        syncSidebarTableWidths()
    }

    private func syncSidebarTableWidths() {
        let sideW = sidebarScrollView.contentView.bounds.width
        if sideW > 0 {
            if abs(sidebarTableView.frame.width - sideW) > 0.5 {
                sidebarTableView.frame.size.width = sideW
            }
            sidebarTableView.tableColumns.first?.width = sideW
            sidebarTableView.sizeLastColumnToFit()
        }
        let smartW = smartScrollView.contentView.bounds.width
        if smartW > 0 {
            if abs(smartTableView.frame.width - smartW) > 0.5 {
                smartTableView.frame.size.width = smartW
            }
            smartTableView.tableColumns.first?.width = smartW
            smartTableView.sizeLastColumnToFit()
            smartTableView.tile()
        }
    }

    private func setupTopHeaderUI(_ topHeader: NSView) {
        let tabsStack = NSStackView()
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabsStack.orientation = .horizontal
        tabsStack.spacing = 10
        tabsStack.alignment = .centerY
        topHeader.addSubview(tabsStack)

        poolTabSwitchBtn.image = Lucide.template(.fileVideoCamera, size: 17)
        poolTabSwitchBtn.toolTip = "Media Pool — Clicca per passare a Timeline Grid"
        poolTabSwitchBtn.activeTintColor = .systemCyan
        poolTabSwitchBtn.isToggleActive = false
        poolTabSwitchBtn.target = self
        poolTabSwitchBtn.action = #selector(onPoolTabSwitchClicked)
        poolTabSwitchBtn.widthAnchor.constraint(equalToConstant: 26).isActive = true
        poolTabSwitchBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        tabsStack.addArrangedSubview(poolTabSwitchBtn)

        gridExpandToggleBtn.image = Lucide.template(.maximize2, size: 15)
        gridExpandToggleBtn.toolTip = "Espandi Timeline Grid verticalmente sulla sinistra"
        gridExpandToggleBtn.activeTintColor = .systemCyan
        gridExpandToggleBtn.isToggleActive = false
        gridExpandToggleBtn.target = self
        gridExpandToggleBtn.action = #selector(onGridExpandToggleClicked)
        gridExpandToggleBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        gridExpandToggleBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        gridExpandToggleBtn.isHidden = true
        tabsStack.addArrangedSubview(gridExpandToggleBtn)

        gridHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        gridHeaderStack.orientation = .horizontal
        gridHeaderStack.spacing = 8
        gridHeaderStack.alignment = .centerY
        gridHeaderStack.isHidden = true

        let gridDivider = NSView()
        gridDivider.translatesAutoresizingMaskIntoConstraints = false
        gridDivider.wantsLayer = true
        gridDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        gridDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        gridDivider.heightAnchor.constraint(equalToConstant: 14).isActive = true
        gridHeaderStack.addArrangedSubview(gridDivider)

        let trackLabel = NSTextField(labelWithString: "Traccia:")
        trackLabel.translatesAutoresizingMaskIntoConstraints = false
        trackLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        gridHeaderStack.addArrangedSubview(trackLabel)

        trackPopUp.translatesAutoresizingMaskIntoConstraints = false
        trackPopUp.target = self
        trackPopUp.action = #selector(onTrackPopUpChanged)
        trackPopUp.widthAnchor.constraint(equalToConstant: 75).isActive = true
        gridHeaderStack.addArrangedSubview(trackPopUp)

        gridInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        gridInfoLabel.font = NSFont.systemFont(ofSize: 11)
        gridInfoLabel.textColor = .secondaryLabelColor
        gridInfoLabel.lineBreakMode = .byTruncatingTail
        gridInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gridHeaderStack.addArrangedSubview(gridInfoLabel)

        tabsStack.addArrangedSubview(gridHeaderStack)

        let viewModeStack = NSStackView()
        viewModeStack.translatesAutoresizingMaskIntoConstraints = false
        viewModeStack.orientation = .horizontal
        viewModeStack.spacing = 8
        viewModeStack.alignment = .centerY
        topHeader.addSubview(viewModeStack)

        gridSizeIcon.translatesAutoresizingMaskIntoConstraints = false
        gridSizeIcon.image = Lucide.template(.layoutGrid, size: 13)
        gridSizeIcon.contentTintColor = .secondaryLabelColor
        gridSizeIcon.toolTip = "Dimensione schede (doppio clic sullo slider per ripristinare)"
        gridSizeIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        gridSizeIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        gridSizeIcon.isHidden = true
        viewModeStack.addArrangedSubview(gridSizeIcon)

        gridSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        gridSizeSlider.target = self
        gridSizeSlider.action = #selector(onGridSizeSliderChanged)
        gridSizeSlider.toolTip = "Dimensione schede (doppio clic per ripristinare)"
        gridSizeSlider.widthAnchor.constraint(equalToConstant: 74).isActive = true
        gridSizeSlider.isHidden = true
        viewModeStack.addArrangedSubview(gridSizeSlider)

        viewModeSwitchBtn.image = Lucide.template(.list, size: 16)
        viewModeSwitchBtn.toolTip = "Vista Elenco — Clicca per Vista Anteprime (Grid)"
        viewModeSwitchBtn.activeTintColor = .systemCyan
        viewModeSwitchBtn.isToggleActive = false
        viewModeSwitchBtn.target = self
        viewModeSwitchBtn.action = #selector(onViewModeSwitchClicked)
        viewModeSwitchBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        viewModeSwitchBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        viewModeStack.addArrangedSubview(viewModeSwitchBtn)

        viewModeDivider.translatesAutoresizingMaskIntoConstraints = false
        viewModeDivider.wantsLayer = true
        viewModeDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        viewModeDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        viewModeDivider.heightAnchor.constraint(equalToConstant: 14).isActive = true
        viewModeStack.addArrangedSubview(viewModeDivider)

        searchToggleBtn.image = Lucide.template(.search, size: 15)
        searchToggleBtn.toolTip = "Cerca nel Media Pool"
        searchToggleBtn.activeTintColor = .systemCyan
        searchToggleBtn.isToggleActive = false
        searchToggleBtn.target = self
        searchToggleBtn.action = #selector(onSearchToggleClicked)
        searchToggleBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        searchToggleBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        viewModeStack.addArrangedSubview(searchToggleBtn)

        NSLayoutConstraint.activate([
            tabsStack.leadingAnchor.constraint(equalTo: topHeader.leadingAnchor, constant: 10),
            tabsStack.centerYAnchor.constraint(equalTo: topHeader.centerYAnchor),
            tabsStack.trailingAnchor.constraint(lessThanOrEqualTo: viewModeStack.leadingAnchor, constant: -8),

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
        syncSidebarTableWidths()
    }

    private func setupSidebarUI() {
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor

        // Top section: "Progetto" root + user folders (scrollable, multi-select Resolve-style)
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
        col.width = 145
        col.minWidth = 80
        col.resizingMask = .autoresizingMask
        sidebarTableView.autoresizingMask = [.width, .height]
        sidebarTableView.addTableColumn(col)
        sidebarTableView.headerView = nil
        sidebarTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sidebarTableView.sizeLastColumnToFit()
        sidebarTableView.dataSource = self
        sidebarTableView.delegate = self
        sidebarTableView.allowsMultipleSelection = true
        sidebarTableView.allowsEmptySelection = true
        sidebarTableView.doubleAction = #selector(onSidebarDoubleClicked)
        sidebarTableView.target = self
        sidebarTableView.backgroundColor = .clear
        sidebarTableView.selectionHighlightStyle = .regular
        sidebarTableView.rowSizeStyle = .custom
        sidebarTableView.rowHeight = 22
        sidebarTableView.registerForDraggedTypes([kMediaItemPasteboardType, .fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        sidebarTableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        sidebarTableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        sidebarTableView.onMouseDown = { [weak self] in
            self?.delegate?.didActivateSection(.mediaPool)
        }
        sidebarTableView.onRightClick = { [weak self] event, row in
            self?.showFolderSidebarContextMenu(forRow: row, event: event)
        }

        // Bottom section: Divider + Smart Folders header + fixed list at bottom of sidebar
        smartSectionView.translatesAutoresizingMaskIntoConstraints = false
        smartSectionView.wantsLayer = true
        smartSectionView.layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1.0).cgColor
        sidebarContainer.addSubview(smartSectionView)

        let smartDivider = NSView()
        smartDivider.wantsLayer = true
        smartDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        smartDivider.translatesAutoresizingMaskIntoConstraints = false
        smartSectionView.addSubview(smartDivider)

        let smartHeader = NSTextField(labelWithString: "CARTELLE SMART")
        smartHeader.translatesAutoresizingMaskIntoConstraints = false
        smartHeader.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        smartHeader.textColor = NSColor(calibratedWhite: 0.52, alpha: 1.0)
        smartHeader.setContentHuggingPriority(.required, for: .vertical)
        smartHeader.setContentCompressionResistancePriority(.required, for: .vertical)
        smartSectionView.addSubview(smartHeader)

        smartScrollView.translatesAutoresizingMaskIntoConstraints = false
        smartScrollView.documentView = smartTableView
        smartScrollView.borderType = .noBorder
        smartScrollView.hasVerticalScroller = true
        smartScrollView.hasHorizontalScroller = false
        smartScrollView.scrollerStyle = .overlay
        smartScrollView.autohidesScrollers = true
        smartScrollView.drawsBackground = false
        smartSectionView.addSubview(smartScrollView)

        let smartCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SmartSidebarCol"))
        smartCol.title = "Smart"
        smartCol.width = 145
        smartCol.minWidth = 80
        smartCol.resizingMask = .autoresizingMask
        smartTableView.autoresizingMask = [.width, .height]
        smartTableView.addTableColumn(smartCol)
        smartTableView.headerView = nil
        smartTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        smartTableView.sizeLastColumnToFit()
        smartTableView.dataSource = self
        smartTableView.delegate = self
        smartTableView.allowsMultipleSelection = false
        smartTableView.allowsEmptySelection = true
        smartTableView.doubleAction = #selector(onSmartSidebarDoubleClicked)
        smartTableView.target = self
        smartTableView.backgroundColor = .clear
        smartTableView.selectionHighlightStyle = .regular
        if #available(macOS 11.0, *) {
            smartTableView.style = .plain
        }
        smartTableView.rowSizeStyle = .custom
        smartTableView.rowHeight = 22
        smartTableView.registerForDraggedTypes([.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        smartTableView.onMouseDown = { [weak self] in
            self?.delegate?.didActivateSection(.mediaPool)
        }
        smartTableView.onRightClick = { [weak self] event, row in
            self?.showSmartSidebarContextMenu(forRow: row, event: event)
        }

        let smartHeight = min(220.0, CGFloat(smartSidebarRows.count) * 24.0 + 34.0)
        let smartHC = smartSectionView.heightAnchor.constraint(equalToConstant: smartHeight)
        self.smartSectionHeightConstraint = smartHC
        NSLayoutConstraint.activate([
            sidebarScrollView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor, constant: 4),
            sidebarScrollView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarScrollView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarScrollView.bottomAnchor.constraint(equalTo: smartSectionView.topAnchor),

            smartSectionView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            smartSectionView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            smartSectionView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            smartHC,

            smartDivider.topAnchor.constraint(equalTo: smartSectionView.topAnchor),
            smartDivider.leadingAnchor.constraint(equalTo: smartSectionView.leadingAnchor),
            smartDivider.trailingAnchor.constraint(equalTo: smartSectionView.trailingAnchor),
            smartDivider.heightAnchor.constraint(equalToConstant: 1),

            smartHeader.topAnchor.constraint(equalTo: smartDivider.bottomAnchor, constant: 6),
            smartHeader.leadingAnchor.constraint(equalTo: smartSectionView.leadingAnchor, constant: 10),
            smartHeader.trailingAnchor.constraint(equalTo: smartSectionView.trailingAnchor, constant: -8),

            smartScrollView.topAnchor.constraint(equalTo: smartHeader.bottomAnchor, constant: 3),
            smartScrollView.leadingAnchor.constraint(equalTo: smartSectionView.leadingAnchor),
            smartScrollView.trailingAnchor.constraint(equalTo: smartSectionView.trailingAnchor),
            smartScrollView.bottomAnchor.constraint(equalTo: smartSectionView.bottomAnchor, constant: -4)
        ])
    }

    private func setupContentUI() {
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor

        // Compact minimal Search/Filter Bar scoped to active folder(s) / Smart Folder (toggled from header icon)
        searchBarContainer.translatesAutoresizingMaskIntoConstraints = false
        searchBarContainer.wantsLayer = true
        searchBarContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.088, alpha: 1.0).cgColor
        searchBarContainer.isHidden = true
        contentContainer.addSubview(searchBarContainer)

        searchLeadingIcon.translatesAutoresizingMaskIntoConstraints = false
        searchLeadingIcon.image = Lucide.template(.search, size: 13)
        searchLeadingIcon.contentTintColor = .tertiaryLabelColor
        searchLeadingIcon.imageScaling = .scaleProportionallyDown
        searchBarContainer.addSubview(searchLeadingIcon)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 11.5, weight: .light)
        searchField.textColor = .labelColor
        searchField.placeholderString = "Cerca nella cartella..."
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.lineBreakMode = .byTruncatingTail
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(onSearchFieldChanged)
        searchBarContainer.addSubview(searchField)

        searchCountLabel.translatesAutoresizingMaskIntoConstraints = false
        searchCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .light)
        searchCountLabel.textColor = .secondaryLabelColor
        searchCountLabel.isHidden = true
        searchBarContainer.addSubview(searchCountLabel)

        searchClearBtn.translatesAutoresizingMaskIntoConstraints = false
        searchClearBtn.isBordered = false
        searchClearBtn.title = "✕"
        searchClearBtn.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        searchClearBtn.contentTintColor = .tertiaryLabelColor
        searchClearBtn.toolTip = "Pulisci o chiudi ricerca"
        searchClearBtn.target = self
        searchClearBtn.action = #selector(onSearchClearClicked)
        searchBarContainer.addSubview(searchClearBtn)

        let searchDivider = NSBox()
        searchDivider.boxType = .separator
        searchDivider.translatesAutoresizingMaskIntoConstraints = false
        searchBarContainer.addSubview(searchDivider)
        NSLayoutConstraint.activate([
            searchDivider.leadingAnchor.constraint(equalTo: searchBarContainer.leadingAnchor),
            searchDivider.trailingAnchor.constraint(equalTo: searchBarContainer.trailingAnchor),
            searchDivider.bottomAnchor.constraint(equalTo: searchBarContainer.bottomAnchor)
        ])

        contentTableScrollView.translatesAutoresizingMaskIntoConstraints = false
        contentTableScrollView.documentView = contentTableView
        contentTableScrollView.borderType = .noBorder
        contentTableScrollView.hasVerticalScroller = true
        contentTableScrollView.hasHorizontalScroller = false
        contentTableScrollView.scrollerStyle = .overlay
        contentTableScrollView.autohidesScrollers = true
        contentTableScrollView.drawsBackground = false
        contentContainer.addSubview(contentTableScrollView)

        syncContentTableColumns(isMusicLibrary: false)

        contentTableView.dataSource = self
        contentTableView.delegate = self
        contentTableView.rowSizeStyle = .custom
        contentTableView.rowHeight = 24
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
        contentTableView.onSingleClickRow = { [weak self] row in
            guard let self = self else { return }
            let list = self.currentListItems
            guard row >= 0 && row < list.count, case .media(let m) = list[row] else { return }
            self.delegate?.didSelectMediaItemForSourcePreview(m)
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
        gridView.onSelectionChanged = { [weak self] selectedIds in
            guard let self = self else { return }
            self.delegate?.didActivateSection(.mediaPool)
            self.syncTableSelectionFromGridIds(selectedIds)
        }
        gridView.onClipSelected = { [weak self] item, modifiers in
            self?.delegate?.didActivateSection(.mediaPool)
            if !modifiers.contains(.command) && !modifiers.contains(.shift) {
                self?.delegate?.didSelectMediaItemForSourcePreview(item)
            }
        }
        gridView.onMusicTrackSelected = { [weak self] _, _ in
            self?.delegate?.didActivateSection(.mediaPool)
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
        gridView.onMoveItemsToFolder = { [weak self] itemIds, targetFolderId in
            for id in itemIds {
                EditorProject.shared.moveItem(id, toFolder: targetFolderId)
            }
            self?.refreshMediaPoolDisplay()
            DebugLogger.shared.log("Spostate \(itemIds.count) clip nella cartella", level: .info)
        }
        gridView.onInsertToTimeline = { [weak self] item in
            self?.delegate?.didActivateSection(.mediaPool)
            self?.delegate?.didSelectAddClipToTimeline(item)
        }
        gridView.onDeleteFromPool = { [weak self] item in
            self?.confirmAndDeletePoolItems(mediaIds: [item.id], timelineIds: [], folderIds: [])
        }
        gridView.onDeleteItemsFromPool = { [weak self] ids in
            self?.confirmAndDeletePoolItems(mediaIds: ids, timelineIds: [], folderIds: [])
        }
        gridView.getSelectedPoolCount = { [weak self] in
            self?.selectedDeletablePoolItemCount ?? 0
        }
        gridView.onDeleteSelectedPoolItems = { [weak self] in
            _ = self?.deleteSelectedPoolItems(requireConfirmation: true)
        }
        gridView.onInsertMusicTrack = { [weak self] track in
            self?.importAndAppendMusicTracks([track.url])
        }
        gridView.onAddMusicTracksToFolder = { [weak self] urls, folderId in
            self?.importURLs(urls, targetFolderId: folderId) { imported in
                DebugLogger.shared.log("Aggiunti \(imported.count) brani dalla Libreria musicale al progetto.", level: .info)
            }
        }
        gridView.onURLsDropped = { [weak self] urls in
            self?.processDroppedURLs(urls)
        }
        gridView.onDropItemsOnGrid = { [weak self] ids in
            guard let self = self, self.activeSmartFolder == nil else { return }
            let targetFId = self.isProjectRootSelected && self.selectedFolderIds.isEmpty ? nil : EditorProject.shared.activeFolderId
            for id in ids {
                EditorProject.shared.moveItem(id, toFolder: targetFId)
            }
            self.refreshMediaPoolDisplay()
            DebugLogger.shared.log("Clip spostate in \(targetFId == nil ? "Progetto" : "cartella").", level: .info)
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
            self?.selectSidebarBins(includeProjectRoot: false, folderIds: [f.id])
        }
        gridView.onRenameFolder = { [weak self] f in
            self?.showRenameFolderDialog(folder: f)
        }
        gridView.onRenameMedia = { [weak self] m in
            self?.renameMediaItemInPlace(media: m)
        }
        gridView.onRelinkFolder = { [weak self] f in
            self?.relinkMediaInFolder(f)
        }
        gridView.onRelinkMedia = { [weak self] items in
            self?.relinkOrReplaceMediaItems(items, allowSingleFile: items.count == 1, forceManualReplace: false)
        }
        gridView.onReplaceMediaSource = { [weak self] item in
            self?.relinkOrReplaceMediaItems([item], allowSingleFile: true, forceManualReplace: true)
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

        let searchHeightConstraint = searchBarContainer.heightAnchor.constraint(equalToConstant: 0)
        self.searchBarHeightConstraint = searchHeightConstraint

        NSLayoutConstraint.activate([
            searchBarContainer.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            searchBarContainer.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            searchBarContainer.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            searchHeightConstraint,

            searchLeadingIcon.leadingAnchor.constraint(equalTo: searchBarContainer.leadingAnchor, constant: 10),
            searchLeadingIcon.centerYAnchor.constraint(equalTo: searchBarContainer.centerYAnchor),
            searchLeadingIcon.widthAnchor.constraint(equalToConstant: 13),
            searchLeadingIcon.heightAnchor.constraint(equalToConstant: 13),

            searchField.leadingAnchor.constraint(equalTo: searchLeadingIcon.trailingAnchor, constant: 7),
            searchField.centerYAnchor.constraint(equalTo: searchBarContainer.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: searchCountLabel.leadingAnchor, constant: -6),

            searchCountLabel.trailingAnchor.constraint(equalTo: searchClearBtn.leadingAnchor, constant: -6),
            searchCountLabel.centerYAnchor.constraint(equalTo: searchBarContainer.centerYAnchor),

            searchClearBtn.trailingAnchor.constraint(equalTo: searchBarContainer.trailingAnchor, constant: -8),
            searchClearBtn.centerYAnchor.constraint(equalTo: searchBarContainer.centerYAnchor),
            searchClearBtn.widthAnchor.constraint(equalToConstant: 18),
            searchClearBtn.heightAnchor.constraint(equalToConstant: 18),

            contentTableScrollView.topAnchor.constraint(equalTo: searchBarContainer.bottomAnchor),
            contentTableScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentTableScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentTableScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            gridScrollView.topAnchor.constraint(equalTo: searchBarContainer.bottomAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    private func setupTimelineGridUI(in container: NSView) {
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
        timelineGridView.onSelectionChanged = { [weak self] in
            self?.delegate?.didChangeSelectionFromGrid()
        }
        timelineGridView.onReorderCommitted = { [weak self] in
            self?.delegate?.didReorderTimelineFromGrid()
            self?.updateTimelineGridInfo()
        }
        timelineGridView.onSectionActivated = { [weak self] in
            self?.delegate?.didActivateSection(.mediaPool)
        }
        timelineGridView.onDropMediaIdsAtSlot = { [weak self] ids, slot, trackIdx in
            guard let self = self else { return }
            let items = ids.compactMap { self.mediaItem(for: $0) }
            if !items.isEmpty,
               self.timelineModel?.insertMediaItemsSequentially(items, atSlot: slot, trackIndex: trackIdx) == true {
                self.delegate?.didReorderTimelineFromGrid()
                self.updateTimelineGridInfo()
            }
        }
        timelineGridView.onDropURLsAtSlot = { [weak self] urls, slot, trackIdx in
            guard let self = self else { return }
            let supported = urls.filter { Self.isSupportedMediaURL($0) }
            guard !supported.isEmpty else { return }
            self.importURLs(supported, targetFolderId: EditorProject.shared.activeFolderId) { [weak self] items in
                guard let self = self, !items.isEmpty else { return }
                if self.timelineModel?.insertMediaItemsSequentially(items, atSlot: slot, trackIndex: trackIdx) == true {
                    self.delegate?.didReorderTimelineFromGrid()
                    self.updateTimelineGridInfo()
                }
            }
        }
        timelineGridView.onDropSelectionAtSlot = { [weak self] selId, slot, trackIdx in
            guard let self = self,
                  let sel = EditorProject.shared.selectionTimelines.first(where: { $0.id == selId }) else { return }
            let mediaList = sel.videoTracks.first?.clips.map(\.mediaItem) ?? []
            if !mediaList.isEmpty,
               self.timelineModel?.insertMediaItemsSequentially(mediaList, atSlot: slot, trackIndex: trackIdx) == true {
                self.delegate?.didReorderTimelineFromGrid()
                self.updateTimelineGridInfo()
            }
        }
        timelineGridView.onDeleteSelectedFromGrid = { [weak self] in
            guard let self = self else { return }
            self.timelineModel?.removeSelectedClips()
            self.delegate?.didReorderTimelineFromGrid()
            self.updateTimelineGridInfo()
        }
        timelineGridView.onClipContextMenuRequested = { [weak self] clip, event, sourceView, extraItems in
            self?.delegate?.didRequestClipContextMenuFromGrid(clip, event: event, sourceView: sourceView, extraItems: extraItems)
        }

        NSLayoutConstraint.activate([
            timelineGridScrollView.topAnchor.constraint(equalTo: container.topAnchor),
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

        let label = emptyPlaceholderLabel
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
    private func setTimelineGridVisible(_ showGrid: Bool) {
        poolTabSwitchBtn.image = Lucide.template(showGrid ? .galleryHorizontalEnd : .fileVideoCamera, size: 17)
        poolTabSwitchBtn.isToggleActive = showGrid
        poolTabSwitchBtn.toolTip = showGrid
            ? "Timeline Grid — Clicca per tornare a Media Pool"
            : "Media Pool — Clicca per passare a Timeline Grid"

        gridHeaderStack.isHidden = !showGrid
        gridExpandToggleBtn.isHidden = !showGrid
        gridSizeIcon.isHidden = !showGrid
        gridSizeSlider.isHidden = !showGrid
        viewModeSwitchBtn.isHidden = showGrid
        viewModeDivider.isHidden = showGrid
        searchToggleBtn.isHidden = showGrid
        mediaPoolContainer.isHidden = showGrid
        timelineGridContainer.isHidden = !showGrid

        if showGrid {
            isGridExpanded = isGridExpanded && isTimelineGridVisible
            updateGridExpandButtonVisual()
            refreshTimelineGrid()
            timelineGridView.updateLayoutForCurrentWidth()
        } else if isGridExpanded {
            isGridExpanded = false
            updateGridExpandButtonVisual()
            delegate?.didToggleTimelineGridExpanded(false)
        }
    }

    @objc private func onGridSizeSliderChanged() {
        timelineGridView.cardScale = CGFloat(gridSizeSlider.doubleValue)
    }

    public func revealClipInTimelineGrid(clipId: UUID, trackIndex: Int) {
        delegate?.didActivateSection(.mediaPool)
        if !isTimelineGridVisible {
            setTimelineGridVisible(true)
        }
        if timelineGridView.selectedTrackIndex != trackIndex {
            timelineGridView.selectedTrackIndex = trackIndex
        }
        refreshTimelineGrid()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timelineGridContainer.layoutSubtreeIfNeeded()
            self.timelineGridView.reloadData()
            self.timelineGridView.scrollToClipIfNeeded(clipId)
        }
    }

    @objc private func onPoolTabSwitchClicked() {
        delegate?.didActivateSection(.mediaPool)
        setTimelineGridVisible(!isTimelineGridVisible)
    }

    @objc private func onGridExpandToggleClicked() {
        delegate?.didActivateSection(.mediaPool)
        guard isTimelineGridVisible else { return }
        isGridExpanded.toggle()
        updateGridExpandButtonVisual()
        delegate?.didToggleTimelineGridExpanded(isGridExpanded)
    }

    private func updateGridExpandButtonVisual() {
        gridExpandToggleBtn.image = Lucide.template(isGridExpanded ? .minimize2 : .maximize2, size: 15)
        gridExpandToggleBtn.isToggleActive = isGridExpanded
        gridExpandToggleBtn.toolTip = isGridExpanded
            ? "Ripristina layout predefinito di Timeline Grid"
            : "Espandi Timeline Grid verticalmente sulla sinistra"
    }

    @objc private func onViewModeSwitchClicked() {
        delegate?.didActivateSection(.mediaPool)
        currentViewMode = (currentViewMode == .list) ? .grid : .list
        let isGrid = (currentViewMode == .grid)
        viewModeSwitchBtn.image = Lucide.template(isGrid ? .squarePlay : .list, size: 16)
        viewModeSwitchBtn.isToggleActive = isGrid
        viewModeSwitchBtn.toolTip = isGrid
            ? "Vista Anteprime — Clicca per Vista Elenco"
            : "Vista Elenco — Clicca per Vista Anteprime"
        updateContentModeVisibility()
    }

    private var isUpdatingSidebarSelection: Bool = false

    @objc private func onSearchToggleClicked() {
        delegate?.didActivateSection(.mediaPool)
        setSearchBarOpen(!isSearchBarOpen, focus: true)
    }

    @objc private func onSearchClearClicked() {
        if !searchQuery.isEmpty || !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            searchQuery = ""
            view.window?.makeFirstResponder(searchField)
        } else {
            setSearchBarOpen(false, focus: false)
        }
    }

    public func setSearchBarOpen(_ open: Bool, focus: Bool = false) {
        isSearchBarOpen = open
        searchToggleBtn.isToggleActive = open
        searchBarContainer.isHidden = !open
        searchBarHeightConstraint?.constant = open ? 28 : 0
        if open {
            updateSearchScopeUI(visibleCount: currentListItems.count)
            if focus {
                view.window?.makeFirstResponder(searchField)
            }
        } else {
            if !searchField.stringValue.isEmpty || !searchQuery.isEmpty {
                searchField.stringValue = ""
                searchQuery = ""
            }
            if view.window?.firstResponder === searchField.currentEditor() {
                view.window?.makeFirstResponder(currentViewMode == .grid ? gridView : contentTableView)
            }
        }
        contentContainer.needsLayout = true
    }

    @objc private func onSearchFieldChanged() {
        let txt = searchField.stringValue
        if searchQuery != txt {
            searchQuery = txt
        } else {
            refreshContentOnly()
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        if let tf = obj.object as? NSTextField, tf === searchField {
            searchQuery = tf.stringValue
        }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            setSearchBarOpen(false, focus: false)
            return true
        }
        return false
    }

    private func syncContentTableColumns(isMusicLibrary: Bool) {
        if contentTableView.tableColumns.isEmpty || isShowingMusicColumns != isMusicLibrary {
            isShowingMusicColumns = isMusicLibrary
            for col in Array(contentTableView.tableColumns) {
                contentTableView.removeTableColumn(col)
            }

            if isMusicLibrary {
                let colTitle = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MusicTitle"))
                colTitle.title = "Titolo"
                colTitle.width = 190
                colTitle.sortDescriptorPrototype = NSSortDescriptor(key: "title", ascending: true)
                contentTableView.addTableColumn(colTitle)

                let colArtist = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MusicArtist"))
                colArtist.title = "Artista"
                colArtist.width = 135
                colArtist.sortDescriptorPrototype = NSSortDescriptor(key: "artist", ascending: true)
                contentTableView.addTableColumn(colArtist)

                let colAlbum = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MusicAlbum"))
                colAlbum.title = "Album"
                colAlbum.width = 145
                colAlbum.sortDescriptorPrototype = NSSortDescriptor(key: "album", ascending: true)
                contentTableView.addTableColumn(colAlbum)

                let colGenre = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MusicGenre"))
                colGenre.title = "Genere"
                colGenre.width = 80
                colGenre.sortDescriptorPrototype = NSSortDescriptor(key: "genre", ascending: true)
                contentTableView.addTableColumn(colGenre)

                let colDur = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MusicDuration"))
                colDur.title = "Durata"
                colDur.width = 58
                colDur.sortDescriptorPrototype = NSSortDescriptor(key: "duration", ascending: true)
                contentTableView.addTableColumn(colDur)
            } else {
                let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
                colName.title = "Nome Clip"
                colName.width = 165
                colName.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
                contentTableView.addTableColumn(colName)

                let colDur = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Duration"))
                colDur.title = "Durata"
                colDur.width = 58
                colDur.sortDescriptorPrototype = NSSortDescriptor(key: "duration", ascending: true)
                contentTableView.addTableColumn(colDur)

                let colRes = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Resolution"))
                colRes.title = "Risoluzione"
                colRes.width = 84
                colRes.sortDescriptorPrototype = NSSortDescriptor(key: "resolution", ascending: true)
                contentTableView.addTableColumn(colRes)

                let colFmt = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileFormat"))
                colFmt.title = "Formato"
                colFmt.width = 62
                colFmt.sortDescriptorPrototype = NSSortDescriptor(key: "fileFormat", ascending: true)
                contentTableView.addTableColumn(colFmt)

                let colCodec = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Codec"))
                colCodec.title = "Codec"
                colCodec.width = 74
                colCodec.sortDescriptorPrototype = NSSortDescriptor(key: "codec", ascending: true)
                contentTableView.addTableColumn(colCodec)

                let colFps = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FPS"))
                colFps.title = "FPS"
                colFps.width = 52
                colFps.sortDescriptorPrototype = NSSortDescriptor(key: "fps", ascending: true)
                contentTableView.addTableColumn(colFps)

                let colUsage = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Usage"))
                colUsage.title = "Utilizzo"
                colUsage.width = 58
                colUsage.sortDescriptorPrototype = NSSortDescriptor(key: "usage", ascending: false)
                contentTableView.addTableColumn(colUsage)
            }
            loadSortStateForCurrentScope()
        }
    }

    private func updateSearchScopeUI(visibleCount: Int) {
        let placeholderText: String
        if let smart = activeSmartFolder {
            if smart == .musicLibrary {
                placeholderText = "Cerca titolo, artista, album, genere..."
            } else if smart == .video, let fpsLabel = activeSmartVideoFPSLabel {
                placeholderText = "Cerca in Video (\(fpsLabel) fps)..."
            } else {
                placeholderText = "Cerca in \(smart.rawValue)..."
            }
        } else if selectedFolderIds.isEmpty {
            placeholderText = "Cerca in Progetto..."
        } else if selectedFolderIds.count == 1 && !isProjectRootSelected,
                  let fId = selectedFolderIds.first,
                  let f = EditorProject.shared.folders.first(where: { $0.id == fId }) {
            placeholderText = "Cerca in \"\(f.name)\"..."
        } else {
            let count = selectedFolderIds.count + (isProjectRootSelected ? 1 : 0)
            placeholderText = "Cerca in \(count) cartelle selezionate..."
        }
        searchField.placeholderString = placeholderText
        searchField.placeholderAttributedString = NSAttributedString(
            string: placeholderText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .light),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )

        let isFiltering = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isFiltering {
            searchCountLabel.stringValue = "\(visibleCount)"
            searchCountLabel.isHidden = false
        } else {
            searchCountLabel.stringValue = ""
            searchCountLabel.isHidden = true
        }
    }

    private func updateContentModeVisibility() {
        syncContentTableColumns(isMusicLibrary: activeSmartFolder == .musicLibrary)
        let list = currentListItems
        let hasItems = !list.isEmpty
        let isFiltering = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateSearchScopeUI(visibleCount: list.count)

        if isFiltering && !hasItems {
            emptyPlaceholderLabel.stringValue = "Nessun risultato per \"\(searchQuery)\""
        } else if activeSmartFolder == .musicLibrary {
            emptyPlaceholderLabel.stringValue = MusicLibraryManager.shared.sourceFolderPaths.isEmpty
                ? "Libreria musicale vuota.\nFai clic destro qui o su 'Libreria musicale' per aggiungere una o più cartelle fonte."
                : (MusicLibraryManager.shared.isScanning ? "Scansione cartelle musicali in corso..." : "Nessun brano audio trovato nelle cartelle fonte collegate.")
        } else {
            emptyPlaceholderLabel.stringValue = "Trascina qui file video, audio o cartelle\n(Formati: MOV, MP4, ProRes, WAV, MP3, M4A, ecc.)"
        }
        emptyPlaceholderView.isHidden = hasItems

        if currentViewMode == .list {
            contentTableScrollView.isHidden = !hasItems
            gridScrollView.isHidden = true
            contentTableView.reloadData()
        } else {
            contentTableScrollView.isHidden = true
            gridScrollView.isHidden = !hasItems

            let items: [GridCardItem] = list.map { listItem in
                switch listItem {
                case .timeline(let tl, let idx): return .timeline(tl, index: idx)
                case .media(let m): return .media(m)
                case .folder(let f): return .folder(f)
                case .musicTrack(let tr): return .musicTrack(tr)
                }
            }
            gridView.gridItems = items

            let selectedRows = contentTableView.selectedRowIndexes
            let selectedIds = selectedRows.compactMap { (idx: Int) -> UUID? in
                if idx < list.count {
                    switch list[idx] {
                    case .media(let m): return m.id
                    case .timeline(let tl, _): return tl.id
                    case .folder(let f): return f.id
                    case .musicTrack(let tr): return tr.stableUUID
                    }
                }
                return nil
            }
            gridView.selectedItemIds = Set(selectedIds)
        }
    }

    private func refreshContentOnly() {
        contentTableView.reloadData()
        updateContentModeVisibility()
    }

    private func updateSmartSectionHeight() {
        let targetH = min(220.0, CGFloat(smartSidebarRows.count) * 24.0 + 34.0)
        smartSectionHeightConstraint?.constant = targetH
    }

    @objc private func onSmartVideoDisclosureClicked() {
        isSmartVideoExpanded.toggle()
        if !isSmartVideoExpanded && activeSmartVideoFPSLabel != nil {
            activeSmartVideoFPSLabel = nil
            activeSmartFolder = .video
            loadSortStateForCurrentScope()
        }
        updateSmartSectionHeight()
        isUpdatingSidebarSelection = true
        smartTableView.reloadData()
        isUpdatingSidebarSelection = false
        updateSidebarSelection()
        updateContentModeVisibility()
    }

    public func refreshMediaPoolDisplay() {
        refreshUsageCache()
        if let activeFps = activeSmartVideoFPSLabel, !videoFPSBuckets.contains(where: { $0.label == activeFps }) {
            activeSmartVideoFPSLabel = nil
        }
        updateSmartSectionHeight()
        isUpdatingSidebarSelection = true
        sidebarTableView.reloadData()
        smartTableView.reloadData()
        isUpdatingSidebarSelection = false
        updateSidebarSelection()
        contentTableView.reloadData()
        updateContentModeVisibility()
    }

    private func updateSidebarSelection() {
        isUpdatingSidebarSelection = true
        defer { isUpdatingSidebarSelection = false }

        let knownFolderIds = Set(EditorProject.shared.folders.map(\.id))
        selectedFolderIds = selectedFolderIds.intersection(knownFolderIds)

        if let smart = activeSmartFolder {
            sidebarTableView.deselectAll(nil)
            let sRows = smartSidebarRows
            let targetIdx: Int?
            if smart == .video, let fpsLabel = activeSmartVideoFPSLabel {
                targetIdx = sRows.firstIndex { row in
                    if case .smartVideoFPS(_, let lbl, _) = row { return lbl == fpsLabel }
                    return false
                }
            } else {
                targetIdx = sRows.firstIndex { row in
                    if case .smart(let k) = row { return k == smart }
                    return false
                }
            }
            if let smartIdx = targetIdx {
                smartTableView.selectRowIndexes(IndexSet(integer: smartIdx), byExtendingSelection: false)
            } else {
                smartTableView.deselectAll(nil)
            }
        } else {
            smartTableView.deselectAll(nil)
            var idxs = IndexSet()
            if isProjectRootSelected || selectedFolderIds.isEmpty {
                isProjectRootSelected = selectedFolderIds.isEmpty ? true : isProjectRootSelected
                idxs.insert(0)
            }
            let fRows = folderSidebarRows
            for (rowIdx, rowItem) in fRows.enumerated() {
                if case .folder(let f, _) = rowItem, selectedFolderIds.contains(f.id) {
                    idxs.insert(rowIdx)
                }
            }
            if idxs.isEmpty {
                isProjectRootSelected = true
                idxs.insert(0)
            }
            sidebarTableView.selectRowIndexes(idxs, byExtendingSelection: false)
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
            let ids: [UUID] = currentListItems.compactMap { item in
                switch item {
                case .media(let m): return m.id
                case .musicTrack(let tr): return tr.stableUUID
                case .timeline(let tl, _): return tl.id
                case .folder(let f): return f.id
                }
            }
            contentTableView.selectAll(nil)
            gridView.selectedItemIds = Set(ids)
        } else {
            timelineGridView.selectAllClips()
        }
    }

    private func syncTableSelectionFromGridIds(_ ids: Set<UUID>) {
        var rowIndexes = IndexSet()
        for (idx, item) in currentListItems.enumerated() {
            let entryId: UUID
            switch item {
            case .media(let m): entryId = m.id
            case .musicTrack(let tr): entryId = tr.stableUUID
            case .timeline(let tl, _): entryId = tl.id
            case .folder(let f): entryId = f.id
            }
            if ids.contains(entryId) {
                rowIndexes.insert(idx)
            }
        }
        if contentTableView.selectedRowIndexes != rowIndexes {
            contentTableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
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

    // MARK: - Context Menus (Custom Rounded VisionMenu + Lucide)
    private func musicLibraryContextMenuItems() -> [VisionMenuItem] {
        var items: [VisionMenuItem] = [
            .header("Libreria musicale"),
            .action(title: "Aggiungi cartella fonte...", icon: .folderPlus, iconColor: .systemOrange) { [weak self] in
                self?.addMusicLibrarySourceWithPanel()
            }
        ]
        let sources = MusicLibraryManager.shared.sourceFolderPaths
        if !sources.isEmpty {
            let removeChildren: [VisionMenuItem] = sources.map { path in
                let name = URL(fileURLWithPath: path).lastPathComponent
                return .action(title: "Rimuovi \"\(name)\"", icon: .trash, isDestructive: true) {
                    MusicLibraryManager.shared.removeSourceFolder(path: path)
                }
            }
            items.append(.submenu(title: "Fonti collegate (\(sources.count))", icon: .folder, items: removeChildren))
            items.append(.action(title: "Aggiorna / Riscansiona", icon: .rotateCw, iconColor: .systemCyan) {
                MusicLibraryManager.shared.rescan()
            })
        }
        return items
    }

    private func addMusicLibrarySourceWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Seleziona una o più cartelle contenenti i tuoi brani audio (verranno lette anche le sottocartelle):"
        if panel.runModal() == .OK {
            for url in panel.urls {
                MusicLibraryManager.shared.addSourceFolder(url)
            }
            selectSmartFolder(.musicLibrary)
        }
    }

    private func importAndAppendMusicTracks(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importURLs(urls, targetFolderId: nil) { [weak self] imported in
            guard let self = self else { return }
            for item in imported {
                self.delegate?.didSelectAddClipToTimeline(item)
            }
        }
    }

    private func generalContextMenuItems(defaultParentFolderId: UUID? = nil, isProjectRootMenu: Bool = false) -> [VisionMenuItem] {
        if activeSmartFolder == .musicLibrary {
            return musicLibraryContextMenuItems()
        }
        let parentTarget = defaultParentFolderId ?? (selectedFolderIds.count == 1 && !isProjectRootSelected ? selectedFolderIds.first : nil)
        var items: [VisionMenuItem] = [
            .action(title: parentTarget == nil ? "Nuova cartella in Progetto" : "Nuova sottocartella", icon: .folder, iconColor: .systemOrange) { [weak self] in
                self?.showNewFolderDialog(parentId: parentTarget)
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
        if isProjectRootMenu || (defaultParentFolderId == nil && isProjectRootSelected && activeSmartFolder == nil) {
            items.append(.separator)
            items.append(.action(title: "Ricollega clip...", icon: .link, iconColor: .systemCyan) { [weak self] in
                self?.relinkAllProjectMedia()
            })
        } else if let folderId = parentTarget,
                  let folder = EditorProject.shared.folders.first(where: { $0.id == folderId }) {
            items.append(.separator)
            items.append(.action(title: "Ricollega clip...", icon: .link, iconColor: .systemCyan) { [weak self] in
                self?.relinkMediaInFolder(folder)
            })
        }
        return items
    }

    private func showGeneralContextMenu(event: NSEvent) {
        VisionMenu(items: generalContextMenuItems()).show(for: event, in: self.view)
    }

    private func showFolderSidebarContextMenu(forRow row: Int, event: NSEvent) {
        let rows = folderSidebarRows
        var items: [VisionMenuItem]
        if row >= 0 && row < rows.count {
            switch rows[row] {
            case .projectRoot:
                items = generalContextMenuItems(defaultParentFolderId: nil, isProjectRootMenu: true)
            case .folder(let folder, _):
                items = [
                    .header(folder.name),
                    .action(title: "Apri cartella", icon: .folder, iconColor: .systemOrange) { [weak self] in
                        self?.selectSidebarBins(includeProjectRoot: false, folderIds: [folder.id])
                    },
                    .action(title: "Nuova sottocartella...", icon: .folderPlus, iconColor: .systemOrange) { [weak self] in
                        self?.showNewFolderDialog(parentId: folder.id)
                    },
                    .action(title: "Rinomina cartella...", icon: .pencil) { [weak self] in
                        self?.showRenameFolderDialog(folder: folder, preferSidebar: true)
                    },
                    .action(title: "Ricollega clip...", icon: .link, iconColor: .systemCyan) { [weak self] in
                        self?.relinkMediaInFolder(folder)
                    },
                    .separator,
                    .action(title: "Elimina cartella", icon: .trash, isDestructive: true) { [weak self] in
                        self?.deleteFolder(id: folder.id)
                    }
                ]
            case .smart, .smartVideoFPS:
                items = generalContextMenuItems()
            }
        } else {
            items = generalContextMenuItems()
        }
        VisionMenu(items: items).show(for: event, in: self.view)
    }

    private func showSmartSidebarContextMenu(forRow row: Int, event: NSEvent) {
        let rows = smartSidebarRows
        guard row >= 0 && row < rows.count else {
            showGeneralContextMenu(event: event)
            return
        }
        let items: [VisionMenuItem]
        switch rows[row] {
        case .smart(let kind):
            if kind == .musicLibrary {
                items = musicLibraryContextMenuItems()
            } else if kind == .video {
                items = [
                    .header("Cartella Smart: Video"),
                    .action(title: "Apri Video", icon: .folder, iconColor: .systemCyan) { [weak self] in
                        self?.selectSmartFolder(.video)
                    },
                    .action(title: self.isSmartVideoExpanded ? "Comprimi sottocartelle FPS" : "Espandi sottocartelle FPS", icon: self.isSmartVideoExpanded ? .chevronDown : .chevronRight) { [weak self] in
                        self?.onSmartVideoDisclosureClicked()
                    }
                ]
            } else {
                items = [
                    .header("Cartella Smart: \(kind.rawValue)"),
                    .action(title: "Apri \(kind.rawValue)", icon: .folder, iconColor: .systemCyan) { [weak self] in
                        self?.selectSmartFolder(kind)
                    }
                ]
            }
        case .smartVideoFPS(_, let label, _):
            items = [
                .header("Video • \(label) fps"),
                .action(title: "Mostra clip a \(label) fps", icon: .film, iconColor: .systemIndigo) { [weak self] in
                    self?.activeSmartFolder = .video
                    self?.activeSmartVideoFPSLabel = label
                    self?.isProjectRootSelected = false
                    self?.selectedFolderIds.removeAll()
                    self?.loadSortStateForCurrentScope()
                    self?.refreshMediaPoolDisplay()
                }
            ]
        default:
            showGeneralContextMenu(event: event)
            return
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

        let selected = collectSelectedPoolIds()
        let selectedIdsUnion = Set(selected.mediaIds).union(selected.timelineIds).union(selected.folderIds)
        let isPartOfMultiSelection = (item.deletableId.map { selectedIdsUnion.contains($0) } ?? false) && selectedIdsUnion.count > 1

        switch item {
        case .timeline(let timeline, let index):
            let kindTitle = timeline.isSelection ? "Selezione" : "Timeline"
            items.append(.header(isPartOfMultiSelection ? "\(selectedIdsUnion.count) elementi selezionati" : timeline.name))
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
            if isPartOfMultiSelection {
                items.append(.separator)
                items.append(.action(title: "Elimina \(selectedIdsUnion.count) elementi dal Media Pool...", icon: .trash, isDestructive: true) { [weak self] in
                    _ = self?.deleteSelectedPoolItems(requireConfirmation: true)
                })
            } else if EditorProject.shared.timelines.count > 1 {
                items.append(.separator)
                items.append(.action(title: "Elimina...", icon: .trash, isDestructive: true) { [weak self] in
                    self?.deleteTimeline(index: index)
                })
            }

        case .folder(let folder):
            items.append(.header(isPartOfMultiSelection ? "\(selectedIdsUnion.count) elementi selezionati" : folder.name))
            items.append(.action(title: "Apri cartella", icon: .folder, iconColor: .systemOrange) { [weak self] in
                self?.selectSidebarBins(includeProjectRoot: false, folderIds: [folder.id])
            })
            items.append(.action(title: "Nuova sottocartella...", icon: .folderPlus, iconColor: .systemOrange) { [weak self] in
                self?.showNewFolderDialog(parentId: folder.id)
            })
            items.append(.action(title: "Rinomina cartella...", icon: .pencil) { [weak self] in
                self?.showRenameFolderDialog(folder: folder)
            })
            items.append(.action(title: "Ricollega clip...", icon: .link, iconColor: .systemCyan) { [weak self] in
                self?.relinkMediaInFolder(folder)
            })
            items.append(.separator)
            if isPartOfMultiSelection {
                items.append(.action(title: "Elimina \(selectedIdsUnion.count) elementi dal Media Pool...", icon: .trash, isDestructive: true) { [weak self] in
                    _ = self?.deleteSelectedPoolItems(requireConfirmation: true)
                })
            } else {
                items.append(.action(title: "Elimina cartella...", icon: .trash, isDestructive: true) { [weak self] in
                    self?.deleteFolder(id: folder.id)
                })
            }

        case .media(let media):
            let selMedia = selectedMediaItems
            let targetItems = (selMedia.contains(where: { $0.id == media.id }) && selMedia.count > 1) ? selMedia : [media]
            let targetIds = targetItems.map(\.id)

            items.append(.header(isPartOfMultiSelection ? "\(selectedIdsUnion.count) elementi selezionati" : (targetIds.count > 1 ? "\(targetIds.count) elementi selezionati" : media.name)))
            items.append(.action(title: targetItems.count > 1 ? "Inserisci \(targetItems.count) clip in timeline" : "Inserisci in timeline", icon: .plus, iconColor: .systemCyan) { [weak self] in
                if targetItems.count > 1 {
                    self?.delegate?.didSelectAddClipsToTimeline(targetItems)
                } else {
                    self?.delegate?.didSelectAddClipToTimeline(media)
                }
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

            if targetItems.count == 1 && !isPartOfMultiSelection {
                items.append(.action(title: "Rinomina...", icon: .pencil) { [weak self] in
                    self?.renameMediaItemInPlace(media: media)
                })
            }

            items.append(.action(
                title: targetItems.count > 1 ? "Ricollega \(targetItems.count) clip..." : "Ricollega clip...",
                icon: .link,
                iconColor: .systemCyan
            ) { [weak self] in
                self?.relinkOrReplaceMediaItems(targetItems, allowSingleFile: targetItems.count == 1, forceManualReplace: false)
            })
            if targetItems.count == 1 && !isPartOfMultiSelection {
                items.append(.action(title: "Sostituisci sorgente...", icon: .arrowLeftRight) { [weak self] in
                    self?.relinkOrReplaceMediaItems([media], allowSingleFile: true, forceManualReplace: true)
                })
            }

            var folderChildren: [VisionMenuItem] = [
                .action(title: "Progetto (Root)", icon: .layers) { [weak self] in
                    for id in targetIds { EditorProject.shared.moveItem(id, toFolder: nil) }
                    self?.refreshMediaPoolDisplay()
                }
            ]
            for (f, depth) in EditorProject.shared.flattenedFoldersWithDepth() {
                let prefix = depth > 0 ? String(repeating: "  ", count: depth) + "↳ " : ""
                folderChildren.append(.action(title: prefix + f.name, icon: .folder, iconColor: .systemOrange) { [weak self] in
                    for id in targetIds { EditorProject.shared.moveItem(id, toFolder: f.id) }
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
            let deleteTitle = isPartOfMultiSelection
                ? "Elimina \(selectedIdsUnion.count) elementi dal Media Pool..."
                : (targetIds.count > 1
                    ? "Elimina \(targetIds.count) elementi dal Media Pool..."
                    : "Elimina dal Media Pool...")
            items.append(.action(title: deleteTitle, icon: .trash, isDestructive: true) { [weak self] in
                if isPartOfMultiSelection {
                    _ = self?.deleteSelectedPoolItems(requireConfirmation: true)
                } else {
                    self?.confirmAndDeletePoolItems(mediaIds: targetIds, timelineIds: [], folderIds: [])
                }
            })

        case .musicTrack(let track):
            let selTracks = selectedMusicTracks
            let trackURLs = (selTracks.contains(where: { $0.id == track.id }) && selTracks.count > 1) ? selTracks.map(\.url) : [track.url]
            items.append(.header(trackURLs.count > 1 ? "\(trackURLs.count) brani selezionati" : track.displayTitle))
            items.append(.action(title: "Inserisci in timeline", icon: .plus, iconColor: .systemCyan) { [weak self] in
                self?.importAndAppendMusicTracks(trackURLs)
            })
            var destChildren: [VisionMenuItem] = [
                .action(title: "Progetto (Root)", icon: .layers) { [weak self] in
                    self?.importURLs(trackURLs, targetFolderId: nil)
                }
            ]
            for (f, depth) in EditorProject.shared.flattenedFoldersWithDepth() {
                let prefix = depth > 0 ? String(repeating: "  ", count: depth) + "↳ " : ""
                destChildren.append(.action(title: prefix + f.name, icon: .folder, iconColor: .systemOrange) { [weak self] in
                    self?.importURLs(trackURLs, targetFolderId: f.id)
                })
            }
            items.append(.submenu(title: "Aggiungi al progetto in", icon: .folderInput, items: destChildren))
            items.append(.separator)
            for item in musicLibraryContextMenuItems() {
                if case .header = item { continue }
                items.append(item)
            }
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
        self.activeProxyDialog = dialog
        dialog.showWindow(nil)
    }

    @objc private func onSidebarDoubleClicked() {
        delegate?.didActivateSection(.mediaPool)
        let row = sidebarTableView.clickedRow
        let rows = folderSidebarRows
        guard row >= 0 && row < rows.count else { return }
        switch rows[row] {
        case .projectRoot:
            showRenameProjectDialog()
        case .folder(let folder, _):
            showRenameFolderDialog(folder: folder)
        case .smart, .smartVideoFPS:
            break
        }
    }

    @objc private func onSmartSidebarDoubleClicked() {
        delegate?.didActivateSection(.mediaPool)
        let row = smartTableView.clickedRow
        let rows = smartSidebarRows
        guard row >= 0 && row < rows.count else { return }
        if case .smart(let kind) = rows[row] {
            if kind == .musicLibrary {
                addMusicLibrarySourceWithPanel()
            } else if kind == .video {
                onSmartVideoDisclosureClicked()
            }
        }
    }

    // MARK: - Dialogs & Mutations
    private func showNewFolderDialog(parentId: UUID? = nil) {
        delegate?.didActivateSection(.mediaPool)
        let alert = NSAlert()
        alert.messageText = parentId == nil ? "Nuova Cartella" : "Nuova Sottocartella"
        alert.informativeText = parentId == nil ? "Inserisci il nome per la nuova cartella in Progetto:" : "Inserisci il nome per la sottocartella:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = "Cartella \(EditorProject.shared.folders.count + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Crea")
        alert.addButton(withTitle: "Annulla")

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let folder = EditorProject.shared.addFolder(name: name, parentId: parentId)
                selectSidebarBins(includeProjectRoot: false, folderIds: [folder.id])
                DebugLogger.shared.log("Creata cartella: '\(folder.name)'", level: .info)
            }
        }
    }

    private func beginInlineRename(in tableView: NSTableView, row: Int, initialText: String, onCommit: @escaping (String) -> Void) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()
        let colIndex: Int
        if tableView === contentTableView {
            colIndex = tableView.tableColumns.firstIndex(where: {
                let id = $0.identifier.rawValue
                return id == "Name" || id == "MusicTitle"
            }) ?? 0
        } else {
            colIndex = 0
        }
        guard let cell = tableView.view(atColumn: colIndex, row: row, makeIfNecessary: true) as? NSTableCellView else { return }
        cell.layoutSubtreeIfNeeded()
        let anchorView: NSView = cell.textField ?? cell
        var rect = tableView.convert(anchorView.bounds, from: anchorView)
        let maxRight = tableView.convert(cell.bounds, from: cell).maxX - 4
        rect.origin.x -= 3
        rect.size.width = max(rect.width + 6, maxRight - rect.origin.x)
        rect.size.height = max(rect.height + 4, 20)
        rect.origin.y = rect.midY - rect.size.height * 0.5
        InlineRenameSession.begin(
            in: tableView,
            frame: rect,
            font: cell.textField?.font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
            initialText: initialText,
            maskedView: cell.textField,
            onCommit: onCommit
        )
    }

    private func showRenameFolderDialog(folder: MediaFolder, preferSidebar: Bool = false) {
        delegate?.didActivateSection(.mediaPool)
        let commit: (String) -> Void = { [weak self] name in
            EditorProject.shared.renameFolder(id: folder.id, newName: name)
            self?.refreshMediaPoolDisplay()
        }

        if !preferSidebar {
            if currentViewMode == .grid && timelineGridContainer.isHidden,
               currentListItems.contains(where: { if case .folder(let f) = $0 { return f.id == folder.id }; return false }) {
                gridView.beginInlineRename(forItemId: folder.id, initialText: folder.name, onCommit: commit)
                return
            }
            if let row = currentListItems.firstIndex(where: { if case .folder(let f) = $0 { return f.id == folder.id }; return false }) {
                beginInlineRename(in: contentTableView, row: row, initialText: folder.name, onCommit: commit)
                return
            }
        }

        if let sidebarRow = folderSidebarRows.firstIndex(where: { if case .folder(let f, _) = $0 { return f.id == folder.id }; return false }) {
            beginInlineRename(in: sidebarTableView, row: sidebarRow, initialText: folder.name, onCommit: commit)
        }
    }

    private func renameMediaItemInPlace(media: MediaItem) {
        delegate?.didActivateSection(.mediaPool)
        let commit: (String) -> Void = { [weak self] name in
            guard let self = self,
                  let idx = self.mediaItems.firstIndex(where: { $0.id == media.id }) else { return }
            self.mediaItems[idx].name = name
            let updated = self.mediaItems[idx]
            self.refreshMediaPoolDisplay()
            self.delegate?.didRenameMediaItem(updated)
        }

        if currentViewMode == .grid && timelineGridContainer.isHidden {
            gridView.beginInlineRename(forItemId: media.id, initialText: media.name, onCommit: commit)
        } else if let row = currentListItems.firstIndex(where: { if case .media(let m) = $0 { return m.id == media.id }; return false }) {
            beginInlineRename(in: contentTableView, row: row, initialText: media.name, onCommit: commit)
        }
    }

    private func deleteFolder(id: UUID) {
        confirmAndDeletePoolItems(mediaIds: [], timelineIds: [], folderIds: [id])
    }

    // MARK: - Media Relink & Source Replacement (Nome file + Dimensione esatta in byte)
    private func descendantMediaItemIds(inFolder rootFolderId: UUID) -> Set<UUID> {
        var folderIds: Set<UUID> = [rootFolderId]
        var added = true
        while added {
            added = false
            for f in EditorProject.shared.folders {
                if let pId = f.parentId, folderIds.contains(pId), !folderIds.contains(f.id) {
                    folderIds.insert(f.id)
                    added = true
                }
            }
        }
        var result: Set<UUID> = []
        for f in EditorProject.shared.folders where folderIds.contains(f.id) {
            result.formUnion(f.itemIds)
        }
        return result
    }

    public func relinkAllProjectMedia() {
        promptAndRelinkScope(targetItems: mediaItems, scopeTitle: "Progetto", allowSingleFile: false)
    }

    private func relinkMediaInFolder(_ folder: MediaFolder) {
        let scopedIds = descendantMediaItemIds(inFolder: folder.id)
        let scopedItems = mediaItems.filter { scopedIds.contains($0.id) }
        promptAndRelinkScope(targetItems: scopedItems, scopeTitle: folder.name, allowSingleFile: false)
    }

    public func relinkOrReplaceMediaItems(_ items: [MediaItem], allowSingleFile: Bool, forceManualReplace: Bool) {
        let targetIds = Set(items.map(\.id))
        let resolvedItems = mediaItems.filter { targetIds.contains($0.id) }
        let effectiveItems = resolvedItems.isEmpty ? items : resolvedItems
        guard !effectiveItems.isEmpty else { return }

        if forceManualReplace, let single = effectiveItems.first {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = "Scegli il nuovo file sorgente da collegare a '\(single.name)':"
            panel.prompt = "Collega sorgente"
            guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
            let actualBytes = MediaItem.measureFileSizeBytes(at: chosenURL)
            applyManualSourceReplacement(item: single, to: chosenURL, actualBytes: actualBytes)
            return
        }

        let scopeLabel = effectiveItems.count == 1 ? effectiveItems[0].name : "\(effectiveItems.count) clip selezionate"
        promptAndRelinkScope(targetItems: effectiveItems, scopeTitle: scopeLabel, allowSingleFile: allowSingleFile)
    }

    private func promptAndRelinkScope(targetItems: [MediaItem], scopeTitle: String, allowSingleFile: Bool) {
        delegate?.didActivateSection(.mediaPool)
        guard !targetItems.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nessuna clip presente"
            alert.informativeText = "Non ci sono clip da ricollegare in '\(scopeTitle)'."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowSingleFile && targetItems.count == 1
        panel.allowsMultipleSelection = false
        panel.prompt = "Ricollega"
        if panel.canChooseFiles {
            panel.message = "Seleziona una cartella Finder in cui cercare '\(targetItems[0].matchFileName)' oppure scegli il file diretto:"
        } else {
            panel.message = "Seleziona la cartella Finder in cui cercare le clip spostate di '\(scopeTitle)' (verifica per nome file e dimensione esatta in byte):"
        }

        guard panel.runModal() == .OK, let chosenURL = panel.url else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: chosenURL.path, isDirectory: &isDir) else { return }

        if !isDir.boolValue && targetItems.count == 1 {
            let single = targetItems[0]
            let verification = MediaRelinkService.doesFileMatchStrict(chosenURL, item: single)
            if verification.matches {
                applyStrictSingleRelink(item: single, to: chosenURL, actualBytes: verification.actualBytes)
            } else {
                let expectedDesc = single.fileSizeBytes.map { "\($0) byte" } ?? "dimensione sconosciuta"
                let actualDesc = verification.actualBytes.map { "\($0) byte" } ?? "dimensione sconosciuta"
                let confirm = NSAlert()
                confirm.alertStyle = .informational
                confirm.messageText = "Sorgente diversa rilevata"
                confirm.informativeText = "Atteso: \(single.matchFileName) (\(expectedDesc))\nSelezionato: \(chosenURL.lastPathComponent) (\(actualDesc))\n\nVuoi collegare comunque questo file come nuova sorgente?"
                confirm.addButton(withTitle: "Collega comunque")
                confirm.addButton(withTitle: "Annulla")
                if confirm.runModal() == .alertFirstButtonReturn {
                    applyManualSourceReplacement(item: single, to: chosenURL, actualBytes: verification.actualBytes)
                }
            }
            return
        }

        // Scansione ricorsiva della cartella scelta su coda asincrona
        Task {
            let index = await Task.detached(priority: .userInitiated) {
                MediaRelinkService.indexDirectory(at: chosenURL)
            }.value

            var relinkedItems: [MediaItem] = []
            var relinkedCount = 0
            var alreadyOkCount = 0
            var unmatchedNames: [String] = []

            for item in targetItems {
                if let match = MediaRelinkService.findMatch(for: item, in: index) {
                    let samePath = match.url.standardizedFileURL.path == item.url.standardizedFileURL.path
                    if samePath && item.isMediaAvailableOnDisk {
                        if item.fileSizeBytes == nil || item.originalFileName != match.fileName {
                            var refreshed = item
                            refreshed.originalFileName = match.fileName
                            refreshed.fileSizeBytes = match.fileSizeBytes
                            relinkedItems.append(refreshed)
                        }
                        alreadyOkCount += 1
                    } else {
                        let updated = await MediaRelinkService.buildRelinkedItem(
                            from: item,
                            to: match.url,
                            actualBytes: match.fileSizeBytes,
                            reloadMediaProperties: false
                        )
                        relinkedItems.append(updated)
                        relinkedCount += 1
                    }
                } else {
                    unmatchedNames.append(item.matchFileName)
                }
            }

            await MainActor.run {
                self.commitRelinkedItems(
                    relinkedItems,
                    scopeTitle: scopeTitle,
                    totalTargeted: targetItems.count,
                    relinkedCount: relinkedCount,
                    alreadyOkCount: alreadyOkCount,
                    unmatchedNames: unmatchedNames,
                    showSummaryAlert: true
                )
            }
        }
    }

    private func applyStrictSingleRelink(item: MediaItem, to newURL: URL, actualBytes: Int64?) {
        Task {
            let updated = await MediaRelinkService.buildRelinkedItem(
                from: item,
                to: newURL,
                actualBytes: actualBytes,
                reloadMediaProperties: false
            )
            await MainActor.run {
                self.commitRelinkedItems(
                    [updated],
                    scopeTitle: item.name,
                    totalTargeted: 1,
                    relinkedCount: 1,
                    alreadyOkCount: 0,
                    unmatchedNames: [],
                    showSummaryAlert: false
                )
            }
        }
    }

    private func applyManualSourceReplacement(item: MediaItem, to newURL: URL, actualBytes: Int64?) {
        Task {
            let updated = await MediaRelinkService.buildRelinkedItem(
                from: item,
                to: newURL,
                actualBytes: actualBytes,
                reloadMediaProperties: true
            )
            await MainActor.run {
                self.commitRelinkedItems(
                    [updated],
                    scopeTitle: item.name,
                    totalTargeted: 1,
                    relinkedCount: 1,
                    alreadyOkCount: 0,
                    unmatchedNames: [],
                    showSummaryAlert: false
                )
                DebugLogger.shared.log("Sorgente di '\(item.name)' sostituita con '\(newURL.lastPathComponent)'.", level: .info)
            }
        }
    }

    @MainActor
    private func commitRelinkedItems(
        _ updatedItems: [MediaItem],
        scopeTitle: String,
        totalTargeted: Int,
        relinkedCount: Int,
        alreadyOkCount: Int,
        unmatchedNames: [String],
        showSummaryAlert: Bool
    ) {
        var appliedItems: [MediaItem] = []
        for updated in updatedItems {
            if let idx = mediaItems.firstIndex(where: { $0.id == updated.id }) {
                mediaItems[idx] = updated
            }
            if updated.hasAudio {
                AudioWaveformCache.shared.loadWaveform(for: updated)
            }
            appliedItems.append(updated)
        }

        if !appliedItems.isEmpty {
            refreshMediaPoolDisplay()
            delegate?.didRelinkMediaItems(appliedItems)
        }

        let unmatchedCount = unmatchedNames.count
        DebugLogger.shared.log(
            "Ricollegamento '\(scopeTitle)': \(relinkedCount) ricollegate, \(alreadyOkCount) già collegate, \(unmatchedCount) non trovate (su \(totalTargeted)).",
            level: unmatchedCount > 0 ? .warning : .info
        )

        if showSummaryAlert {
            let alert = NSAlert()
            alert.alertStyle = relinkedCount > 0 || alreadyOkCount > 0 ? .informational : .warning
            alert.messageText = relinkedCount > 0
                ? "Ricollegamento completato (\(scopeTitle))"
                : (alreadyOkCount > 0 ? "Nessuna clip da spostare (\(scopeTitle))" : "Nessuna corrispondenza trovata (\(scopeTitle))")
            var lines: [String] = []
            if relinkedCount > 0 { lines.append("• \(relinkedCount) clip ricollegate (nome + dimensione byte esatta)") }
            if alreadyOkCount > 0 { lines.append("• \(alreadyOkCount) clip già puntavano al file corretto") }
            if unmatchedCount > 0 {
                let preview = unmatchedNames.prefix(5).joined(separator: ", ")
                let suffix = unmatchedCount > 5 ? " ..." : ""
                lines.append("• \(unmatchedCount) clip non trovate nella cartella scelta (\(preview)\(suffix))")
            }
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
        delegate?.didActivateSection(.mediaPool)
        let timeline = EditorProject.shared.timelines[timelineIndex]
        let commit: (String) -> Void = { [weak self] name in
            EditorProject.shared.renameTimeline(index: timelineIndex, newName: name)
            self?.refreshMediaPoolDisplay()
            if timelineIndex < EditorProject.shared.timelines.count {
                self?.delegate?.didRenameTimeline(EditorProject.shared.timelines[timelineIndex])
            }
        }

        if currentViewMode == .grid && timelineGridContainer.isHidden {
            gridView.beginInlineRename(forItemId: timeline.id, initialText: timeline.name, onCommit: commit)
        } else if let row = currentListItems.firstIndex(where: {
            if case .timeline(_, let idx) = $0 { return idx == timelineIndex }
            return false
        }) {
            beginInlineRename(in: contentTableView, row: row, initialText: timeline.name, onCommit: commit)
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
        guard index >= 0 && index < EditorProject.shared.timelines.count else { return }
        let tlId = EditorProject.shared.timelines[index].id
        confirmAndDeletePoolItems(mediaIds: [], timelineIds: [tlId], folderIds: [])
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
        delegate?.didActivateSection(.mediaPool)
        guard let rootRow = folderSidebarRows.firstIndex(where: { if case .projectRoot = $0 { return true }; return false }) else { return }
        beginInlineRename(in: sidebarTableView, row: rootRow, initialText: EditorProject.shared.projectName) { [weak self] name in
            EditorProject.shared.projectName = name
            self?.refreshMediaPoolDisplay()
        }
    }

    public var selectedDeletablePoolItemCount: Int {
        let sel = collectSelectedPoolIds()
        return sel.mediaIds.count + sel.timelineIds.count + sel.folderIds.count
    }

    private func collectSelectedPoolIds() -> (mediaIds: [UUID], timelineIds: [UUID], folderIds: [UUID]) {
        let list = currentListItems
        var mediaIds: [UUID] = []
        var timelineIds: [UUID] = []
        var folderIds: [UUID] = []

        if currentViewMode == .grid && timelineGridContainer.isHidden {
            let ids = gridView.selectedItemIds
            for entry in list where entry.deletableId.map({ ids.contains($0) }) ?? false {
                switch entry {
                case .media(let m): mediaIds.append(m.id)
                case .timeline(let tl, _): timelineIds.append(tl.id)
                case .folder(let f): folderIds.append(f.id)
                case .musicTrack: break
                }
            }
        } else {
            let selectedRows = contentTableView.selectedRowIndexes
            for idx in selectedRows where idx < list.count {
                switch list[idx] {
                case .media(let m): mediaIds.append(m.id)
                case .timeline(let tl, _): timelineIds.append(tl.id)
                case .folder(let f): folderIds.append(f.id)
                case .musicTrack: break
                }
            }
        }
        return (mediaIds, timelineIds, folderIds)
    }

    private func deleteMediaItem(_ item: MediaItem) {
        confirmAndDeletePoolItems(mediaIds: [item.id], timelineIds: [], folderIds: [])
    }

    public func deleteMediaItems(ids: [UUID]) {
        performDeletePoolItems(mediaIds: ids, timelineIds: [], folderIds: [])
    }

    @discardableResult
    public func deleteSelectedMediaItems() -> Bool {
        return deleteSelectedPoolItems(requireConfirmation: true)
    }

    @discardableResult
    public func deleteSelectedPoolItems(requireConfirmation: Bool = true) -> Bool {
        let sel = collectSelectedPoolIds()
        guard !sel.mediaIds.isEmpty || !sel.timelineIds.isEmpty || !sel.folderIds.isEmpty else {
            return false
        }
        if requireConfirmation {
            return confirmAndDeletePoolItems(
                mediaIds: sel.mediaIds,
                timelineIds: sel.timelineIds,
                folderIds: sel.folderIds
            )
        } else {
            return performDeletePoolItems(
                mediaIds: sel.mediaIds,
                timelineIds: sel.timelineIds,
                folderIds: sel.folderIds
            )
        }
    }

    @discardableResult
    public func confirmAndDeletePoolItems(mediaIds: [UUID], timelineIds: [UUID], folderIds: [UUID]) -> Bool {
        let validMedia = mediaItems.filter { Set(mediaIds).contains($0.id) }
        let validTimelines = EditorProject.shared.timelines.filter { Set(timelineIds).contains($0.id) }
        let validFolders = EditorProject.shared.folders.filter { Set(folderIds).contains($0.id) }

        var allowedTimelines = validTimelines
        if !allowedTimelines.isEmpty && (EditorProject.shared.timelines.count - allowedTimelines.count) < 1 {
            if validMedia.isEmpty && validFolders.isEmpty {
                let warn = NSAlert()
                warn.alertStyle = .warning
                warn.messageText = "Impossibile eliminare tutte le timeline"
                warn.informativeText = EditorProject.shared.timelines.count <= 1
                    ? "Il progetto deve contenere almeno una timeline o selezione."
                    : "Il progetto deve mantenere almeno una timeline o selezione. Deselezionane almeno una prima di procedere."
                warn.addButton(withTitle: "OK")
                warn.runModal()
                return false
            }
            // Se sono selezionate tutte le timeline insieme ad altri elementi, preserva l'ultima timeline attiva/prima
            let keepId = EditorProject.shared.activeTimeline.id
            if let dropKeepIdx = allowedTimelines.firstIndex(where: { $0.id == keepId }) {
                allowedTimelines.remove(at: dropKeepIdx)
            } else {
                allowedTimelines.removeLast()
            }
        }

        let totalCount = validMedia.count + allowedTimelines.count + validFolders.count
        guard totalCount > 0 else { return false }

        let alert = NSAlert()
        alert.alertStyle = .warning

        if totalCount == 1 {
            if let m = validMedia.first {
                alert.messageText = "Eliminare \"\(m.name)\" dal Media Pool?"
            } else if let tl = allowedTimelines.first {
                let label = tl.isSelection ? "la selezione" : "la timeline"
                alert.messageText = "Eliminare \(label) \"\(tl.name)\"?"
            } else if let f = validFolders.first {
                alert.messageText = "Eliminare la cartella \"\(f.name)\"?"
            }
        } else {
            alert.messageText = "Eliminare \(totalCount) elementi dal Media Pool?"
        }

        var notes: [String] = []
        if !validMedia.isEmpty {
            notes.append(validMedia.count == 1
                ? "• 1 file media verrà rimosso dal Media Pool (le eventuali clip già presenti sulle timeline rimarranno al loro posto in rosso come offline)."
                : "• \(validMedia.count) file media verranno rimossi dal Media Pool (le eventuali clip già presenti sulle timeline rimarranno al loro posto in rosso come offline).")
        }
        if !allowedTimelines.isEmpty {
            let tlCount = allowedTimelines.filter { !$0.isSelection }.count
            let selCount = allowedTimelines.filter { $0.isSelection }.count
            if tlCount > 0 && selCount > 0 {
                notes.append("• \(tlCount) timeline e \(selCount) selezioni verranno eliminate dal progetto.")
            } else if tlCount > 0 {
                notes.append(tlCount == 1 ? "• 1 timeline verrà eliminata dal progetto." : "• \(tlCount) timeline verranno eliminate dal progetto.")
            } else {
                notes.append(selCount == 1 ? "• 1 selezione verrà eliminata dal progetto." : "• \(selCount) selezioni verranno eliminate dal progetto.")
            }
        }
        if !validFolders.isEmpty {
            notes.append(validFolders.count == 1
                ? "• 1 cartella verrà eliminata (i media contenuti torneranno visibili nella root del progetto)."
                : "• \(validFolders.count) cartelle verranno eliminate (i media contenuti torneranno visibili nella root del progetto).")
        }
        alert.informativeText = notes.joined(separator: "\n")

        let deleteBtn = alert.addButton(withTitle: "Elimina")
        deleteBtn.hasDestructiveAction = true
        alert.addButton(withTitle: "Annulla")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        return performDeletePoolItems(
            mediaIds: validMedia.map(\.id),
            timelineIds: allowedTimelines.map(\.id),
            folderIds: validFolders.map(\.id)
        )
    }

    @discardableResult
    public func performDeletePoolItems(mediaIds: [UUID], timelineIds: [UUID], folderIds: [UUID]) -> Bool {
        let folderIdSet = Set(folderIds)
        let timelineIdSet = Set(timelineIds)
        let mediaIdSet = Set(mediaIds)

        var deletedFoldersCount = 0
        if !folderIdSet.isEmpty {
            for fId in folderIds where EditorProject.shared.folders.contains(where: { $0.id == fId }) {
                EditorProject.shared.removeFolder(id: fId)
                selectedFolderIds.remove(fId)
                deletedFoldersCount += 1
            }
        }

        var deletedTimelinesCount = 0
        var activeTimelineWasDeleted = false
        if !timelineIdSet.isEmpty && EditorProject.shared.timelines.count > 1 {
            let previousActiveId = EditorProject.shared.activeTimeline.id
            var remainingAllowed = EditorProject.shared.timelines.count
            var idsToRemove = Set<UUID>()
            for tl in EditorProject.shared.timelines where timelineIdSet.contains(tl.id) {
                if remainingAllowed <= 1 { break }
                idsToRemove.insert(tl.id)
                remainingAllowed -= 1
            }
            if !idsToRemove.isEmpty {
                deletedTimelinesCount = idsToRemove.count
                activeTimelineWasDeleted = idsToRemove.contains(previousActiveId)
                EditorProject.shared.timelines.removeAll { idsToRemove.contains($0.id) }
                if !activeTimelineWasDeleted,
                   let keptIdx = EditorProject.shared.timelines.firstIndex(where: { $0.id == previousActiveId }) {
                    EditorProject.shared.activeTimelineIndex = keptIdx
                } else {
                    EditorProject.shared.activeTimelineIndex = min(
                        max(0, EditorProject.shared.activeTimelineIndex),
                        max(0, EditorProject.shared.timelines.count - 1)
                    )
                }
                EditorProject.shared.onProjectChanged?()
            }
        }

        let removedMedia = mediaItems.filter { mediaIdSet.contains($0.id) }
        if !removedMedia.isEmpty {
            mediaItems.removeAll(where: { mediaIdSet.contains($0.id) })
            for i in 0..<EditorProject.shared.folders.count {
                EditorProject.shared.folders[i].itemIds.subtract(mediaIdSet)
            }
            for timeline in EditorProject.shared.timelines {
                for id in mediaIdSet {
                    timeline.markOrphans(forMediaId: id)
                }
            }
        }

        guard !removedMedia.isEmpty || deletedTimelinesCount > 0 || deletedFoldersCount > 0 else {
            return false
        }

        gridView.selectedItemIds.subtract(mediaIdSet)
        gridView.selectedItemIds.subtract(timelineIdSet)
        gridView.selectedItemIds.subtract(folderIdSet)
        contentTableView.deselectAll(nil)

        refreshMediaPoolDisplay()

        if deletedTimelinesCount > 0 {
            delegate?.didDeleteTimelinesFromPool(
                activeChanged: activeTimelineWasDeleted,
                deletedCount: deletedTimelinesCount
            )
        }
        if !removedMedia.isEmpty {
            delegate?.didDeleteMediaItemsFromPool(removedMedia)
        }

        DebugLogger.shared.log(
            "Eliminati dal Media Pool: \(removedMedia.count) clip, \(deletedTimelinesCount) timeline/selezioni, \(deletedFoldersCount) cartelle.",
            level: .info
        )
        return true
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

    public func refreshThumbnailsForLUTChange() {
        gridView.refreshAllThumbnails()
        timelineGridView.needsDisplay = true
    }

    public func scrollToSelectedTimelineClipIfVisible(_ clipId: UUID) {
        if !timelineGridContainer.isHidden {
            timelineGridView.scrollToClipIfNeeded(clipId)
        }
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
            return folderSidebarRows.count
        } else if tableView == smartTableView {
            return smartSidebarRows.count
        } else {
            return currentListItems.count
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTableView else { return }
        if isUpdatingSidebarSelection { return }
        delegate?.didActivateSection(.mediaPool)

        if tv == sidebarTableView {
            let rows = folderSidebarRows
            let selIndexes = tv.selectedRowIndexes
            if selIndexes.isEmpty {
                selectSidebarBins(includeProjectRoot: true, folderIds: [])
                return
            }

            activeSmartFolder = nil
            var includeRoot = false
            var folderIds = Set<UUID>()
            for idx in selIndexes where idx < rows.count {
                switch rows[idx] {
                case .projectRoot:
                    includeRoot = true
                case .folder(let f, _):
                    folderIds.insert(f.id)
                case .smart, .smartVideoFPS:
                    break
                }
            }
            isProjectRootSelected = includeRoot
            selectedFolderIds = folderIds
            EditorProject.shared.activeFolderId = folderIds.first

            isUpdatingSidebarSelection = true
            smartTableView.deselectAll(nil)
            isUpdatingSidebarSelection = false

            loadSortStateForCurrentScope()
            updateContentModeVisibility()
            timelineGridView.reloadData()
        } else if tv == smartTableView {
            let row = tv.selectedRow
            let rows = smartSidebarRows
            guard row >= 0 && row < rows.count else { return }
            switch rows[row] {
            case .smart(let kind):
                activeSmartFolder = kind
                activeSmartVideoFPSLabel = nil
            case .smartVideoFPS(_, let label, _):
                activeSmartFolder = .video
                activeSmartVideoFPSLabel = label
            default:
                return
            }
            isProjectRootSelected = false
            selectedFolderIds.removeAll()
            EditorProject.shared.activeFolderId = nil

            isUpdatingSidebarSelection = true
            sidebarTableView.deselectAll(nil)
            isUpdatingSidebarSelection = false

            loadSortStateForCurrentScope()
            updateContentModeVisibility()
            timelineGridView.reloadData()
        } else if tv == contentTableView {
            let list = currentListItems
            let selectedRows = contentTableView.selectedRowIndexes
            let selectedIds = selectedRows.compactMap { (idx: Int) -> UUID? in
                if idx < list.count {
                    switch list[idx] {
                    case .media(let m): return m.id
                    case .timeline(let tl, _): return tl.id
                    case .folder(let f): return f.id
                    case .musicTrack(let tr): return tr.stableUUID
                    }
                }
                return nil
            }
            gridView.selectedItemIds = Set(selectedIds)
        }
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSortDescriptors,
              tableView == contentTableView,
              let first = tableView.sortDescriptors.first,
              let key = first.key else { return }
        sortAscending = first.ascending
        switch key {
        case "name": sortKey = .name
        case "duration": sortKey = .duration
        case "resolution": sortKey = .resolution
        case "fileFormat": sortKey = .fileFormat
        case "codec": sortKey = .codec
        case "fps": sortKey = .fps
        case "usage": sortKey = .usage
        case "title": sortKey = .title
        case "artist": sortKey = .artist
        case "album": sortKey = .album
        case "genre": sortKey = .genre
        default: sortKey = (activeSmartFolder == .musicLibrary) ? .title : .name
        }
        saveSortStateForCurrentScope(key: sortKey, ascending: sortAscending)
        updateContentModeVisibility()
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let list = currentListItems
        guard tableView == contentTableView, row < list.count else { return nil }
        let item = list[row]
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
        case .musicTrack(let tr):
            let pbItem = NSPasteboardItem()
            pbItem.setString(tr.url.absoluteString, forType: .fileURL)
            pbItem.setString(tr.url.path, forType: .string)
            return pbItem
        default:
            return nil
        }
    }

    // MARK: - Drag and Drop into Folders (Sidebar & Content Table)
    public func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let (clipIds, fileURLs) = extractDroppedResources(from: info)
        let isExternalFiles = !fileURLs.isEmpty || info.draggingPasteboard.types?.contains(.fileURL) == true
        let hasInternalClips = !clipIds.isEmpty

        if tableView == sidebarTableView {
            let rows = folderSidebarRows
            if row >= 0 && row < rows.count {
                switch rows[row] {
                case .projectRoot:
                    tableView.setDropRow(row, dropOperation: .on)
                    return hasInternalClips ? .move : (isExternalFiles ? .copy : [])
                case .folder:
                    tableView.setDropRow(row, dropOperation: .on)
                    return hasInternalClips ? .move : (isExternalFiles ? .copy : [])
                case .smart, .smartVideoFPS:
                    return []
                }
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return isExternalFiles ? .copy : []
        } else if tableView == smartTableView {
            let rows = smartSidebarRows
            if row >= 0 && row < rows.count, case .smart(let kind) = rows[row], kind == .musicLibrary && isExternalFiles {
                tableView.setDropRow(row, dropOperation: .on)
                return .copy
            }
            return []
        } else if tableView == contentTableView {
            let list = currentListItems
            if row >= 0 && row < list.count, case .folder = list[row] {
                tableView.setDropRow(row, dropOperation: .on)
                return hasInternalClips ? .move : (isExternalFiles ? .copy : [])
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
                return isExternalFiles ? .copy : []
            }
        }
        return []
    }

    public func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let (clipIds, fileURLs) = extractDroppedResources(from: info)

        if tableView == sidebarTableView {
            let rows = folderSidebarRows
            if row >= 0 && row < rows.count {
                switch rows[row] {
                case .projectRoot:
                    if !clipIds.isEmpty {
                        for id in clipIds { EditorProject.shared.moveItem(id, toFolder: nil) }
                        refreshMediaPoolDisplay()
                        return true
                    } else if !fileURLs.isEmpty {
                        processDroppedURLs(fileURLs, targetFolderId: nil)
                        return true
                    }
                case .folder(let f, _):
                    if !clipIds.isEmpty {
                        for id in clipIds { EditorProject.shared.moveItem(id, toFolder: f.id) }
                        refreshMediaPoolDisplay()
                        return true
                    } else if !fileURLs.isEmpty {
                        processDroppedURLs(fileURLs, targetFolderId: f.id)
                        return true
                    }
                case .smart, .smartVideoFPS:
                    return false
                }
            } else if !fileURLs.isEmpty {
                processDroppedURLs(fileURLs, targetFolderId: nil)
                return true
            }
        } else if tableView == smartTableView {
            let rows = smartSidebarRows
            if row >= 0 && row < rows.count, case .smart(let kind) = rows[row], kind == .musicLibrary {
                let fm = FileManager.default
                var addedDir = false
                for u in fileURLs {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                        MusicLibraryManager.shared.addSourceFolder(u)
                        addedDir = true
                    }
                }
                if addedDir {
                    selectSmartFolder(.musicLibrary)
                    return true
                }
            }
            return false
        } else if tableView == contentTableView {
            let list = currentListItems
            var targetFolderId: UUID? = (activeSmartFolder == nil && selectedFolderIds.count == 1 && !isProjectRootSelected)
                ? selectedFolderIds.first
                : nil
            if row >= 0 && row < list.count, case .folder(let folder) = list[row] {
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
        let list = currentListItems
        guard row >= 0 && row < list.count else { return }
        let item = list[row]

        switch item {
        case .timeline(let tl, let idx):
            EditorProject.shared.activeTimelineIndex = idx
            delegate?.didSwitchActiveTimeline(to: tl)
            refreshMediaPoolDisplay()
        case .media(let m):
            delegate?.didSelectAddClipToTimeline(m)
        case .folder(let f):
            selectSidebarBins(includeProjectRoot: false, folderIds: [f.id])
        case .musicTrack(let tr):
            importAndAppendMusicTracks([tr.url])
        }
    }

    private func makeSidebarCell(for tableView: NSTableView, indent: CGFloat) -> NSTableCellView {
        let cellId = NSUserInterfaceItemIdentifier("SidebarCell_\(Int(indent))")
        if let existing = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            return existing
        }
        let cell = NSTableCellView()
        cell.identifier = cellId

        let imgView = NSImageView()
        imgView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imgView)
        cell.imageView = imgView

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.lineBreakMode = .byTruncatingTail
        tf.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        cell.addSubview(tf)
        cell.textField = tf

        NSLayoutConstraint.activate([
            imgView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6 + indent),
            imgView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 15),
            imgView.heightAnchor.constraint(equalToConstant: 15),

            tf.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == sidebarTableView {
            let rows = folderSidebarRows
            guard row >= 0 && row < rows.count else { return nil }
            let item = rows[row]
            switch item {
            case .projectRoot:
                let cell = makeSidebarCell(for: tableView, indent: 0)
                cell.imageView?.image = Lucide.image(.layers, size: 14, color: .labelColor)
                let rootCount = unfiledMediaItems.count
                cell.textField?.stringValue = "Progetto (\(rootCount))"
                cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                cell.textField?.textColor = .labelColor
                return cell
            case .folder(let f, let depth):
                let indent = CGFloat(min(3, 1 + depth)) * 12.0
                let cell = makeSidebarCell(for: tableView, indent: indent)
                cell.imageView?.image = Lucide.image(.folder, size: 14, color: .systemOrange)
                cell.textField?.stringValue = "\(f.name) (\(f.itemIds.count))"
                cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                cell.textField?.textColor = .labelColor
                return cell
            case .smart, .smartVideoFPS:
                return nil
            }
        }

        if tableView == smartTableView {
            let rows = smartSidebarRows
            guard row >= 0 && row < rows.count else { return nil }
            switch rows[row] {
            case .smart(let kind):
                if kind == .video {
                    let cellId = NSUserInterfaceItemIdentifier("SmartVideoToggleCell")
                    var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView
                    if cell == nil {
                        let newCell = NSTableCellView()
                        newCell.identifier = cellId

                        let imgView = NSImageView()
                        imgView.translatesAutoresizingMaskIntoConstraints = false
                        newCell.addSubview(imgView)
                        newCell.imageView = imgView

                        let tf = NSTextField(labelWithString: "")
                        tf.translatesAutoresizingMaskIntoConstraints = false
                        tf.isBordered = false
                        tf.drawsBackground = false
                        tf.lineBreakMode = .byTruncatingTail
                        tf.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                        tf.setContentHuggingPriority(.required, for: .horizontal)
                        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                        newCell.addSubview(tf)
                        newCell.textField = tf

                        let toggleBtn = NSButton()
                        toggleBtn.translatesAutoresizingMaskIntoConstraints = false
                        toggleBtn.isBordered = false
                        toggleBtn.bezelStyle = .regularSquare
                        toggleBtn.setButtonType(.momentaryChange)
                        toggleBtn.imagePosition = .imageOnly
                        toggleBtn.title = ""
                        toggleBtn.tag = 901
                        toggleBtn.target = self
                        toggleBtn.action = #selector(onSmartVideoDisclosureClicked)
                        newCell.addSubview(toggleBtn)

                        NSLayoutConstraint.activate([
                            imgView.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 8),
                            imgView.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                            imgView.widthAnchor.constraint(equalToConstant: 15),
                            imgView.heightAnchor.constraint(equalToConstant: 15),

                            tf.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 6),
                            tf.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),

                            toggleBtn.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 4),
                            toggleBtn.trailingAnchor.constraint(lessThanOrEqualTo: newCell.trailingAnchor, constant: -6),
                            toggleBtn.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                            toggleBtn.widthAnchor.constraint(equalToConstant: 14),
                            toggleBtn.heightAnchor.constraint(equalToConstant: 16)
                        ])
                        cell = newCell
                    }
                    let count = mediaItems.filter { $0.hasVideo }.count
                    if let toggleBtn = cell?.viewWithTag(901) as? NSButton {
                        let chevIcon: LucideIcon = isSmartVideoExpanded ? .chevronDown : .chevronRight
                        let chevColor = videoFPSBuckets.isEmpty ? NSColor.tertiaryLabelColor : NSColor(calibratedWhite: 0.72, alpha: 1.0)
                        toggleBtn.image = Lucide.image(chevIcon, size: 11, color: chevColor)
                        toggleBtn.toolTip = isSmartVideoExpanded ? "Nascondi sottocartelle FPS" : "Mostra sottocartelle per FPS"
                    }
                    cell?.imageView?.image = Lucide.image(.film, size: 14, color: .systemIndigo)
                    cell?.textField?.stringValue = "Video (\(count))"
                    cell?.textField?.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                    cell?.textField?.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
                    return cell
                }

                let cell = makeSidebarCell(for: tableView, indent: 2)
                switch kind {
                case .video:
                    break
                case .audio:
                    let count = mediaItems.filter { $0.hasAudio && !$0.hasVideo }.count
                    cell.imageView?.image = Lucide.image(.music, size: 14, color: .systemGreen)
                    cell.textField?.stringValue = "Audio (\(count))"
                case .timelines:
                    let count = EditorProject.shared.timelines.filter { !$0.isSelection }.count
                    cell.imageView?.image = Lucide.image(.clapperboard, size: 14, color: .systemCyan)
                    cell.textField?.stringValue = "Timeline (\(count))"
                case .selections:
                    let count = EditorProject.shared.timelines.filter { $0.isSelection }.count
                    cell.imageView?.image = Lucide.image(.sparkles, size: 14, color: .systemPurple)
                    cell.textField?.stringValue = "Selezioni (\(count))"
                case .musicLibrary:
                    let count = MusicLibraryManager.shared.tracks.count
                    cell.imageView?.image = Lucide.image(.volume2, size: 14, color: .systemOrange)
                    cell.textField?.stringValue = "Libreria musicale (\(count))"
                }
                cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                cell.textField?.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
                return cell

            case .smartVideoFPS(_, let label, let count):
                let cell = makeSidebarCell(for: tableView, indent: 16)
                cell.imageView?.image = Lucide.image(.film, size: 12, color: NSColor.systemIndigo.withAlphaComponent(0.85))
                cell.textField?.stringValue = "\(label) fps (\(count))"
                cell.textField?.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
                cell.textField?.textColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
                return cell

            default:
                return nil
            }
        }

        // Content Table View
        let list = currentListItems
        guard row < list.count, let tableColumn = tableColumn else { return nil }
        let listItem = list[row]
        let colId = tableColumn.identifier.rawValue

        if colId == "Name" || colId == "MusicTitle" {
            let cellId = NSUserInterfaceItemIdentifier("ContentNameCell_\(colId)")
            var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView
            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellId

                let imgView = NSImageView()
                imgView.translatesAutoresizingMaskIntoConstraints = false
                imgView.wantsLayer = true
                imgView.layer?.cornerRadius = 3
                imgView.layer?.masksToBounds = true
                imgView.imageScaling = .scaleProportionallyUpOrDown
                cell?.addSubview(imgView)
                cell?.imageView = imgView

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.isBordered = false
                tf.drawsBackground = false
                tf.lineBreakMode = .byTruncatingTail
                tf.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                cell?.addSubview(tf)
                cell?.textField = tf

                let iconSize: CGFloat = colId == "MusicTitle" ? 18 : 16
                NSLayoutConstraint.activate([
                    imgView.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                    imgView.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                    imgView.widthAnchor.constraint(equalToConstant: iconSize),
                    imgView.heightAnchor.constraint(equalToConstant: iconSize),

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
                if !m.isMediaAvailableOnDisk {
                    cell?.textField?.stringValue = "\(m.name) [Offline]"
                    cell?.textField?.textColor = .systemRed
                } else if m.hasProxy {
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
            case .musicTrack(let tr):
                if let cover = ThumbnailCache.shared.artworkThumbnail(for: tr.url) {
                    cell?.imageView?.image = cover
                } else {
                    cell?.imageView?.image = Lucide.image(.music, size: 14, color: .systemOrange)
                }
                cell?.textField?.stringValue = tr.displayTitle
                cell?.textField?.textColor = .labelColor
                cell?.toolTip = "\(tr.displayTitle)\nFile: \(tr.name)"
            }
            return cell
        } else {
            let cellId = NSUserInterfaceItemIdentifier("ContentTextCell")
            var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView
            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellId

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.isBordered = false
                tf.drawsBackground = false
                tf.lineBreakMode = .byTruncatingTail
                tf.font = NSFont.systemFont(ofSize: 11)
                cell?.addSubview(tf)
                cell?.textField = tf

                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor)
                ])
            }
            let textField = cell?.textField

            switch colId {
            case "Duration", "MusicDuration":
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
                case .musicTrack(let tr):
                    textField?.stringValue = tr.formattedDuration
                    textField?.textColor = .secondaryLabelColor
                }
            case "Resolution":
                switch listItem {
                case .timeline(let tl, _):
                    textField?.stringValue = tl.isSelection ? "1V+1A" : "\(Int(tl.format.size.width))×\(Int(tl.format.size.height))"
                    textField?.textColor = .secondaryLabelColor
                case .media(let m):
                    textField?.stringValue = (m.hasVideo && m.resolution.width > 0)
                        ? "\(Int(m.resolution.width))×\(Int(m.resolution.height))"
                        : "—"
                    textField?.textColor = m.hasVideo ? .labelColor : .tertiaryLabelColor
                case .folder, .musicTrack:
                    textField?.stringValue = ""
                }
            case "FileFormat":
                switch listItem {
                case .timeline(let tl, _):
                    textField?.stringValue = tl.isSelection ? "Selezione" : "Timeline"
                    textField?.textColor = .secondaryLabelColor
                case .media(let m):
                    textField?.stringValue = formatExtensionLabel(for: m)
                    textField?.textColor = .secondaryLabelColor
                case .folder:
                    textField?.stringValue = "Cartella"
                    textField?.textColor = .secondaryLabelColor
                case .musicTrack(let tr):
                    let ext = tr.url.pathExtension.uppercased()
                    textField?.stringValue = ext.isEmpty ? "AUDIO" : ext
                    textField?.textColor = .secondaryLabelColor
                }
            case "Codec":
                switch listItem {
                case .timeline(let tl, _):
                    textField?.stringValue = tl.format.name
                    textField?.textColor = .secondaryLabelColor
                case .media(let m):
                    textField?.stringValue = m.hasVideo ? m.videoCodec : "Audio (\(m.audioTrackCount) ch)"
                    textField?.textColor = .labelColor
                case .folder:
                    textField?.stringValue = ""
                case .musicTrack(let tr):
                    let loc = tr.relativeSubfolder.isEmpty ? tr.sourceFolderName : "\(tr.sourceFolderName)/\(tr.relativeSubfolder)"
                    textField?.stringValue = "Libreria • \(loc)"
                    textField?.textColor = .secondaryLabelColor
                }
            case "FPS":
                switch listItem {
                case .timeline(let tl, _):
                    textField?.stringValue = tl.isSelection ? "—" : TimelineModel.formatFPSLabel(tl.format.fps)
                    textField?.textColor = .secondaryLabelColor
                case .media(let m):
                    textField?.stringValue = (m.hasVideo && m.frameRate > 0) ? TimelineModel.formatFPSLabel(m.frameRate) : "—"
                    textField?.textColor = m.hasVideo ? .labelColor : .tertiaryLabelColor
                case .folder, .musicTrack:
                    textField?.stringValue = ""
                }
            case "Usage":
                if case .media(let m) = listItem {
                    let u = usageText(for: m.id)
                    textField?.stringValue = u.text
                    textField?.textColor = u.isActive ? .systemCyan : .secondaryLabelColor
                } else {
                    textField?.stringValue = ""
                }
            case "MusicArtist":
                if case .musicTrack(let tr) = listItem {
                    textField?.stringValue = (tr.artist?.isEmpty == false) ? tr.artist! : "—"
                    textField?.textColor = (tr.artist?.isEmpty == false) ? .labelColor : .tertiaryLabelColor
                } else {
                    textField?.stringValue = ""
                }
            case "MusicAlbum":
                if case .musicTrack(let tr) = listItem {
                    textField?.stringValue = (tr.album?.isEmpty == false) ? tr.album! : "—"
                    textField?.textColor = (tr.album?.isEmpty == false) ? .secondaryLabelColor : .tertiaryLabelColor
                } else {
                    textField?.stringValue = ""
                }
            case "MusicGenre":
                if case .musicTrack(let tr) = listItem {
                    textField?.stringValue = (tr.genre?.isEmpty == false) ? tr.genre! : "—"
                    textField?.textColor = .secondaryLabelColor
                } else {
                    textField?.stringValue = ""
                }
            default:
                textField?.stringValue = ""
            }
            return cell
        }
    }
}
