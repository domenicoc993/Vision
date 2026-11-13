import Foundation
import CoreMedia

public struct MediaFolder: Identifiable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var itemIds: Set<UUID>

    public init(id: UUID = UUID(), name: String, itemIds: Set<UUID> = []) {
        self.id = id
        self.name = name
        self.itemIds = itemIds
    }
}

public final class EditorProject {
    public static let shared = EditorProject()

    public var projectId: UUID = UUID()
    public var projectName: String = "Progetto 1"
    public var createdAt: Date = Date()
    public var lastSavedAt: Date? = nil

    public var folders: [MediaFolder] = []
    public var activeFolderId: UUID? = nil // nil = "Tutti i file"

    public var timelines: [TimelineModel] = []
    public var activeTimelineIndex: Int = 0

    public var selections: [SelectionModel] = []
    public var activeSelectionIndex: Int = 0

    // Proxy Engine state
    public var isProxyPlaybackEnabled: Bool = false
    public var proxyOutputFolderURL: URL? = nil
    public var onProxyToggleChanged: (() -> Void)?

    public var onProjectChanged: (() -> Void)?

    public var activeSelection: SelectionModel? {
        guard !selections.isEmpty else { return nil }
        if activeSelectionIndex >= selections.count {
            activeSelectionIndex = 0
        }
        return selections[activeSelectionIndex]
    }

    @discardableResult
    public func createSelection(name: String, clips: [MediaItem]) -> SelectionModel {
        let sel = SelectionModel(name: name, clips: clips)
        selections.append(sel)
        activeSelectionIndex = selections.count - 1
        onProjectChanged?()
        return sel
    }

    @discardableResult
    public func duplicateSelection(id: UUID) -> SelectionModel? {
        guard let orig = selections.first(where: { $0.id == id }) else { return nil }
        let copy = SelectionModel(name: "\(orig.name) (Copia)", clips: orig.initialClips)
        copy.analysisClips = orig.analysisClips
        copy.rejectedClips = orig.rejectedClips
        copy.selectedClips = orig.selectedClips
        selections.append(copy)
        activeSelectionIndex = selections.count - 1
        onProjectChanged?()
        return copy
    }

    public func removeSelection(id: UUID) {
        selections.removeAll(where: { $0.id == id })
        if activeSelectionIndex >= selections.count {
            activeSelectionIndex = max(0, selections.count - 1)
        }
        onProjectChanged?()
    }

    public var activeTimeline: TimelineModel {
        if timelines.isEmpty {
            let def = TimelineModel(name: "Timeline 1")
            timelines.append(def)
        }
        if activeTimelineIndex >= timelines.count {
            activeTimelineIndex = 0
        }
        return timelines[activeTimelineIndex]
    }

    public init() {
        let defaultTimeline = TimelineModel(name: "Timeline 1")
        self.timelines = [defaultTimeline]
    }

    @discardableResult
    public func addTimeline(name: String? = nil) -> TimelineModel {
        let count = timelines.count + 1
        let tName = name ?? "Timeline \(count)"
        let newModel = TimelineModel(name: tName)
        timelines.append(newModel)
        activeTimelineIndex = timelines.count - 1
        onProjectChanged?()
        return newModel
    }

    public func renameTimeline(index: Int, newName: String) {
        guard index >= 0 && index < timelines.count else { return }
        timelines[index].name = newName
        onProjectChanged?()
    }

    public func removeTimeline(index: Int) {
        guard timelines.count > 1, index >= 0 && index < timelines.count else { return }
        timelines.remove(at: index)
        if activeTimelineIndex >= timelines.count {
            activeTimelineIndex = timelines.count - 1
        }
        onProjectChanged?()
    }

    @discardableResult
    public func addFolder(name: String) -> MediaFolder {
        let folder = MediaFolder(name: name)
        folders.append(folder)
        onProjectChanged?()
        return folder
    }

    public func renameFolder(id: UUID, newName: String) {
        if let idx = folders.firstIndex(where: { $0.id == id }) {
            folders[idx].name = newName
            onProjectChanged?()
        }
    }

    public func removeFolder(id: UUID) {
        folders.removeAll(where: { $0.id == id })
        if activeFolderId == id {
            activeFolderId = nil
        }
        onProjectChanged?()
    }

    public func moveItem(_ itemId: UUID, toFolder folderId: UUID?) {
        for i in 0..<folders.count {
            folders[i].itemIds.remove(itemId)
            if let fId = folderId, folders[i].id == fId {
                folders[i].itemIds.insert(itemId)
            }
        }
        onProjectChanged?()
    }

    public func reset(with document: ProjectDocumentData, restoredMedia: [MediaItem]) {
        self.projectId = document.id
        self.projectName = document.name
        self.createdAt = document.createdAt
        self.folders = document.folders
        self.activeFolderId = document.activeFolderId

        let mediaDict = Dictionary(uniqueKeysWithValues: restoredMedia.map { ($0.id, $0) })
        self.timelines = document.timelines.map { $0.toModel(mediaItems: mediaDict) }
        self.activeTimelineIndex = min(document.activeTimelineIndex, max(0, self.timelines.count - 1))
        self.selections = document.selections.map { $0.toModel(mediaItems: mediaDict) }
        self.activeSelectionIndex = min(document.activeSelectionIndex, max(0, self.selections.count - 1))
        self.isProxyPlaybackEnabled = document.isProxyPlaybackEnabled
        if let pPath = document.proxyOutputFolderPath {
            self.proxyOutputFolderURL = URL(fileURLWithPath: pPath)
        }
        self.lastSavedAt = Date()
        self.onProjectChanged?()
    }
}
