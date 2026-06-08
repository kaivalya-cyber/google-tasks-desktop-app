import Foundation
import Combine
import SwiftUI

// MARK: - Data Manager

/// Central state manager for the Google Tasks desktop app.
/// Coordinates authentication, API calls, local persistence, and offline support.
/// - Online: Fetches from Google Tasks API and caches locally
/// - Offline: Reads from local cache and queues mutations for replay
@MainActor
final class DataManager: ObservableObject {
    static let shared = DataManager()

    // MARK: - Published State

    @Published var taskLists: [TaskList] = []
    @Published var tasksByListId: [String: [GoogleTask]] = [:]
    @Published var selectedTaskListId: String?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isOffline: Bool = false
    @Published var pendingMutations: Int = 0

    // Auth is managed by AuthManager
    var authManager: AuthManager { AuthManager.shared }

    private let apiService = GoogleTasksAPIService.shared
    private let cache = LocalCache.shared
    private let networkMonitor = NetworkMonitor.shared
    private var refreshTimer: Timer?
    private var isReplayingMutations: Bool = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupNotificationObservers()
    }

    // MARK: - Cache Helpers

    /// Persists the current in-memory state to the local JSON cache
    private func saveToCache() {
        cache.saveSnapshot(
            taskLists: taskLists,
            tasksByListId: tasksByListId,
            selectedTaskListId: selectedTaskListId
        )
    }

    /// Loads state from the local cache, restoring the previous session's data
    private func loadFromCache() -> Bool {
        guard let snapshot = cache.loadSnapshot() else { return false }

        self.taskLists = snapshot.taskLists
        self.tasksByListId = snapshot.tasksByListId
        self.selectedTaskListId = snapshot.selectedTaskListId

        if selectedTaskListId == nil || !taskLists.contains(where: { $0.id == selectedTaskListId }) {
            selectedTaskListId = taskLists.first?.id
        }

        NotificationCenter.default.post(name: AppConstants.Notifications.taskListsDidUpdate, object: nil)
        NotificationCenter.default.post(name: AppConstants.Notifications.tasksDidUpdate, object: nil)
        return true
    }

    // MARK: - Public API

    /// Loads all task lists, falling back to cache when offline
    func loadTaskLists() async {
        guard authManager.isAuthenticated else { return }

        isLoading = true
        errorMessage = nil

        do {
            let lists = try await apiService.fetchTaskLists()
            self.taskLists = lists

            if selectedTaskListId == nil || !lists.contains(where: { $0.id == selectedTaskListId }) {
                selectedTaskListId = lists.first?.id
            }

            saveToCache()
            NotificationCenter.default.post(name: AppConstants.Notifications.taskListsDidUpdate, object: nil)
        } catch {
            // Fall back to cache if offline
            if networkMonitor.isConnected == false && cache.hasCachedSnapshot {
                _ = loadFromCache()
                isOffline = true
                errorMessage = "You're offline — showing cached data"
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    /// Loads tasks for the selected list, falling back to cache when offline
    func loadTasks(for listId: String? = nil) async {
        guard authManager.isAuthenticated else { return }
        let targetListId = listId ?? selectedTaskListId
        guard let targetListId = targetListId else { return }

        isLoading = true
        errorMessage = nil

        do {
            let tasks = try await apiService.fetchTasks(taskListId: targetListId)
            self.tasksByListId[targetListId] = tasks
            saveToCache()
            NotificationCenter.default.post(name: AppConstants.Notifications.tasksDidUpdate, object: nil)
        } catch {
            // Fall back to cache
            if cache.hasCachedSnapshot {
                _ = loadFromCache()
                isOffline = true
                errorMessage = "You're offline — showing cached data"
            } else {
                errorMessage = error.localizedDescription
            }
        }

        isLoading = false
    }

    /// Loads all data (lists + tasks), with cache fallback
    func refreshAll() async {
        guard authManager.isAuthenticated else { return }

        if !networkMonitor.isConnected {
            // Offline: load from cache
            isLoading = true
            errorMessage = nil
            isOffline = true

            if loadFromCache() {
                errorMessage = "You're offline — showing cached data"
            } else {
                errorMessage = "You're offline and no cached data is available"
            }

            pendingMutations = cache.pendingMutationCount
            isLoading = false
            return
        }

        // Online: fetch from API and update cache
        isOffline = false
        isLoading = true
        errorMessage = nil

        do {
            let lists = try await apiService.fetchTaskLists()
            self.taskLists = lists

            if selectedTaskListId == nil || !lists.contains(where: { $0.id == selectedTaskListId }) {
                selectedTaskListId = lists.first?.id
            }

            saveToCache()
            NotificationCenter.default.post(name: AppConstants.Notifications.taskListsDidUpdate, object: nil)

            if let selectedId = selectedTaskListId {
                let tasks = try await apiService.fetchTasks(taskListId: selectedId)
                self.tasksByListId[selectedId] = tasks
                saveToCache()
                NotificationCenter.default.post(name: AppConstants.Notifications.tasksDidUpdate, object: nil)
            }

            // Replay any pending offline mutations
            await replayPendingMutations()
        } catch {
            // Fall back to cache if available
            if cache.hasCachedSnapshot {
                _ = loadFromCache()
                isOffline = true
                errorMessage = "Connection lost — showing cached data"
            } else {
                errorMessage = error.localizedDescription
            }
        }

        pendingMutations = cache.pendingMutationCount
        isLoading = false
    }

    /// Creates a new task, queuing the mutation if offline
    func createTask(title: String, notes: String? = nil, due: Date? = nil, parent: String? = nil) async -> GoogleTask? {
        guard let listId = selectedTaskListId else { return nil }

        isLoading = true
        errorMessage = nil

        do {
            let task = try await apiService.createTask(taskListId: listId, title: title, notes: notes, due: due, parent: parent)
            await loadTasks()
            return task
        } catch {
            // Queue offline mutation
            if !networkMonitor.isConnected {
                var payload: [String: String] = ["title": title]
                if let notes = notes { payload["notes"] = notes }
                if let due = due { payload["due"] = due.googleDateString }

                let mutation = OfflineMutation(
                    type: .createTask,
                    taskListId: listId,
                    taskId: parent,
                    payload: payload
                )
                cache.enqueueMutation(mutation)

                // Optimistically add to local state
                let tempTask = GoogleTask(
                    id: mutation.id,
                    title: title,
                    updated: nil,
                    selfLink: nil,
                    parent: parent,
                    position: nil,
                    notes: notes,
                    status: "needsAction",
                    due: due?.googleDateString,
                    completed: nil,
                    deleted: nil,
                    hidden: nil
                )
                var currentTasks = tasksByListId[listId] ?? []
                currentTasks.append(tempTask)
                tasksByListId[listId] = currentTasks
                saveToCache()

                isOffline = true
                pendingMutations = cache.pendingMutationCount
                errorMessage = "Saved offline — will sync when connected"
                isLoading = false
                return tempTask
            }

            errorMessage = error.localizedDescription
        }

        isLoading = false
        return nil
    }

    /// Updates an existing task, queuing the mutation if offline
    func updateTask(taskId: String, title: String? = nil, notes: String? = nil, status: String? = nil, due: Date? = nil) async -> GoogleTask? {
        guard let listId = selectedTaskListId else { return nil }

        isLoading = true
        errorMessage = nil

        do {
            let task = try await apiService.updateTask(taskListId: listId, taskId: taskId, title: title, notes: notes, status: status, due: due)
            await loadTasks()
            return task
        } catch {
            if !networkMonitor.isConnected {
                var payload: [String: String] = [:]
                if let title = title { payload["title"] = title }
                if let notes = notes { payload["notes"] = notes }
                if let status = status { payload["status"] = status }
                if let due = due { payload["due"] = due.googleDateString }

                let mutation = OfflineMutation(
                    type: .updateTask,
                    taskListId: listId,
                    taskId: taskId,
                    payload: payload
                )
                cache.enqueueMutation(mutation)

                // Optimistically update local state
                if var tasks = tasksByListId[listId],
                   let index = tasks.firstIndex(where: { $0.id == taskId }) {
                    let completionString = status == "completed" ? ISO8601DateFormatter().string(from: Date()) : nil
                    tasks[index] = tasks[index].with(
                        title: title,
                        notes: notes,
                        status: status,
                        due: due?.googleDateString,
                        completed: status == "completed" ? completionString : nil
                    )
                    tasksByListId[listId] = tasks
                    saveToCache()
                }

                isOffline = true
                pendingMutations = cache.pendingMutationCount
                errorMessage = "Saved offline — will sync when connected"
                isLoading = false
                return nil
            }

            errorMessage = error.localizedDescription
        }

        isLoading = false
        return nil
    }

    /// Toggles task completion status, queuing if offline
    func toggleTaskCompletion(task: GoogleTask) async {
        guard let listId = selectedTaskListId else { return }

        isLoading = true
        errorMessage = nil

        do {
            let newStatus = task.isCompleted ? "needsAction" : "completed"
            _ = try await apiService.updateTask(taskListId: listId, taskId: task.id, status: newStatus)
            await loadTasks()
        } catch {
            if !networkMonitor.isConnected {
                let newStatus = task.isCompleted ? "needsAction" : "completed"
                let mutation = OfflineMutation(
                    type: .toggleTask,
                    taskListId: listId,
                    taskId: task.id,
                    payload: ["status": newStatus]
                )
                cache.enqueueMutation(mutation)

                // Optimistically toggle local state
                if var tasks = tasksByListId[listId],
                   let index = tasks.firstIndex(where: { $0.id == task.id }) {
                    let completionString = newStatus == "completed" ? ISO8601DateFormatter().string(from: Date()) : nil
                    tasks[index] = tasks[index].with(
                        status: newStatus,
                        completed: completionString
                    )
                    tasksByListId[listId] = tasks
                    saveToCache()
                }

                isOffline = true
                pendingMutations = cache.pendingMutationCount
                errorMessage = "Saved offline — will sync when connected"
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Deletes a task, queuing if offline
    func deleteTask(taskId: String) async {
        guard let listId = selectedTaskListId else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await apiService.deleteTask(taskListId: listId, taskId: taskId)
            await loadTasks()
        } catch {
            if !networkMonitor.isConnected {
                let mutation = OfflineMutation(
                    type: .deleteTask,
                    taskListId: listId,
                    taskId: taskId
                )
                cache.enqueueMutation(mutation)

                // Optimistically remove from local state
                tasksByListId[listId]?.removeAll { $0.id == taskId }
                saveToCache()

                isOffline = true
                pendingMutations = cache.pendingMutationCount
                errorMessage = "Saved offline — will sync when connected"
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Creates a new task list, queuing if offline
    func createTaskList(title: String) async -> TaskList? {
        guard authManager.isAuthenticated else { return nil }

        isLoading = true
        errorMessage = nil

        do {
            let list = try await apiService.createTaskList(title: title)
            await loadTaskLists()
            selectedTaskListId = list.id
            await loadTasks(for: list.id)
            return list
        } catch {
            if !networkMonitor.isConnected {
                let mutation = OfflineMutation(
                    type: .createList,
                    taskListId: "user",
                    payload: ["title": title]
                )
                cache.enqueueMutation(mutation)

                // Optimistically add temp list
                let tempList = TaskList(id: mutation.id, title: title, updated: nil, selfLink: nil)
                taskLists.append(tempList)
                tasksByListId[tempList.id] = []
                selectedTaskListId = tempList.id
                saveToCache()

                isOffline = true
                pendingMutations = cache.pendingMutationCount
                errorMessage = "Saved offline — will sync when connected"
                isLoading = false
                return tempList
            }
            errorMessage = error.localizedDescription
        }

        isLoading = false
        return nil
    }

    /// Deletes a task list, queuing if offline
    func deleteTaskList(id: String) async {
        guard authManager.isAuthenticated else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await apiService.deleteTaskList(id: id)
            await loadTaskLists()
        } catch {
            if !networkMonitor.isConnected {
                let mutation = OfflineMutation(
                    type: .deleteList,
                    taskListId: id
                )
                cache.enqueueMutation(mutation)

                // Optimistically remove from local state
                taskLists.removeAll { $0.id == id }
                tasksByListId.removeValue(forKey: id)
                if selectedTaskListId == id {
                    selectedTaskListId = taskLists.first?.id
                }
                saveToCache()

                isOffline = true
                pendingMutations = cache.pendingMutationCount
                errorMessage = "Saved offline — will sync when connected"
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Mutation Replay

    /// Replays all pending offline mutations against the live API
    func replayPendingMutations() async {
        guard !isReplayingMutations else { return }
        isReplayingMutations = true

        let mutations = cache.loadMutationQueue()

        for mutation in mutations {
            do {
                try await replayMutation(mutation)
                cache.removeMutation(id: mutation.id)
            } catch {
                cache.incrementRetry(id: mutation.id)
                // Don't stop — try remaining mutations
            }
        }

        // Refresh state after replay
        await refreshAll()
        pendingMutations = cache.pendingMutationCount
        isReplayingMutations = false
    }

    private func replayMutation(_ mutation: OfflineMutation) async throws {
        let dict = mutation.payloadDict ?? [:]

        switch mutation.type {
        case .createTask:
            _ = try await apiService.createTask(
                taskListId: mutation.taskListId,
                title: dict["title"] ?? "Untitled",
                notes: dict["notes"],
                due: dict["due"].flatMap { Date.parseGoogleDate($0) }
            )
        case .updateTask:
            _ = try await apiService.updateTask(
                taskListId: mutation.taskListId,
                taskId: mutation.taskId ?? "",
                title: dict["title"],
                notes: dict["notes"],
                status: dict["status"],
                due: dict["due"].flatMap { Date.parseGoogleDate($0) }
            )
        case .toggleTask:
            _ = try await apiService.updateTask(
                taskListId: mutation.taskListId,
                taskId: mutation.taskId ?? "",
                status: dict["status"]
            )
        case .deleteTask:
            try await apiService.deleteTask(
                taskListId: mutation.taskListId,
                taskId: mutation.taskId ?? ""
            )
        case .createList:
            _ = try await apiService.createTaskList(title: dict["title"] ?? "Untitled")
        case .deleteList:
            try await apiService.deleteTaskList(id: mutation.taskListId)
        }
    }

    /// Returns tasks for the currently selected list
    var selectedListTasks: [GoogleTask] {
        guard let listId = selectedTaskListId else { return [] }
        return tasksByListId[listId] ?? []
    }

    /// Returns the currently selected task list
    var selectedTaskList: TaskList? {
        guard let listId = selectedTaskListId else { return nil }
        return taskLists.first { $0.id == listId }
    }

    /// Signs in to Google. Loads cached data first, then refreshes from API.
    func signIn() async {
        isLoading = true
        errorMessage = nil

        await authManager.signIn()

        if authManager.isAuthenticated {
            // Load cached data immediately for fast startup
            _ = loadFromCache()

            // Then refresh from API
            await refreshAll()
            startAutoRefresh()
        } else if case .error(let authError) = authManager.authState {
            if case AuthError.userCancelled = authError {
                // User cancelled - no error needed
            } else {
                errorMessage = authError.localizedDescription
            }
        }

        isLoading = false
    }

    /// Signs out of Google, clearing local data
    func signOut() {
        authManager.signOut()
        taskLists = []
        tasksByListId = [:]
        selectedTaskListId = nil
        errorMessage = nil
        isOffline = false
        cache.clearAll()
    }

    // MARK: - Auto-refresh

    func startAutoRefresh(interval: TimeInterval = 60) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.authManager.isAuthenticated == true {
                    await self?.refreshAll()
                }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Private

    private func setupNotificationObservers() {
        // Sign-in handler
        NotificationCenter.default.publisher(for: AppConstants.Notifications.didSignIn)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshAll()
                    self?.startAutoRefresh()
                }
            }
            .store(in: &cancellables)

        // Network state changes
        networkMonitor.$isConnected
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if connected && self.authManager.isAuthenticated {
                        self.isOffline = false
                        // refreshAll already replays pending mutations internally
                        await self.refreshAll()
                    }
                }
            }
            .store(in: &cancellables)
    }
}
