import Foundation
import AVFoundation
import CoreMedia
import Accelerate

public struct BeatAnalysisResult {
    public let bpm: Double
    public let beatTimes: [CMTime]
    public let transientTimes: [CMTime]
    public let duration: CMTime
    public let audioURL: URL
}

public final class AudioBeatDetector {
    public static let shared = AudioBeatDetector()

    public init() {}

    /// Analizza una traccia audio o video alla ricerca di BPM e battiti ritmici (transienti)
    public func analyze(
        url: URL,
        timeRange: CMTimeRange? = nil
    ) async throws -> BeatAnalysisResult {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw NSError(domain: "VisionBeatDetector", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nessuna traccia audio trovata nel file."])
        }

        let assetDuration = try await asset.load(.duration)
        let actualRange = timeRange ?? CMTimeRange(start: .zero, duration: assetDuration)

        // Lettura PCM mono a 22050 Hz (ottimale per calcolo energetico transienti rapido e leggero)
        let targetSampleRate: Double = 22050.0
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = actualRange
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VisionBeatDetector", code: 2, userInfo: [NSLocalizedDescriptionKey: "Impossibile avviare la lettura audio."])
        }

        var pcmSamples: [Float] = []
        // Riserva memoria ragionevole per evitare continue riallocazioni
        pcmSamples.reserveCapacity(Int(CMTimeGetSeconds(actualRange.duration) * targetSampleRate))

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
            guard status == noErr, let rawData = dataPointer, length >= 2 else { continue }

