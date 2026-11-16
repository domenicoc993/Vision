import Foundation
import CoreMedia
import AVFoundation

public struct FCPXMLImportResult {
    public let importedTimelines: [TimelineModel]
    public let newlyImportedMedia: [MediaItem]
    public let createdFolder: MediaFolder?
    public let folderItemIds: [UUID]
    public let relinkedCount: Int
    public let newMediaCount: Int
    public let missingCount: Int
}

/// Parses Final Cut Pro / DaVinci Resolve `.fcpxml` and `.fcpxmld` bundles,
/// relinking existing project media or loading new assets into a dedicated folder.
public final class FCPXMLImporter: NSObject, XMLParserDelegate {
    private struct FormatInfo {
        let id: String
        let width: CGFloat
        let height: CGFloat
        let fps: Float
    }

    private struct AssetInfo {
        let id: String
        var name: String
        var srcURL: URL?
        let startSec: Double
        let durationSec: Double
        let formatId: String?
        let hasVideo: Bool
        let hasAudio: Bool
    }

    private struct ClipPlacement {
        let assetId: String
        let name: String
        let timelineStartSec: Double
        let sourceInOffsetFromClipSec: Double // raw clip start minus asset start (or clip start)
        let clipRawStartSec: Double
        let durationSec: Double
        let trackIndex: Int
        let isAudioOnly: Bool
        let hasAudio: Bool
        let markerRawTimes: [Double]
        let priority: Int?
    }

    private struct ParsedSequence {
        var name: String
        var formatId: String?
        var tcStartSec: Double
        var placements: [ClipPlacement]
    }

    // Parser state
    private var formats: [String: FormatInfo] = [:]
    private var assets: [String: AssetInfo] = [:]
    private var sequences: [ParsedSequence] = []

    private var currentAssetId: String?
    private var currentEventName: String?
    private var currentProjectName: String?
    private var currentSeq: ParsedSequence?
    private var spineDepth: Int = 0
    private var currentSpineCursorSec: Double = 0

    private struct ActiveClipBuild {
        var elementName: String
        var isGap: Bool = false
        var name: String
        var assetId: String?
        var formatId: String?
        var timelineStartSec: Double
        var clipRawStartSec: Double
        var durationSec: Double
        var hasVideoRef: Bool = false
        var hasAudioRef: Bool = false
        var videoRefStartSec: Double?
        var lane: Int = 0
        var markerRawTimes: [Double] = []
        var priority: Int? = nil
        var enabled: Bool = true
    }

    private var clipStack: [ActiveClipBuild] = []
    private var fallbackTitle: String = "Import XML"

