import Foundation
import SQLite3
import CoreMedia
import AVFoundation

// MARK: - Codable DTO Models for Complete Project Storage
public struct MediaItemData: Codable {
    public var id: UUID
    public var urlPath: String
    public var name: String
    public var durationSeconds: Double
    public var width: Double
    public var height: Double
    public var frameRate: Float
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var videoCodec: String
    public var audioTrackCount: Int
    public var orientation: String
    public var proxyURLPath: String?
    public var beatAnalysis: SavedBeatAnalysis?

    public init(item: MediaItem) {
        self.id = item.id
        self.urlPath = item.url.path
        self.name = item.name
        self.durationSeconds = CMTimeGetSeconds(item.duration)
        self.width = Double(item.resolution.width)
        self.height = Double(item.resolution.height)
        self.frameRate = item.frameRate
        self.hasVideo = item.hasVideo
        self.hasAudio = item.hasAudio
        self.videoCodec = item.videoCodec
        self.audioTrackCount = item.audioTrackCount
        self.orientation = item.orientation.rawValue
        self.proxyURLPath = item.proxyURL?.path
        self.beatAnalysis = item.beatAnalysis
    }

    public func toMediaItem() -> MediaItem {
        var url = URL(fileURLWithPath: urlPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Se il file non esiste, prova a verificare se il volume è stato rinominato (es. Lavoro Apple -> Lavoro A)
            if let volumes = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
                let components = url.pathComponents
                if components.count > 3 && components[1] == "Volumes" {
                    let subPath = components.dropFirst(3).joined(separator: "/")
                    for vol in volumes {
                        let candidate = vol.appendingPathComponent(subPath)
                        if FileManager.default.fileExists(atPath: candidate.path) {
                            url = candidate
                            break
                        }
                    }
                }
            }
        }

        let proxy = proxyURLPath.map { URL(fileURLWithPath: $0) }
        let orient = ClipOrientation(rawValue: orientation) ?? .normal
        return MediaItem(
            id: id,
            url: url,
            name: name,
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600),
            resolution: CGSize(width: width, height: height),
            frameRate: frameRate,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            videoCodec: videoCodec,
            audioTrackCount: audioTrackCount,
            orientation: orient,
            proxyURL: proxy,
            beatAnalysis: beatAnalysis
        )
    }
}

public struct TimelineClipData: Codable {
    public var id: UUID
    public var mediaItemId: UUID
    public var sourceInSeconds: Double
    public var sourceOutSeconds: Double
    public var timelineStartSeconds: Double
    public var trackIndex: Int
    public var mediaType: String
    public var orientation: String
    public var linkGroupId: UUID?
    public var isOrphan: Bool
    public var speed: Double?
    public var cageIndex: Int?
    public var span: Int?
    public var beatMarkers: [Double]?
    public var beatBPM: Double?
    public var markers: [Double]?
    public var priority: Int?
    public var isLocked: Bool?
    public var selectionSourceIn: Double?
    public var selectionSourceOut: Double?

    public init(clip: TimelineClip) {
        self.id = clip.id
        self.mediaItemId = clip.mediaItem.id
        self.sourceInSeconds = CMTimeGetSeconds(clip.sourceIn)
        self.sourceOutSeconds = CMTimeGetSeconds(clip.sourceOut)
        self.timelineStartSeconds = CMTimeGetSeconds(clip.timelineStart)
        self.trackIndex = clip.trackIndex
        self.mediaType = clip.mediaType.rawValue
        self.orientation = clip.orientation.rawValue
        self.linkGroupId = clip.linkGroupId
        self.isOrphan = clip.isOrphan
        self.speed = clip.speed
        self.cageIndex = clip.cageIndex
        self.span = clip.span
        self.beatMarkers = clip.beatMarkers.isEmpty ? nil : clip.beatMarkers
        self.beatBPM = clip.beatBPM
        self.markers = clip.markers.isEmpty ? nil : clip.markers
        self.priority = clip.priority
        self.isLocked = clip.isLocked ? true : nil
        self.selectionSourceIn = clip.selectionSourceIn
        self.selectionSourceOut = clip.selectionSourceOut
    }