            let sampleCount = length / 2
            rawData.withMemoryRebound(to: Int16.self, capacity: sampleCount) { int16Buffer in
                for i in 0..<sampleCount {
                    pcmSamples.append(Float(int16Buffer[i]) / 32768.0)
                }
            }
        }

        guard !pcmSamples.isEmpty else {
            throw NSError(domain: "VisionBeatDetector", code: 3, userInfo: [NSLocalizedDescriptionKey: "Campioni audio vuoti o non decodificabili."])
        }

        // 1. Calcolo Energy Curve con hop size di 256 campioni (~11.6ms)
        let hopSize = 256
        let windowCount = pcmSamples.count / hopSize
        var energyCurve: [Float] = []
        energyCurve.reserveCapacity(windowCount)

        for w in 0..<windowCount {
            let startIdx = w * hopSize
            let endIdx = min(startIdx + hopSize, pcmSamples.count)
            var sumSquare: Float = 0.0
            for i in startIdx..<endIdx {
                let s = pcmSamples[i]
                sumSquare += s * s
            }
            let rms = sqrt(sumSquare / Float(hopSize))
            energyCurve.append(rms)
        }

        // 2. Onset Detection Function (ODF): Derivata prima positiva dell'energia
        var odf: [Float] = Array(repeating: 0.0, count: energyCurve.count)
        for i in 1..<energyCurve.count {
            let diff = energyCurve[i] - energyCurve[i - 1]
            odf[i] = diff > 0 ? diff : 0
        }

        // 3. Soglia dinamica mobile (Moving Average su finestra di ~0.6 secondi)
        let localWindowSize = Int(0.6 * targetSampleRate / Double(hopSize))
        var transientIndices: [Int] = []
        let minPeakInterval = Int(0.18 * targetSampleRate / Double(hopSize)) // Almeno 180ms tra transienti
        var lastPeakIndex = -minPeakInterval

        for i in 0..<odf.count {
            let start = max(0, i - localWindowSize / 2)
            let end = min(odf.count, i + localWindowSize / 2)
            var localSum: Float = 0.0
            for k in start..<end { localSum += odf[k] }
            let localMean = localSum / Float(max(1, end - start))
            let dynamicThreshold = localMean * 1.45 + 0.005

            if odf[i] > dynamicThreshold && (i - lastPeakIndex) >= minPeakInterval {
                // Controllo se è un massimo locale
                let prev = i > 0 ? odf[i - 1] : 0
                let next = (i + 1 < odf.count) ? odf[i + 1] : 0
                if odf[i] >= prev && odf[i] >= next {
                    transientIndices.append(i)
                    lastPeakIndex = i
                }
            }
        }

        // Converti indici di transienti in tempi reali (secondi)
        let secondsPerHop = Double(hopSize) / targetSampleRate
        let startOffset = CMTimeGetSeconds(actualRange.start)
        let transientTimes: [CMTime] = transientIndices.map { idx in
            let sec = startOffset + (Double(idx) * secondsPerHop)
            return CMTime(seconds: sec, preferredTimescale: 600)
        }

        // 4. Stima del BPM tramite istogramma degli intervalli inter-onsets
        var intervalHistogram: [Int: Int] = [:] // Bin di 5ms
        for i in 0..<(transientIndices.count - 1) {
            for j in (i + 1)..<min(i + 5, transientIndices.count) {
                let intervalSec = Double(transientIndices[j] - transientIndices[i]) * secondsPerHop
                // Considera intervalli compatibili con BPM tra 65 e 180 (da 0.33s a 0.92s)
                if intervalSec >= 0.30 && intervalSec <= 1.0 {
                    let bin = Int(round(intervalSec * 100)) // 10ms bins
                    intervalHistogram[bin, default: 0] += 1
                }
            }
        }

        var bestIntervalSec: Double = 0.5 // Default: 120 BPM (0.5s per beat)
        var maxCount = 0
        for (bin, count) in intervalHistogram {
            if count > maxCount {
                maxCount = count
                bestIntervalSec = Double(bin) / 100.0
            }
        }

        var detectedBPM = 60.0 / bestIntervalSec
        // Normalizza il tempo in un range musicale standard (70 - 160 BPM)
        while detectedBPM < 70.0 { detectedBPM *= 2.0 }
        while detectedBPM > 160.0 { detectedBPM /= 2.0 }
        detectedBPM = round(detectedBPM * 10) / 10.0 // es. 124.5

        let beatInterval = 60.0 / detectedBPM

        // 5. Allinea i battiti al primo picco significativo
        let firstTransientSec = transientTimes.first.map { CMTimeGetSeconds($0) } ?? startOffset
        var beatTimes: [CMTime] = []
        let totalDurationSec = CMTimeGetSeconds(actualRange.duration)
        var currentBeatSec = firstTransientSec

        // Se il primo picco è oltre 1 battito dall'inizio, calcola battiti precedenti a ritroso
        while currentBeatSec - beatInterval >= startOffset {
            currentBeatSec -= beatInterval
        }

        while currentBeatSec <= (startOffset + totalDurationSec) {
            beatTimes.append(CMTime(seconds: currentBeatSec, preferredTimescale: 600))
            currentBeatSec += beatInterval
        }

        return BeatAnalysisResult(
            bpm: detectedBPM,
            beatTimes: beatTimes,
            transientTimes: transientTimes,
            duration: actualRange.duration,
            audioURL: url
        )
    }

    /// Genera la lista di Gabbie Ritmate a partire dai risultati dell'analisi
    public func generateCages(
        from result: BeatAnalysisResult,
        mode: BeatIntervalMode,
        startTimeOffset: CMTime = .zero
    ) -> [RhythmicCage] {
        var cutPoints: [Double] = []

        switch mode {
        case .oneBeat:
            // Taglio ad ogni singolo battito
            cutPoints = result.beatTimes.map { CMTimeGetSeconds($0) }

        case .twoBeats:
            // Taglio ogni 2 battiti (1/2 misura)
            for (idx, beat) in result.beatTimes.enumerated() {
                if idx % 2 == 0 {
                    cutPoints.append(CMTimeGetSeconds(beat))
                }
            }

        case .fourBeats:
            // Taglio ogni 4 battiti (1 battuta intera)
            for (idx, beat) in result.beatTimes.enumerated() {
                if idx % 4 == 0 {
                    cutPoints.append(CMTimeGetSeconds(beat))
                }
            }

        case .dynamicTransients:
            // Taglio solo dove ci sono stati transienti energetici reali
            cutPoints = result.transientTimes.map { CMTimeGetSeconds($0) }
        }

        cutPoints.sort()

        // Rimuovi eventuali duplicati o punti troppo vicini (< 0.25s)
        var filteredPoints: [Double] = []
        for p in cutPoints {
            if let last = filteredPoints.last {
                if p - last >= 0.25 {
                    filteredPoints.append(p)
                }
            } else {
                filteredPoints.append(p)
            }
        }

        guard filteredPoints.count >= 2 else {
            // Se i tagli sono insufficienti, genera intervalli di sicurezza da 2.0s
            let totalSec = CMTimeGetSeconds(result.duration)
            var generatedCages: [RhythmicCage] = []
            var t = CMTimeGetSeconds(startTimeOffset)
            var idx = 0
            while t < CMTimeGetSeconds(startTimeOffset) + totalSec {
                let dur = min(2.0, (CMTimeGetSeconds(startTimeOffset) + totalSec) - t)
                generatedCages.append(RhythmicCage(index: idx, startSeconds: t, durationSeconds: dur))
                t += dur
                idx += 1
            }
            return generatedCages
        }

        var cages: [RhythmicCage] = []
        for i in 0..<(filteredPoints.count - 1) {
            let start = filteredPoints[i]
            let end = filteredPoints[i + 1]
            let dur = end - start
            cages.append(RhythmicCage(
                index: i,
                startSeconds: start,
                durationSeconds: dur
            ))
        }

        return cages
    }
}