    public static func isSupportedXMLURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "fcpxmld" || ext == "fcpxml" || ext == "xml"
    }

    public static func resolveXMLFileURL(from url: URL) -> URL? {
        let ext = url.pathExtension.lowercased()
        let fm = FileManager.default
        if ext == "fcpxmld" {
            let infoXML = url.appendingPathComponent("Info.fcpxml")
            if fm.fileExists(atPath: infoXML.path) {
                return infoXML
            }
            if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
               let firstXML = contents.first(where: { ["fcpxml", "xml"].contains($0.pathExtension.lowercased()) }) {
                return firstXML
            }
            return nil
        }
        if ext == "fcpxml" || ext == "xml" {
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }

    public static func importFromURL(
        _ url: URL,
        existingMedia: [MediaItem],
        existingFolders: [MediaFolder]
    ) async throws -> FCPXMLImportResult {
        guard let xmlURL = resolveXMLFileURL(from: url) else {
            throw NSError(domain: "FCPXMLImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "File Info.fcpxml non trovato in \(url.lastPathComponent)"])
        }

        let data = try Data(contentsOf: xmlURL)
        let importer = FCPXMLImporter()
        importer.fallbackTitle = url.deletingPathExtension().lastPathComponent
        guard importer.parse(data: data) else {
            throw NSError(domain: "FCPXMLImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Impossibile analizzare il file XML \(url.lastPathComponent)"])
        }

        return try await importer.buildImportResult(
            fallbackName: importer.fallbackTitle,
            existingMedia: existingMedia,
            existingFolders: existingFolders
        )
    }

    private func parse(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    // MARK: - XMLParserDelegate
    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "format":
            if let id = attributeDict["id"] {
                let w = CGFloat(Double(attributeDict["width"] ?? "") ?? 1920)
                let h = CGFloat(Double(attributeDict["height"] ?? "") ?? 1080)
                let frameDur = Self.parseRationalSeconds(attributeDict["frameDuration"])
                let fps = (frameDur > 0) ? Float(1.0 / frameDur) : 25.0
                formats[id] = FormatInfo(id: id, width: w, height: h, fps: fps)
            }

        case "asset":
            if let id = attributeDict["id"] {
                let name = attributeDict["name"] ?? "Clip"
                let startSec = Self.parseRationalSeconds(attributeDict["start"])
                let durationSec = Self.parseRationalSeconds(attributeDict["duration"])
                let hasVideo = (attributeDict["hasVideo"] ?? "1") != "0"
                let hasAudio = (attributeDict["hasAudio"] ?? "1") != "0"
                var srcURL: URL? = nil
                if let src = attributeDict["src"] {
                    srcURL = URL(string: src)
                }
                assets[id] = AssetInfo(
                    id: id,
                    name: name,
                    srcURL: srcURL,
                    startSec: startSec,
                    durationSec: durationSec,
                    formatId: attributeDict["format"],
                    hasVideo: hasVideo,
                    hasAudio: hasAudio
                )
                currentAssetId = id
            }

        case "media-rep":
            if let aId = currentAssetId, let src = attributeDict["src"], var asset = assets[aId] {
                if let url = URL(string: src) ?? URL(fileURLWithPath: src) as URL? {
                    if asset.srcURL == nil || attributeDict["kind"] == "original-media" {
                        asset.srcURL = url
                        assets[aId] = asset
                    }
                }
            }

        case "event":
            currentEventName = attributeDict["name"]

        case "project":
            currentProjectName = attributeDict["name"]

        case "sequence":
            let tcStart = Self.parseRationalSeconds(attributeDict["tcStart"])
            let seqName = currentProjectName ?? currentEventName ?? fallbackTitle
            currentSeq = ParsedSequence(
                name: seqName,
                formatId: attributeDict["format"],
                tcStartSec: tcStart,
                placements: []
            )
            currentSpineCursorSec = 0

        case "spine":
            if currentSeq != nil {
                spineDepth += 1
                currentSpineCursorSec = 0
            }

        case "gap":
            if currentSeq != nil && spineDepth > 0 && clipStack.isEmpty {
                let tcStart = currentSeq?.tcStartSec ?? 0
                let hasExplicitOffset = attributeDict["offset"] != nil
                let rawOffset = Self.parseRationalSeconds(attributeDict["offset"])
                let tStart = hasExplicitOffset ? max(0, rawOffset - tcStart) : currentSpineCursorSec
                let dur = Self.parseRationalSeconds(attributeDict["duration"])
                let gapStart = Self.parseRationalSeconds(attributeDict["start"])
                let gapBuild = ActiveClipBuild(
                    elementName: "gap",
                    isGap: true,
                    name: "Gap",
                    timelineStartSec: tStart,
                    clipRawStartSec: gapStart,
                    durationSec: dur
                )
                clipStack.append(gapBuild)
                currentSpineCursorSec = max(currentSpineCursorSec, tStart + dur)
            }

        case "asset-clip", "clip":
            guard currentSeq != nil else { return }
            let tcStart = currentSeq?.tcStartSec ?? 0
            let hasExplicitOffset = attributeDict["offset"] != nil
            let rawOffset = Self.parseRationalSeconds(attributeDict["offset"])
            let tStart: Double
            if let parent = clipStack.last {
                // Nested connected clip inside a spine clip/gap
                tStart = hasExplicitOffset
                    ? max(0, parent.timelineStartSec + (rawOffset - parent.clipRawStartSec))
                    : parent.timelineStartSec
            } else {
                tStart = hasExplicitOffset ? max(0, rawOffset - tcStart) : currentSpineCursorSec
            }
            let dur = Self.parseRationalSeconds(attributeDict["duration"])
            let clipStart = Self.parseRationalSeconds(attributeDict["start"])
            let lane = Int(attributeDict["lane"] ?? "0") ?? 0
            let enabled = (attributeDict["enabled"] ?? "1") != "0"

            var build = ActiveClipBuild(
                elementName: elementName,
                isGap: false,
                name: attributeDict["name"] ?? "Clip",
                assetId: attributeDict["ref"],
                formatId: attributeDict["format"],
                timelineStartSec: tStart,
                clipRawStartSec: clipStart,
                durationSec: dur,
                hasVideoRef: attributeDict["ref"] != nil && lane >= 0,
                hasAudioRef: lane < 0,
                lane: lane,
                enabled: enabled
            )
            if elementName == "asset-clip", let ref = attributeDict["ref"], let asset = assets[ref] {
                build.hasVideoRef = (lane >= 0) && asset.hasVideo
                build.hasAudioRef = asset.hasAudio
            }
            clipStack.append(build)

        case "video":
            if !clipStack.isEmpty {
                var top = clipStack[clipStack.count - 1]
                if top.assetId == nil, let ref = attributeDict["ref"] {
                    top.assetId = ref
                }
                top.hasVideoRef = true
                if let s = attributeDict["start"] {
                    top.videoRefStartSec = Self.parseRationalSeconds(s)
                }
                clipStack[clipStack.count - 1] = top
            }

        case "audio":
            if !clipStack.isEmpty {
                var top = clipStack[clipStack.count - 1]
                if top.assetId == nil, let ref = attributeDict["ref"] {
                    top.assetId = ref
                }
                top.hasAudioRef = true
                clipStack[clipStack.count - 1] = top
            }

        case "marker", "chapter-marker":
            if !clipStack.isEmpty, let startAttr = attributeDict["start"] {
                let markerSec = Self.parseRationalSeconds(startAttr)
                clipStack[clipStack.count - 1].markerRawTimes.append(markerSec)
            }

        case "keyword":
            if !clipStack.isEmpty, let val = attributeDict["value"] {
                if val == "Vision-P1" { clipStack[clipStack.count - 1].priority = 1 }
                else if val == "Vision-P2" { clipStack[clipStack.count - 1].priority = 2 }
                else if val == "Vision-P3" { clipStack[clipStack.count - 1].priority = 3 }
            }

        default:
            break
        }
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "asset":
            currentAssetId = nil

        case "gap":
            if let top = clipStack.last, top.isGap {
                clipStack.removeLast()
            }

        case "asset-clip", "clip":
            guard let build = clipStack.popLast(), !build.isGap else { return }
            if build.enabled, let aId = build.assetId, build.durationSec > 0.01 {
                let assetStart = assets[aId]?.startSec ?? build.videoRefStartSec ?? 0
                let relSourceIn = max(0, build.clipRawStartSec - assetStart)
                let trackIdx: Int
                let isAudioOnly: Bool
                if build.lane < 0 {
                    trackIdx = max(0, abs(build.lane) - 1)
                    isAudioOnly = true
                } else if build.lane > 0 {
                    trackIdx = build.lane
                    isAudioOnly = !build.hasVideoRef && build.hasAudioRef
                } else {
                    trackIdx = 0
                    isAudioOnly = !build.hasVideoRef && build.hasAudioRef
                }

                let placement = ClipPlacement(
                    assetId: aId,
                    name: build.name,
                    timelineStartSec: build.timelineStartSec,
                    sourceInOffsetFromClipSec: relSourceIn,
                    clipRawStartSec: build.clipRawStartSec,
                    durationSec: build.durationSec,
                    trackIndex: trackIdx,
                    isAudioOnly: isAudioOnly,
                    hasAudio: build.hasAudioRef || isAudioOnly,
                    markerRawTimes: build.markerRawTimes,
                    priority: build.priority
                )
                currentSeq?.placements.append(placement)
            }
            if spineDepth > 0 && clipStack.isEmpty {
                currentSpineCursorSec = max(currentSpineCursorSec, build.timelineStartSec + build.durationSec)
            }

        case "spine":
            if spineDepth > 0 { spineDepth -= 1 }

        case "sequence":
            if let seq = currentSeq {
                sequences.append(seq)
                currentSeq = nil
            }

        case "project":
            currentProjectName = nil

        case "event":
            currentEventName = nil

        default:
            break
        }
    }

    // MARK: - Build Vision Models & Relink/Import Media
    private func buildImportResult(
        fallbackName: String,
        existingMedia: [MediaItem],
        existingFolders: [MediaFolder]
    ) async throws -> FCPXMLImportResult {
        var workingMediaById: [String: MediaItem] = [:]
        var missingAssetIds: Set<String> = []
        var relinkedMediaIds: Set<UUID> = []
        var newlyImportedMedia: [MediaItem] = []
        var loadedByCanonicalPath: [String: MediaItem] = [:]
        let existingIds = Set(existingMedia.map(\.id))

        for item in existingMedia {
            loadedByCanonicalPath[item.url.standardizedFileURL.path] = item
        }

        // Collect only referenced assets in order of appearance
        var orderedAssetIds: [String] = []
        var seenAssetIds: Set<String> = []
        for seq in sequences {
            for p in seq.placements {
                if seenAssetIds.insert(p.assetId).inserted {
                    orderedAssetIds.append(p.assetId)
                }
            }
        }

        let fm = FileManager.default
        for aId in orderedAssetIds {
            guard let asset = assets[aId] else { continue }
            let targetFilename = asset.srcURL?.lastPathComponent ?? asset.name

            // 1. Try relink by exact URL/path among already loaded/existing media
            if let srcURL = asset.srcURL {
                let stdPath = srcURL.standardizedFileURL.path
                if let match = loadedByCanonicalPath[stdPath] {
                    workingMediaById[aId] = match
                    if existingIds.contains(match.id) {
                        relinkedMediaIds.insert(match.id)
                    }
                    continue
                }
            }

            // 2. Try relink by filename among existing media in project (or just imported in this batch)
            let allKnownMedia = existingMedia + newlyImportedMedia
            if let nameMatch = allKnownMedia.first(where: {
                $0.url.lastPathComponent.caseInsensitiveCompare(targetFilename) == .orderedSame ||
                $0.name.caseInsensitiveCompare(asset.name) == .orderedSame
            }) {
                workingMediaById[aId] = nameMatch
                if existingIds.contains(nameMatch.id) {
                    relinkedMediaIds.insert(nameMatch.id)
                }
                continue
            }

            // 3. Load from disk if available
            if let srcURL = asset.srcURL, fm.fileExists(atPath: srcURL.path) {
                do {
                    await CompositionEngine.shared.preloadMetadata(for: srcURL)
                    let loaded = try await MediaItem.load(from: srcURL)
                    loadedByCanonicalPath[srcURL.standardizedFileURL.path] = loaded
                    newlyImportedMedia.append(loaded)
                    workingMediaById[aId] = loaded
                    continue
                } catch {
                    DebugLogger.shared.log("FCPXML Import: errore caricamento '\(targetFilename)': \(error.localizedDescription)", level: .warning)
                }
            }

            // 4. Fallback offline placeholder if media file is currently unreachable/offline
            let fmt = asset.formatId.flatMap { formats[$0] }
            let placeholderURL = asset.srcURL ?? URL(fileURLWithPath: "/\(asset.name)")
            let offlineItem = MediaItem(
                url: placeholderURL,
                name: asset.name,
                duration: CMTime(seconds: max(0.1, asset.durationSec), preferredTimescale: 600),
                resolution: CGSize(width: fmt?.width ?? 1920, height: fmt?.height ?? 1080),
                frameRate: fmt?.fps ?? 25.0,
                hasVideo: asset.hasVideo,
                hasAudio: asset.hasAudio,
                videoCodec: "Offline",
                audioTrackCount: asset.hasAudio ? 1 : 0
            )
            newlyImportedMedia.append(offlineItem)
            workingMediaById[aId] = offlineItem
            missingAssetIds.insert(aId)
        }

        // Deduplicate relinked / newly imported items by URL/ID
        let allReferencedMedia = Array(
            Dictionary(
                workingMediaById.values.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
        )

        // Create dedicated import folder
        let baseFolderName = sequences.first?.name.isEmpty == false ? sequences.first!.name : fallbackName
        var folderName = baseFolderName
        var suffix = 2
        while existingFolders.contains(where: { $0.name.caseInsensitiveCompare(folderName) == .orderedSame }) {
            folderName = "\(baseFolderName) \(suffix)"
            suffix += 1
        }

        // Only place items into the new folder that aren't already placed inside another user folder,
        // plus all newly imported items.
        let itemsAlreadyInFolders = Set(existingFolders.flatMap(\.itemIds))
        let folderItemIds = allReferencedMedia
            .filter { item in
                newlyImportedMedia.contains(where: { $0.id == item.id }) || !itemsAlreadyInFolders.contains(item.id)
            }
            .map(\.id)

        let createdFolder = MediaFolder(name: folderName, itemIds: Set(folderItemIds))

        // Build timelines
        var resultTimelines: [TimelineModel] = []
        for seq in sequences {
            let maxTrackIdx = seq.placements.map(\.trackIndex).max() ?? 0
            let isSel = (maxTrackIdx == 0) && seq.name.lowercased().contains("selezione")
            let tl = TimelineModel(name: seq.name, isSelection: isSel)

            if let fId = seq.formatId, let fmt = formats[fId] {
                let orientLabel = fmt.height > fmt.width ? "Verticale" : "Orizzontale"
                tl.format = TimelineFormat(
                    id: "fcpxml-\(fId)",
                    name: "\(Int(fmt.width))×\(Int(fmt.height)) \(orientLabel)",
                    size: CGSize(width: fmt.width, height: fmt.height),
                    fps: fmt.fps
                )
            }

            for p in seq.placements {
                guard let mItem = workingMediaById[p.assetId], let asset = assets[p.assetId] else { continue }
                let isOffline = missingAssetIds.contains(p.assetId)
                let maxDurSec = CMTimeGetSeconds(mItem.duration)
                let safeInSec = min(max(0, p.sourceInOffsetFromClipSec), max(0, maxDurSec - 0.04))
                let safeOutSec = min(maxDurSec, safeInSec + p.durationSec)
                guard safeOutSec - safeInSec > 0.01 else { continue }

                let sIn = CMTime(seconds: safeInSec, preferredTimescale: 600)
                let sOut = CMTime(seconds: safeOutSec, preferredTimescale: 600)
                let tStart = CMTime(seconds: max(0, p.timelineStartSec), preferredTimescale: 600)

                let markers = p.markerRawTimes.compactMap { rawM -> Double? in
                    let rel = rawM - asset.startSec
                    guard rel >= safeInSec - 0.05 && rel <= safeOutSec + 0.05 else { return nil }
                    return max(safeInSec, min(safeOutSec, rel))
                }.sorted()

                let vTrackIdx = tl.isSelection ? 0 : min(p.trackIndex, tl.maxVideoTracks - 1)
                let aTrackIdx = tl.isSelection ? 0 : min(p.trackIndex, tl.maxAudioTracks - 1)
                let wantsVideo = !p.isAudioOnly && mItem.hasVideo
                let wantsAudio = p.hasAudio && mItem.hasAudio
                let linkId = (wantsVideo && wantsAudio && vTrackIdx == aTrackIdx) ? UUID() : nil

                if wantsVideo {
                    tl.ensureVideoTrack(id: vTrackIdx)
                    let vClip = TimelineClip(
                        mediaItem: mItem,
                        sourceIn: sIn,
                        sourceOut: sOut,
                        timelineStart: tStart,
                        trackIndex: vTrackIdx,
                        mediaType: .video,
                        orientation: mItem.orientation,
                        linkGroupId: linkId,
                        isOrphan: isOffline,
                        markers: markers,
                        priority: p.priority
                    )
                    tl.videoTracks[vTrackIdx].clips.append(vClip)
                }

                if wantsAudio {
                    tl.ensureAudioTrack(id: aTrackIdx)
                    let aClip = TimelineClip(
                        mediaItem: mItem,
                        sourceIn: sIn,
                        sourceOut: sOut,
                        timelineStart: tStart,
                        trackIndex: aTrackIdx,
                        mediaType: .audio,
                        orientation: .normal,
                        linkGroupId: linkId,
                        isOrphan: isOffline,
                        markers: markers,
                        priority: p.priority
                    )
                    tl.audioTracks[aTrackIdx].clips.append(aClip)
                }
            }

            for i in 0..<tl.videoTracks.count {
                tl.videoTracks[i].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
            }
            for i in 0..<tl.audioTracks.count {
                tl.audioTracks[i].clips.sort { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
            }

            resultTimelines.append(tl)
        }

        return FCPXMLImportResult(
            importedTimelines: resultTimelines,
            newlyImportedMedia: newlyImportedMedia,
            createdFolder: createdFolder,
            folderItemIds: folderItemIds,
            relinkedCount: relinkedMediaIds.count,
            newMediaCount: newlyImportedMedia.count,
            missingCount: missingAssetIds.count
        )
    }

    private static func parseRationalSeconds(_ raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return 0
        }
        let cleaned = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        let parts = cleaned.split(separator: "/")
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den != 0 {
            return num / den
        }
        return Double(cleaned) ?? 0
    }
}