    public func toClip(mediaItems: [UUID: MediaItem]) -> TimelineClip? {
        guard let item = mediaItems[mediaItemId] else { return nil }
        let orient = ClipOrientation(rawValue: orientation) ?? item.orientation
        let mType = AVMediaType(rawValue: mediaType)
        return TimelineClip(
            id: id,
            mediaItem: item,
            sourceIn: CMTime(seconds: sourceInSeconds, preferredTimescale: 600),
            sourceOut: CMTime(seconds: sourceOutSeconds, preferredTimescale: 600),
            timelineStart: CMTime(seconds: timelineStartSeconds, preferredTimescale: 600),
            trackIndex: trackIndex,
            mediaType: mType,
            orientation: orient,
            linkGroupId: linkGroupId,
            isOrphan: isOrphan,
            speed: speed ?? 1.0,
            cageIndex: cageIndex,
            span: span ?? 1,
            beatMarkers: beatMarkers ?? [],
            beatBPM: beatBPM,
            markers: markers ?? [],
            priority: priority,
            isLocked: isLocked ?? false,
            selectionSourceIn: selectionSourceIn,
            selectionSourceOut: selectionSourceOut
        )
    }
}

public struct TimelineTrackData: Codable {
    public var id: Int
    public var name: String
    public var mediaType: String
    public var clips: [TimelineClipData]
    public var isEnabled: Bool
    public var isLocked: Bool

    public init(track: TimelineTrack) {
        self.id = track.id
        self.name = track.name
        self.mediaType = track.mediaType.rawValue
        self.clips = track.clips.map { TimelineClipData(clip: $0) }
        self.isEnabled = track.isEnabled
        self.isLocked = track.isLocked
    }

    public func toTrack(mediaItems: [UUID: MediaItem]) -> TimelineTrack {
        let restoredClips = clips.compactMap { $0.toClip(mediaItems: mediaItems) }
        let mType = AVMediaType(rawValue: mediaType)
        return TimelineTrack(
            id: id,
            name: name,
            mediaType: mType,
            clips: restoredClips,
            isEnabled: isEnabled,
            isLocked: isLocked
        )
    }
}

public struct TimelineModelData: Codable {
    public var id: UUID
    public var name: String
    public var isSelection: Bool?
    public var width: Double
    public var height: Double
    public var fps: Double
    public var videoTracks: [TimelineTrackData]
    public var audioTracks: [TimelineTrackData]
    public var isLinkActive: Bool
    public var isSnappingActive: Bool
    public var isSelectionFollowsPlayhead: Bool
    public var isCageLockActive: Bool?
    public var rhythmicCages: [RhythmicCage]?
    public var detectedBPM: Double?
    public var beatIntervalMode: BeatIntervalMode?
    public var peakSensitivity: Double?
    public var playheadSeconds: Double?

    public init(model: TimelineModel) {
        self.id = model.id
        self.name = model.name
        self.isSelection = model.isSelection
        self.width = Double(model.format.size.width)
        self.height = Double(model.format.size.height)
        self.fps = Double(model.format.fps)
        self.videoTracks = model.videoTracks.map { TimelineTrackData(track: $0) }
        self.audioTracks = model.audioTracks.map { TimelineTrackData(track: $0) }
        self.isLinkActive = model.isLinkActive
        self.isSnappingActive = model.isSnappingActive
        self.isSelectionFollowsPlayhead = model.isSelectionFollowsPlayhead
        self.isCageLockActive = model.isCageLockActive
        self.rhythmicCages = model.rhythmicCages
        self.detectedBPM = model.detectedBPM
        self.beatIntervalMode = model.beatIntervalMode
        self.peakSensitivity = model.peakSensitivity
        self.playheadSeconds = model.playheadSeconds
    }

    public func toModel(mediaItems: [UUID: MediaItem]) -> TimelineModel {
        let isSel = isSelection ?? false
        let model = TimelineModel(name: name, isSelection: isSel)
        model.format = TimelineFormat(id: "custom", name: "\(Int(width))×\(Int(height))", size: CGSize(width: width, height: height), fps: Float(fps))
        model.id = id
        model.videoTracks = videoTracks.map { $0.toTrack(mediaItems: mediaItems) }
        model.audioTracks = audioTracks.map { $0.toTrack(mediaItems: mediaItems) }
        if isSel {
            model.videoTracks = Array(model.videoTracks.prefix(1))
            model.audioTracks = Array(model.audioTracks.prefix(1))
        }
        model.isLinkActive = isLinkActive
        model.isSnappingActive = isSnappingActive
        model.isSelectionFollowsPlayhead = isSelectionFollowsPlayhead
        model.isCageLockActive = isCageLockActive ?? true
        model.rhythmicCages = rhythmicCages ?? []
        model.detectedBPM = detectedBPM
        if let savedMode = beatIntervalMode {
            model.beatIntervalMode = savedMode
        }
        if let savedSens = peakSensitivity {
            model.peakSensitivity = savedSens
        }
        model.playheadSeconds = max(0.0, playheadSeconds ?? 0.0)
        return model
    }
}

