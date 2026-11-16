import Foundation
import CoreMedia
import AVFoundation

/// Esporta qualsiasi `TimelineModel` (Timeline o Selezione) nel formato nativo Final Cut Pro / DaVinci Resolve (`FCPXML 1.14` / `.fcpxmld`).
public final class FCPXMLExporter {
    private struct ConnectedEntry {
        let clip: TimelineClip
        let lane: Int
        let isEnabled: Bool
        let role: String?
    }

    private struct SpineNode {
        let timelineStartSec: Double
        let durationSec: Double
        let localStartSec: Double
        let clip: TimelineClip? // nil = <gap>
        let linkedAudio: TimelineClip?
        let isVideoEnabled: Bool
        var connected: [ConnectedEntry] = []
    }

    public static func exportTimeline(
        _ timeline: TimelineModel,
        to destinationURL: URL,
        eventName: String? = nil
    ) throws -> URL {
        let xmlString = generateXML(for: timeline, eventName: eventName)
        guard let data = xmlString.data(using: .utf8) else {
            throw NSError(domain: "FCPXMLExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Impossibile codificare XML UTF-8."])
        }

        let ext = destinationURL.pathExtension.lowercased()
        let fm = FileManager.default

        if ext == "fcpxml" || ext == "xml" {
            let parent = destinationURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try data.write(to: destinationURL, options: .atomic)
            DebugLogger.shared.log("Esportato FCPXML: \(destinationURL.path)", level: .info)
            return destinationURL
        }

        // Default: bundle .fcpxmld identico al formato Final Cut Pro / DaVinci Resolve (`Info.fcpxml` dentro la cartella bundle)
        let bundleURL: URL
        if ext == "fcpxmld" {
            bundleURL = destinationURL
        } else {
            bundleURL = destinationURL.appendingPathExtension("fcpxmld")
        }

        if fm.fileExists(atPath: bundleURL.path) {
            try fm.removeItem(at: bundleURL)
        }
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let infoURL = bundleURL.appendingPathComponent("Info.fcpxml")
        try data.write(to: infoURL, options: .atomic)

