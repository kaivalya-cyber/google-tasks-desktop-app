import Foundation
import Combine
import SwiftUI

// MARK: - Data Manager

/// Central state manager for the Google Tasks desktop app.
/// Coordinates authentication, API calls, and local state.
@MainActor
final class DataManager: ObservableObject {
    static let shared = DataManager()

    // MARK: - Published State

    @Published var taskLists: [TaskList] = []
    @Published var tasksByListId: [String: [GoogleTask]] = [:]
    @Published var selectedTaskListId: String?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Auth is managed by AuthManager
    var authManager: AuthManager { AuthManager.shared }

    private let apiService = GoogleTasksAPIService.shared
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupNotificationObservers()
    }

    // MARK: - Public API

    /// Loads all task lists
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

            NotificationCenter.default.post(name: AppConstants.Notifications.taskListsDidUpdate, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Loads tasks for the selected list
    func loadTasks(for listId: String? = nil) async {
        guard authManager.isAuthenticated else { return }
        let targetListId = listId ?? selectedTaskListId
        guard let targetListId = targetListId else { return }

        isLoading = true
        errorMessage = nil

        do {
            let tasks = try await apiService.fetchTasks(taskListId: targetListId)
            self.tasksByListId[targetListId] = tasks
            NotificationCenter.default.post(name: AppConstants.Notifications.tasksDidUpdate, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Loads all data (lists + tasks)
    func refreshAll() async {
        guard authManager.isAuthenticated else { return }

        isLoading = true
        errorMessage = nil

        do {
            let lists = try await apiService.fetchTaskLists()
            self.taskLists = lists

            if selectedTaskListId == nil || !lists.contains(where: { $0.id == selectedTaskListId }) {
                selectedTaskListId = lists.first?.id
            }

            NotificationCenter.default.post(name: AppConstants.Notifications.taskListsDidUpdate, object: nil)

            if let selectedId = selectedTaskListId {
                let tasks = try await apiService.fetchTasks(taskListId: selectedId)
                self.tasksByListId[selectedId] = tasks
                NotificationCenter.default.post(name: AppConstants.Notifications.tasksDidUpdate, object: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Creates a new task
    func createTask(title: String, notes: String? = nil, due: Date? = nil, parent: String? = nil) async -> GoogleTask? {
        guard let listId = selectedTaskListId else { return nil }

        isLoading = true
        errorMessage = nil

        do {
            let task = try await apiService.createTask(taskListId: listId, title: title, notes: notes, due: due, parent: parent)
            await loadTasks()
            return task
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        return nil
    }

    /// Updates an existing task
    func updateTask(taskId: String, title: String? = nil, notes: String? = nil, status: String? = nil, due: Date? = nil) async -> GoogleTask? {
        guard let listId = selectedTaskListId else { return nil }

        isLoading = true
        errorMessage = nil

        do {
            let task = try await apiService.updateTask(taskListId: listId, taskId: taskId, title: title, notes: notes, status: status, due: due)
            await loadTasks()
            return task
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        return nil
    }

    /// Toggles task completion status
    func toggleTaskCompletion(task: GoogleTask) async {
        guard let listId = selectedTaskListId else { return }

        isLoading = true
        errorMessage = nil

        do {
            let newStatus = task.isCompleted ? "needsAction" : "completed"
            _ = try await apiService.updateTask(taskListId: listId, taskId: task.id, status: newStatus)
            await loadTasks()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Deletes a task
    func deleteTask(taskId: String) async {
        guard let listId = selectedTaskListId else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await apiService.deleteTask(taskListId: listId, taskId: taskId)
            await loadTasks()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Creates a new task list
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
            errorMessage = error.localizedDescription
        }

        isLoading = false
        return nil
    }

    /// Deletes a task list
    func deleteTaskList(id: String) async {
        guard authManager.isAuthenticated else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await apiService.deleteTaskList(id: id)
            await loadTaskLists()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
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

    /// Signs in to Google. Surfaces auth errors in errorMessage.
    func signIn() async {
        isLoading = true
        errorMessage = nil

        await authManager.signIn()

        if authManager.isAuthenticated {
            await refreshAll()
        } else if case .error(let authError) = authManager.authState {
            // Only set error message for actual errors (not user cancellation)
            if case AuthError.userCancelled = authError {
                // User cancelled - no need to show error
            } else {
                errorMessage = authError.localizedDescription
            }
        }

        isLoading = false
    }

    /// Signs out of Google
    func signOut() {
        authManager.signOut()
        taskLists = []
        tasksByListId = [:]
        selectedTaskListId = nil
        errorMessage = nil
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
        NotificationCenter.default.publisher(for: AppConstants.Notifications.didSignIn)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshAll()
                    self?.startAutoRefresh()
                }
            }
            .store(in: &cancellables)
    }
}
