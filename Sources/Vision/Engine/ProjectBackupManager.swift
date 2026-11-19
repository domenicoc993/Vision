import Foundation
import CryptoKit

/// Metadata record for a single compressed project backup snapshot stored on disk.
public struct ProjectBackupRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let projectId: UUID
    public var projectName: String
    public let createdAt: Date
    public let reason: String
    public let contentHash: String
    public let timelinesCount: Int
    public let selectionsCount: Int
    public let mediaCount: Int
    public let clipCount: Int
    public let compressedBytes: Int
    public let fileName: String

    private static let absFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    public var formattedDate: String {
        Self.absFormatter.string(from: createdAt)
    }

    public var shortCopyTag: String {
        Self.shortTimeFormatter.string(from: createdAt)
    }

    public func formattedRelative(to now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(createdAt))
        if age < 60 { return "adesso" }
        let mins = Int(age / 60)
        if mins < 60 { return "\(mins) min fa" }
        let hours = Int(age / 3600)
        if hours < 24 { return "\(hours) ore fa" }
        let days = Int(age / 86400)
        let remHours = (Int(age) % 86400) / 3600
        return remHours > 0 ? "\(days)g \(remHours)h fa" : "\(days)g fa"
    }

    public var formattedSummary: String {
        let selStr = selectionsCount > 0 ? " • \(selectionsCount) sel." : ""
        return "\(timelinesCount) timeline\(selStr) • \(mediaCount) media • \(clipCount) clip"
    }

    public var formattedSize: String {
        if compressedBytes < 1024 {
            return "\(compressedBytes) B"
        } else if compressedBytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(compressedBytes) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(compressedBytes) / (1024.0 * 1024.0))
        }
    }
}

/// Manages incremental LZFSE-compressed project snapshots stored separately from `projects.db`
/// with a strict 3-day (72h) max retention window and progressive GFS thinning.
public final class ProjectBackupManager: @unchecked Sendable {
    public static let shared = ProjectBackupManager()

    /// Maximum backup history span: 3 days (72 hours).
    public static let maxSpanSeconds: TimeInterval = 3.0 * 24.0 * 60.0 * 60.0

    /// Default periodic backup check interval while Vision is open: 5 minutes.
    public static let periodicIntervalSeconds: TimeInterval = 5.0 * 60.0

    /// Keep all snapshots within the last 2 hours, 1/hour between 2h..24h, and 1/4h between 24h..72h.
    private static let denseWindowSeconds: TimeInterval = 2.0 * 60.0 * 60.0
    private static let hourlyWindowSeconds: TimeInterval = 24.0 * 60.0 * 60.0

    private let backupQueue = DispatchQueue(label: "com.vision.projectbackups", qos: .utility)
    private var periodicTimer: Timer?
    private var snapshotProvider: (() -> ProjectDocumentData?)?

