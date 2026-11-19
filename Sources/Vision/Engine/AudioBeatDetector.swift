import Foundation
import AVFoundation
import CoreMedia
import Accelerate
import CoreML

public struct StrongPeakCandidate: Sendable, Hashable, Codable {
    public let timeSeconds: Double
    public let strength: Double // 0.0 ... 1.0 normalized impact score

    public init(timeSeconds: Double, strength: Double) {
        self.timeSeconds = timeSeconds
        self.strength = strength
    }
}

public struct AdaptiveGridSlot: Sendable, Hashable, Codable {
    public let timeSeconds: Double
    public let isBeat: Bool
    public let isDownbeat: Bool
    public let globalStrength: Double
    public let envJump: Double
    public let localRatio: Double
    public let localRmsNorm: Double

    public init(
        timeSeconds: Double,
        isBeat: Bool,
        isDownbeat: Bool,
        globalStrength: Double,
        envJump: Double,
        localRatio: Double,
        localRmsNorm: Double
    ) {
        self.timeSeconds = timeSeconds
        self.isBeat = isBeat
        self.isDownbeat = isDownbeat
        self.globalStrength = globalStrength
        self.envJump = envJump
        self.localRatio = localRatio
        self.localRmsNorm = localRmsNorm
    }
}

/// Dati persistenti dell'analisi neurale Beat This! salvati sulla clip del progetto.
public struct SavedBeatAnalysis: Codable, Hashable, Sendable {
    public let bpm: Double
    public let beatSeconds: [Double]
    public let downbeatSeconds: [Double]
    public let transientSeconds: [Double]
    public let strongPeaks: [StrongPeakCandidate]
    public let adaptiveGrid: [AdaptiveGridSlot]
    public let durationSeconds: Double
    public let analyzedAt: Date

    public init(
        bpm: Double,
        beatSeconds: [Double],
        downbeatSeconds: [Double],
        transientSeconds: [Double],
        strongPeaks: [StrongPeakCandidate],
        adaptiveGrid: [AdaptiveGridSlot],
        durationSeconds: Double,
        analyzedAt: Date = Date()
    ) {
        self.bpm = bpm
        self.beatSeconds = beatSeconds
        self.downbeatSeconds = downbeatSeconds
        self.transientSeconds = transientSeconds
        self.strongPeaks = strongPeaks
        self.adaptiveGrid = adaptiveGrid
        self.durationSeconds = durationSeconds
        self.analyzedAt = analyzedAt
    }

    /// Estrae una vista `BeatAnalysisResult` allineata alla finestra `[sourceStart ..< sourceStart + sourceDuration]` della clip.
    public func toBeatAnalysisResult(
        audioURL: URL,
        sourceStart: Double = 0.0,
        sourceDuration: Double? = nil
    ) -> BeatAnalysisResult {
        let start = max(0.0, sourceStart)
        let dur = max(0.05, sourceDuration ?? max(0.05, durationSeconds - start))
        let end = start + dur
        let eps = 0.02

        let slicedBeats = beatSeconds
            .filter { $0 >= start - eps && $0 <= end + eps }
            .map { CMTime(seconds: max(0.0, $0 - start), preferredTimescale: 600) }

        let slicedDownbeats = downbeatSeconds
            .filter { $0 >= start - eps && $0 <= end + eps }
            .map { CMTime(seconds: max(0.0, $0 - start), preferredTimescale: 600) }

        let slicedTransients = transientSeconds
            .filter { $0 >= start - eps && $0 <= end + eps }
            .map { CMTime(seconds: max(0.0, $0 - start), preferredTimescale: 600) }

        let slicedPeaks = strongPeaks
            .filter { $0.timeSeconds >= start - eps && $0.timeSeconds <= end + eps }
            .map { StrongPeakCandidate(timeSeconds: max(0.0, $0.timeSeconds - start), strength: $0.strength) }

        let slicedGrid = adaptiveGrid
            .filter { $0.timeSeconds >= start - eps && $0.timeSeconds <= end + eps }
            .map {
                AdaptiveGridSlot(
                    timeSeconds: max(0.0, $0.timeSeconds - start),
                    isBeat: $0.isBeat,
                    isDownbeat: $0.isDownbeat,
                    globalStrength: $0.globalStrength,
                    envJump: $0.envJump,
                    localRatio: $0.localRatio,
                    localRmsNorm: $0.localRmsNorm
                )
            }

        return BeatAnalysisResult(
            bpm: bpm,
            beatTimes: slicedBeats,
            downbeatTimes: slicedDownbeats,
            transientTimes: slicedTransients,
            strongPeaks: slicedPeaks,
            adaptiveGrid: slicedGrid,
            duration: CMTime(seconds: dur, preferredTimescale: 600),
            audioURL: audioURL
        )
    }
}

public struct BeatAnalysisResult {
    public let bpm: Double
    public let beatTimes: [CMTime]
    public let downbeatTimes: [CMTime]
    public let transientTimes: [CMTime]
    public let strongPeaks: [StrongPeakCandidate]
    public let adaptiveGrid: [AdaptiveGridSlot]
    public let duration: CMTime
    public let audioURL: URL

    public init(
        bpm: Double,
        beatTimes: [CMTime],
        downbeatTimes: [CMTime] = [],
        transientTimes: [CMTime],
        strongPeaks: [StrongPeakCandidate] = [],
        adaptiveGrid: [AdaptiveGridSlot] = [],
        duration: CMTime,
        audioURL: URL
    ) {
        self.bpm = bpm
        self.beatTimes = beatTimes
        self.downbeatTimes = downbeatTimes
        self.transientTimes = transientTimes
        self.strongPeaks = strongPeaks
        self.adaptiveGrid = adaptiveGrid
        self.duration = duration
        self.audioURL = audioURL
    }

    public func toSavedBeatAnalysis() -> SavedBeatAnalysis {
        SavedBeatAnalysis(
            bpm: bpm,
            beatSeconds: beatTimes.map { CMTimeGetSeconds($0) },
            downbeatSeconds: downbeatTimes.map { CMTimeGetSeconds($0) },
            transientSeconds: transientTimes.map { CMTimeGetSeconds($0) },
            strongPeaks: strongPeaks,
            adaptiveGrid: adaptiveGrid,
            durationSeconds: CMTimeGetSeconds(duration)
        )
    }

    /// Filtra i candidati ai picchi forti in base alla sensibilità [0.0 = Solo Clou, 1.0 = Frenetico / Alta Densità]
    /// applicando Non-Maximum Suppression decrescente per punteggio.
    public func selectStrongPeaks(sensitivity: Double) -> [Double] {
        Self.selectStrongPeaks(from: strongPeaks, sensitivity: sensitivity)
    }