public struct LegacySelectionClipData: Codable {
    public var id: UUID
    public var mediaItemId: UUID
    public var sourceInSeconds: Double
    public var durationSeconds: Double
    public var originalName: String
}

public struct LegacySelectionModelData: Codable {
    public var id: UUID
    public var name: String
    public var initialClipIds: [UUID]
    public var rejectedClips: [LegacySelectionClipData]
    public var analysisClips: [LegacySelectionClipData]
    public var selectedClips: [LegacySelectionClipData]
    public var createdAt: Date

    public func toSelectionTimeline(mediaItems: [UUID: MediaItem]) -> TimelineModel {
        let model = TimelineModel(name: name, isSelection: true)
        model.id = id
        let chosen = !selectedClips.isEmpty ? selectedClips : analysisClips
        var cursor: CMTime = .zero
        for itemData in chosen {
            guard let m = mediaItems[itemData.mediaItemId] else { continue }
            let dur = CMTime(seconds: max(0.05, itemData.durationSeconds), preferredTimescale: 600)
            let sIn = CMTime(seconds: max(0, itemData.sourceInSeconds), preferredTimescale: 600)
            let sOut = CMTimeAdd(sIn, dur)
            let linkId = (m.hasVideo && m.hasAudio) ? UUID() : nil
            if m.hasVideo {
                model.videoTracks[0].clips.append(TimelineClip(
                    mediaItem: m,
                    sourceIn: sIn,
                    sourceOut: sOut,
                    timelineStart: cursor,
                    trackIndex: 0,
                    mediaType: .video,
                    orientation: m.orientation,
                    linkGroupId: linkId
                ))
            }
            if m.hasAudio {
                model.audioTracks[0].clips.append(TimelineClip(
                    mediaItem: m,
                    sourceIn: sIn,
                    sourceOut: sOut,
                    timelineStart: cursor,
                    trackIndex: 0,
                    mediaType: .audio,
                    orientation: .normal,
                    linkGroupId: linkId
                ))
            }
            cursor = CMTimeAdd(cursor, dur)
        }
        return model
    }
}

public struct ProjectDocumentData: Codable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var folders: [MediaFolder]
    public var activeFolderId: UUID?
    public var mediaItems: [MediaItemData]
    public var timelines: [TimelineModelData]
    public var activeTimelineIndex: Int
    public var selections: [LegacySelectionModelData]?
    public var activeSelectionIndex: Int?
    public var isProxyPlaybackEnabled: Bool
    public var proxyOutputFolderPath: String?
    public var lutEnabled: Bool?
    public var lutPreset: String?
    public var lutCustomPath: String?

    public init(
        project: EditorProject,
        mediaItems: [MediaItem]
    ) {
        self.id = project.projectId
        self.name = project.projectName
        self.createdAt = project.createdAt
        self.updatedAt = Date()
        self.folders = project.folders
        self.activeFolderId = project.activeFolderId
        self.mediaItems = mediaItems.map { MediaItemData(item: $0) }
        self.timelines = project.timelines.map { TimelineModelData(model: $0) }
        self.activeTimelineIndex = project.activeTimelineIndex
        self.selections = nil
        self.activeSelectionIndex = nil
        self.isProxyPlaybackEnabled = project.isProxyPlaybackEnabled
        self.proxyOutputFolderPath = project.proxyOutputFolderURL?.path
        self.lutEnabled = LUTEngine.shared.isEnabled
        self.lutPreset = LUTEngine.shared.currentPreset.rawValue
        self.lutCustomPath = LUTEngine.shared.activeCustomLUTPath
    }
}

// MARK: - Project Record for Listing in Project Manager
public struct ProjectRecord: Identifiable {
    public let id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var fps: Double
    public var width: Int
    public var height: Int
    public var timelinesCount: Int
    public var mediaCount: Int
    public var selectionsCount: Int

    public var formattedResolution: String {
        return "\(width) × \(height) (\(Int(fps.rounded())) fps)"
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: updatedAt)
    }
}

// MARK: - SQLite Project Database Engine
public final class ProjectDatabase: @unchecked Sendable {
    public static let shared = ProjectDatabase()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.vision.projectdb", qos: .userInitiated)
    private var pendingSaveWorkItem: DispatchWorkItem?

