import Foundation
import AVFoundation
import CryptoKit

/// Metadati persistenti su disco per evitare di rileggere tag/durate di centinaia di brani ad ogni avvio.
private struct CachedTrackMetadata: Codable {
    var fileSize: Int
    var modTimestamp: Double
    var durationSeconds: Double?
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
}

/// Brano audio scoperto ricorsivamente nelle cartelle fonte della Libreria Musicale (non ancora importato nel progetto finché non viene usato).
public struct MusicLibraryTrack: Identifiable, Hashable {
    public var id: String { url.standardizedFileURL.path }
    public let stableUUID: UUID
    public let url: URL
    public let name: String
    public let sourceFolderName: String
    public let relativeSubfolder: String
    public var durationSeconds: Double?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var year: String?
    public var metadataLoaded: Bool

    public init(
        url: URL,
        name: String,
        sourceFolderName: String,
        relativeSubfolder: String,
        durationSeconds: Double?,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        year: String? = nil,
        metadataLoaded: Bool = false
    ) {
        self.url = url
        self.name = name
        self.sourceFolderName = sourceFolderName
        self.relativeSubfolder = relativeSubfolder
        self.durationSeconds = durationSeconds
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.metadataLoaded = metadataLoaded
        let digest = Array(SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)))
        self.stableUUID = UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// Titolo dai metadati se presente, altrimenti nome file.
    public var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return name
    }

    public var formattedDuration: String {
        guard let d = durationSeconds, d.isFinite, d > 0 else { return "--:--" }
        let total = Int(d.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Ricerca intelligente su titolo, nome file, artista, album, genere, anno e cartella.
    public func matchesSearchTokens(_ foldedTokens: [String]) -> Bool {
        guard !foldedTokens.isEmpty else { return true }
        let haystack = [
            displayTitle,
            name,
            artist ?? "",
            album ?? "",
            genre ?? "",
            year ?? "",
            sourceFolderName,
            relativeSubfolder
        ].joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return foldedTokens.allSatisfy { haystack.contains($0) }
    }
}

/// Gestore globale della Smart Folder "Libreria musicale": scansiona cartelle fonte + sottocartelle per file audio e metadati.
public final class MusicLibraryManager: @unchecked Sendable {
    public static let shared = MusicLibraryManager()
    public static let didUpdateNotification = Notification.Name("Vision.MusicLibraryManager.DidUpdate")

    private static let sourcesDefaultsKey = "com.vision.musicLibrarySources.v1"

    private var _sourceFolderPaths: [String] = []
    private var _tracks: [MusicLibraryTrack] = []
    private var _isScanning: Bool = false
    private var scanGeneration: UInt64 = 0

    /// Thread-safe snapshots protected by `lock` (prevents CoW array data races with background scans).
    public var sourceFolderPaths: [String] {
        lock.withLock { _sourceFolderPaths }
    }

    public var tracks: [MusicLibraryTrack] {
        lock.withLock { _tracks }
    }

    public var isScanning: Bool {
        lock.withLock { _isScanning }
    }

    private let scanQueue = DispatchQueue(label: "com.vision.musicLibraryScan", qos: .utility)
    private var metadataCache: [String: CachedTrackMetadata] = [:]
    private let metadataCacheURL: URL
    private let lock = NSLock()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("Vision", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.metadataCacheURL = dir.appendingPathComponent("music_metadata_v1.json")

        if let data = try? Data(contentsOf: metadataCacheURL),
           let decoded = try? JSONDecoder().decode([String: CachedTrackMetadata].self, from: data) {
            self.metadataCache = decoded
        }

        if let saved = UserDefaults.standard.stringArray(forKey: Self.sourcesDefaultsKey) {
            self._sourceFolderPaths = saved
        }
        if !sourceFolderPaths.isEmpty {
            rescan()
        }
    }

    public func addSourceFolder(_ url: URL) {
        let stdPath = url.standardizedFileURL.path
        var added = false
        lock.withLock {
            if !_sourceFolderPaths.contains(stdPath) {
                _sourceFolderPaths.append(stdPath)
                UserDefaults.standard.set(_sourceFolderPaths, forKey: Self.sourcesDefaultsKey)
                added = true
            }
        }
        if added {
            rescan()
        }
    }

    public func removeSourceFolder(path: String) {
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.withLock {
            _sourceFolderPaths.removeAll { $0 == stdPath || $0 == path }
            UserDefaults.standard.set(_sourceFolderPaths, forKey: Self.sourcesDefaultsKey)
        }
        rescan()
    }

    public func clearAllSourcesForTesting() {
        lock.withLock {
            scanGeneration &+= 1
            _sourceFolderPaths.removeAll()
            _tracks.removeAll()
            _isScanning = false
            UserDefaults.standard.removeObject(forKey: Self.sourcesDefaultsKey)
        }
        notifyUpdated()
    }

    public func rescan() {
        let (pathsSnapshot, cacheSnapshot, gen) = lock.withLock { () -> ([String], [String: CachedTrackMetadata], UInt64) in
            scanGeneration &+= 1
            _isScanning = true
            return (_sourceFolderPaths, metadataCache, scanGeneration)
        }
        notifyUpdated()

        scanQueue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            var discovered: [MusicLibraryTrack] = []
            var seenPaths: Set<String> = []
            var fileFingerprints: [String: (size: Int, mtime: Double)] = [:]

            for rawPath in pathsSnapshot {
                if !self.isCurrentGeneration(gen) { return }
                let rootURL = URL(fileURLWithPath: rawPath, isDirectory: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let rootName = rootURL.lastPathComponent
                let rootPrefix = rootURL.standardizedFileURL.path

                if let enumerator = fm.enumerator(
                    at: rootURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    while let itemURL = enumerator.nextObject() as? URL {
                        if !self.isCurrentGeneration(gen) { return }
                        let vals = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                        guard vals?.isRegularFile == true else { continue }
                        guard MediaPoolViewController.isAudioOnlyURL(itemURL) else { continue }
                        let std = itemURL.standardizedFileURL.path
                        guard seenPaths.insert(std).inserted else { continue }

                        let parentDir = itemURL.deletingLastPathComponent().standardizedFileURL.path
                        let relSub: String
                        if parentDir.count > rootPrefix.count && parentDir.hasPrefix(rootPrefix) {
                            relSub = String(parentDir.dropFirst(rootPrefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        } else {
                            relSub = ""
                        }

                        let fSize = vals?.fileSize ?? 0
                        let fMtime = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
                        fileFingerprints[std] = (fSize, fMtime)

                        let cached = cacheSnapshot[std]
                        let isCacheFresh = cached != nil
                            && cached!.fileSize == fSize
                            && abs(cached!.modTimestamp - fMtime) < 1.0

                        discovered.append(MusicLibraryTrack(
                            url: itemURL,
                            name: itemURL.lastPathComponent,
                            sourceFolderName: rootName,
                            relativeSubfolder: relSub,
                            durationSeconds: isCacheFresh ? cached?.durationSeconds : nil,
                            title: isCacheFresh ? cached?.title : nil,
                            artist: isCacheFresh ? cached?.artist : nil,
                            album: isCacheFresh ? cached?.album : nil,
                            genre: isCacheFresh ? cached?.genre : nil,
                            year: isCacheFresh ? cached?.year : nil,
                            metadataLoaded: isCacheFresh
                        ))
                    }
                }
            }

            discovered.sort {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }

            let committed = self.lock.withLock { () -> Bool in
                guard self.scanGeneration == gen else { return false }
                self._tracks = discovered
                self._isScanning = false
                return true
            }
            guard committed else { return }
            self.notifyUpdated()

            // Probe missing/outdated metadata & durations lazily in background
            let needsProbe = discovered.filter { !$0.metadataLoaded }
            if !needsProbe.isEmpty {
                Task.detached(priority: .utility) { [weak self] in
                    guard let self = self else { return }
                    var updatedAny = false
                    for (i, tr) in needsProbe.enumerated() {
                        if !self.isTrackStillPresent(id: tr.id, generation: gen) { break }

                        let parsed = await Self.probeMetadata(for: tr.url)
                        let fp = fileFingerprints[tr.id] ?? (0, 0)
                        let metaRecord = CachedTrackMetadata(
                            fileSize: fp.size,
                            modTimestamp: fp.mtime,
                            durationSeconds: parsed.duration,
                            title: parsed.title,
                            artist: parsed.artist,
                            album: parsed.album,
                            genre: parsed.genre,
                            year: parsed.year
                        )
                        self.updateCachedTrackMetadata(id: tr.id, metadata: metaRecord, generation: gen)
                        updatedAny = true

                        if (i + 1) % 15 == 0 && updatedAny {
                            updatedAny = false
                            self.notifyUpdated()
                        }
                    }
                    if updatedAny {
                        self.notifyUpdated()
                    }
                    self.saveMetadataCacheToDisk()
                }
            }
        }
    }

    private struct ParsedAudioMetadata {
        var duration: Double?
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var year: String?
    }

    private static func probeMetadata(for url: URL) async -> ParsedAudioMetadata {
        var parsed = ParsedAudioMetadata()
        let asset = AVURLAsset(url: url)

        if let dur = try? await asset.load(.duration) {
            let sec = CMTimeGetSeconds(dur)
            if sec.isFinite && sec > 0 { parsed.duration = sec }
        }

        if let common = try? await asset.load(.commonMetadata) {
            for item in common {
                guard let key = item.commonKey else { continue }
                guard let raw = (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { continue }
                switch key {
                case .commonKeyTitle:
                    if parsed.title == nil { parsed.title = raw }
                case .commonKeyArtist:
                    if parsed.artist == nil { parsed.artist = raw }
                case .commonKeyAlbumName:
                    if parsed.album == nil { parsed.album = raw }
                case .commonKeyType:
                    if parsed.genre == nil { parsed.genre = raw }
                case .commonKeyCreationDate:
                    if parsed.year == nil { parsed.year = String(raw.prefix(4)) }
                default:
                    break
                }
            }
        }

        if parsed.genre == nil || parsed.year == nil || parsed.artist == nil || parsed.title == nil || parsed.album == nil {
            if let allMeta = try? await asset.load(.metadata) {
                for item in allMeta {
                    let ident = (item.identifier?.rawValue ?? String(describing: item.key)).lowercased()
                    guard let raw = (try? await item.load(.stringValue))?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty else { continue }
                    if parsed.title == nil && (ident.contains("tit2") || ident.contains("%a9nam") || ident.hasSuffix("/title")) {
                        parsed.title = raw
                    } else if parsed.artist == nil && (ident.contains("tpe1") || ident.contains("%a9art") || ident.hasSuffix("/aart") || ident.hasSuffix("/artist")) {
                        parsed.artist = raw
                    } else if parsed.album == nil && (ident.contains("talb") || ident.contains("%a9alb") || ident.hasSuffix("/album")) {
                        parsed.album = raw
                    } else if parsed.genre == nil && (ident.contains("tcon") || ident.contains("%a9gen") || ident.contains("gnre") || ident.hasSuffix("/genre")) {
                        parsed.genre = raw
                    } else if parsed.year == nil && (ident.contains("tdrc") || ident.contains("tyer") || ident.contains("%a9day")) {
                        let digits = raw.prefix(4)
                        if digits.count == 4, Int(digits) != nil {
                            parsed.year = String(digits)
                        }
                    }
                }
            }
        }

        return parsed
    }

    private func isCurrentGeneration(_ gen: UInt64) -> Bool {
        lock.withLock { scanGeneration == gen }
    }

    private func isTrackStillPresent(id: String, generation gen: UInt64) -> Bool {
        lock.withLock {
            scanGeneration == gen && _tracks.contains(where: { $0.id == id })
        }
    }

    private func updateCachedTrackMetadata(id: String, metadata: CachedTrackMetadata, generation gen: UInt64) {
        lock.withLock {
            metadataCache[id] = metadata
            guard scanGeneration == gen else { return }
            if let idx = _tracks.firstIndex(where: { $0.id == id }) {
                if let d = metadata.durationSeconds { _tracks[idx].durationSeconds = d }
                if let t = metadata.title { _tracks[idx].title = t }
                if let a = metadata.artist { _tracks[idx].artist = a }
                if let al = metadata.album { _tracks[idx].album = al }
                if let g = metadata.genre { _tracks[idx].genre = g }
                if let y = metadata.year { _tracks[idx].year = y }
                _tracks[idx].metadataLoaded = true
            }
        }
    }

    private func saveMetadataCacheToDisk() {
        let snapshot = lock.withLock { metadataCache }
        let targetURL = metadataCacheURL
        scanQueue.async {
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: targetURL, options: .atomic)
            }
        }
    }

    private func notifyUpdated() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
        }
    }
}
