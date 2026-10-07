import Foundation
import AVFoundation
import AppKit

public extension Notification.Name {
    static let waveformReadyNotification = Notification.Name("AudioWaveformCache.waveformReady")
}

public final class AudioWaveformCache {
    public static let shared = AudioWaveformCache()

    private let lock = NSLock()
    private var cache: [URL: [Float]] = [:]
    private var inProgress: Set<URL> = []
    private let queue = DispatchQueue(label: "com.vision.waveform", qos: .utility)

    public init() {}

    public func waveform(for url: URL) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[url]
    }

    public func samples(for url: URL) -> [Float]? {
        waveform(for: url)
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

            let samples = self.extractWaveformPeaks(from: url, targetSampleCount: 600)

            self.lock.lock()
            self.inProgress.remove(url)
            if let samples = samples, !samples.isEmpty {
                self.cache[url] = samples
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

    private func extractWaveformPeaks(from url: URL, targetSampleCount: Int) -> [Float]? {
        let asset = AVURLAsset(url: url)
        var audioTrack: AVAssetTrack? = nil

        if #available(macOS 13.0, *) {
            let semaphore = DispatchSemaphore(value: 0)
            asset.loadTracks(withMediaType: .audio) { tracks, _ in
                audioTrack = tracks?.first
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5.0)
        }
        if audioTrack == nil {
            audioTrack = asset.tracks(withMediaType: .audio).first
        }

        guard let track = audioTrack else {
            return nil
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            return nil
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            return nil
        }

        var rawPeaks: [Float] = []
        var maxPeak: Float = 0.0001

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
                var blockMax: Float = 0
                let step = max(1, sampleCount / 24)
                for i in stride(from: 0, to: sampleCount, by: step) {
                    let val = abs(Float(int16Buffer[i])) / 32768.0
                    if val > blockMax { blockMax = val }
                }
                rawPeaks.append(blockMax)
                if blockMax > maxPeak { maxPeak = blockMax }
            }

            // Cap at 3000 blocks to prevent excessive memory usage on long tracks
            if rawPeaks.count >= 3000 {
                reader.cancelReading()
                break
            }
        }

        if !rawPeaks.isEmpty {
            return resample(peaks: rawPeaks, maxPeak: maxPeak, targetCount: targetSampleCount)
        }
        return nil
    }

    private func resample(peaks: [Float], maxPeak: Float, targetCount: Int) -> [Float] {
        guard !peaks.isEmpty else { return [] }
        let normalizer = max(0.005, maxPeak)
        var result = [Float](repeating: 0, count: targetCount)

        let factor = Double(peaks.count) / Double(targetCount)
        for i in 0..<targetCount {
            let startIdx = Int(Double(i) * factor)
            let endIdx = min(peaks.count, max(startIdx + 1, Int(Double(i + 1) * factor)))
            var pMax: Float = 0
            for k in startIdx..<endIdx {
                if peaks[k] > pMax { pMax = peaks[k] }
            }
            // Normalize with logarithmic perception scaling for realistic professional NLE waveform appearance
            let normalized = min(1.0, pMax / normalizer)
            let perceptual = sqrt(normalized) // Equal-power perceptual curve
            result[i] = min(1.0, max(0.02, perceptual))
        }
        return result
    }
}
