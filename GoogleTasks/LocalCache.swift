import Foundation
import Network

// MARK: - Offline Mutation

/// Represents a mutation that should be replayed when connectivity is restored
struct OfflineMutation: Codable, Identifiable, Equatable {
    let id: String
    let type: MutationType
    let taskListId: String
    let taskId: String?
    let createdAt: Date
    var retryCount: Int

    enum MutationType: String, Codable, Equatable {
        case createTask
        case updateTask
        case toggleTask
        case deleteTask
        case createList
        case deleteList
    }

    /// The payload stored as raw JSON data
    let payload: Data?

    init(id: String = UUID().uuidString, type: MutationType, taskListId: String, taskId: String? = nil, payload: [String: String]? = nil) {
        self.id = id
        self.type = type
        self.taskListId = taskListId
        self.taskId = taskId
        self.createdAt = Date()
        self.retryCount = 0
        self.payload = payload.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    var payloadDict: [String: String]? {
        guard let data = payload else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: String]
    }
}

// MARK: - Cached Snapshot

/// A complete cached snapshot of all task data for offline access
struct CachedSnapshot: Codable {
    let taskLists: [TaskList]
    let tasksByListId: [String: [GoogleTask]]
    let selectedTaskListId: String?
    let cachedAt: Date
}

// MARK: - Local Cache

/// Manages local persistence of task data using JSON files on disk.
/// Provides:
///  - Cached snapshots for offline reading
///  - An offline mutation queue that replays when connectivity returns
///  - Zero external dependencies (pure Foundation)
@MainActor
final class LocalCache {
    static let shared = LocalCache()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cacheDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("com.google.tasks.desktop/cache")
    }

    private var snapshotURL: URL {
        cacheDirectory.appendingPathComponent("cached_snapshot.json")
    }

    private var mutationQueueURL: URL {
        cacheDirectory.appendingPathComponent("offline_mutations.json")
    }

    private init() {
        encoder.outputFormatting = .prettyPrinted
        ensureCacheDirectory()
    }

    // MARK: - Snapshot (Read Cache)

    /// Saves a full snapshot of the current task data for offline reading
    func saveSnapshot(taskLists: [TaskList], tasksByListId: [String: [GoogleTask]], selectedTaskListId: String?) {
        let snapshot = CachedSnapshot(
            taskLists: taskLists,
            tasksByListId: tasksByListId,
            selectedTaskListId: selectedTaskListId,
            cachedAt: Date()
        )

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            print("[LocalCache] Failed to save snapshot: \(error.localizedDescription)")
        }
    }

    /// Loads a cached snapshot from disk, if available
    func loadSnapshot() -> CachedSnapshot? {
        guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: snapshotURL)
            let snapshot = try decoder.decode(CachedSnapshot.self, from: data)
            return snapshot
        } catch {
            print("[LocalCache] Failed to load snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether a cached snapshot exists (for quickly determining if we have offline data)
    var hasCachedSnapshot: Bool {
        fileManager.fileExists(atPath: snapshotURL.path)
    }

    // MARK: - Mutation Queue

    /// Enqueues an offline mutation to be replayed when connectivity returns
    func enqueueMutation(_ mutation: OfflineMutation) {
        var queue = loadMutationQueue()
        queue.append(mutation)
        saveMutationQueue(queue)
    }

    /// Loads all pending offline mutations
    func loadMutationQueue() -> [OfflineMutation] {
        guard fileManager.fileExists(atPath: mutationQueueURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: mutationQueueURL)
            return try decoder.decode([OfflineMutation].self, from: data)
        } catch {
            print("[LocalCache] Failed to load mutation queue: \(error.localizedDescription)")
            return []
        }
    }

    /// Removes a successfully replayed mutation from the queue
    func removeMutation(id: String) {
        var queue = loadMutationQueue()
        queue.removeAll { $0.id == id }
        saveMutationQueue(queue)
    }

    /// Increments retry count for a failed mutation
    func incrementRetry(id: String) {
        var queue = loadMutationQueue()
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue[index].retryCount += 1
        }
        saveMutationQueue(queue)
    }

    /// Clears all pending mutations (e.g., after sign out)
    func clearMutationQueue() {
        try? fileManager.removeItem(at: mutationQueueURL)
    }

    /// Returns count of pending offline mutations
    var pendingMutationCount: Int {
        loadMutationQueue().count
    }

    /// Whether there are pending mutations to replay
    var hasPendingMutations: Bool {
        pendingMutationCount > 0
    }

    // MARK: - Cleanup

    /// Clears all cached data (snapshot + mutations)
    func clearAll() {
        try? fileManager.removeItem(at: snapshotURL)
        clearMutationQueue()
    }

    // MARK: - Private

    private func saveMutationQueue(_ queue: [OfflineMutation]) {
        do {
            let data = try encoder.encode(queue)
            try data.write(to: mutationQueueURL, options: .atomic)
        } catch {
            print("[LocalCache] Failed to save mutation queue: \(error.localizedDescription)")
        }
    }

    private func ensureCacheDirectory() {
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - Network Monitor

/// Monitors network connectivity and publishes state changes
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.google.tasks.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
