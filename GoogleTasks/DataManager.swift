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
    @Published var isSyncing: Bool = false

    // Auth is managed by AuthManager
    var authManager: AuthManager { AuthManager.shared }

    private let apiService = GoogleTasksAPIService.shared
    private let cache = LocalCache.shared
    private let networkMonitor = NetworkMonitor.shared
    private let notificationManager = NotificationManager.shared
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
            await scheduleNotificationsIfNeeded()
        } catch {
            // Fall back to cache if offline
            if networkMonitor.isConnected == false && cache.hasCachedSnapshot {
                _ = loadFromCache()
                isOffline = true
                errorMessage = "You're offline — showing cached data"
                await scheduleNotificationsIfNeeded()
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

        await scheduleNotificationsIfNeeded()
    }

    /// Creates a new task, queuing the mutation if offline
    func createTask(title: String, notes: String? = nil, due: Date? = nil, parent: String? = nil) async -> GoogleTask? {
        guard let listId = selectedTaskListId else { return nil }
        let listName = selectedTaskList?.displayTitle ?? ""

        isLoading = true
        errorMessage = nil

        do {
            let task = try await apiService.createTask(taskListId: listId, title: title, notes: notes, due: due, parent: parent)
            if let due = due {
                await notificationManager.scheduleTaskDueNotification(taskId: task.id, dueDate: due, title: task.title, listName: listName)
            }
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
        let listName = selectedTaskList?.displayTitle ?? ""

        isLoading = true
        errorMessage = nil

        do {
            let task = try await apiService.updateTask(taskListId: listId, taskId: taskId, title: title, notes: notes, status: status, due: due)
            // Only touch notifications when due date was explicitly provided
            if let due = due {
                notificationManager.cancelTaskNotification(taskId: taskId)
                await notificationManager.scheduleTaskDueNotification(taskId: taskId, dueDate: due, title: task.title, listName: listName)
            }
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
            // Cancel notification if marking complete, or reschedule if uncompleting
            if newStatus == "completed" {
                notificationManager.cancelTaskNotification(taskId: task.id)
            } else if let dueDate = task.dueDate, dueDate > Date() {
                await notificationManager.scheduleTaskDueNotification(taskId: task.id, dueDate: dueDate, title: task.title, listName: selectedTaskList?.displayTitle ?? "")
            }
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
                    let completionString = newStatus == "completed" ? ISO8601DateFormatter().string(from: Date()) : nil                    tasks[index] = tasks[index].with(status: newStatus, completed: .some(completionString))
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
            notificationManager.cancelTaskNotification(taskId: taskId)
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

    /// Clears all completed tasks from the currently selected list
    func clearCompletedTasks() async {
        guard let listId = selectedTaskListId else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await apiService.clearCompletedTasks(taskListId: listId)
            await loadTasks()
        } catch {
            if networkMonitor.isConnected {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "Cannot clear tasks while offline"
            }
        }

        isLoading = false
    }

    // MARK: - Task Reordering

    /// Moves a task to a different task list
    func moveTaskToList(taskId: String, toListId: String) async {
        guard let fromListId = selectedTaskListId,
              fromListId != toListId else { return }

        isLoading = true
        errorMessage = nil

        do {
            _ = try await apiService.moveTask(
                taskListId: fromListId,
                taskId: taskId,
                destinationTaskListId: toListId
            )
            // Refresh both source and destination
            await loadTasks(for: fromListId)
            await loadTasks(for: toListId)
            NotificationCenter.default.post(name: AppConstants.Notifications.tasksDidUpdate, object: nil)
        } catch {
            if networkMonitor.isConnected {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "Cannot move tasks while offline"
            }
        }

        isLoading = false
    }

    // MARK: - Mutation Replay

    /// Replays all pending offline mutations against the live API
    func replayPendingMutations() async {
        guard !isReplayingMutations else { return }
        isReplayingMutations = true
        isSyncing = true

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
        isSyncing = false
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

    /// Returns all tasks (including nested subtasks) for the selected list, flattened
    var allTasksInSelectedList: [GoogleTask] {
        var result: [GoogleTask] = []
        for task in selectedListTasks {
            collectTasks(task, into: &result)
        }
        return result
    }

    private func collectTasks(_ task: GoogleTask, into result: inout [GoogleTask]) {
        result.append(task)
        if let subtasks = task.subtasks {
            for subtask in subtasks {
                collectTasks(subtask, into: &result)
            }
        }
    }

    /// Returns the currently selected task list
    var selectedTaskList: TaskList? {
        guard let listId = selectedTaskListId else { return nil }
        return taskLists.first { $0.id == listId }
    }

    /// Returns all incomplete tasks due today or overdue, across all lists (flattened)
    var allTasksDueToday: [GoogleTask] {
        var result: [GoogleTask] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for (_, tasks) in tasksByListId {
            for task in tasks {
                collectDueToday(task, today: today, into: &result)
            }
        }
        return result.sorted { ($0.due ?? "") < ($1.due ?? "") }
    }

    private func collectDueToday(_ task: GoogleTask, today: Date, into result: inout [GoogleTask]) {
        if !task.isCompleted, let dueDate = task.dueDate {
            let dueDay = Calendar.current.startOfDay(for: dueDate)
            if dueDay <= today {
                result.append(task)
            }
        }
        if let subtasks = task.subtasks {
            for subtask in subtasks {
                collectDueToday(subtask, today: today, into: &result)
            }
        }
    }

    /// Batch-deletes multiple tasks
    func batchDeleteTasks(taskIds: Set<String>) async {
        guard let listId = selectedTaskListId else { return }
        isLoading = true
        errorMessage = nil
        var failed = 0
        for taskId in taskIds {
            do {
                try await apiService.deleteTask(taskListId: listId, taskId: taskId)
            } catch {
                failed += 1
            }
        }
        await loadTasks()
        if failed > 0 { errorMessage = "\(failed) deletion(s) failed" }
        isLoading = false
    }

    /// Returns all tasks completed in the past 7 days, across all lists
    var allTasksCompletedThisWeek: [GoogleTask] {
        var result: [GoogleTask] = []
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) else { return [] }
        for (_, tasks) in tasksByListId {
            for task in tasks {
                collectCompletedThisWeek(task, weekAgo: weekAgo, into: &result)
            }
        }
        return result.sorted { ($0.completed ?? "") > ($1.completed ?? "") }
    }

    private func collectCompletedThisWeek(_ task: GoogleTask, weekAgo: Date, into result: inout [GoogleTask]) {
        if task.isCompleted, let completedDate = task.completedDate, completedDate >= weekAgo {
            result.append(task)
        }
        if let subtasks = task.subtasks {
            for subtask in subtasks {
                collectCompletedThisWeek(subtask, weekAgo: weekAgo, into: &result)
            }
        }
    }

    /// Batch-moves multiple tasks to another list
    func batchMoveTasks(taskIds: Set<String>, toListId: String) async {
        guard let fromListId = selectedTaskListId, fromListId != toListId else { return }
        isLoading = true
        errorMessage = nil
        var failed = 0
        for taskId in taskIds {
            do {
                _ = try await apiService.moveTask(
                    taskListId: fromListId, taskId: taskId,
                    destinationTaskListId: toListId
                )
            } catch {
                failed += 1
            }
        }
        await loadTasks(for: fromListId)
        await loadTasks(for: toListId)
        if failed > 0 { errorMessage = "\(failed) move(s) failed" }
        isLoading = false
    }

    /// Moves a task before another task within the same list (for drag-to-reorder)
    func moveTaskBefore(taskId: String, beforeId: String) async {
        guard let listId = selectedTaskListId,
              let tasks = tasksByListId[listId] else { return }

        // Find the task that should be "previous" to the moved task
        guard let beforeIndex = tasks.firstIndex(where: { $0.id == beforeId }) else { return }
        let previous = beforeIndex > 0 ? tasks[beforeIndex - 1].id : nil

        isLoading = true
        errorMessage = nil

        do {
            _ = try await apiService.moveTask(taskListId: listId, taskId: taskId, previous: previous)
            await loadTasks()
        } catch {
            if networkMonitor.isConnected {
                errorMessage = error.localizedDescription
            } else {
                errorMessage = "Cannot reorder tasks while offline"
            }
        }

        isLoading = false
    }

    /// Returns task counts (incomplete/total) for each list
    var taskCountsByListId: [String: (incomplete: Int, total: Int)] {
        var counts: [String: (incomplete: Int, total: Int)] = [:]
        for (listId, tasks) in tasksByListId {
            var incomplete = 0
            var total = 0
            countTasks(tasks, incomplete: &incomplete, total: &total)
            counts[listId] = (incomplete, total)
        }
        return counts
    }

    private func countTasks(_ tasks: [GoogleTask], incomplete: inout Int, total: inout Int) {
        for task in tasks {
            total += 1
            if !task.isCompleted { incomplete += 1 }
            if let subtasks = task.subtasks {
                countTasks(subtasks, incomplete: &incomplete, total: &total)
            }
        }
    }

    /// Exports all tasks as a Markdown string
    func exportTasksAsMarkdown() -> String {
        var md = "# Google Tasks\n\nExported: \(Date().formatted(date: .long, time: .shortened))\n\n"
        for list in taskLists {
            md += "## \(list.displayTitle)\n\n"
            guard let tasks = tasksByListId[list.id] else {
                md += "_No tasks_\n\n"
                continue
            }
            for task in tasks where !task.isCompleted {
                md += "- [ ] \(task.displayTitle)\n"
                if let notes = task.notes, !notes.isEmpty {
                    md += "  > \(notes.replacingOccurrences(of: "\n", with: "\n  > "))\n"
                }
                if let due = task.dueDate {
                    md += "  📅 \(due.formatted(date: .abbreviated, time: .omitted))\n"
                }
                exportSubtasks(task.subtasks ?? [], into: &md, indent: "  ")
            }
            for task in tasks where task.isCompleted {
                md += "- [x] \(task.displayTitle)\n"
                exportSubtasks(task.subtasks ?? [], into: &md, indent: "  ")
            }
            md += "\n"
        }
        return md
    }

    private func exportSubtasks(_ subtasks: [GoogleTask], into md: inout String, indent: String) {
        for subtask in subtasks {
            let prefix = subtask.isCompleted ? "[x]" : "[ ]"
            md += "\(indent)- \(prefix) \(subtask.displayTitle)\n"
            if let subSubtasks = subtask.subtasks {
                exportSubtasks(subSubtasks, into: &md, indent: indent + "  ")
            }
        }
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

    // MARK: - Notifications

    /// Schedules local notifications for tasks due today after a data refresh
    private func scheduleNotificationsIfNeeded() async {
        await notificationManager.scheduleDueDateNotifications(
            taskLists: taskLists,
            tasksByListId: tasksByListId
        )
    }

    // MARK: - Private

    private func setupNotificationObservers() {
        // Sign-in handler
        NotificationCenter.default.publisher(for: AppConstants.Notifications.didSignIn)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.notificationManager.requestAuthorization()
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
