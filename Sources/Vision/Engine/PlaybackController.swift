import Foundation
import AVFoundation

public final class PlaybackController: NSObject {
    public let player = AVPlayer()
    public var currentTime: CMTime = .zero
    public var isPlaying: Bool = false {
        didSet {
            notifyPlayStateChanged(isPlaying)
        }
    }
    public var duration: CMTime = .zero
    public var fps: Double = 30.0

    public var onTimeChanged: ((CMTime) -> Void)?
    public var onPlayStateChanged: ((Bool) -> Void)?
    public var onStatusChanged: ((String) -> Void)?

    private struct TimeObserver {
        let ownerId: ObjectIdentifier
        weak var owner: AnyObject?
        let handler: (CMTime) -> Void
    }
    private struct PlayStateObserver {
        let ownerId: ObjectIdentifier
        weak var owner: AnyObject?
        let handler: (Bool) -> Void
    }
    private var timeObservers: [TimeObserver] = []
    private var playStateObservers: [PlayStateObserver] = []

    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDidPlayToEndObserver: Any?

    // Smooth Scrubbing: Seek-Chase Engine (Resolve style)
    private var isSeekInProgress = false
    private var chaseTime: CMTime = .invalid
    private var seekGeneration: UInt64 = 0

    public func addTimeObserver(_ owner: AnyObject, handler: @escaping (CMTime) -> Void) {
        let oid = ObjectIdentifier(owner)
        timeObservers.removeAll { $0.owner == nil || $0.ownerId == oid }
        timeObservers.append(TimeObserver(ownerId: oid, owner: owner, handler: handler))
    }

    public func addPlayStateObserver(_ owner: AnyObject, handler: @escaping (Bool) -> Void) {
        let oid = ObjectIdentifier(owner)
        playStateObservers.removeAll { $0.owner == nil || $0.ownerId == oid }
        playStateObservers.append(PlayStateObserver(ownerId: oid, owner: owner, handler: handler))
    }

    private func notifyTimeChanged(_ time: CMTime) {
        let dispatch = { [weak self] in
            guard let self = self else { return }
            self.onTimeChanged?(time)
            self.timeObservers.removeAll { $0.owner == nil }
            for obs in self.timeObservers {
                obs.handler(time)
            }
        }
        if Thread.isMainThread {
            dispatch()
        } else {
            DispatchQueue.main.async(execute: dispatch)
        }
    }

