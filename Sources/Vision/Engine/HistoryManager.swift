import Foundation

public struct HistoryEntry: Identifiable {
    public let id: UUID
    public let title: String
    public let timestamp: Date
    public let snapshot: ProjectDocumentData

    public init(id: UUID = UUID(), title: String, timestamp: Date = Date(), snapshot: ProjectDocumentData) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.snapshot = snapshot
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }
}

public final class HistoryManager {
    public static let shared = HistoryManager()

    public private(set) var pastEntries: [HistoryEntry] = []
    public private(set) var futureEntries: [HistoryEntry] = []
    public private(set) var currentTitle: String = "Progetto Aperto"

    public var maxEntries: Int = 60
    public var onHistoryChanged: (() -> Void)?

    private var isPerformingUndoRedo: Bool = false

    private init() {}

    public var canUndo: Bool {
        return !pastEntries.isEmpty
    }

    public var canRedo: Bool {
        return !futureEntries.isEmpty
    }

    public func reset(withInitialTitle title: String = "Progetto Aperto", project: EditorProject, mediaItems: [MediaItem]) {
        pastEntries.removeAll()
        futureEntries.removeAll()
        currentTitle = title
        onHistoryChanged?()
    }

    /// Registra un'azione nel cronologico salvando lo snapshot precedente nello stack di Undo
    public func record(title: String, project: EditorProject, mediaItems: [MediaItem]) {
        guard !isPerformingUndoRedo else { return }

        let snapshot = ProjectDocumentData(project: project, mediaItems: mediaItems)
        let entry = HistoryEntry(title: currentTitle, snapshot: snapshot)

        pastEntries.append(entry)
        if pastEntries.count > maxEntries {
            pastEntries.removeFirst()
        }

        futureEntries.removeAll()
        currentTitle = title
        onHistoryChanged?()

        // Schedula contemporaneamente il salvataggio in tempo reale su SQLite
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: project, mediaItems: mediaItems)
    }

    /// Esegue l'Undo tornando allo snapshot precedente
    public func undo(currentProject: EditorProject, currentMediaItems: [MediaItem]) -> ProjectDocumentData? {
        guard canUndo else { return nil }
        isPerformingUndoRedo = true
        defer { isPerformingUndoRedo = false }

        // Salva lo stato corrente nello stack di redo
        let currentSnapshot = ProjectDocumentData(project: currentProject, mediaItems: currentMediaItems)
        let redoEntry = HistoryEntry(title: currentTitle, snapshot: currentSnapshot)
        futureEntries.append(redoEntry)

        // Estrai lo stato precedente
        let previous = pastEntries.removeLast()
        currentTitle = previous.title
        onHistoryChanged?()

        // Sincronizza anche con il database SQLite
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: currentProject, mediaItems: currentMediaItems)
        return previous.snapshot
    }

    /// Esegue il Redo ripristinando l'azione annullata
    public func redo(currentProject: EditorProject, currentMediaItems: [MediaItem]) -> ProjectDocumentData? {
        guard canRedo else { return nil }
        isPerformingUndoRedo = true
        defer { isPerformingUndoRedo = false }

        // Salva lo stato corrente nello stack di undo
        let currentSnapshot = ProjectDocumentData(project: currentProject, mediaItems: currentMediaItems)
        let undoEntry = HistoryEntry(title: currentTitle, snapshot: currentSnapshot)
        pastEntries.append(undoEntry)

        // Estrai lo stato futuro
        let next = futureEntries.removeLast()
        currentTitle = next.title
        onHistoryChanged?()

        // Sincronizza anche con il database SQLite
        ProjectDatabase.shared.scheduleRealtimeAutosave(project: currentProject, mediaItems: currentMediaItems)
        return next.snapshot
    }

    /// Salta direttamente a un'azione specifica nell'elenco della cronologia
    public func jumpTo(pastIndex: Int, currentProject: EditorProject, currentMediaItems: [MediaItem]) -> ProjectDocumentData? {
        guard pastIndex >= 0 && pastIndex < pastEntries.count else { return nil }
        isPerformingUndoRedo = true
        defer { isPerformingUndoRedo = false }

        // Salva lo stato corrente in cima a futureEntries
        let currentSnapshot = ProjectDocumentData(project: currentProject, mediaItems: currentMediaItems)
        futureEntries.append(HistoryEntry(title: currentTitle, snapshot: currentSnapshot))

        // Sposta tutti gli elementi tra pastIndex + 1 e la fine in futureEntries in ordine inverso
        while pastEntries.count > pastIndex + 1 {
            let item = pastEntries.removeLast()
            futureEntries.append(item)
        }

        let target = pastEntries.removeLast()
        currentTitle = target.title
        onHistoryChanged?()

        ProjectDatabase.shared.scheduleRealtimeAutosave(project: currentProject, mediaItems: currentMediaItems)
        return target.snapshot
    }
}