    public static func selectStrongPeaks(from candidates: [StrongPeakCandidate], sensitivity: Double) -> [Double] {
        let s = max(0.0, min(1.0, sensitivity))
        let minStrength: Double
        let minSpacing: Double
        if s <= 0.45 {
            let t = s / 0.45
            minStrength = 0.50 - 0.16 * t  // 0.50 -> 0.34
            minSpacing = 4.2 - 1.75 * t    // 4.2s -> 2.45s
        } else {
            let t = (s - 0.45) / 0.55
            minStrength = 0.34 - 0.28 * t  // 0.34 -> 0.06
            minSpacing = 2.45 - 2.03 * t   // 2.45s -> 0.42s (~2+ tagli/s al 100%)
        }

        var picked: [Double] = []
        for cand in candidates.sorted(by: { $0.strength > $1.strength }) {
            guard cand.strength >= minStrength else { continue }
            if picked.allSatisfy({ abs($0 - cand.timeSeconds) >= minSpacing }) {
                picked.append(cand.timeSeconds)
            }
        }
        return picked.sorted()
    }

    /// Regia Adattiva: seleziona tagli su griglia beat/ottavi combinando andatura di battuta,
    /// contrasto locale (±4s) e raffiche/fill dinamici (fino a ~1+ taglio/sec ad alta densità).
    public func selectAdaptiveCuts(sensitivity: Double) -> [Double] {
        Self.selectAdaptiveCuts(from: adaptiveGrid, bpm: bpm, sensitivity: sensitivity)
    }

    public static func selectAdaptiveCuts(
        from grid: [AdaptiveGridSlot],
        bpm: Double,
        sensitivity: Double
    ) -> [Double] {
        guard !grid.isEmpty else { return [] }
        let s = max(0.0, min(1.0, sensitivity))
        let beatPeriod = 60.0 / max(40.0, bpm)
        let barDur = beatPeriod * 4.0

        let firstMinRatio = s >= 0.70 ? 0.90 : 1.15
        let firstIdx = grid.firstIndex(where: {
            $0.localRatio >= firstMinRatio && ($0.isDownbeat || $0.envJump >= (s >= 0.70 ? 1.25 : 1.50))
        }) ?? 0

        var cuts: [Double] = [grid[firstIdx].timeSeconds]

        let minNormalGap: Double
        let targetBarGap: Double
        let maxBarGap: Double
        if s <= 0.45 {
            let t = s / 0.45
            minNormalGap = (0.78 - 0.14 * t) * barDur          // 0.78 -> 0.64 bar
            targetBarGap = (1.35 - 0.40 * t) * barDur          // 1.35 -> 0.95 bar
            maxBarGap = (2.00 - 0.45 * t) * barDur             // 2.00 -> 1.55 bar
        } else {
            let t = (s - 0.45) / 0.55
            // Progressive compression from bar-level pacing (~1.9s) down to fast beat-level pacing (~0.45-0.85s)
            let highTarget = min(0.85, 1.05 * beatPeriod)
            let highMinGap = max(0.24, 0.72 * beatPeriod)
            let highMaxGap = max(0.85, 1.75 * beatPeriod)
            let baseMinGap = 0.64 * barDur
            let baseTarget = 0.95 * barDur
            let baseMaxGap = 1.55 * barDur
            let curve = pow(t, 1.15)
            minNormalGap = baseMinGap + (highMinGap - baseMinGap) * curve
            targetBarGap = baseTarget + (highTarget - baseTarget) * curve
            maxBarGap = baseMaxGap + (highMaxGap - baseMaxGap) * curve
        }

        let burstRatioThresh = 2.08 - 0.68 * s             // 2.08 -> 1.40
        let burstJumpThresh = 1.95 - 0.60 * s              // 1.95 -> 1.35
        let fillRatioThresh = 1.60 - 0.45 * s              // 1.60 -> 1.15
        let quietHighlightRatio = 3.2 - 1.3 * s            // 3.2 -> 1.9
        let burstStrengthFloor = 0.42 - 0.24 * s
        let maxBurstStreak = s >= 0.82 ? 24 : (s >= 0.62 ? 8 : 4)
        let minSubBeatDt = s >= 0.80 ? max(0.19, 0.38 * beatPeriod) : max(0.20, 0.42 * beatPeriod)

        var curIdx = firstIdx
        var burstStreak = 0
        var lastGap = targetBarGap

        while curIdx + 1 < grid.count {
            let tLast = cuts[cuts.count - 1]
            var chosenIdx: Int? = nil
            var wasBurst = false

            // 1. Scan early window [minBurstGap .. minNormalGap) for standout bursts or drum fills
            let burstLimitT = tLast + minNormalGap
            var j = curIdx + 1
            while j < grid.count && grid[j].timeSeconds < burstLimitT {
                let sl = grid[j]
                let dt = sl.timeSeconds - tLast
                if dt < minSubBeatDt {
                    j += 1
                    continue
                }

                let isQuietSection = sl.localRmsNorm < 0.35
                if isQuietSection {
                    if sl.localRatio >= quietHighlightRatio && sl.envJump >= (s >= 0.75 ? 1.8 : 2.5) && dt >= 0.85 * beatPeriod {
                        chosenIdx = j
                        wasBurst = true
                        break
                    }
                } else if dt < 0.72 * beatPeriod {
                    // 8th-note burst when continuing an active burst/fill or at ultra-dense sensitivity
                    let allowSubBeat = (burstStreak >= 1 || lastGap <= 1.25 * beatPeriod || s >= 0.88) && burstStreak < maxBurstStreak
                    if allowSubBeat && sl.localRatio >= fillRatioThresh && (sl.envJump >= 1.20 || sl.globalStrength >= 0.14) {
                        chosenIdx = j
                        wasBurst = true
                        break
                    }
                } else {
                    // Quarter-note or fast beat accent/hit
                    let isStrongBurst = (sl.localRatio >= burstRatioThresh && sl.envJump >= burstJumpThresh)
                        || (sl.globalStrength >= burstStrengthFloor && (sl.localRatio >= (s >= 0.75 ? 1.25 : 1.60) || sl.envJump >= (s >= 0.75 ? 1.60 : 2.20)) && sl.envJump >= 1.35)
                        || (s >= 0.90 && sl.isBeat && (sl.localRatio >= 1.15 || sl.envJump >= 1.25 || sl.globalStrength >= 0.10))
                    let blockedByRefractory = (burstStreak >= maxBurstStreak && dt < 1.25 * beatPeriod && sl.globalStrength < 0.50)
                    if isStrongBurst && !blockedByRefractory {
                        chosenIdx = j
                        wasBurst = true
                        break
                    }
                }
                j += 1
            }

            // 2. Otherwise pick strongest rhythmic anchor inside [minNormalGap .. maxBarGap]
            if chosenIdx == nil {
                var bestIdx: Int? = nil
                var bestScore = -Double.greatestFiniteMagnitude
                var k = j
                while k < grid.count && grid[k].timeSeconds <= tLast + maxBarGap {
                    let sl = grid[k]
                    let dt = sl.timeSeconds - tLast
                    if dt < minSubBeatDt {
                        k += 1
                        continue
                    }
                    let distFromBar = abs(dt - barDur) / max(0.3, barDur)
                    let distFromTarget = abs(dt - targetBarGap) / max(0.25, targetBarGap)

                    var paceScore = 1.25 - 1.15 * min(1.5, distFromTarget)
                    if s < 0.70 {
                        paceScore += max(0.0, 0.35 - 0.8 * distFromBar)
                    }

                    let isQuiet = sl.localRmsNorm < 0.35
                    let gridBonus: Double
                    if sl.isDownbeat {
                        gridBonus = isQuiet ? 0.85 : 0.38
                    } else if sl.isBeat {
                        gridBonus = s >= 0.75 ? 0.36 : (isQuiet ? 0.10 : 0.24)
                    } else {
                        gridBonus = (sl.localRatio >= (s >= 0.75 ? 1.45 : 1.85) && sl.envJump >= (s >= 0.75 ? 1.40 : 1.80)) ? 0.22 : -0.45
                    }

                    let prominence = (isQuiet ? 0.25 : 0.75) * min(1.6, sl.localRatio * 0.55 + sl.globalStrength)
                    let jumpBonus = 0.25 * min(1.5, max(0.0, sl.envJump - 1.0))
                    let total = paceScore + gridBonus + prominence + jumpBonus
                    if total > bestScore {
                        bestScore = total
                        bestIdx = k
                    }
                    k += 1
                }
                if bestIdx == nil && j < grid.count {
                    // Safety net at 100% density: advance to next rhythmic slot instead of stalling
                    bestIdx = j
                }
                chosenIdx = bestIdx
                wasBurst = false
            }

            guard let nextIdx = chosenIdx else { break }
            let nextTime = grid[nextIdx].timeSeconds
            lastGap = nextTime - tLast
            burstStreak = wasBurst ? (burstStreak + 1) : 0
            cuts.append(nextTime)
            curIdx = nextIdx
        }

        return cuts
    }
}