    private func notifyPlayStateChanged(_ playing: Bool) {
        let dispatch = { [weak self] in
            guard let self = self else { return }
            self.onPlayStateChanged?(playing)
            self.playStateObservers.removeAll { $0.owner == nil }
            for obs in self.playStateObservers {
                obs.handler(playing)
            }
        }
        if Thread.isMainThread {
            dispatch()
        } else {
            DispatchQueue.main.async(execute: dispatch)
        }
    }

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
            guard let self = self else { return }
            let playing = (self.player.rate != 0)
            if self.isPlaying != playing {
                self.isPlaying = playing
            }
            // While actively playing, always publish periodic time unless a seek is actively chasing
            if self.isSeekInProgress && !playing { return }
            self.currentTime = time
            self.notifyTimeChanged(time)
        }
    }

    private func setupEndObserver() {
        itemDidPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            // CRITICAL: Only trigger end of timeline if the notification belongs to the ACTIVE player item!
            // When replacing an item, detached previous items emit this notification, which must NOT jump to end.
            if let notifItem = notification.object as? AVPlayerItem, notifItem === self.player.currentItem {
                self.isPlaying = false
                DebugLogger.shared.log("Fine timeline raggiunta.", level: .playback)
            }
        }
    }

    public func clear() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        seekGeneration &+= 1
        isSeekInProgress = false
        chaseTime = .invalid
        player.replaceCurrentItem(with: nil)
        self.duration = .zero
        self.currentTime = .zero
        self.isPlaying = false
        self.onStatusChanged?("Pronto")
        self.notifyTimeChanged(.zero)
        DebugLogger.shared.log("Player azzerato (timeline vuota).", level: .playback)
    }

    public func load(item: AVPlayerItem?, duration: CMTime, targetFPS: Double = 30.0, seekToTime: CMTime? = nil) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        guard let item = item, CMTimeCompare(duration, .zero) > 0 else {
            clear()
            return
        }

        let targetTime: CMTime
        if let explicit = seekToTime {
            targetTime = CMTimeClampToRange(explicit, range: CMTimeRange(start: .zero, duration: duration))
        } else {
            let savedTime = currentTime
            if CMTimeCompare(savedTime, duration) <= 0 && CMTimeCompare(savedTime, .zero) > 0 {
                targetTime = savedTime
            } else if CMTimeCompare(savedTime, duration) > 0 {
                targetTime = duration
            } else {
                targetTime = .zero
            }
        }

        self.duration = duration
        self.fps = targetFPS
        self.currentTime = targetTime
        self.seekGeneration &+= 1
        self.isSeekInProgress = false
        self.chaseTime = .invalid

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            guard let self = self else { return }
            switch observedItem.status {
            case .readyToPlay:
                DebugLogger.shared.log("PlayerItem status: READY TO PLAY (Pronto alla riproduzione)", level: .playback)
                self.onStatusChanged?("Pronto")
                // Seek frame-accurately now that decoders are active, avoiding black screens!
                self.player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.currentTime = targetTime
                        self.notifyTimeChanged(targetTime)
                    }
                }
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

        player.replaceCurrentItem(with: item)
        // Also seek immediately
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

    /// Restituisce l'istante più accurato corrente (usando il clock hardware live durante la riproduzione)
    public var accurateCurrentTime: CMTime {
        if isPlaying && !isSeekInProgress && player.rate != 0 {
            let live = player.currentTime()
            if live.isValid && !CMTimeGetSeconds(live).isNaN {
                let dur = max(duration, CMTime(value: 1, timescale: 600))
                return CMTimeClampToRange(live, range: CMTimeRange(start: .zero, duration: dur))
            }
        }
        return currentTime
    }

    public func play() {
        // If at the end of the timeline, automatically rewind to start
        if CMTimeCompare(currentTime, duration) >= 0 {
            DebugLogger.shared.log("Play alla fine della timeline: riavvolgimento automatico a 00:00:00:00", level: .playback)
            isPlaying = true
            seekGeneration &+= 1
            let gen = seekGeneration
            isSeekInProgress = true
            chaseTime = .invalid
            currentTime = .zero
            notifyTimeChanged(.zero)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self, self.seekGeneration == gen else { return }
                    self.isSeekInProgress = false
                    if self.isPlaying {
                        self.player.play()
                    }
                }
            }
            DebugLogger.shared.log("Riproduzione avviata da \(formattedCurrentTime)", level: .playback)
            return
        }

        // Completa eventuale seek/scrub ancora in corso prima di far partire l'audio
        if isSeekInProgress || chaseTime.isValid {
            let target = chaseTime.isValid ? chaseTime : currentTime
            chaseTime = .invalid
            currentTime = target
            isPlaying = true
            seekGeneration &+= 1
            let gen = seekGeneration
            isSeekInProgress = true
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self, self.seekGeneration == gen else { return }
                    self.isSeekInProgress = false
                    if self.isPlaying {
                        self.player.play()
                    }
                }
            }
            DebugLogger.shared.log("Riproduzione avviata da \(formattedCurrentTime)", level: .playback)
            return
        }

        player.play()
        isPlaying = true
        DebugLogger.shared.log("Riproduzione avviata da \(formattedCurrentTime)", level: .playback)
    }

    public func pause() {
        player.pause()
        isPlaying = false
        if !isSeekInProgress {
            let exact = player.currentTime()
            if exact.isValid && !CMTimeGetSeconds(exact).isNaN {
                let dur = max(duration, CMTime(value: 1, timescale: 600))
                let clamped = CMTimeClampToRange(exact, range: CMTimeRange(start: .zero, duration: dur))
                currentTime = clamped
                notifyTimeChanged(clamped)
            }
        }
        DebugLogger.shared.log("Pausa a \(formattedCurrentTime)", level: .playback)
    }

    // High performance seek-chase for dragging / scrubbing (Resolve style)
    public func scrub(to time: CMTime) {
        let clampedTime = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: max(duration, CMTime(value: 1, timescale: 600))))
        currentTime = clampedTime
        notifyTimeChanged(clampedTime) // Instant 0ms latency UI update!

        if !isSeekInProgress {
            executeActualSeek(to: clampedTime, frameAccurate: false)
        } else {
            chaseTime = clampedTime
        }
    }

    public func seek(to time: CMTime, frameAccurate: Bool = true) {
        let clampedTime = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: max(duration, CMTime(value: 1, timescale: 600))))
        currentTime = clampedTime
        notifyTimeChanged(clampedTime)

        if !isSeekInProgress {
            executeActualSeek(to: clampedTime, frameAccurate: frameAccurate)
        } else {
            chaseTime = clampedTime
        }
    }

    private func executeActualSeek(to time: CMTime, frameAccurate: Bool) {
        isSeekInProgress = true
        seekGeneration &+= 1
        let gen = seekGeneration
        let seekTarget = time

        let tolerance: CMTime = frameAccurate ? .zero : CMTime(value: 1, timescale: 30)

        player.seek(to: seekTarget, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.seekGeneration == gen else { return }
                if self.chaseTime.isValid && CMTimeCompare(self.chaseTime, seekTarget) != 0 {
                    let next = self.chaseTime
                    self.chaseTime = .invalid
                    self.executeActualSeek(to: next, frameAccurate: frameAccurate)
                } else {
                    self.isSeekInProgress = false
                }
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
