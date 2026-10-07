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

    public var projectName: String = "Progetto 1"
    public var folders: [MediaFolder] = []
    public var activeFolderId: UUID? = nil // nil = "Tutti i file"

    public var timelines: [TimelineModel] = []
    public var activeTimelineIndex: Int = 0

    public var onProjectChanged: (() -> Void)?

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
}