public final class AudioBeatDetector {
    public static let shared = AudioBeatDetector()

    // Beat This! preprocessing & inference constants
    private let sampleRate: Double = 22050.0
    private let nFFT: Int = 1024
    private let hopLength: Int = 441        // 22050 / 441 = 50.0 fps exact
    private let fps: Double = 50.0
    private let nMels: Int = 128
    private let freqBins: Int = 513         // nFFT / 2 + 1
    private let chunkSize: Int = 1500       // 30.0s per chunk at 50 fps
    private let borderSize: Int = 6
    private let minCoreMLFrames: Int = 32   // Matches CoreML RangeDim(32, 1500)

    private let modelLock = NSLock()
    private var cachedModel: MLModel?
    private var cachedHannWindow: [Float]?
    private var cachedMelFilterbank: [Float]?

    public init() {}

    /// Analizza una traccia audio o video alla ricerca di BPM, battiti (beat), downbeat e accenti
    /// usando il modello neurale `Beat This!` (`final0`) via CoreML, con fallback spettrale in caso di assenza risorse.
    public func analyze(
        url: URL,
        timeRange: CMTimeRange? = nil
    ) async throws -> BeatAnalysisResult {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw NSError(
                domain: "VisionBeatDetector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nessuna traccia audio trovata nel file."]
            )
        }

        let assetDuration = try await asset.load(.duration)
        let actualRange = timeRange ?? CMTimeRange(start: .zero, duration: assetDuration)
        let pcmSamples = try readMonoFloatSamples(asset: asset, track: audioTrack, timeRange: actualRange)

        guard !pcmSamples.isEmpty else {
            throw NSError(
                domain: "VisionBeatDetector",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Campioni audio vuoti o non decodificabili."]
            )
        }

        let (logMel, nFrames) = computeLogMelSpectrogram(samples: pcmSamples)

        var beatSeconds: [Double] = []
        var downbeatSeconds: [Double] = []

        if let model = loadBeatThisModel(), nFrames > 0 {
            do {
                let (beatLogits, downbeatLogits) = try predictWithBeatThis(
                    model: model,
                    logMel: logMel,
                    nFrames: nFrames
                )
                (beatSeconds, downbeatSeconds) = postprocessMinimal(
                    beatLogits: beatLogits,
                    downbeatLogits: downbeatLogits
                )
                DebugLogger.shared.log(
                    "BeatThis CoreML: \(beatSeconds.count) beat, \(downbeatSeconds.count) downbeat su \(nFrames) frame.",
                    level: .info
                )
            } catch {
                DebugLogger.shared.log(
                    "BeatThis CoreML errore (\(error.localizedDescription)); uso fallback spettrale.",
                    level: .warning
                )
            }
        } else {
            DebugLogger.shared.log("Modello CoreML BeatThis_final0 non trovato; uso analisi spettrale fallback.", level: .warning)
        }

        let frameRMS = computeFrameRMS(samples: pcmSamples, nFrames: nFrames)
        let strongPeakCandidates = detectStrongPeaks(
            frameRMS: frameRMS,
            logMel: logMel,
            nFrames: nFrames,
            beatSeconds: beatSeconds,
            downbeatSeconds: downbeatSeconds
        )
        let defaultStrongTimes = BeatAnalysisResult.selectStrongPeaks(from: strongPeakCandidates, sensitivity: 0.45)

        let detectedBPM: Double
        if beatSeconds.count >= 2 {
            detectedBPM = estimateBPM(fromBeatTimes: beatSeconds)
        } else {
            let fallbackBPM = estimateFallbackBPM(transientSeconds: defaultStrongTimes)
            detectedBPM = fallbackBPM
            if beatSeconds.isEmpty {
                let interval = 60.0 / max(40.0, fallbackBPM)
                var t = defaultStrongTimes.first ?? 0.0
                while t - interval >= 0 { t -= interval }
                let dur = CMTimeGetSeconds(actualRange.duration)
                while t <= dur {
                    beatSeconds.append(t)
                    t += interval
                }
            }
        }

        let adaptiveGridSlots = buildAdaptiveGrid(
            frameRMS: frameRMS,
            beatSeconds: beatSeconds,
            downbeatSeconds: downbeatSeconds,
            strongPeaks: strongPeakCandidates,
            bpm: detectedBPM
        )

        let beatTimes = beatSeconds.map { CMTime(seconds: $0, preferredTimescale: 600) }
        let downbeatTimes = downbeatSeconds.map { CMTime(seconds: $0, preferredTimescale: 600) }
        let transientTimes = defaultStrongTimes.map { CMTime(seconds: $0, preferredTimescale: 600) }

        return BeatAnalysisResult(
            bpm: detectedBPM,
            beatTimes: beatTimes,
            downbeatTimes: downbeatTimes,
            transientTimes: transientTimes,
            strongPeaks: strongPeakCandidates,
            adaptiveGrid: adaptiveGridSlots,
            duration: actualRange.duration,
            audioURL: url
        )
    }

    // MARK: - Audio Decoding

    private func readMonoFloatSamples(
        asset: AVURLAsset,
        track: AVAssetTrack,
        timeRange: CMTimeRange
    ) throws -> [Float] {
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "VisionBeatDetector",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Impossibile avviare la lettura audio."]
            )
        }

        var pcmSamples: [Float] = []
        let expectedSamples = max(0, Int(CMTimeGetSeconds(timeRange.duration) * sampleRate))
        pcmSamples.reserveCapacity(expectedSamples)

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard status == noErr, let rawData = dataPointer, length >= MemoryLayout<Float>.size else { continue }
            let count = length / MemoryLayout<Float>.size
            rawData.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
                pcmSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
            }
        }

        return pcmSamples
    }

    // MARK: - Resources & Model Loading

    private func findModelResourceURL(name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Models") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        let fm = FileManager.default
        let cwdCandidate = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("Resources/Models/\(name).\(ext)")
        if fm.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }
        return nil
    }

    private func loadBeatThisModel() -> MLModel? {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cached = cachedModel { return cached }

        let config = MLModelConfiguration()
        config.computeUnits = .all

        if let compiledURL = findModelResourceURL(name: "BeatThis_final0", ext: "mlmodelc") {
            if let model = try? MLModel(contentsOf: compiledURL, configuration: config) {
                cachedModel = model
                return model
            }
        }

        if let packageURL = findModelResourceURL(name: "BeatThis_final0", ext: "mlpackage") {
            if let tempCompiled = try? MLModel.compileModel(at: packageURL),
               let model = try? MLModel(contentsOf: tempCompiled, configuration: config) {
                cachedModel = model
                return model
            }
        }

        return nil
    }

    private func loadHannWindow() -> [Float] {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cached = cachedHannWindow { return cached }

        if let url = findModelResourceURL(name: "hann_1024", ext: "bin"),
           let data = try? Data(contentsOf: url),
           data.count == nFFT * MemoryLayout<Float>.size {
            let win = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            cachedHannWindow = win
            return win
        }

        // Programmatic periodic Hann window fallback
        var win = [Float](repeating: 0, count: nFFT)
        for i in 0..<nFFT {
            win[i] = 0.5 * (1.0 - cosf(2.0 * .pi * Float(i) / Float(nFFT)))
        }
        cachedHannWindow = win
        return win
    }

    private func loadMelFilterbank() -> [Float] {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cached = cachedMelFilterbank { return cached }

        let expectedBytes = freqBins * nMels * MemoryLayout<Float>.size
        if let url = findModelResourceURL(name: "mel_fb_513x128", ext: "bin"),
           let data = try? Data(contentsOf: url),
           data.count == expectedBytes {
            let fb = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            cachedMelFilterbank = fb
            return fb
        }

        let fb = buildSlaneyMelFilterbank()
        cachedMelFilterbank = fb
        return fb
    }

    private func buildSlaneyMelFilterbank() -> [Float] {
        func hzToMelSlaney(_ f: Double) -> Double {
            let fSp = 200.0 / 3.0
            let minLogHz = 1000.0
            let minLogMel = minLogHz / fSp
            let logStep = log(6.4) / 27.0
            return f >= minLogHz ? (minLogMel + log(f / minLogHz) / logStep) : (f / fSp)
        }
        func melToHzSlaney(_ m: Double) -> Double {
            let fSp = 200.0 / 3.0
            let minLogHz = 1000.0
            let minLogMel = minLogHz / fSp
            let logStep = log(6.4) / 27.0
            return m >= minLogMel ? (minLogHz * exp(logStep * (m - minLogMel))) : (fSp * m)
        }

        let melMin = hzToMelSlaney(30.0)
        let melMax = hzToMelSlaney(11000.0)
        let mPts = (0..<(nMels + 2)).map { i in
            melToHzSlaney(melMin + Double(i) * (melMax - melMin) / Double(nMels + 1))
        }
        let allFreqs = (0..<freqBins).map { Double($0) * (sampleRate / Double(nFFT)) }
        var fb = [Float](repeating: 0, count: freqBins * nMels)

        for m in 0..<nMels {
            let fLeft = mPts[m]
            let fCenter = mPts[m + 1]
            let fRight = mPts[m + 2]
            let enorm = 2.0 / max(1e-9, fRight - fLeft)
            for k in 0..<freqBins {
                let f = allFreqs[k]
                let lower = (f - fLeft) / max(1e-9, fCenter - fLeft)
                let upper = (fRight - f) / max(1e-9, fRight - fCenter)
                let w = max(0.0, min(lower, upper)) * enorm
                fb[k * nMels + m] = Float(w)
            }
        }
        return fb
    }

    // MARK: - Accelerate Log-Mel Spectrogram (matches torchaudio LogMelSpect)

    private func reflectIndex(_ idx: Int, count: Int) -> Int {
        if count <= 1 { return 0 }
        var i = idx
        while i < 0 || i >= count {
            if i < 0 { i = -i }
            if i >= count { i = 2 * count - 2 - i }
        }
        return i
    }

    private func computeLogMelSpectrogram(samples: [Float]) -> (logMel: [Float], nFrames: Int) {
        let pad = nFFT / 2 // 512, matching center=True, pad_mode="reflect"
        let totalPadded = samples.count + 2 * pad
        guard totalPadded >= nFFT else { return ([], 0) }

        var padded = [Float](repeating: 0, count: totalPadded)
        for i in 0..<pad {
            padded[i] = samples[reflectIndex(i - pad, count: samples.count)]
        }
        padded.replaceSubrange(pad..<(pad + samples.count), with: samples)
        for i in 0..<pad {
            padded[pad + samples.count + i] = samples[reflectIndex(samples.count + i, count: samples.count)]
        }

        let nFrames = 1 + (totalPadded - nFFT) / hopLength
        guard nFrames > 0 else { return ([], 0) }

        let hann = loadHannWindow()
        let melFB = loadMelFilterbank() // row-major (513 x 128)
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(10), FFTRadix(kFFTRadix2)) else {
            return ([], 0)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var specs = [Float](repeating: 0, count: nFrames * freqBins)
        var windowed = [Float](repeating: 0, count: nFFT)
        var realBuf = [Float](repeating: 0, count: nFFT / 2)
        var imagBuf = [Float](repeating: 0, count: nFFT / 2)
        let normDivisor: Float = 2.0 * sqrtf(Float(nFFT)) // vDSP 2x factor * sqrt(n_fft) frame_length norm

        realBuf.withUnsafeMutableBufferPointer { rPtr in
            imagBuf.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)

                padded.withUnsafeBufferPointer { padPtr in
                    hann.withUnsafeBufferPointer { winPtr in
                        windowed.withUnsafeMutableBufferPointer { wPtr in
                            specs.withUnsafeMutableBufferPointer { specPtr in
                                for f in 0..<nFrames {
                                    let framePtr = padPtr.baseAddress! + f * hopLength
                                    vDSP_vmul(framePtr, 1, winPtr.baseAddress!, 1, wPtr.baseAddress!, 1, vDSP_Length(nFFT))

                                    wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { cPtr in
                                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(nFFT / 2))
                                    }

                                    vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(10), FFTDirection(FFT_FORWARD))

                                    let outRow = specPtr.baseAddress! + f * freqBins
                                    outRow[0] = fabsf(rPtr[0]) / normDivisor
                                    vDSP_vdist(rPtr.baseAddress! + 1, 1, iPtr.baseAddress! + 1, 1, outRow + 1, 1, vDSP_Length(nFFT / 2 - 1))
                                    var invScale: Float = 1.0 / normDivisor
                                    vDSP_vsmul(outRow + 1, 1, &invScale, outRow + 1, 1, vDSP_Length(nFFT / 2 - 1))
                                    outRow[nFFT / 2] = fabsf(iPtr[0]) / normDivisor
                                }
                            }
                        }
                    }
                }
            }
        }

        // Matrix multiply: specs (nFrames x 513) * melFB (513 x 128) -> melSpect (nFrames x 128)
        var melSpect = [Float](repeating: 0, count: nFrames * nMels)
        vDSP_mmul(
            specs, 1,
            melFB, 1,
            &melSpect, 1,
            vDSP_Length(nFrames),
            vDSP_Length(nMels),
            vDSP_Length(freqBins)
        )

        // log1p(1000 * x)
        var logMult: Float = 1000.0
        let totalElements = nFrames * nMels
        vDSP_vsmul(melSpect, 1, &logMult, &melSpect, 1, vDSP_Length(totalElements))
        var logMel = [Float](repeating: 0, count: totalElements)
        var n32 = Int32(totalElements)
        vvlog1pf(&logMel, &melSpect, &n32)

        return (logMel, nFrames)
    }

    // MARK: - CoreML Chunked Inference (matches split_predict_aggregate)

    private func predictWithBeatThis(
        model: MLModel,
        logMel: [Float],
        nFrames: Int
    ) throws -> (beatLogits: [Float], downbeatLogits: [Float]) {
        let stride = chunkSize - 2 * borderSize // 1488
        var starts: [Int] = []
        var s = -borderSize
        while s < nFrames - borderSize {
            starts.append(s)
            s += stride
        }
        if nFrames > stride, !starts.isEmpty {
            starts[starts.count - 1] = nFrames - (chunkSize - borderSize)
        }
        if starts.isEmpty {
            starts = [-borderSize]
        }

        var fullBeat = [Float](repeating: -1000.0, count: nFrames)
        var fullDownbeat = [Float](repeating: -1000.0, count: nFrames)

        // overlap_mode = "keep_first": process in reverse order so earlier chunks win on overlaps
        for start in starts.reversed() {
            let validStart = max(start, 0)
            let validEnd = min(start + chunkSize, nFrames)
            let leftPad = max(0, -start)
            let rightPad = max(0, min(borderSize, start + chunkSize - nFrames))
            let unpaddedChunkLen = leftPad + max(0, validEnd - validStart) + rightPad
            let modelInputLen = min(chunkSize, max(minCoreMLFrames, unpaddedChunkLen))

            let inputArray = try makeInputMultiArray(
                logMel: logMel,
                nFrames: nFrames,
                validStart: validStart,
                validEnd: validEnd,
                leftPad: leftPad,
                chunkLen: modelInputLen
            )
            let provider = try MLDictionaryFeatureProvider(dictionary: ["spect": MLFeatureValue(multiArray: inputArray)])
            let output = try model.prediction(from: provider)

            guard let beatArr = output.featureValue(for: "beat")?.multiArrayValue,
                  let downbeatArr = output.featureValue(for: "downbeat")?.multiArrayValue else {
                throw NSError(
                    domain: "VisionBeatDetector",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Output BeatThis non valido."]
                )
            }

            let outBeat = extractFloatVector(from: beatArr, length: unpaddedChunkLen)
            let outDownbeat = extractFloatVector(from: downbeatArr, length: unpaddedChunkLen)

            let innerCount = unpaddedChunkLen - 2 * borderSize
            guard innerCount > 0 else { continue }

            for localIdx in 0..<innerCount {
                let globalIdx = start + borderSize + localIdx
                if globalIdx >= 0 && globalIdx < nFrames {
                    fullBeat[globalIdx] = outBeat[borderSize + localIdx]
                    fullDownbeat[globalIdx] = outDownbeat[borderSize + localIdx]
                }
            }
        }

        return (fullBeat, fullDownbeat)
    }

    private func makeInputMultiArray(
        logMel: [Float],
        nFrames: Int,
        validStart: Int,
        validEnd: Int,
        leftPad: Int,
        chunkLen: Int
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: chunkLen), NSNumber(value: nMels)], dataType: .float32)
        let rowStride = array.strides[1].intValue
        let colStride = array.strides[2].intValue
        let dst = array.dataPointer.assumingMemoryBound(to: Float.self)

        // Zero-initialize entire buffer cleanly (handles leftPad, rightPad, and minCoreMLFrames tail)
        let totalAllocated = chunkLen * rowStride
        if colStride == 1 {
            memset(dst, 0, totalAllocated * MemoryLayout<Float>.size)
        } else {
            for r in 0..<chunkLen {
                for c in 0..<nMels {
                    dst[r * rowStride + c * colStride] = 0
                }
            }
        }

        let copyFrames = max(0, min(nFrames, validEnd) - validStart)
        if copyFrames > 0 {
            logMel.withUnsafeBufferPointer { srcPtr in
                let srcBase = srcPtr.baseAddress!
                if rowStride == nMels && colStride == 1 {
                    let srcOffset = validStart * nMels
                    let dstOffset = leftPad * nMels
                    memcpy(dst + dstOffset, srcBase + srcOffset, copyFrames * nMels * MemoryLayout<Float>.size)
                } else {
                    for f in 0..<copyFrames {
                        let sRow = (validStart + f) * nMels
                        let dRow = (leftPad + f) * rowStride
                        for m in 0..<nMels {
                            dst[dRow + m * colStride] = srcBase[sRow + m]
                        }
                    }
                }
            }
        }
        return array
    }

    private func extractFloatVector(from multiArray: MLMultiArray, length: Int) -> [Float] {
        var result = [Float](repeating: 0, count: max(0, length))
        let count = min(length, multiArray.shape.last?.intValue ?? length)
        let stride = multiArray.strides.last?.intValue ?? 1

        switch multiArray.dataType {
        case .float32:
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
            if stride == 1 {
                _ = result.withUnsafeMutableBufferPointer { dst in
                    memcpy(dst.baseAddress!, ptr, count * MemoryLayout<Float>.size)
                }
            } else {
                for i in 0..<count { result[i] = ptr[i * stride] }
            }
        case .float16:
            let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0..<count { result[i] = Float(ptr[i * stride]) }
        default:
            for i in 0..<count { result[i] = multiArray[i].floatValue }
        }
        return result
    }

    // MARK: - Beat This! Minimal Postprocessor (matches Postprocessor(type="minimal", fps=50))

    private func postprocessMinimal(
        beatLogits: [Float],
        downbeatLogits: [Float]
    ) -> (beats: [Double], downbeats: [Double]) {
        let beatPeakFrames = extractPeakFrames(logits: beatLogits, minSpacingFrames: 11)     // >= 0.22s
        let downbeatPeakFrames = extractPeakFrames(logits: downbeatLogits, minSpacingFrames: 25) // >= 0.50s

        let beats = beatPeakFrames.map { $0 / fps }
        var downbeats = downbeatPeakFrames.map { $0 / fps }

        if !beats.isEmpty && !downbeats.isEmpty {
            var snapped: [Double] = []
            snapped.reserveCapacity(downbeats.count)
            for db in downbeats {
                var bestBeat = beats[0]
                var bestDist = abs(db - bestBeat)
                for b in beats {
                    let d = abs(db - b)
                    if d < bestDist {
                        bestDist = d
                        bestBeat = b
                    }
                }
                if bestDist <= 0.14 {
                    if let prev = snapped.last {
                        if abs(bestBeat - prev) >= 0.45 && !snapped.contains(bestBeat) {
                            snapped.append(bestBeat)
                        }
                    } else {
                        snapped.append(bestBeat)
                    }
                }
            }
            downbeats = snapped.sorted()
        }

        return (beats, downbeats)
    }

    private func extractPeakFrames(logits: [Float], minSpacingFrames: Int) -> [Double] {
        let n = logits.count
        guard n > 0 else { return [] }

        // Matches F.max_pool1d(logits, kernel_size=7, stride=1, padding=3) & logit > 0.0
        var rawPeaks: [Int] = []
        for i in 0..<n {
            let val = logits[i]
            guard val > 0.0 else { continue }
            let lo = max(0, i - 3)
            let hi = min(n - 1, i + 3)
            var isMax = true
            for k in lo...hi {
                if logits[k] > val {
                    isMax = false
                    break
                }
            }
            if isMax {
                rawPeaks.append(i)
            }
        }

        let deduped = deduplicatePeaks(rawPeaks, width: 1.0)
        guard minSpacingFrames > 1 else { return deduped }

        // Keep highest-logit peak within minSpacingFrames
        var picked: [Double] = []
        let byStrength = deduped.sorted { a, b in
            let ia = min(n - 1, max(0, Int(a.rounded())))
            let ib = min(n - 1, max(0, Int(b.rounded())))
            return logits[ia] > logits[ib]
        }
        for p in byStrength {
            if picked.allSatisfy({ abs($0 - p) >= Double(minSpacingFrames) }) {
                picked.append(p)
            }
        }
        return picked.sorted()
    }

    private func deduplicatePeaks(_ peaks: [Int], width: Double) -> [Double] {
        guard let first = peaks.first else { return [] }
        var result: [Double] = []
        var p = Double(first)
        var c = 1.0
        for idx in peaks.dropFirst() {
            let p2 = Double(idx)
            if p2 - p <= width {
                c += 1.0
                p += (p2 - p) / c
            } else {
                result.append(p)
                p = p2
                c = 1.0
            }
        }
        result.append(p)
        return result
    }

    // MARK: - BPM & Spectral Onset Helpers

    private func estimateBPM(fromBeatTimes beats: [Double]) -> Double {
        guard beats.count >= 2 else { return 120.0 }
        var intervals: [Double] = []
        intervals.reserveCapacity(beats.count - 1)
        for i in 0..<(beats.count - 1) {
            let dt = beats[i + 1] - beats[i]
            if dt >= 0.25 && dt <= 1.50 { // 40..240 BPM
                intervals.append(dt)
            }
        }
        guard !intervals.isEmpty else { return 120.0 }

        // Find dominant interval cluster so isolated double/missed beats don't skew BPM
        let sorted = intervals.sorted()
        let coarseMedian = sorted[sorted.count / 2]
        let clustered = sorted.filter { abs($0 - coarseMedian) / coarseMedian <= 0.08 }
        let clean = clustered.isEmpty ? sorted : clustered
        let avgInterval = clean.reduce(0.0, +) / Double(clean.count)
        let bpm = 60.0 / max(0.20, avgInterval)
        return (bpm * 10.0).rounded() / 10.0
    }

    // MARK: - Hybrid Strong Peak / Impact Detector (Macro Energy + Multi-Band Punch + Neural Snap)

    private func computeFrameRMS(samples: [Float], nFrames: Int) -> [Double] {
        guard nFrames > 0, !samples.isEmpty else { return [] }
        var rms = [Double](repeating: 0.0, count: nFrames)
        let winLen = min(nFFT, samples.count)
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for f in 0..<nFrames {
                let start = min(max(0, f * hopLength - nFFT / 2), samples.count - winLen)
                var ms: Float = 0.0
                vDSP_measqv(base + start, 1, &ms, vDSP_Length(winLen))
                rms[f] = sqrt(Double(max(0.0, ms)))
            }
        }
        return rms
    }

    private func detectStrongPeaks(
        frameRMS: [Double],
        logMel: [Float],
        nFrames: Int,
        beatSeconds: [Double],
        downbeatSeconds: [Double]
    ) -> [StrongPeakCandidate] {
        guard nFrames >= 12, frameRMS.count >= nFrames else { return [] }

        let sortedRms = frameRMS.sorted()
        let p90Rms = max(1e-5, sortedRms[min(sortedRms.count - 1, Int(Double(sortedRms.count) * 0.90))])
        let normRms = frameRMS.map { min(1.8, $0 / p90Rms) }

        // 2. Multi-band Mel profiles from precomputed logMel (128 Mel bins: low 0..<26, mid 26..<82, high 82..<128)
        var lowBand = [Double](repeating: 0.0, count: nFrames)
        var midBand = [Double](repeating: 0.0, count: nFrames)
        var highBand = [Double](repeating: 0.0, count: nFrames)

        for f in 0..<nFrames {
            let base = f * nMels
            var lo = 0.0, mi = 0.0, hi = 0.0
            for m in 0..<26 { lo += Double(logMel[base + m]) }
            for m in 26..<82 { mi += Double(logMel[base + m]) }
            for m in 82..<nMels { hi += Double(logMel[base + m]) }
            lowBand[f] = lo / 26.0
            midBand[f] = mi / 56.0
            highBand[f] = hi / Double(nMels - 82)
        }

        // 3. Broadband positive impact weighted by kick+crash punch and dynamic loudness
        var impact = [Double](repeating: 0.0, count: nFrames)
        for f in 1..<nFrames {
            let dl = max(0.0, lowBand[f] - lowBand[f - 1])
            let dm = max(0.0, midBand[f] - midBand[f - 1])
            let dh = max(0.0, highBand[f] - highBand[f - 1])
            let punch = 0.42 * dl + 0.43 * dh + 0.15 * dm
            impact[f] = punch * (0.25 + 0.75 * normRms[f])
        }

        // Prefix sums for O(nFrames) macro context evaluation
        var pRms = [Double](repeating: 0.0, count: nFrames + 1)
        var pImp = [Double](repeating: 0.0, count: nFrames + 1)
        var pImpSq = [Double](repeating: 0.0, count: nFrames + 1)
        var pLo = [Double](repeating: 0.0, count: nFrames + 1)
        var pMid = [Double](repeating: 0.0, count: nFrames + 1)
        var pHi = [Double](repeating: 0.0, count: nFrames + 1)
        for i in 0..<nFrames {
            pRms[i + 1] = pRms[i] + normRms[i]
            pImp[i + 1] = pImp[i] + impact[i]
            pImpSq[i + 1] = pImpSq[i] + impact[i] * impact[i]
            pLo[i + 1] = pLo[i] + lowBand[i]
            pMid[i + 1] = pMid[i] + midBand[i]
            pHi[i + 1] = pHi[i] + highBand[i]
        }

        var score = [Double](repeating: 0.0, count: nFrames)
        let wImp = 100   // ±2.0s Z-score window
        let preWin = 150 // 3.0s lookback
        let postWin = 60 // 1.2s sustain lookahead
        let novWin = 75  // 1.5s timbral contrast window

        for f in 5..<(nFrames - 5) {
            // A. Standout transient impact vs ±2.0s context
            let lo = max(0, f - wImp)
            let hi = min(nFrames - 1, f + wImp)
            let cnt = Double(hi - lo + 1)
            let mean = (pImp[hi + 1] - pImp[lo]) / cnt
            let meanSq = (pImpSq[hi + 1] - pImpSq[lo]) / cnt
            let std = sqrt(max(1e-8, meanSq - mean * mean))
            let localImp = max(impact[f], 0.8 * max(impact[f - 1], impact[f + 1]))
            let zImp = max(0.0, (localImp - mean) / max(0.015, std))

            // B. Macro loudness surge (step-up over preceding 3s into following 1.2s)
            let p0 = max(0, f - preWin)
            let p1 = max(p0 + 1, f - 4)
            let q1 = min(nFrames, f + postWin)
            let instEnd = min(nFrames, f + 4)
            let preRms = (pRms[p1] - pRms[p0]) / Double(p1 - p0)
            let postRms = (pRms[q1] - pRms[f]) / Double(max(1, q1 - f))
            let instRms = (pRms[instEnd] - pRms[f]) / Double(max(1, instEnd - f))
            let lift = max(0.0, min(postRms, instRms * 1.15) - preRms) / max(0.18, preRms + 0.12)

            // C. Timbral/arrangement change (drum/chorus entry across 1.5s before vs after)
            let n0 = max(0, f - novWin)
            let n1 = min(nFrames, f + novWin)
            let cBefore = Double(max(1, f - n0))
            let cAfter = Double(max(1, n1 - f))
            let dLo = ((pLo[n1] - pLo[f]) / cAfter) - ((pLo[f] - pLo[n0]) / cBefore)
            let dMid = ((pMid[n1] - pMid[f]) / cAfter) - ((pMid[f] - pMid[n0]) / cBefore)
            let dHi = ((pHi[n1] - pHi[f]) / cAfter) - ((pHi[f] - pHi[n0]) / cBefore)
            let novelty = max(0.0, 0.45 * max(0.0, dLo) + 0.35 * max(0.0, dHi) + 0.20 * abs(dMid))

            let energyFloor = min(1.0, max(0.25, normRms[f] * 1.1))
            let combined = energyFloor * (
                0.35 * min(zImp / 2.2, 2.0) +
                0.45 * min(lift * 1.6, 2.0) +
                0.20 * min(novelty * 1.2, 1.5)
            )

            // Boost score on neural beats & downbeats from Beat This!
            let t = Double(f) / fps
            var beatBoost = 1.0
            if let dbDist = minDistance(inSorted: downbeatSeconds, to: t), dbDist <= 0.10 {
                beatBoost = 1.35
            } else if let bDist = minDistance(inSorted: beatSeconds, to: t), bDist <= 0.08 {
                beatBoost = 1.18
            }
            score[f] = combined * beatBoost
        }

        // Local maxima (+/- 120ms), snapped onto nearest neural beat/downbeat within 100ms
        var rawCandidates: [(time: Double, score: Double)] = []
        for f in 6..<(nFrames - 6) {
            let s = score[f]
            guard s > 0.06 else { continue }
            var isMax = true
            for k in (f - 6)...(f + 6) where k != f {
                if score[k] > s {
                    isMax = false
                    break
                }
            }
            if isMax {
                var t = Double(f) / fps
                if let bestDb = nearestValue(inSorted: downbeatSeconds, to: t, maxDistance: 0.10) {
                    t = bestDb
                } else if let bestB = nearestValue(inSorted: beatSeconds, to: t, maxDistance: 0.09) {
                    t = bestB
                }
                rawCandidates.append((t, s))
            }
        }

        // Merge any candidates that snapped to the exact same beat timestamp
        var mergedByTime: [Double: Double] = [:]
        for c in rawCandidates {
            let bucket = (c.time * 100.0).rounded() / 100.0
            mergedByTime[bucket] = max(mergedByTime[bucket] ?? 0.0, c.score)
        }

        let sortedValues = mergedByTime.values.sorted()
        let refMax = max(1e-5, sortedValues.last ?? 1.0)

        return mergedByTime
            .map { StrongPeakCandidate(timeSeconds: $0.key, strength: min(1.0, $0.value / refMax)) }
            .sorted { $0.timeSeconds < $1.timeSeconds }
    }

    private func buildAdaptiveGrid(
        frameRMS: [Double],
        beatSeconds: [Double],
        downbeatSeconds: [Double],
        strongPeaks: [StrongPeakCandidate],
        bpm: Double
    ) -> [AdaptiveGridSlot] {
        guard !frameRMS.isEmpty, !beatSeconds.isEmpty else { return [] }

        let n = frameRMS.count
        var prefixRMS = [Double](repeating: 0.0, count: n + 1)
        for i in 0..<n {
            prefixRMS[i + 1] = prefixRMS[i] + frameRMS[i]
        }

        let sortedRms = frameRMS.sorted()
        let p90Rms = max(1e-5, sortedRms[min(sortedRms.count - 1, Int(Double(sortedRms.count) * 0.90))])
        let silenceFloor = max(1e-4, p90Rms * 0.05)

        func maxRMS(from t0: Double, to t1: Double) -> Double {
            let i0 = max(0, min(n - 1, Int((t0 * fps).rounded(.down))))
            let i1 = max(i0, min(n - 1, Int((t1 * fps).rounded(.up))))
            var m = 0.0
            for idx in i0...i1 where frameRMS[idx] > m {
                m = frameRMS[idx]
            }
            return m
        }

        func meanRMS(from t0: Double, to t1: Double) -> Double {
            let i0 = max(0, min(n - 1, Int((t0 * fps).rounded(.down))))
            let i1 = max(i0, min(n - 1, Int((t1 * fps).rounded(.up))))
            let count = max(1, (i1 - i0 + 1))
            return (prefixRMS[i1 + 1] - prefixRMS[i0]) / Double(count)
        }

        let beatPeriod = 60.0 / max(40.0, bpm)
        var rawGrid: [(t: Double, isBeat: Bool, isDb: Bool)] = []
        rawGrid.reserveCapacity(beatSeconds.count * 2)

        for i in 0..<beatSeconds.count {
            let b = beatSeconds[i]
            let isDb = (minDistance(inSorted: downbeatSeconds, to: b) ?? .infinity) <= 0.06
            rawGrid.append((b, true, isDb))
            if i + 1 < beatSeconds.count {
                let bNext = beatSeconds[i + 1]
                let dt = bNext - b
                if dt >= 0.55 * beatPeriod && dt <= 1.55 * beatPeriod {
                    rawGrid.append((0.5 * (b + bNext), false, false))
                }
            }
        }

        var slots: [AdaptiveGridSlot] = []
        slots.reserveCapacity(rawGrid.count)
        var spLeft = 0

        for g in rawGrid {
            let cur = maxRMS(from: g.t - 0.04, to: g.t + 0.08)
            let pre = meanRMS(from: g.t - 0.24, to: g.t - 0.06)
            let ctx = meanRMS(from: g.t - 4.0, to: g.t + 4.0)

            while spLeft < strongPeaks.count && strongPeaks[spLeft].timeSeconds < g.t - 0.11 {
                spLeft += 1
            }
            var maxSP = 0.0
            var scan = spLeft
            while scan < strongPeaks.count && strongPeaks[scan].timeSeconds <= g.t + 0.11 {
                if strongPeaks[scan].strength > maxSP {
                    maxSP = strongPeaks[scan].strength
                }
                scan += 1
            }

            slots.append(AdaptiveGridSlot(
                timeSeconds: g.t,
                isBeat: g.isBeat,
                isDownbeat: g.isDb,
                globalStrength: maxSP,
                envJump: cur / max(silenceFloor, pre),
                localRatio: cur / max(silenceFloor, ctx),
                localRmsNorm: min(1.5, ctx / p90Rms)
            ))
        }
        return slots
    }

    private func minDistance(inSorted array: [Double], to target: Double) -> Double? {
        guard let nearest = nearestValue(inSorted: array, to: target, maxDistance: .infinity) else { return nil }
        return abs(nearest - target)
    }

    private func nearestValue(inSorted array: [Double], to target: Double, maxDistance: Double) -> Double? {
        guard !array.isEmpty else { return nil }
        var lo = 0
        var hi = array.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid] < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var best = array[lo]
        var bestDist = abs(best - target)
        if lo > 0 {
            let prev = array[lo - 1]
            let prevDist = abs(prev - target)
            if prevDist < bestDist {
                best = prev
                bestDist = prevDist
            }
        }
        return bestDist <= maxDistance ? best : nil
    }

    private func estimateFallbackBPM(transientSeconds: [Double]) -> Double {
        guard transientSeconds.count >= 2 else { return 120.0 }
        var hist: [Int: Int] = [:]
        for i in 0..<(transientSeconds.count - 1) {
            for j in (i + 1)..<min(i + 5, transientSeconds.count) {
                let dt = transientSeconds[j] - transientSeconds[i]
                if dt >= 0.30 && dt <= 1.00 {
                    hist[Int((dt * 200.0).rounded()), default: 0] += 1 // 5ms bins
                }
            }
        }
        var bestBin = 100
        var bestCount = 0
        for (bin, count) in hist where count > bestCount {
            bestCount = count
            bestBin = bin
        }
        var bpm = 60.0 / (Double(bestBin) / 200.0)
        while bpm < 70.0 { bpm *= 2.0 }
        while bpm > 170.0 { bpm /= 2.0 }
        return (bpm * 10.0).rounded() / 10.0
    }

    // MARK: - Rhythmic Cage Generation (Downbeat-Aligned)

    /// Genera la lista di Gabbie Ritmate a partire dai risultati dell'analisi
    public func generateCages(
        from result: BeatAnalysisResult,
        mode: BeatIntervalMode,
        startTimeOffset: CMTime = .zero,
        peakSensitivity: Double = 0.45
    ) -> [RhythmicCage] {
        let offsetSec = CMTimeGetSeconds(startTimeOffset)
        let beats = result.beatTimes.map { offsetSec + CMTimeGetSeconds($0) }.sorted()
        let downbeats = result.downbeatTimes.map { offsetSec + CMTimeGetSeconds($0) }.sorted()
        let peakTimes = result.strongPeaks.isEmpty
            ? result.transientTimes.map { offsetSec + CMTimeGetSeconds($0) }.sorted()
            : result.selectStrongPeaks(sensitivity: peakSensitivity).map { offsetSec + $0 }

        var cutPoints: [Double] = []

        switch mode {
        case .oneBeat:
            cutPoints = beats

        case .twoBeats:
            if !beats.isEmpty {
                let anchorIdx = nearestBeatIndex(in: beats, to: downbeats.first) ?? 0
                for (idx, beat) in beats.enumerated() {
                    let mod = ((idx - anchorIdx) % 2 + 2) % 2
                    if mod == 0 {
                        cutPoints.append(beat)
                    }
                }
            }

        case .fourBeats:
            if downbeats.count >= 2 {
                cutPoints = downbeats
            } else if !beats.isEmpty {
                let anchorIdx = nearestBeatIndex(in: beats, to: downbeats.first) ?? 0
                for (idx, beat) in beats.enumerated() {
                    let mod = ((idx - anchorIdx) % 4 + 4) % 4
                    if mod == 0 {
                        cutPoints.append(beat)
                    }
                }
            }

        case .dynamicTransients:
            cutPoints = peakTimes

        case .adaptiveDirector:
            if !result.adaptiveGrid.isEmpty {
                cutPoints = result.selectAdaptiveCuts(sensitivity: peakSensitivity).map { offsetSec + $0 }
            } else {
                cutPoints = peakTimes
            }
        }

        cutPoints.sort()

        // Rimuovi duplicati o punti troppo ravvicinati (< 0.18s)
        var filteredPoints: [Double] = []
        for p in cutPoints {
            if let last = filteredPoints.last {
                if p - last >= 0.18 {
                    filteredPoints.append(p)
                }
            } else {
                filteredPoints.append(p)
            }
        }

        guard filteredPoints.count >= 2 else {
            let totalSec = CMTimeGetSeconds(result.duration)
            var generatedCages: [RhythmicCage] = []
            var t = offsetSec
            var idx = 0
            while t < offsetSec + totalSec {
                let dur = min(2.0, (offsetSec + totalSec) - t)
                generatedCages.append(RhythmicCage(index: idx, startSeconds: t, durationSeconds: dur))
                t += dur
                idx += 1
            }
            return generatedCages
        }

        var cages: [RhythmicCage] = []
        cages.reserveCapacity(filteredPoints.count - 1)
        for i in 0..<(filteredPoints.count - 1) {
            let start = filteredPoints[i]
            let end = filteredPoints[i + 1]
            cages.append(RhythmicCage(
                index: i,
                startSeconds: start,
                durationSeconds: end - start
            ))
        }

        return cages
    }

    private func nearestBeatIndex(in beats: [Double], to target: Double?) -> Int? {
        guard let target = target, !beats.isEmpty else { return nil }
        var bestIdx = 0
        var bestDist = abs(beats[0] - target)
        for (i, b) in beats.enumerated() {
            let d = abs(b - target)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return bestIdx
    }
}
