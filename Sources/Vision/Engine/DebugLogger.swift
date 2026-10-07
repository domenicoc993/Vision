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
        }

        public var formattedString: String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            return "[\(df.string(from: timestamp))] [\(level.rawValue)] \(message)"
        }
    }

    public var logs: [LogEntry] = []
    public var onLogAdded: ((LogEntry) -> Void)?

    private init() {}

    public func log(_ message: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        DispatchQueue.main.async {
            self.logs.append(entry)
            if self.logs.count > 500 {
                self.logs.removeFirst(100)
            }
            self.onLogAdded?(entry)
            print(entry.formattedString)
        }
    }
}