        DebugLogger.shared.log("Esportato bundle Final Cut Pro (.fcpxmld): \(bundleURL.path)", level: .info)
        return bundleURL
    }

    public static func generateXML(for timeline: TimelineModel, eventName: String? = nil) -> String {
        let seqFps = Double(timeline.format.fps > 0 ? timeline.format.fps : 25.0)
        let seqRat = rationalFrameSpec(for: seqFps)
        let seqWidth = max(1, Int(timeline.format.size.width.rounded()))
        let seqHeight = max(1, Int(timeline.format.size.height.rounded()))

        // 1. Raccolta formati unici: r0 = formato timeline
        var formatIndexByKey: [String: String] = [:]
        var formatLines: [String] = []
        let seqFmtKey = "\(seqWidth)x\(seqHeight)@\(seqRat.frameNum)/\(seqRat.frameDen)"
        formatIndexByKey[seqFmtKey] = "r0"
        formatLines.append(
            "        <format id=\"r0\" name=\"FFVideoFormatRateUndefined\" width=\"\(seqWidth)\" height=\"\(seqHeight)\" frameDuration=\"\(seqRat.frameNum)/\(seqRat.frameDen)s\"/>"
        )

        var nextResourceCounter = 1
        func allocateResourceId() -> String {
            let id = "r\(nextResourceCounter)"
            nextResourceCounter += 1
            return id
        }

        func formatId(for item: MediaItem) -> String {
            let w = item.resolution.width > 1 ? Int(item.resolution.width.rounded()) : seqWidth
            let h = item.resolution.height > 1 ? Int(item.resolution.height.rounded()) : seqHeight
            let fps = item.frameRate > 1 ? Double(item.frameRate) : seqFps
            let rat = rationalFrameSpec(for: fps)
            let key = "\(w)x\(h)@\(rat.frameNum)/\(rat.frameDen)"
            if let existing = formatIndexByKey[key] {
                return existing
            }
            let newId = allocateResourceId()
            formatIndexByKey[key] = newId
            formatLines.append(
                "        <format id=\"\(newId)\" name=\"FFVideoFormatRateUndefined\" width=\"\(w)\" height=\"\(h)\" frameDuration=\"\(rat.frameNum)/\(rat.frameDen)s\"/>"
            )
            return newId
        }

        // 2. Raccolta asset unici referenziati in timeline
        var assetIdByMediaUUID: [UUID: String] = [:]
        var assetBlocks: [String] = []

        func registerAsset(for item: MediaItem) -> (assetId: String, fmtId: String) {
            let fmtId = formatId(for: item)
            if let existing = assetIdByMediaUUID[item.id] {
                return (existing, fmtId)
            }
            let aId = allocateResourceId()
            assetIdByMediaUUID[item.id] = aId

            let itemFps = item.frameRate > 1 ? Double(item.frameRate) : seqFps
            let itemDur = max(0.04, CMTimeGetSeconds(item.duration))
            let durStr = formatRationalSeconds(itemDur, fps: itemFps)
            let audioChannels = item.hasAudio ? max(1, item.audioTrackCount) : 0
            let audioSources = item.hasAudio ? 1 : 0

            let block = """
                    <asset id="\(aId)" name="\(xmlEscape(item.name))" start="0/1s" duration="\(durStr)" format="\(fmtId)" hasVideo="\(item.hasVideo ? 1 : 0)" hasAudio="\(item.hasAudio ? 1 : 0)" audioSources="\(audioSources)" audioChannels="\(audioChannels)">
                        <media-rep kind="original-media" src="\(xmlEscape(item.url.absoluteString))"/>
                    </asset>
            """
            assetBlocks.append(block)
            return (aId, fmtId)
        }

        // Pre-registra tutti i media in ordine di apparizione
        for track in timeline.videoTracks {
            for clip in track.clips { _ = registerAsset(for: clip.mediaItem) }
        }
        for track in timeline.audioTracks {
            for clip in track.clips { _ = registerAsset(for: clip.mediaItem) }
        }

        // 3. Costruisci Spine principale su V1 + abbina audio A1 collegato
        let tcStartSec = 3600.0
        let v1Track = timeline.videoTracks.first
        let v1Clips = (v1Track?.clips ?? []).sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }
        let a1Track = timeline.audioTracks.first
        let a1Clips = (a1Track?.clips ?? []).sorted { CMTimeCompare($0.timelineStart, $1.timelineStart) < 0 }

        var matchedAudioIds: Set<UUID> = []
        var matchedAudioByVideoId: [UUID: TimelineClip] = [:]

        for vClip in v1Clips {
            if let lId = vClip.linkGroupId,
               let aMatch = a1Clips.first(where: {
                   $0.linkGroupId == lId &&
                   abs(CMTimeGetSeconds($0.timelineStart) - CMTimeGetSeconds(vClip.timelineStart)) < 0.03
               }) {
                matchedAudioByVideoId[vClip.id] = aMatch
                matchedAudioIds.insert(aMatch.id)
            }
        }

        let totalTimelineSec = max(0.0, CMTimeGetSeconds(timeline.totalDuration))
        var spineNodes: [SpineNode] = []
        var cursorSec = 0.0

        for vClip in v1Clips {
            let cStart = max(0.0, CMTimeGetSeconds(vClip.timelineStart))
            let cDur = max(0.04, CMTimeGetSeconds(vClip.duration))
            if cStart - cursorSec > 0.005 {
                let gapDur = cStart - cursorSec
                spineNodes.append(SpineNode(
                    timelineStartSec: cursorSec,
                    durationSec: gapDur,
                    localStartSec: tcStartSec,
                    clip: nil,
                    linkedAudio: nil,
                    isVideoEnabled: true
                ))
            }

            let srcInSec = max(0.0, CMTimeGetSeconds(vClip.sourceIn))
            spineNodes.append(SpineNode(
                timelineStartSec: cStart,
                durationSec: cDur,
                localStartSec: srcInSec,
                clip: vClip,
                linkedAudio: matchedAudioByVideoId[vClip.id],
                isVideoEnabled: v1Track?.isEnabled ?? true
            ))
            cursorSec = max(cursorSec, cStart + cDur)
        }

        // Se ci sono clip audio (es. musica) o tracce superiori oltre la fine di V1 (o V1 vuota), aggiungi gap finale
        if totalTimelineSec - cursorSec > 0.005 || spineNodes.isEmpty {
            let tailDur = max(0.04, totalTimelineSec - cursorSec)
            spineNodes.append(SpineNode(
                timelineStartSec: cursorSec,
                durationSec: tailDur,
                localStartSec: tcStartSec,
                clip: nil,
                linkedAudio: nil,
                isVideoEnabled: true
            ))
        }

        // 4. Raccogli tutti gli elementi connessi (V2.., A1 indipendenti, A2..)
        var connectedItems: [ConnectedEntry] = []
        for track in timeline.videoTracks where track.id >= 1 {
            for clip in track.clips {
                connectedItems.append(ConnectedEntry(clip: clip, lane: track.id, isEnabled: track.isEnabled, role: "video"))
            }
        }
        for track in timeline.audioTracks {
            let lane = -(track.id + 1) // A1 -> -1, A2 -> -2, ...
            let role = track.id == 0 ? "dialogue" : "music"
            for clip in track.clips {
                if track.id == 0 && matchedAudioIds.contains(clip.id) {
                    continue
                }
                connectedItems.append(ConnectedEntry(clip: clip, lane: lane, isEnabled: track.isEnabled, role: role))
            }
        }

        connectedItems.sort { CMTimeCompare($0.clip.timelineStart, $1.clip.timelineStart) < 0 }

        // Aggancia ogni clip connessa allo SpineNode che copre il suo start
        for entry in connectedItems {
            let cStart = max(0.0, CMTimeGetSeconds(entry.clip.timelineStart))
            if let hostIdx = spineNodes.lastIndex(where: { cStart >= $0.timelineStartSec - 0.005 }) {
                spineNodes[hostIdx].connected.append(entry)
            } else if !spineNodes.isEmpty {
                spineNodes[0].connected.append(entry)
            }
        }

        // 5. Renderizza XML della Spine
        var spineXML = ""
        for node in spineNodes {
            let nodeOffsetStr = formatRationalSeconds(tcStartSec + node.timelineStartSec, fps: seqFps)
            let nodeDurStr = formatRationalSeconds(node.durationSec, fps: seqFps)

            if let vClip = node.clip {
                let (aId, fmtId) = registerAsset(for: vClip.mediaItem)
                let srcInSec = max(0.0, CMTimeGetSeconds(vClip.sourceIn))
                let startStr = formatRationalSeconds(srcInSec, fps: seqFps)
                let enabledFlag = node.isVideoEnabled ? "1" : "0"
                let clipName = xmlEscape(vClip.mediaItem.name)

                var innerXML = ""
                if let linkedA = node.linkedAudio {
                    // Clip video con audio collegato
                    let aEnabled = (a1Track?.isEnabled ?? true) ? "1" : "0"
                    if vClip.speed > 0 && abs(vClip.speed - 1.0) > 0.001 {
                        innerXML += speedTimeMapXML(sourceStartSec: srcInSec, sourceDurationSec: CMTimeGetSeconds(vClip.sourceDuration), timelineDurationSec: node.durationSec, fps: seqFps, indent: "                            ")
                    }
                    innerXML += markersXML(for: vClip, parentLocalStart: srcInSec, fps: seqFps, indent: "                            ")
                    innerXML += priorityKeywordXML(for: vClip, startSec: srcInSec, durSec: CMTimeGetSeconds(vClip.sourceDuration), fps: seqFps, indent: "                            ")
                    if aEnabled == "0" {
                        innerXML += "                            <adjust-volume amount=\"-96dB\"/>\n"
                    }
                    innerXML += renderConnectedChildren(node.connected, parentTimelineStart: node.timelineStartSec, parentLocalStart: node.localStartSec, seqFps: seqFps, registerAsset: registerAsset, indent: "                            ")

                    let _ = linkedA
                    if innerXML.isEmpty {
                        spineXML += "                        <asset-clip tcFormat=\"NDF\" duration=\"\(nodeDurStr)\" enabled=\"\(enabledFlag)\" offset=\"\(nodeOffsetStr)\" format=\"\(fmtId)\" start=\"\(startStr)\" name=\"\(clipName)\" ref=\"\(aId)\"/>\n"
                    } else {
                        spineXML += "                        <asset-clip tcFormat=\"NDF\" duration=\"\(nodeDurStr)\" enabled=\"\(enabledFlag)\" offset=\"\(nodeOffsetStr)\" format=\"\(fmtId)\" start=\"\(startStr)\" name=\"\(clipName)\" ref=\"\(aId)\">\n"
                        spineXML += innerXML
                        spineXML += "                        </asset-clip>\n"
                    }
                } else {
                    // Clip solo video (senza traccia audio A1) -> <clip> con solo <video ref="...">
                    let assetDurStr = formatRationalSeconds(max(0.04, CMTimeGetSeconds(vClip.mediaItem.duration)), fps: seqFps)
                    innerXML += "                            <video ref=\"\(aId)\" offset=\"0/1s\" start=\"0/1s\" duration=\"\(assetDurStr)\"/>\n"
                    if vClip.speed > 0 && abs(vClip.speed - 1.0) > 0.001 {
                        innerXML += speedTimeMapXML(sourceStartSec: srcInSec, sourceDurationSec: CMTimeGetSeconds(vClip.sourceDuration), timelineDurationSec: node.durationSec, fps: seqFps, indent: "                            ")
                    }
                    innerXML += markersXML(for: vClip, parentLocalStart: srcInSec, fps: seqFps, indent: "                            ")
                    innerXML += priorityKeywordXML(for: vClip, startSec: srcInSec, durSec: CMTimeGetSeconds(vClip.sourceDuration), fps: seqFps, indent: "                            ")
                    innerXML += renderConnectedChildren(node.connected, parentTimelineStart: node.timelineStartSec, parentLocalStart: node.localStartSec, seqFps: seqFps, registerAsset: registerAsset, indent: "                            ")

                    spineXML += "                        <clip tcFormat=\"NDF\" duration=\"\(nodeDurStr)\" enabled=\"\(enabledFlag)\" offset=\"\(nodeOffsetStr)\" format=\"\(fmtId)\" start=\"\(startStr)\" name=\"\(clipName)\">\n"
                    spineXML += innerXML
                    spineXML += "                        </clip>\n"
                }
            } else {
                // Gap
                let childXML = renderConnectedChildren(node.connected, parentTimelineStart: node.timelineStartSec, parentLocalStart: node.localStartSec, seqFps: seqFps, registerAsset: registerAsset, indent: "                            ")
                let startGapStr = formatRationalSeconds(node.localStartSec, fps: seqFps)
                if childXML.isEmpty {
                    spineXML += "                        <gap name=\"Gap\" offset=\"\(nodeOffsetStr)\" duration=\"\(nodeDurStr)\" start=\"\(startGapStr)\"/>\n"
                } else {
                    spineXML += "                        <gap name=\"Gap\" offset=\"\(nodeOffsetStr)\" duration=\"\(nodeDurStr)\" start=\"\(startGapStr)\">\n"
                    spineXML += childXML
                    spineXML += "                        </gap>\n"
                }
            }
        }

        let seqTotalDurStr = formatRationalSeconds(max(0.04, totalTimelineSec), fps: seqFps)
        let tcStartStr = formatRationalSeconds(tcStartSec, fps: seqFps)
        let safeProjectName = xmlEscape(timeline.name)
        let safeEventName = xmlEscape(eventName ?? timeline.name)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.14">
            <resources>
        \(formatLines.joined(separator: "\n"))
        \(assetBlocks.joined(separator: "\n"))
            </resources>
            <library>
                <event name="\(safeEventName)">
                    <project name="\(safeProjectName)">
                        <sequence tcFormat="NDF" tcStart="\(tcStartStr)" duration="\(seqTotalDurStr)" format="r0">
                            <spine>
        \(spineXML)                    </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """
    }

    private static func renderConnectedChildren(
        _ entries: [ConnectedEntry],
        parentTimelineStart: Double,
        parentLocalStart: Double,
        seqFps: Double,
        registerAsset: (MediaItem) -> (assetId: String, fmtId: String),
        indent: String
    ) -> String {
        var out = ""
        for entry in entries {
            let clip = entry.clip
            let (aId, fmtId) = registerAsset(clip.mediaItem)
            let cStart = max(0.0, CMTimeGetSeconds(clip.timelineStart))
            let cDur = max(0.04, CMTimeGetSeconds(clip.duration))
            let srcInSec = max(0.0, CMTimeGetSeconds(clip.sourceIn))

            let relOffsetInParent = parentLocalStart + (cStart - parentTimelineStart)
            let offsetStr = formatRationalSeconds(relOffsetInParent, fps: seqFps)
            let startStr = formatRationalSeconds(srcInSec, fps: seqFps)
            let durStr = formatRationalSeconds(cDur, fps: seqFps)
            let enabledFlag = entry.isEnabled ? "1" : "0"
            let roleAttr = entry.role.map { " audioRole=\"\(xmlEscape($0))\"" } ?? ""

            var nested = ""
            if clip.speed > 0 && abs(clip.speed - 1.0) > 0.001 {
                nested += speedTimeMapXML(sourceStartSec: srcInSec, sourceDurationSec: CMTimeGetSeconds(clip.sourceDuration), timelineDurationSec: cDur, fps: seqFps, indent: indent + "    ")
            }
            nested += markersXML(for: clip, parentLocalStart: srcInSec, fps: seqFps, indent: indent + "    ")
            nested += priorityKeywordXML(for: clip, startSec: srcInSec, durSec: CMTimeGetSeconds(clip.sourceDuration), fps: seqFps, indent: indent + "    ")

            if nested.isEmpty {
                out += "\(indent)<asset-clip lane=\"\(entry.lane)\" ref=\"\(aId)\" offset=\"\(offsetStr)\" start=\"\(startStr)\" duration=\"\(durStr)\" enabled=\"\(enabledFlag)\" name=\"\(xmlEscape(clip.mediaItem.name))\" format=\"\(fmtId)\"\(roleAttr) tcFormat=\"NDF\"/>\n"
            } else {
                out += "\(indent)<asset-clip lane=\"\(entry.lane)\" ref=\"\(aId)\" offset=\"\(offsetStr)\" start=\"\(startStr)\" duration=\"\(durStr)\" enabled=\"\(enabledFlag)\" name=\"\(xmlEscape(clip.mediaItem.name))\" format=\"\(fmtId)\"\(roleAttr) tcFormat=\"NDF\">\n"
                out += nested
                out += "\(indent)</asset-clip>\n"
            }
        }
        return out
    }

    private static func markersXML(for clip: TimelineClip, parentLocalStart: Double, fps: Double, indent: String) -> String {
        let sIn = CMTimeGetSeconds(clip.sourceIn)
        let sOut = CMTimeGetSeconds(clip.sourceOut)
        let frameSpec = rationalFrameSpec(for: fps)
        let markerDurStr = "\(frameSpec.frameNum)/\(frameSpec.frameDen)s"
        var out = ""
        for m in clip.markers where m >= sIn - 0.05 && m <= sOut + 0.05 {
            let mClamped = max(sIn, min(sOut, m))
            let startStr = formatRationalSeconds(mClamped, fps: fps)
            out += "\(indent)<marker start=\"\(startStr)\" duration=\"\(markerDurStr)\" value=\"Marker\"/>\n"
        }
        return out
    }

    private static func priorityKeywordXML(for clip: TimelineClip, startSec: Double, durSec: Double, fps: Double, indent: String) -> String {
        guard let p = clip.priority, (1...3).contains(p) else { return "" }
        let sStr = formatRationalSeconds(startSec, fps: fps)
        let dStr = formatRationalSeconds(max(0.04, durSec), fps: fps)
        return "\(indent)<keyword start=\"\(sStr)\" duration=\"\(dStr)\" value=\"Vision-P\(p)\"/>\n"
    }

    private static func speedTimeMapXML(
        sourceStartSec: Double,
        sourceDurationSec: Double,
        timelineDurationSec: Double,
        fps: Double,
        indent: String
    ) -> String {
        let tStartStr = formatRationalSeconds(sourceStartSec, fps: fps)
        let tOutTlStr = formatRationalSeconds(sourceStartSec + timelineDurationSec, fps: fps)
        let vInStr = formatRationalSeconds(sourceStartSec, fps: fps)
        let vOutStr = formatRationalSeconds(sourceStartSec + sourceDurationSec, fps: fps)
        return """
        \(indent)<timeMap>
        \(indent)    <timept time="\(tStartStr)" value="\(vInStr)" interp="linear"/>
        \(indent)    <timept time="\(tOutTlStr)" value="\(vOutStr)" interp="linear"/>
        \(indent)</timeMap>
        """
    }

    // MARK: - Rational Frame Timing & XML Helpers
    private static func rationalFrameSpec(for fps: Double) -> (frameNum: Int64, frameDen: Int64) {
        let standards: [(fps: Double, num: Int64, den: Int64)] = [
            (23.976, 1001, 24000),
            (24.0, 1, 24),
            (25.0, 1, 25),
            (29.97, 1001, 30000),
            (30.0, 1, 30),
            (48.0, 1, 48),
            (50.0, 1, 50),
            (59.94, 1001, 60000),
            (60.0, 1, 60),
            (120.0, 1, 120)
        ]
        if let best = standards.min(by: { abs($0.fps - fps) < abs($1.fps - fps) }), abs(best.fps - fps) < 0.05 {
            return (best.num, best.den)
        }
        let roundedFps = max(1, Int64(fps.rounded()))
        return (1, roundedFps)
    }

    public static func formatRationalSeconds(_ seconds: Double, fps: Double) -> String {
        let safeSec = max(0.0, seconds)
        let spec = rationalFrameSpec(for: fps)
        let frames = Int64((safeSec * Double(spec.frameDen) / Double(spec.frameNum)).rounded())
        if frames == 0 {
            return "0/1s"
        }
        let rawNum = frames * spec.frameNum
        let rawDen = spec.frameDen
        let g = gcd(abs(rawNum), abs(rawDen))
        return "\(rawNum / g)/\(rawDen / g)s"
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = a
        var y = b
        while y != 0 {
            let r = x % y
            x = y
            y = r
        }
        return max(1, x)
    }

    private static func xmlEscape(_ str: String) -> String {
        var s = str
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        return s
    }
}
