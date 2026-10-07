import Foundation
import AVFoundation

public final class PlaybackController: NSObject {
    public let player = AVPlayer()
    public var currentTime: CMTime = .zero
    public var isPlaying: Bool = false {
        didSet {
            onPlayStateChanged?(isPlaying)
        }
    }
    public var duration: CMTime = .zero
    public var fps: Double = 30.0

    public var onTimeChanged: ((CMTime) -> Void)?
    public var onPlayStateChanged: ((Bool) -> Void)?
    public var onStatusChanged: ((String) -> Void)?

    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDidPlayToEndObserver: Any?

    // Smooth Scrubbing: Seek-Chase Engine (Resolve style)
    private var isSeekInProgress = false
    private var chaseTime: CMTime = .invalid

    public override init() {
        super.init()
        player.actionAtItemEnd = .pause
        player.volume = 1.0
        player.isMuted = false
        setupTimeObserver()
        setupEndObserver()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let obs = itemDidPlayToEndObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        itemStatusObservation?.invalidate()
    }

    private func setupTimeObserver() {
        let interval = CMTime(value: 1, timescale: 60) // 60Hz UI updates
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isSeekInProgress else { return }
            self.currentTime = time
            let playing = (self.player.rate != 0)
            if self.isPlaying != playing {
                self.isPlaying = playing
            }
            self.onTimeChanged?(time)
        }
    }

    private func setupEndObserver() {
        itemDidPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isPlaying = false
            self.onPlayStateChanged?(false)
            DebugLogger.shared.log("Fine timeline raggiunta.", level: .playback)
        }
    }

    public func clear() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        player.replaceCurrentItem(with: nil)
        self.duration = .zero
        self.currentTime = .zero
        self.isPlaying = false
        self.onStatusChanged?("Pronto")
        self.onTimeChanged?(.zero)
        DebugLogger.shared.log("Player azzerato (timeline vuota).", level: .playback)
    }

    public func load(item: AVPlayerItem?, duration: CMTime, targetFPS: Double = 30.0) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        guard let item = item, CMTimeCompare(duration, .zero) > 0 else {
            clear()
            return
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            guard let self = self else { return }
            switch observedItem.status {
            case .readyToPlay:
                DebugLogger.shared.log("PlayerItem status: READY TO PLAY (Pronto alla riproduzione)", level: .playback)
                self.onStatusChanged?("Pronto")
            case .failed:
                let errMsg = observedItem.error?.localizedDescription ?? "Errore sconosciuto"
                DebugLogger.shared.log("PlayerItem status: FAILED - \(errMsg)", level: .error)
                self.onStatusChanged?("Errore: \(errMsg)")
            case .unknown:
                DebugLogger.shared.log("PlayerItem status: Inizializzazione...", level: .playback)
                self.onStatusChanged?("Caricamento...")
            @unknown default:
                break
            }
        }

        let savedTime = currentTime
        player.replaceCurrentItem(with: item)
        self.duration = duration
        self.fps = targetFPS

        // Preserve playhead across edits / trim / cuts
        let targetTime: CMTime
        if CMTimeCompare(savedTime, duration) <= 0 && CMTimeCompare(savedTime, .zero) > 0 {
            targetTime = savedTime
        } else if CMTimeCompare(savedTime, duration) > 0 {
            targetTime = duration
        } else {
            targetTime = .zero
        }

        currentTime = targetTime
        seek(to: targetTime, frameAccurate: true)

        DebugLogger.shared.log("Player caricato: durata = \(String(format: "%.2f", CMTimeGetSeconds(duration)))s, fps = \(targetFPS), playhead a \(formattedCurrentTime)", level: .playback)
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func play() {
        // If at the end of the timeline, automatically rewind to start
        if CMTimeCompare(currentTime, duration) >= 0 {
            DebugLogger.shared.log("Play alla fine della timeline: riavvolgimento automatico a 00:00:00:00", level: .playback)
            seek(to: .zero, frameAccurate: true)
        }

        player.play()
        isPlaying = true
        DebugLogger.shared.log("Riproduzione avviata da \(formattedCurrentTime)", level: .playback)
    }

    public func pause() {
        player.pause()
        isPlaying = false
        DebugLogger.shared.log("Pausa a \(formattedCurrentTime)", level: .playback)
    }

    // High performance seek-chase for dragging / scrubbing (Resolve style)
    public func scrub(to time: CMTime) {
        let clampedTime = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: max(duration, CMTime(value: 1, timescale: 600))))
        currentTime = clampedTime
        onTimeChanged?(clampedTime) // Instant 0ms latency UI update!

        if !isSeekInProgress {
            executeActualSeek(to: clampedTime, frameAccurate: false)
        } else {
            chaseTime = clampedTime
        }
    }

    public func seek(to time: CMTime, frameAccurate: Bool = true) {
        let clampedTime = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: max(duration, CMTime(value: 1, timescale: 600))))
        currentTime = clampedTime
        onTimeChanged?(clampedTime)

        if !isSeekInProgress {
            executeActualSeek(to: clampedTime, frameAccurate: frameAccurate)
        } else {
            chaseTime = clampedTime
        }
    }

    private func executeActualSeek(to time: CMTime, frameAccurate: Bool) {
        isSeekInProgress = true
        let seekTarget = time

        let tolerance: CMTime = frameAccurate ? .zero : CMTime(value: 1, timescale: 30)

        player.seek(to: seekTarget, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard let self = self else { return }
            if self.chaseTime.isValid && CMTimeCompare(self.chaseTime, seekTarget) != 0 {
                let next = self.chaseTime
                self.chaseTime = .invalid
                self.executeActualSeek(to: next, frameAccurate: frameAccurate)
            } else {
                self.isSeekInProgress = false
            }
        }
    }

    public func step(by frames: Int) {
        pause()
        let frameDuration = CMTime(value: 1, timescale: Int32(fps > 0 ? fps : 30.0))
        let delta = CMTimeMultiply(frameDuration, multiplier: Int32(frames))
        let newTime = CMTimeAdd(currentTime, delta)
        seek(to: newTime, frameAccurate: true)
    }

    public var formattedCurrentTime: String {
        formatTimecode(currentTime, fps: fps)
    }

    public var formattedDuration: String {
        formatTimecode(duration, fps: fps)
    }

    public func formatTimecode(_ time: CMTime, fps: Double) -> String {
        let totalSeconds = CMTimeGetSeconds(time)
        guard !totalSeconds.isNaN && !totalSeconds.isInfinite && totalSeconds >= 0 else {
            return "00:00:00:00"
        }
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = Int(totalSeconds) % 60
        let frameNum = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * fps)
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frameNum)
    }
}
