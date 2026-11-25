import Foundation
import AVFoundation
import AppKit

public extension Notification.Name {
    static let waveformReadyNotification = Notification.Name("AudioWaveformCache.waveformReady")
}

public struct WaveformData {
    public let peaks: [Float]
    public let rms: [Float]
    public let displayPeaks: [Float]
    public let displayRms: [Float]
    public let binsPerSecond: Double
    public let durationSeconds: Double

    public init(peaks: [Float], rms: [Float], binsPerSecond: Double, durationSeconds: Double) {
        self.peaks = peaks
        self.rms = rms
        self.displayPeaks = peaks.map { powf($0, 0.72) }
        self.displayRms = rms.map { powf($0, 0.78) }
        self.binsPerSecond = binsPerSecond
        self.durationSeconds = durationSeconds
    }

    /// Restituisce (picco massimo, RMS massimo) nell'intervallo [startTime, endTime] in secondi sorgente.
    public func envelope(from startTime: Double, to endTime: Double) -> (peak: Float, rms: Float) {
        guard !peaks.isEmpty, binsPerSecond > 0 else { return (0, 0) }
        let t0 = max(0.0, min(durationSeconds, startTime))
        let t1 = max(t0, min(durationSeconds, endTime))
        let i0 = max(0, min(peaks.count - 1, Int(floor(t0 * binsPerSecond))))
        let i1 = max(i0, min(peaks.count - 1, Int(floor(t1 * binsPerSecond))))

        var maxPeak: Float = 0
        var maxRms: Float = 0
        for i in i0...i1 {
            let p = peaks[i]
            let r = rms[i]
            if p > maxPeak { maxPeak = p }
            if r > maxRms { maxRms = r }
        }
        return (maxPeak, maxRms)
    }

    /// Versione pre-curvata percettivamente per rendering a 60fps senza `pow()` sul main thread.
    public func displayEnvelope(from startTime: Double, to endTime: Double) -> (peak: Float, rms: Float) {
        guard !displayPeaks.isEmpty, binsPerSecond > 0 else { return (0, 0) }
        let t0 = max(0.0, min(durationSeconds, startTime))
        let t1 = max(t0, min(durationSeconds, endTime))
        let i0 = max(0, min(displayPeaks.count - 1, Int(floor(t0 * binsPerSecond))))
        let i1 = max(i0, min(displayPeaks.count - 1, Int(floor(t1 * binsPerSecond))))

        var maxPeak: Float = 0
        var maxRms: Float = 0
        for i in i0...i1 {
            let p = displayPeaks[i]
            let r = displayRms[i]
            if p > maxPeak { maxPeak = p }
            if r > maxRms { maxRms = r }
        }
        return (maxPeak, maxRms)
    }
}

public final class AudioWaveformCache {
    public static let shared = AudioWaveformCache()

    public static let defaultBinsPerSecond: Double = 200.0

    private let lock = NSLock()
    private var cache: [URL: WaveformData] = [:]
    private var inProgress: Set<URL> = []
    private let queue = DispatchQueue(label: "com.vision.waveform", qos: .utility)

    public init() {}

    public func invalidate(url: URL) {
        lock.lock()
        cache.removeValue(forKey: url)
        inProgress.remove(url)
        lock.unlock()
    }

    public func waveformData(for url: URL) -> WaveformData? {
        lock.lock()
        defer { lock.unlock() }
        return cache[url]
    }

