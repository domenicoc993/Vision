import AppKit
import Foundation

public final class DebugLogger {
    public static let shared = DebugLogger()

    public struct LogEntry: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let level: Level
        public let message: String

        public enum Level: String {
            case info = "INFO"
            case warning = "WARN"
            case error = "ERROR"
            case playback = "PLAY"
            case perf = "PERF"
        }

        private static let entryDateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            return df
        }()

        public var formattedString: String {
            "[\(Self.entryDateFormatter.string(from: timestamp))] [\(level.rawValue)] \(message)"
        }
    }

    public static let didAddLogNotification = Notification.Name("DebugLogger.didAddLog")

    public var logs: [LogEntry] = []
    public var onLogAdded: ((LogEntry) -> Void)?

    private let perfLock = NSLock()
    private var perfEvents: [String] = []
    private var currentActiveTrace: String = "idle"
    private var traceStartTime: CFAbsoluteTime = 0
    private var lastResignActiveTime: CFAbsoluteTime?
    private var lastWillBecomeActiveTime: CFAbsoluteTime?
    private var isMonitoringStarted = false
    private var watchdogThread: Thread?
    private var runLoopObserver: CFRunLoopObserver?
    private var lastRunLoopWakeTime: CFAbsoluteTime = 0
    private let appLaunchTime = CFAbsoluteTimeGetCurrent()

    private init() {}

    public func log(_ message: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.logs.append(entry)
            if self.logs.count > 2500 {
                self.logs.removeFirst(500)
            }
            self.onLogAdded?(entry)
            NotificationCenter.default.post(name: Self.didAddLogNotification, object: nil, userInfo: ["entry": entry])
            print(entry.formattedString)
        }
    }

    public func recordPerf(_ message: String) {
        let ts = LogEntry.entryDateFormatterStatic.string(from: Date())
        let line = "[\(ts)] \(message)"
        perfLock.lock()
        perfEvents.append(line)
        if perfEvents.count > 250 {
            perfEvents.removeFirst(50)
        }
        perfLock.unlock()
    }

    public func setTrace(_ phase: String) {
        perfLock.lock()
        currentActiveTrace = phase
        traceStartTime = CFAbsoluteTimeGetCurrent()
        perfLock.unlock()
    }

    public func measure<T>(_ label: String, thresholdMs: Double = 25.0, block: () -> T) -> T {
        let start = CFAbsoluteTimeGetCurrent()
        setTrace(label)
        defer {
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            setTrace("idle")
            if elapsedMs >= thresholdMs {
                recordPerf("SLOW [\(label)] \(String(format: "%.1f", elapsedMs)) ms")
            }
        }
        return block()
    }

    public func startPerformanceMonitoring() {
        guard !isMonitoringStarted else { return }
        isMonitoringStarted = true

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.lastResignActiveTime = CFAbsoluteTimeGetCurrent()
            self.recordPerf("FOCUS -> didResignActive")
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.lastWillBecomeActiveTime = now
            let awaySec = self.lastResignActiveTime.map { now - $0 } ?? 0
            self.recordPerf("FOCUS -> willBecomeActive (away \(String(format: "%.1f", awaySec))s)")
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let deltaMs = self.lastWillBecomeActiveTime.map { (now - $0) * 1000.0 } ?? 0
            self.recordPerf("FOCUS -> didBecomeActive (will->did: \(String(format: "%.1f", deltaMs)) ms)")
            // Schedule an async tick to measure how long it takes main RunLoop to become responsive after activation
            DispatchQueue.main.async {
                let responsiveMs = (CFAbsoluteTimeGetCurrent() - now) * 1000.0
                self.recordPerf("FOCUS -> mainRunLoopReady afterBecomeActive: \(String(format: "%.1f", responsiveMs)) ms")
            }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let title = (note.object as? NSWindow)?.title ?? "window"
            self?.recordPerf("WINDOW -> didBecomeKey (\(title))")
        }

        // CFRunLoop stall detector (>40ms single main-thread pass)
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            guard let self = self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if activity.contains(.afterWaiting) {
                self.lastRunLoopWakeTime = now
            } else if activity.contains(.beforeWaiting), self.lastRunLoopWakeTime > 0 {
                let busyMs = (now - self.lastRunLoopWakeTime) * 1000.0
                if busyMs >= 45.0 {
                    self.perfLock.lock()
                    let trace = self.currentActiveTrace
                    self.perfLock.unlock()
                    self.recordPerf("RUNLOOP BUSY \(String(format: "%.1f", busyMs)) ms (trace: \(trace))")
                }
                self.lastRunLoopWakeTime = 0
            }
        }
        if let observer = observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.runLoopObserver = observer
        }

        // Background watchdog thread checking main-thread responsiveness every 250ms
        let thread = Thread { [weak self] in
            while let self = self, !Thread.current.isCancelled {
                let sem = DispatchSemaphore(value: 0)
                let pingStart = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async {
                    sem.signal()
                }
                let res = sem.wait(timeout: .now() + 0.25)
                if res == .timedOut {
                    // Wait until main responds to measure exact duration of hang
                    _ = sem.wait(timeout: .now() + 10.0)
                    let hangMs = (CFAbsoluteTimeGetCurrent() - pingStart) * 1000.0
                    self.perfLock.lock()
                    let trace = self.currentActiveTrace
                    self.perfLock.unlock()
                    self.recordPerf("⚠️ MAIN THREAD HANG DETECTED: \(String(format: "%.0f", hangMs)) ms (trace: \(trace))")
                }
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
        thread.name = "com.vision.hangwatchdog"
        thread.qualityOfService = .utility
        thread.start()
        self.watchdogThread = thread
    }

    public func buildDiagnosticReport(
        activeTimeline: TimelineModel?,
        playerStatus: String?,
        mediaPoolCount: Int
    ) -> String {
        let uptimeSec = CFAbsoluteTimeGetCurrent() - appLaunchTime
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let ramMB = (kerr == KERN_SUCCESS) ? Double(info.resident_size) / (1024.0 * 1024.0) : -1.0

        var lines: [String] = []
        lines.append("=== VISION DIAGNOSTIC REPORT ===")
        lines.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Uptime: \(String(format: "%.1f", uptimeSec))s | RAM: \(String(format: "%.1f", ramMB)) MB | OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("App Active: \(NSApp.isActive) | KeyWindow: \(NSApp.keyWindow?.title ?? "nil") | Modal: \(NSApp.modalWindow != nil)")
        if let tl = activeTimeline {
            let vClips = tl.videoTracks.reduce(0) { $0 + $1.clips.count }
            let aClips = tl.audioTracks.reduce(0) { $0 + $1.clips.count }
            lines.append("Timeline: '\(tl.name)' | isSelection=\(tl.isSelection) | filterActive=\(tl.isSmartFilterActive) | V(\(tl.videoTracks.count)):\(vClips) A(\(tl.audioTracks.count)):\(aClips) | MediaPool:\(mediaPoolCount)")
        }
        if let st = playerStatus {
            lines.append("Player: \(st)")
        }
        let se = SpeedEditorManager.shared
        lines.append("Speed Editor: connected=\(se.isConnected) auth=\(se.isAuthenticated) mode=\(se.currentWheelMode.rawValue) sensitivity=\(String(format: "%.2fx", se.wheelSensitivity))")

        lines.append("")
        lines.append("--- FOCUS / HANG / RUNLOOP EVENTS ---")
        perfLock.lock()
        let recentPerf = perfEvents.suffix(80)
        perfLock.unlock()
        if recentPerf.isEmpty {
            lines.append("(nessun evento perf > soglia registrato)")
        } else {
            lines.append(contentsOf: recentPerf)
        }

        lines.append("")
        lines.append("--- RECENT APP LOGS ---")
        for entry in logs.suffix(80) {
            lines.append(entry.formattedString)
        }
        return lines.joined(separator: "\n")
    }
}

private extension DebugLogger.LogEntry {
    static let entryDateFormatterStatic: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
}
