import Foundation
import AVFoundation
import CoreGraphics

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
    public var onWillReplaceItem: ((CGImage?) -> Void)?
    public var onReadyFrameRendered: (() -> Void)?

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
    private var isLoadingItem = false
    private var chaseTime: CMTime = .invalid
    private var chaseFrameAccurate: Bool = false
    private var seekGeneration: UInt64 = 0
    private var jogSettleWorkItem: DispatchWorkItem?

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
            // Ignore transitional AVPlayer timestamps when paused, loading a new item, or seeking
            guard playing, !self.isLoadingItem, !self.isSeekInProgress else { return }
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

    public func setPlayheadForPendingReload(_ time: CMTime) {
        jogSettleWorkItem?.cancel()
        jogSettleWorkItem = nil
        let clamped = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: max(duration, CMTime(value: 1, timescale: 600))))
        seekGeneration &+= 1
        isLoadingItem = true
        isSeekInProgress = false
        chaseTime = .invalid
        currentTime = clamped
        notifyTimeChanged(clamped)
    }

    public func clear() {
        jogSettleWorkItem?.cancel()
        jogSettleWorkItem = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        seekGeneration &+= 1
        isLoadingItem = false
        isSeekInProgress = false
        chaseTime = .invalid
        onReadyFrameRendered?()
        player.replaceCurrentItem(with: nil)
        self.duration = .zero
        self.currentTime = .zero
        self.isPlaying = false
        self.onStatusChanged?("Pronto")
        self.notifyTimeChanged(.zero)
        DebugLogger.shared.log("Player azzerato (timeline vuota).", level: .playback)
    }

    public func load(
        item: AVPlayerItem?,
        duration: CMTime,
        targetFPS: Double = 30.0,
        seekToTime: CMTime? = nil,
        visualHoldImage: CGImage? = nil
    ) {
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

        onWillReplaceItem?(visualHoldImage)

        self.duration = duration
        self.fps = targetFPS
        self.currentTime = targetTime
        self.seekGeneration &+= 1
        let loadGeneration = self.seekGeneration
        self.isLoadingItem = true
        self.isSeekInProgress = false
        self.chaseTime = .invalid

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            guard let self = self else { return }
            switch observedItem.status {
            case .readyToPlay:
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.player.currentItem === observedItem else { return }
                    DebugLogger.shared.log("PlayerItem status: READY TO PLAY (Pronto alla riproduzione)", level: .playback)
                    self.onStatusChanged?("Pronto")
                    let desiredTime = (self.seekGeneration == loadGeneration) ? targetTime : self.currentTime
                    self.player.seek(to: desiredTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        DispatchQueue.main.async {
                            guard let self = self, self.player.currentItem === observedItem else { return }
                            self.isLoadingItem = false
                            self.currentTime = desiredTime
                            self.notifyTimeChanged(desiredTime)
                            self.onReadyFrameRendered?()
                        }
                    }
                }
            case .failed:
                let errMsg = observedItem.error?.localizedDescription ?? "Errore sconosciuto"
                DebugLogger.shared.log("PlayerItem status: FAILED - \(errMsg)", level: .error)
                DispatchQueue.main.async { [weak self] in
                    self?.isLoadingItem = false
                    self?.onStatusChanged?("Errore: \(errMsg)")
                    self?.onReadyFrameRendered?()
                }
            case .unknown:
                DebugLogger.shared.log("PlayerItem status: Inizializzazione...", level: .playback)
                self.onStatusChanged?("Caricamento...")
            @unknown default:
                break
            }
        }

        player.replaceCurrentItem(with: item)

        // Safety failsafe so freeze overlay / loading flag can never linger if AVPlayer stalls
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.seekGeneration == loadGeneration else { return }
            self.isLoadingItem = false
            self.onReadyFrameRendered?()
        }

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
        jogSettleWorkItem?.cancel()
        jogSettleWorkItem = nil
        onReadyFrameRendered?()
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
        jogSettleWorkItem?.cancel()
        jogSettleWorkItem = nil
        let wasPlaying = isPlaying || (player.rate != 0)
        player.pause()
        if wasPlaying {
            isPlaying = false
            if !isSeekInProgress && !isLoadingItem {
                let exact = player.currentTime()
                if exact.isValid && !CMTimeGetSeconds(exact).isNaN {
                    let dur = max(duration, CMTime(value: 1, timescale: 600))
                    let clamped = CMTimeClampToRange(exact, range: CMTimeRange(start: .zero, duration: dur))
                    currentTime = clamped
                    notifyTimeChanged(clamped)
                }
            }
            DebugLogger.shared.log("Pausa a \(formattedCurrentTime)", level: .playback)
        } else {
            isPlaying = false
        }
    }

    // High performance seek-chase for dragging / scrubbing (Resolve style)
    public func scrub(to time: CMTime) {
        jogSettleWorkItem?.cancel()
        jogSettleWorkItem = nil
        let clampedTime = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: max(duration, CMTime(value: 1, timescale: 600))))
        currentTime = clampedTime
        notifyTimeChanged(clampedTime) // Instant 0ms latency UI update!

        if !isSeekInProgress && !isLoadingItem {
            executeActualSeek(to: clampedTime, frameAccurate: false)
        } else {
            chaseTime = clampedTime
            chaseFrameAccurate = false
        }
    }

    public func seek(to time: CMTime, frameAccurate: Bool = true) {
        jogSettleWorkItem?.cancel()
        jogSettleWorkItem = nil
        let clampedTime = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: max(duration, CMTime(value: 1, timescale: 600))))
        currentTime = clampedTime
        notifyTimeChanged(clampedTime)

        if !isSeekInProgress && !isLoadingItem {
            executeActualSeek(to: clampedTime, frameAccurate: frameAccurate)
        } else {
            chaseTime = clampedTime
            chaseFrameAccurate = frameAccurate
        }
    }

    private func executeActualSeek(to time: CMTime, frameAccurate: Bool) {
        isSeekInProgress = true
        seekGeneration &+= 1
        let gen = seekGeneration
        let seekTarget = time

        let tolerance: CMTime = frameAccurate ? .zero : CMTimeMakeWithSeconds(1.0 / max(1.0, fps), preferredTimescale: 6000)

        player.seek(to: seekTarget, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.seekGeneration == gen else { return }
                if self.chaseTime.isValid && CMTimeCompare(self.chaseTime, seekTarget) != 0 {
                    let next = self.chaseTime
                    let nextAccurate = self.chaseFrameAccurate
                    self.chaseTime = .invalid
                    self.executeActualSeek(to: next, frameAccurate: nextAccurate)
                } else {
                    self.isSeekInProgress = false
                    self.onReadyFrameRendered?()
                }
            }
        }
    }

    public func step(by frames: Int) {
        pause()
        let safeFPS = max(1.0, fps)
        let delta = CMTimeMakeWithSeconds(Double(frames) / safeFPS, preferredTimescale: 6000)
        let newTime = CMTimeAdd(currentTime, delta)
        seek(to: newTime, frameAccurate: true)
    }

    /// Jog fluido per la ghiera dello Speed Editor: evita snap-back da `player.currentTime()`,
    /// usa seek rapido durante la rotazione veloce e assesta il frame esatto (`tolerance: .zero`) a fine corsa.
    public func jog(byFrames frames: Int) {
        guard frames != 0 else { return }
        let safeDuration = max(duration, CMTime(value: 1, timescale: 600))
        let baseTime: CMTime
        if isPlaying || player.rate != 0 {
            let live = accurateCurrentTime
            player.pause()
            isPlaying = false
            baseTime = live
        } else {
            baseTime = currentTime
        }

        let safeFPS = max(1.0, fps)
        let delta = CMTimeMakeWithSeconds(Double(frames) / safeFPS, preferredTimescale: 6000)
        let clampedTime = CMTimeClampToRange(CMTimeAdd(baseTime, delta), range: CMTimeRange(start: .zero, duration: safeDuration))

        currentTime = clampedTime
        notifyTimeChanged(clampedTime)

        jogSettleWorkItem?.cancel()
        jogSettleWorkItem = nil

        let useImmediateExact = abs(frames) <= 2 && !isSeekInProgress && !isLoadingItem
        if !isSeekInProgress && !isLoadingItem {
            executeActualSeek(to: clampedTime, frameAccurate: useImmediateExact)
        } else {
            chaseTime = clampedTime
            chaseFrameAccurate = false
        }

        if !useImmediateExact {
            let settle = DispatchWorkItem { [weak self] in
                guard let self = self, !self.isPlaying, !self.isLoadingItem else { return }
                let target = self.currentTime
                if !self.isSeekInProgress {
                    self.executeActualSeek(to: target, frameAccurate: true)
                } else {
                    self.chaseTime = target
                    self.chaseFrameAccurate = true
                }
            }
            jogSettleWorkItem = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: settle)
        }
    }

    /// Controllo continuo della velocità in modalità Shuttle (-16x .. +16x; 0 = pausa).
    public func setShuttleRate(_ rate: Float) {
        jogSettleWorkItem?.cancel()
        jogSettleWorkItem = nil
        if abs(rate) < 0.05 {
            if isPlaying || player.rate != 0 {
                pause()
            }
        } else {
            let clamped = max(-16.0, min(16.0, rate))
            player.rate = clamped
            isPlaying = true
        }
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
