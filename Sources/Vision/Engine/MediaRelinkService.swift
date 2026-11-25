import Foundation
import AVFoundation
import CoreMedia

public struct RelinkCandidateFile {
    public let url: URL
    public let fileName: String
    public let fileSizeBytes: Int64
}

public enum MediaRelinkService {
    /// Scansiona ricorsivamente una cartella Finder raccogliendo tutti i file regolari indicizzati per nome (case-insensitive).
    public static func indexDirectory(at rootURL: URL) -> [String: [RelinkCandidateFile]] {
        var index: [String: [RelinkCandidateFile]] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return index
        }

        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: keys),
                  vals.isRegularFile == true,
                  let byteSize = vals.fileSize else {
                continue
            }
            let fileName = fileURL.lastPathComponent
            let key = fileName.lowercased()
            index[key, default: []].append(RelinkCandidateFile(
                url: fileURL,
                fileName: fileName,
                fileSizeBytes: Int64(byteSize)
            ))
        }
        return index
    }

    /// Cerca nell'indice la corrispondenza esatta per nome file + dimensione in byte.
    /// Fallback per clip legacy offline ancora prive di `fileSizeBytes`: corrispondenza per nome file.
    public static func findMatch(for item: MediaItem, in index: [String: [RelinkCandidateFile]]) -> RelinkCandidateFile? {
        let targetName = item.matchFileName
        guard !targetName.isEmpty,
              let candidates = index[targetName.lowercased()],
              !candidates.isEmpty else {
            return nil
        }

        if let expectedBytes = item.fileSizeBytes {
            let exactBytesMatches = candidates.filter { $0.fileSizeBytes == expectedBytes }
            guard !exactBytesMatches.isEmpty else { return nil }
            if let exactName = exactBytesMatches.first(where: { $0.fileName == targetName }) {
                return exactName
            }
            return exactBytesMatches.min(by: { $0.url.path.count < $1.url.path.count })
        }

        // Legacy fallback solo quando il progetto precedente non aveva mai salvato i byte (es. clip già offline prima dell'aggiornamento)
        if let exactName = candidates.first(where: { $0.fileName == targetName }) {
            return exactName
        }
        return candidates.min(by: { $0.url.path.count < $1.url.path.count })
    }

    public static func doesFileMatchStrict(_ fileURL: URL, item: MediaItem) -> (matches: Bool, actualBytes: Int64?) {
        let actualBytes = MediaItem.measureFileSizeBytes(at: fileURL)
        let targetName = item.matchFileName
        let nameMatches = !targetName.isEmpty &&
            fileURL.lastPathComponent.compare(targetName, options: [.caseInsensitive]) == .orderedSame
        guard nameMatches else { return (false, actualBytes) }
        if let expected = item.fileSizeBytes {
            return (actualBytes == expected, actualBytes)
        }
        return (actualBytes != nil, actualBytes)
    }

    /// Costruisce il `MediaItem` ricollegato preservando `id`, nome personalizzato nel Pool (se rinominato), orientamento e beat analysis.
    /// Se `reloadMediaProperties == true` (cambio sorgente manuale verso altro file), ricarica durata/risoluzione/fps/codec dal nuovo file.
    public static func buildRelinkedItem(
        from oldItem: MediaItem,
        to newURL: URL,
        actualBytes: Int64?,
        reloadMediaProperties: Bool
    ) async -> MediaItem {
        let resolvedBytes = actualBytes ?? MediaItem.measureFileSizeBytes(at: newURL)
        let newDiskName = newURL.lastPathComponent
        let hadCustomPoolName = !oldItem.name.isEmpty && oldItem.name != oldItem.matchFileName
        let nextDisplayName = (reloadMediaProperties && !hadCustomPoolName) ? newDiskName : oldItem.name

        ThumbnailCache.shared.invalidate(url: oldItem.url)
        ThumbnailCache.shared.invalidate(url: newURL)
        AudioWaveformCache.shared.invalidate(url: oldItem.url)
        AudioWaveformCache.shared.invalidate(url: newURL)

        if !reloadMediaProperties {
            var updated = oldItem
            updated.url = newURL
            updated.originalFileName = newDiskName
            if let b = resolvedBytes {
                updated.fileSizeBytes = b
            }
            updated.thumbnail = nil
            return updated
        }

        await CompositionEngine.shared.preloadMetadata(for: newURL)
        if let loaded = try? await MediaItem.load(from: newURL) {
            let durationChanged = abs(CMTimeGetSeconds(loaded.duration) - CMTimeGetSeconds(oldItem.duration)) > 0.25
            return MediaItem(
                id: oldItem.id,
                url: newURL,
                name: nextDisplayName,
                originalFileName: newDiskName,
                fileSizeBytes: resolvedBytes ?? loaded.fileSizeBytes,
                duration: loaded.duration,
                resolution: loaded.resolution,
                frameRate: loaded.frameRate,
                hasVideo: loaded.hasVideo,
                hasAudio: loaded.hasAudio,
                videoCodec: loaded.videoCodec,
                audioTrackCount: loaded.audioTrackCount,
                orientation: oldItem.orientation,
                thumbnail: loaded.thumbnail,
                proxyURL: nil,
                beatAnalysis: durationChanged ? nil : oldItem.beatAnalysis
            )
        }

        var fallback = oldItem
        fallback.url = newURL
        fallback.name = nextDisplayName
        fallback.originalFileName = newDiskName
        fallback.fileSizeBytes = resolvedBytes
        fallback.proxyURL = nil
        fallback.thumbnail = nil
        return fallback
    }
}