    private static let fileTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return f
    }()

    private init() {}

    // MARK: - Storage Paths

    public func backupsRootURL() -> URL {
        if let customPath = ProcessInfo.processInfo.environment["VISION_BACKUP_DIR"], !customPath.isEmpty {
            let url = URL(fileURLWithPath: customPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let procName = ProcessInfo.processInfo.processName
        if procName.contains("verify_") || procName.contains("xctest") || procName.hasPrefix("probe_") {
            let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("vision_test_backups", isDirectory: true)
            try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
            return testDir
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("Vision", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func projectBackupDir(for projectId: UUID) -> URL {
        let dir = backupsRootURL().appendingPathComponent(projectId.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func manifestURL(for projectId: UUID) -> URL {
        projectBackupDir(for: projectId).appendingPathComponent("manifest.json")
    }

    // MARK: - Periodic Background Scheduler

    /// Starts checking for dirty changes every `interval` seconds while Vision is open.
    public func startPeriodicBackups(
        interval: TimeInterval = periodicIntervalSeconds,
        snapshotProvider: @escaping () -> ProjectDocumentData?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.periodicTimer?.invalidate()
            self.snapshotProvider = snapshotProvider
            let timer = Timer(timeInterval: max(5.0, interval), repeats: true) { [weak self] _ in
                guard let self = self else { return }
                guard let doc = self.snapshotProvider?() else {
                    self.stopPeriodicBackups()
                    return
                }
                self.createBackupIfNeeded(document: doc, reason: "Automatico", force: false, synchronous: false)
            }
            RunLoop.main.add(timer, forMode: .common)
            self.periodicTimer = timer
        }
    }

    public func stopPeriodicBackups() {
        let stopBlock = { [weak self] in
            self?.periodicTimer?.invalidate()
            self?.periodicTimer = nil
            self?.snapshotProvider = nil
        }
        if Thread.isMainThread {
            stopBlock()
        } else {
            DispatchQueue.main.async(execute: stopBlock)
        }
    }

    // MARK: - Create / List / Prune

    /// Creates a compressed incremental backup if the project's normalized content changed (or if `force == true`).
    @discardableResult
    public func createBackupIfNeeded(
        document doc: ProjectDocumentData,
        reason: String = "Automatico",
        force: Bool = false,
        now: Date = Date(),
        synchronous: Bool = false
    ) -> ProjectBackupRecord? {
        if synchronous {
            return backupQueue.sync {
                performBackupWrite(document: doc, reason: reason, force: force, now: now)
            }
        } else {
            backupQueue.async { [weak self] in
                _ = self?.performBackupWrite(document: doc, reason: reason, force: force, now: now)
            }
            return nil
        }
    }

    /// Returns all retained backups for `projectId` (newest first), pruning anything older than 3 days.
    public func listBackups(for projectId: UUID, now: Date = Date()) -> [ProjectBackupRecord] {
        backupQueue.sync {
            let records = loadAndPruneManifestLocked(for: projectId, now: now)
            return records.sorted { $0.createdAt > $1.createdAt }
        }
    }

    public func backupCount(for projectId: UUID, now: Date = Date()) -> Int {
        listBackups(for: projectId, now: now).count
    }

    public func loadBackupDocument(record: ProjectBackupRecord) -> ProjectDocumentData? {
        backupQueue.sync {
            let fileURL = projectBackupDir(for: record.projectId).appendingPathComponent(record.fileName)
            guard let compressed = try? Data(contentsOf: fileURL) else { return nil }
            guard let rawData = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
            return try? JSONDecoder().decode(ProjectDocumentData.self, from: rawData)
        }
    }

    /// Restores a snapshot as a brand-new project in `ProjectDatabase` without overwriting the original project.
    public func restoreBackupAsNewProject(record: ProjectBackupRecord) -> (document: ProjectDocumentData, record: ProjectRecord)? {
        guard var doc = loadBackupDocument(record: record) else { return nil }
        doc.id = UUID()
        doc.name = "\(doc.name) (Backup \(record.shortCopyTag))"
        doc.createdAt = Date()
        doc.updatedAt = Date()

        ProjectDatabase.shared.saveDocumentImmediately(doc)
        let projRecord = makeProjectRecord(from: doc)
        DebugLogger.shared.log("Backup ripristinato come nuovo progetto: '\(doc.name)'.", level: .info)
        return (doc, projRecord)
    }

    /// Saves a forced safety snapshot of `currentLiveDoc` (or current DB state) and overwrites the project with `record`.
    public func restoreBackupOverwritingProject(
        record: ProjectBackupRecord,
        currentLiveDoc: ProjectDocumentData? = nil
    ) -> ProjectDocumentData? {
        guard var restoredDoc = loadBackupDocument(record: record) else { return nil }

        // Always snapshot the state we are leaving so a restore itself is reversible
        if let liveDoc = currentLiveDoc ?? ProjectDatabase.shared.loadProjectDocument(id: record.projectId) {
            _ = createBackupIfNeeded(
                document: liveDoc,
                reason: "Pre-ripristino",
                force: true,
                now: Date(),
                synchronous: true
            )
        }

        restoredDoc.id = record.projectId
        restoredDoc.updatedAt = Date()
        ProjectDatabase.shared.saveDocumentImmediately(restoredDoc)
        DebugLogger.shared.log("Progetto '\(restoredDoc.name)' ripristinato al backup del \(record.formattedDate).", level: .info)
        return restoredDoc
    }

    /// Runs retention pruning on an existing project's backup folder using `now` as reference clock.
    @discardableResult
    public func pruneBackups(for projectId: UUID, now: Date = Date()) -> [ProjectBackupRecord] {
        backupQueue.sync {
            loadAndPruneManifestLocked(for: projectId, now: now)
        }
    }

    // MARK: - Internal Storage Helpers (backupQueue only)

    private func performBackupWrite(
        document doc: ProjectDocumentData,
        reason: String,
        force: Bool,
        now: Date
    ) -> ProjectBackupRecord? {
        var records = loadManifestLocked(for: doc.id)

        guard let payloadData = try? JSONEncoder().encode(doc) else { return nil }
        let hash = computeNormalizedHash(for: doc) ?? sha256Hex(payloadData)

        if !force, let newest = records.max(by: { $0.createdAt < $1.createdAt }), newest.contentHash == hash {
            let pruned = applyRetentionPolicyLocked(records: records, projectId: doc.id, now: now)
            if pruned.count != records.count {
                saveManifestLocked(pruned, for: doc.id)
            }
            return nil
        }

        guard let compressedData = try? (payloadData as NSData).compressed(using: .lzfse) as Data else {
            return nil
        }

        let stamp = Self.fileTimestampFormatter.string(from: now)
        let shortHash = String(hash.prefix(8))
        let fileName = "backup_\(stamp)_\(shortHash).vbak"
        let fileURL = projectBackupDir(for: doc.id).appendingPathComponent(fileName)

        do {
            try compressedData.write(to: fileURL, options: .atomic)
        } catch {
            DebugLogger.shared.log("Errore scrittura backup '\(fileName)': \(error.localizedDescription)", level: .warning)
            return nil
        }

        let timelinesCount = doc.timelines.filter { !($0.isSelection ?? false) }.count
        let selectionsCount = doc.timelines.filter { $0.isSelection ?? false }.count
        let clipCount = doc.timelines.reduce(0) { sum, tl in
            sum + tl.videoTracks.reduce(0) { $0 + $1.clips.count } + tl.audioTracks.reduce(0) { $0 + $1.clips.count }
        }

        let newRecord = ProjectBackupRecord(
            id: UUID(),
            projectId: doc.id,
            projectName: doc.name,
            createdAt: now,
            reason: reason,
            contentHash: hash,
            timelinesCount: timelinesCount,
            selectionsCount: selectionsCount,
            mediaCount: doc.mediaItems.count,
            clipCount: clipCount,
            compressedBytes: compressedData.count,
            fileName: fileName
        )

        records.append(newRecord)
        let finalRecords = applyRetentionPolicyLocked(records: records, projectId: doc.id, now: now)
        saveManifestLocked(finalRecords, for: doc.id)
        return newRecord
    }

    private func loadAndPruneManifestLocked(for projectId: UUID, now: Date) -> [ProjectBackupRecord] {
        let loaded = loadManifestLocked(for: projectId)
        let pruned = applyRetentionPolicyLocked(records: loaded, projectId: projectId, now: now)
        if pruned != loaded {
            saveManifestLocked(pruned, for: projectId)
        }
        return pruned
    }

    private func loadManifestLocked(for projectId: UUID) -> [ProjectBackupRecord] {
        let dir = projectBackupDir(for: projectId)
        let mURL = manifestURL(for: projectId)
        if let data = try? Data(contentsOf: mURL),
           let decoded = try? JSONDecoder().decode([ProjectBackupRecord].self, from: data) {
            return decoded.filter {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path)
            }
        }
        return []
    }

    private func saveManifestLocked(_ records: [ProjectBackupRecord], for projectId: UUID) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: manifestURL(for: projectId), options: .atomic)
    }

    /// Enforces a hard 3-day (72h) max span and progressive GFS thinning within the 3-day window.
    private func applyRetentionPolicyLocked(
        records: [ProjectBackupRecord],
        projectId: UUID,
        now: Date
    ) -> [ProjectBackupRecord] {
        let sorted = records.sorted { $0.createdAt > $1.createdAt }
        var kept: [ProjectBackupRecord] = []
        var hourlyBuckets: Set<Int> = []
        var fourHourBuckets: Set<Int> = []
        var removedFileNames: [String] = []

        for rec in sorted {
            let age = now.timeIntervalSince(rec.createdAt)
            if age > Self.maxSpanSeconds {
                removedFileNames.append(rec.fileName)
                continue
            }

            if age <= Self.denseWindowSeconds {
                kept.append(rec)
            } else if age <= Self.hourlyWindowSeconds {
                // Keep safety checkpoints taken immediately before restores, plus newest per 1-hour bucket
                let bucket = Int(floor(rec.createdAt.timeIntervalSince1970 / 3600.0))
                if rec.reason == "Pre-ripristino" || hourlyBuckets.insert(bucket).inserted {
                    kept.append(rec)
                } else {
                    removedFileNames.append(rec.fileName)
                }
            } else {
                // Between 24h and 72h: keep newest per 4-hour bucket
                let bucket = Int(floor(rec.createdAt.timeIntervalSince1970 / 14400.0))
                if fourHourBuckets.insert(bucket).inserted {
                    kept.append(rec)
                } else {
                    removedFileNames.append(rec.fileName)
                }
            }
        }

        let dir = projectBackupDir(for: projectId)
        for name in removedFileNames {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }

        return kept
    }

    private func computeNormalizedHash(for doc: ProjectDocumentData) -> String? {
        var normalized = doc
        normalized.updatedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(normalized) else { return nil }
        return sha256Hex(data)
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeProjectRecord(from doc: ProjectDocumentData) -> ProjectRecord {
        let primaryTimeline = doc.timelines.indices.contains(doc.activeTimelineIndex) ? doc.timelines[doc.activeTimelineIndex] : doc.timelines.first
        return ProjectRecord(
            id: doc.id,
            name: doc.name,
            createdAt: doc.createdAt,
            updatedAt: doc.updatedAt,
            fps: primaryTimeline?.fps ?? 25.0,
            width: Int(primaryTimeline?.width ?? 1920),
            height: Int(primaryTimeline?.height ?? 1080),
            timelinesCount: doc.timelines.filter { !($0.isSelection ?? false) }.count,
            mediaCount: doc.mediaItems.count,
            selectionsCount: doc.timelines.filter { $0.isSelection ?? false }.count
        )
    }
}