    /// Restituisce la forma d'onda già in cache oppure la estrae in modo sincrono (per snap preciso ai picchi).
    public func ensureWaveformDataSync(for url: URL) -> WaveformData? {
        if let cached = waveformData(for: url) {
            return cached
        }
        guard let extracted = extractWaveform(from: url, binsPerSecond: Self.defaultBinsPerSecond),
              !extracted.peaks.isEmpty else {
            return nil
        }
        lock.lock()
        cache[url] = extracted
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .waveformReadyNotification, object: url)
        }
        return extracted
    }

    public func waveform(for url: URL) -> [Float]? {
        waveformData(for: url)?.peaks
    }

    public func samples(for url: URL) -> [Float]? {
        waveformData(for: url)?.peaks
    }

    public func loadWaveform(for item: MediaItem) {
        loadWaveform(for: item.url, hasAudio: item.hasAudio)
    }

    public func loadWaveform(for url: URL, hasAudio: Bool = true) {
        guard hasAudio else { return }

        lock.lock()
        if cache[url] != nil || inProgress.contains(url) {
            lock.unlock()
            return
        }
        inProgress.insert(url)
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }

            let data = self.extractWaveform(from: url, binsPerSecond: Self.defaultBinsPerSecond)

            self.lock.lock()
            self.inProgress.remove(url)
            if let data = data, !data.peaks.isEmpty {
                self.cache[url] = data
            }
            self.lock.unlock()

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .waveformReadyNotification,
                    object: url
                )
            }
        }
    }

    private func extractWaveform(from url: URL, binsPerSecond: Double) -> WaveformData? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var audioTrack: AVAssetTrack? = nil
        var durationSeconds: Double = 0

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let tracks = try? await asset.loadTracks(withMediaType: .audio)
            audioTrack = tracks?.first
            if let dur = try? await asset.load(.duration) {
                durationSeconds = max(0, CMTimeGetSeconds(dur))
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 8.0)

        guard let track = audioTrack else { return nil }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else { return nil }

        let initialBins = max(1, Int(ceil(durationSeconds * binsPerSecond)))
        var binPeaks = [Float](repeating: 0, count: initialBins)
        var binSumSq = [Double](repeating: 0, count: initialBins)
        var binCounts = [Int](repeating: 0, count: initialBins)
        var maxGlobalPeak: Float = 0.0001
        var maxObservedEndSec: Double = durationSeconds

        var fallbackSampleRate: Double = 44100.0
        var fallbackChannels: Int = 2
        var cumulativeFrames: Int64 = 0

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                if asbd.mSampleRate > 0 { fallbackSampleRate = asbd.mSampleRate }
                if asbd.mChannelsPerFrame > 0 { fallbackChannels = Int(asbd.mChannelsPerFrame) }
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsSec = pts.isValid && !CMTimeGetSeconds(pts).isNaN
                ? max(0.0, CMTimeGetSeconds(pts))
                : Double(cumulativeFrames) / fallbackSampleRate

            let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numFrames > 0, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                cumulativeFrames += Int64(numFrames)
                continue
            }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard status == noErr, let rawData = dataPointer, length >= 4 else {
                cumulativeFrames += Int64(numFrames)
                continue
            }

            let floatCount = length / MemoryLayout<Float>.size
            let channels = max(1, fallbackChannels)
            let framesAvailable = min(numFrames, floatCount / channels)
            let endSec = ptsSec + Double(framesAvailable) / fallbackSampleRate
            if endSec > maxObservedEndSec { maxObservedEndSec = endSec }

            let neededBins = Int(ceil(maxObservedEndSec * binsPerSecond)) + 1
            if neededBins > binPeaks.count {
                let extra = neededBins - binPeaks.count
                binPeaks.append(contentsOf: repeatElement(0, count: extra))
                binSumSq.append(contentsOf: repeatElement(0, count: extra))
                binCounts.append(contentsOf: repeatElement(0, count: extra))
            }

            let framesPerBin = fallbackSampleRate / binsPerSecond

            rawData.withMemoryRebound(to: Float.self, capacity: framesAvailable * channels) { ptr in
                var f = 0
                while f < framesAvailable {
                    let exactTime = ptsSec + Double(f) / fallbackSampleRate
                    let binIdx = max(0, min(binPeaks.count - 1, Int(exactTime * binsPerSecond)))
                    // Advance within the same time bin tightly in a tight inner loop
                    let binEndSec = Double(binIdx + 1) / binsPerSecond
                    let framesInThisBin = max(1, min(framesAvailable - f, Int(ceil((binEndSec - exactTime) * fallbackSampleRate))))
                    let endF = min(framesAvailable, f + framesInThisBin)

                    var localMax: Float = binPeaks[binIdx]
                    var localSumSq: Double = 0
                    var localCount = 0

                    for fi in f..<endF {
                        let base = fi * channels
                        var framePeak: Float = 0
                        for ch in 0..<channels {
                            let s = abs(ptr[base + ch])
                            if s > framePeak { framePeak = s }
                        }
                        if framePeak > localMax { localMax = framePeak }
                        localSumSq += Double(framePeak) * Double(framePeak)
                        localCount += 1
                    }

                    binPeaks[binIdx] = localMax
                    if localMax > maxGlobalPeak { maxGlobalPeak = localMax }
                    binSumSq[binIdx] += localSumSq
                    binCounts[binIdx] += localCount
                    _ = framesPerBin
                    f = endF
                }
            }

            cumulativeFrames += Int64(framesAvailable)
        }

        let finalCount = max(1, min(binPeaks.count, Int(ceil(maxObservedEndSec * binsPerSecond))))
        guard finalCount > 0 else { return nil }

        let norm = max(0.002, maxGlobalPeak)
        var normPeaks = [Float](repeating: 0, count: finalCount)
        var normRms = [Float](repeating: 0, count: finalCount)
        for i in 0..<finalCount {
            let p = min(1.0, binPeaks[i] / norm)
            normPeaks[i] = p
            if binCounts[i] > 0 {
                let rawRms = Float(sqrt(binSumSq[i] / Double(binCounts[i])))
                normRms[i] = min(p, rawRms / norm)
            }
        }

        return WaveformData(
            peaks: normPeaks,
            rms: normRms,
            binsPerSecond: binsPerSecond,
            durationSeconds: maxObservedEndSec
        )
    }
}