    private init() {
        openDatabase()
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    private func getDatabaseURL() -> URL {
        if let customPath = ProcessInfo.processInfo.environment["VISION_DB_PATH"], !customPath.isEmpty {
            let url = URL(fileURLWithPath: customPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            return url
        }
        let procName = ProcessInfo.processInfo.processName
        if procName.contains("verify_") || procName.contains("xctest") || procName.hasPrefix("probe_") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("vision_test_projects.db")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let visionDir = appSupport.appendingPathComponent("Vision", isDirectory: true)
        try? FileManager.default.createDirectory(at: visionDir, withIntermediateDirectories: true)
        return visionDir.appendingPathComponent("projects.db")
    }

    private func openDatabase() {
        let dbURL = getDatabaseURL()
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            DebugLogger.shared.log("Errore apertura database SQLite: \(String(cString: sqlite3_errmsg(db)))", level: .error)
            return
        }

        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            fps REAL NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            timelines_count INTEGER NOT NULL,
            media_count INTEGER NOT NULL,
            selections_count INTEGER NOT NULL,
            project_json TEXT NOT NULL
        );
        """

        if sqlite3_exec(db, createTableSQL, nil, nil, nil) != SQLITE_OK {
            DebugLogger.shared.log("Errore creazione tabella projects SQLite: \(String(cString: sqlite3_errmsg(db)))", level: .error)
        }
    }

    // MARK: - Public Queries
    public func getAllProjects() -> [ProjectRecord] {
        var records: [ProjectRecord] = []
        dbQueue.sync {
            guard db != nil else { return }
            let query = "SELECT id, name, created_at, updated_at, fps, width, height, timelines_count, media_count, selections_count FROM projects ORDER BY updated_at DESC;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let idStr = String(cString: sqlite3_column_text(stmt, 0))
                    let name = String(cString: sqlite3_column_text(stmt, 1))
                    let createdTs = sqlite3_column_double(stmt, 2)
                    let updatedTs = sqlite3_column_double(stmt, 3)
                    let fps = sqlite3_column_double(stmt, 4)
                    let width = Int(sqlite3_column_int(stmt, 5))
                    let height = Int(sqlite3_column_int(stmt, 6))
                    let tCount = Int(sqlite3_column_int(stmt, 7))
                    let mCount = Int(sqlite3_column_int(stmt, 8))
                    let sCount = Int(sqlite3_column_int(stmt, 9))

                    if let uuid = UUID(uuidString: idStr) {
                        records.append(ProjectRecord(
                            id: uuid,
                            name: name,
                            createdAt: Date(timeIntervalSince1970: createdTs),
                            updatedAt: Date(timeIntervalSince1970: updatedTs),
                            fps: fps,
                            width: width,
                            height: height,
                            timelinesCount: tCount,
                            mediaCount: mCount,
                            selectionsCount: sCount
                        ))
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return records
    }

    public func saveProjectImmediately(project: EditorProject, mediaItems: [MediaItem]) {
        let doc = ProjectDocumentData(project: project, mediaItems: mediaItems)
        saveDocumentImmediately(doc)
    }

    public func saveDocumentImmediately(_ doc: ProjectDocumentData) {
        dbQueue.sync { [weak self] in
            self?.upsertDocumentLocked(doc)
        }
    }

    public func scheduleRealtimeAutosave(project: EditorProject, mediaItems: [MediaItem]) {
        pendingSaveWorkItem?.cancel()
        let doc = ProjectDocumentData(project: project, mediaItems: mediaItems)
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveDocumentAsync(doc)
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func saveDocumentAsync(_ doc: ProjectDocumentData) {
        dbQueue.async { [weak self] in
            self?.upsertDocumentLocked(doc)
        }
    }

    private func upsertDocumentLocked(_ doc: ProjectDocumentData) {
        guard let db = self.db else { return }
        guard let jsonData = try? JSONEncoder().encode(doc),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let pId = doc.id.uuidString
        let name = doc.name
        let createdTs = doc.createdAt.timeIntervalSince1970
        let updatedTs = doc.updatedAt.timeIntervalSince1970
        let primaryTimeline = doc.timelines.indices.contains(doc.activeTimelineIndex) ? doc.timelines[doc.activeTimelineIndex] : doc.timelines.first
        let fps = primaryTimeline?.fps ?? 30.0
        let width = Int(primaryTimeline?.width ?? 1920)
        let height = Int(primaryTimeline?.height ?? 1080)
        let tCount = doc.timelines.filter { !($0.isSelection ?? false) }.count
        let mCount = doc.mediaItems.count
        let sCount = doc.timelines.filter { $0.isSelection ?? false }.count

        let upsertSQL = """
        INSERT INTO projects (id, name, created_at, updated_at, fps, width, height, timelines_count, media_count, selections_count, project_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            updated_at = excluded.updated_at,
            fps = excluded.fps,
            width = excluded.width,
            height = excluded.height,
            timelines_count = excluded.timelines_count,
            media_count = excluded.media_count,
            selections_count = excluded.selections_count,
            project_json = excluded.project_json;
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, upsertSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (pId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, createdTs)
            sqlite3_bind_double(stmt, 4, updatedTs)
            sqlite3_bind_double(stmt, 5, fps)
            sqlite3_bind_int(stmt, 6, Int32(width))
            sqlite3_bind_int(stmt, 7, Int32(height))
            sqlite3_bind_int(stmt, 8, Int32(tCount))
            sqlite3_bind_int(stmt, 9, Int32(mCount))
            sqlite3_bind_int(stmt, 10, Int32(sCount))
            sqlite3_bind_text(stmt, 11, (jsonString as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) != SQLITE_DONE {
                DebugLogger.shared.log("Errore salvataggio progetto SQLite: \(String(cString: sqlite3_errmsg(db)))", level: .error)
            }
        }
        sqlite3_finalize(stmt)

        DispatchQueue.main.async {
            EditorProject.shared.lastSavedAt = Date()
            NotificationCenter.default.post(name: NSNotification.Name("ProjectSavedRealtime"), object: nil)
        }
    }

    public func loadProjectDocument(id: UUID) -> ProjectDocumentData? {
        var result: ProjectDocumentData? = nil
        dbQueue.sync {
            guard db != nil else { return }
            let query = "SELECT project_json FROM projects WHERE id = ? LIMIT 1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    if let jsonCStr = sqlite3_column_text(stmt, 0) {
                        let jsonStr = String(cString: jsonCStr)
                        if let data = jsonStr.data(using: .utf8) {
                            result = try? JSONDecoder().decode(ProjectDocumentData.self, from: data)
                        }
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return result
    }

    public func deleteProject(id: UUID) {
        dbQueue.sync {
            guard db != nil else { return }
            let sql = "DELETE FROM projects WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id.uuidString as NSString).utf8String, -1, nil)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func duplicateProject(id: UUID) -> ProjectRecord? {
        guard let doc = loadProjectDocument(id: id) else { return nil }
        var newDoc = doc
        newDoc.id = UUID()
        newDoc.name = "\(doc.name) (Copia)"
        newDoc.createdAt = Date()
        newDoc.updatedAt = Date()

        guard let jsonData = try? JSONEncoder().encode(newDoc),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        let pId = newDoc.id.uuidString
        let name = newDoc.name
        let createdTs = newDoc.createdAt.timeIntervalSince1970
        let updatedTs = newDoc.updatedAt.timeIntervalSince1970
        let fps = newDoc.timelines.first?.fps ?? 25.0
        let width = Int(newDoc.timelines.first?.width ?? 1920)
        let height = Int(newDoc.timelines.first?.height ?? 1080)
        let tCount = newDoc.timelines.filter { !($0.isSelection ?? false) }.count
        let mCount = newDoc.mediaItems.count
        let sCount = newDoc.timelines.filter { $0.isSelection ?? false }.count

        dbQueue.sync {
            guard db != nil else { return }
            let sql = "INSERT INTO projects VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (pId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 3, createdTs)
                sqlite3_bind_double(stmt, 4, updatedTs)
                sqlite3_bind_double(stmt, 5, fps)
                sqlite3_bind_int(stmt, 6, Int32(width))
                sqlite3_bind_int(stmt, 7, Int32(height))
                sqlite3_bind_int(stmt, 8, Int32(tCount))
                sqlite3_bind_int(stmt, 9, Int32(mCount))
                sqlite3_bind_int(stmt, 10, Int32(sCount))
                sqlite3_bind_text(stmt, 11, (jsonString as NSString).utf8String, -1, nil)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        return ProjectRecord(
            id: newDoc.id,
            name: name,
            createdAt: newDoc.createdAt,
            updatedAt: newDoc.updatedAt,
            fps: fps,
            width: width,
            height: height,
            timelinesCount: tCount,
            mediaCount: mCount,
            selectionsCount: sCount
        )
    }

    public func renameProject(id: UUID, newName: String) {
        dbQueue.sync {
            guard db != nil else { return }
            let sql = "UPDATE projects SET name = ?, updated_at = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (newName as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, (id.uuidString as NSString).utf8String, -1, nil)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
}
