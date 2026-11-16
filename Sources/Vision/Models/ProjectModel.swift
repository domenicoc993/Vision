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

    // Proxy Engine state
    public var isProxyPlaybackEnabled: Bool = false
    public var proxyOutputFolderURL: URL? = nil
    public var onProxyToggleChanged: (() -> Void)?

    public var onProjectChanged: (() -> Void)?

    public var selectionTimelines: [TimelineModel] {
        timelines.filter { $0.isSelection }
    }

    public var regularTimelines: [TimelineModel] {
        timelines.filter { !$0.isSelection }
    }

    @discardableResult
    public func createSelection(name: String, clips: [MediaItem]) -> TimelineModel {
        let sel = TimelineModel(name: name, isSelection: true)
        let sortedItems = clips.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for item in sortedItems {
            sel.appendClip(mediaItem: item)
        }
        timelines.append(sel)
        activeTimelineIndex = timelines.count - 1
        onProjectChanged?()
        return sel
    }

    @discardableResult
    public func duplicateTimeline(index: Int) -> TimelineModel? {
        guard index >= 0 && index < timelines.count else { return nil }
        let orig = timelines[index]
        let copy = TimelineModel(name: "\(orig.name) (Copia)", isSelection: orig.isSelection)
        copy.format = orig.format
        copy.isLinkActive = orig.isLinkActive
        copy.isSnappingActive = orig.isSnappingActive
        copy.isSelectionFollowsPlayhead = orig.isSelectionFollowsPlayhead
        copy.isCageLockActive = orig.isCageLockActive
        copy.rhythmicCages = orig.rhythmicCages
        copy.detectedBPM = orig.detectedBPM
        copy.beatIntervalMode = orig.beatIntervalMode
        copy.peakSensitivity = orig.peakSensitivity
        copy.videoTracks = orig.videoTracks.map { track in
            var t = track
            t.clips = track.clips.map { clip in
                TimelineClip(
                    id: UUID(),
                    mediaItem: clip.mediaItem,
                    sourceIn: clip.sourceIn,
                    sourceOut: clip.sourceOut,
                    timelineStart: clip.timelineStart,
                    trackIndex: clip.trackIndex,
                    mediaType: clip.mediaType,
                    orientation: clip.orientation,
                    linkGroupId: clip.linkGroupId,
                    isOrphan: clip.isOrphan,
                    speed: clip.speed,
                    cageIndex: clip.cageIndex,
                    span: clip.span,
                    beatMarkers: clip.beatMarkers,
                    beatBPM: clip.beatBPM,
                    markers: clip.markers,
                    priority: clip.priority,
                    isLocked: clip.isLocked
                )
            }
            return t
        }
        copy.audioTracks = orig.audioTracks.map { track in
            var t = track
            t.clips = track.clips.map { clip in
                TimelineClip(
                    id: UUID(),
                    mediaItem: clip.mediaItem,
                    sourceIn: clip.sourceIn,
                    sourceOut: clip.sourceOut,
                    timelineStart: clip.timelineStart,
                    trackIndex: clip.trackIndex,
                    mediaType: clip.mediaType,
                    orientation: clip.orientation,
                    linkGroupId: clip.linkGroupId,
                    isOrphan: clip.isOrphan,
                    speed: clip.speed,
                    cageIndex: clip.cageIndex,
                    span: clip.span,
                    beatMarkers: clip.beatMarkers,
                    beatBPM: clip.beatBPM,
                    markers: clip.markers,
                    priority: clip.priority,
                    isLocked: clip.isLocked
                )
            }
            return t
        }
        timelines.append(copy)
        activeTimelineIndex = timelines.count - 1
        onProjectChanged?()
        return copy
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
    public func addTimeline(name: String? = nil, isSelection: Bool = false) -> TimelineModel {
        let count = timelines.filter { $0.isSelection == isSelection }.count + 1
        let defaultPrefix = isSelection ? "Selezione" : "Timeline"
        let tName = name ?? "\(defaultPrefix) \(count)"
        let newModel = TimelineModel(name: tName, isSelection: isSelection)
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
        var loadedTimelines = document.timelines.map { $0.toModel(mediaItems: mediaDict) }
        if let legacySelections = document.selections {
            let existingIds = Set(loadedTimelines.map(\.id))
            for legacy in legacySelections where !existingIds.contains(legacy.id) {
                loadedTimelines.append(legacy.toSelectionTimeline(mediaItems: mediaDict))
            }
        }
        if loadedTimelines.isEmpty {
            loadedTimelines = [TimelineModel(name: "Timeline 1")]
        }
        self.timelines = loadedTimelines
        self.activeTimelineIndex = min(document.activeTimelineIndex, max(0, self.timelines.count - 1))
        self.isProxyPlaybackEnabled = document.isProxyPlaybackEnabled
        if let pPath = document.proxyOutputFolderPath {
            self.proxyOutputFolderURL = URL(fileURLWithPath: pPath)
        }
        self.lastSavedAt = Date()
        self.onProjectChanged?()
    }
}
