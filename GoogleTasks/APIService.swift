import Foundation

// MARK: - API Error

enum GoogleTasksAPIError: LocalizedError {
    case unauthorized
    case notFound
    case clientError(statusCode: Int, message: String)
    case serverError(statusCode: Int, message: String)
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Unauthorized. Please sign in again."
        case .notFound:
            return "The requested resource was not found."
        case .clientError(let statusCode, let message):
            return "Request failed (\(statusCode)): \(message)"
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .invalidURL:
            return "Invalid URL."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .notAuthenticated:
            return "Not signed in to Google. Please sign in first."
        }
    }
}

// MARK: - API Service

/// REST client for the Google Tasks API.
/// Handles all CRUD operations for task lists and tasks.
@MainActor
final class GoogleTasksAPIService {
    static let shared = GoogleTasksAPIService()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .prettyPrinted
    }

    // MARK: - Task Lists

    /// Fetches all task lists for the authenticated user
    func fetchTaskLists() async throws -> [TaskList] {
        let urlString = "\(AppConstants.API.baseURL)/users/@me/lists"
        let response: TaskListsResponse = try await authenticatedRequest(urlString: urlString)
        return response.items ?? []
    }

    /// Fetches a single task list by ID
    func fetchTaskList(id: String) async throws -> TaskList {
        let urlString = "\(AppConstants.API.baseURL)/users/@me/lists/\(id)"
        return try await authenticatedRequest(urlString: urlString)
    }

    /// Creates a new task list
    func createTaskList(title: String) async throws -> TaskList {
        let urlString = "\(AppConstants.API.baseURL)/users/@me/lists"
        let body = TaskListRequestBody(title: title)
        return try await authenticatedRequest(urlString: urlString, method: "POST", body: body)
    }

    /// Updates an existing task list
    func updateTaskList(id: String, title: String) async throws -> TaskList {
        let urlString = "\(AppConstants.API.baseURL)/users/@me/lists/\(id)"
        let body = TaskListRequestBody(title: title)
        return try await authenticatedRequest(urlString: urlString, method: "PATCH", body: body)
    }

    /// Deletes a task list
    func deleteTaskList(id: String) async throws {
        let urlString = "\(AppConstants.API.baseURL)/users/@me/lists/\(id)"
        try await authenticatedRequestVoid(urlString: urlString, method: "DELETE")
    }

    // MARK: - Tasks

    /// Fetches all tasks in a task list (optionally including completed/hidden)
    func fetchTasks(taskListId: String, showCompleted: Bool = true, showHidden: Bool = false) async throws -> [GoogleTask] {
        var components = URLComponents(string: "\(AppConstants.API.baseURL)/lists/\(taskListId)/tasks")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "maxResults", value: String(AppConstants.API.maxResults)),
            URLQueryItem(name: "showCompleted", value: String(showCompleted)),
            URLQueryItem(name: "showHidden", value: String(showHidden))
        ]
        components.queryItems = queryItems

        guard let urlString = components.url?.absoluteString else {
            throw GoogleTasksAPIError.invalidURL
        }

        let response: TasksResponse = try await authenticatedRequest(urlString: urlString)
        let allTasks = response.items ?? []

        // Build subtask hierarchy
        return buildTaskHierarchy(tasks: allTasks)
    }

    /// Fetches a single task
    func fetchTask(taskListId: String, taskId: String) async throws -> GoogleTask {
        let urlString = "\(AppConstants.API.baseURL)/lists/\(taskListId)/tasks/\(taskId)"
        return try await authenticatedRequest(urlString: urlString)
    }

    /// Creates a new task
    func createTask(taskListId: String, title: String, notes: String? = nil, due: Date? = nil, parent: String? = nil) async throws -> GoogleTask {
        let urlString = "\(AppConstants.API.baseURL)/lists/\(taskListId)/tasks"

        let dueString: String?
        if let due = due {
            dueString = due.googleDateString
        } else {
            dueString = nil
        }

        let body: [String: Any?] = [
            "title": title,
            "notes": notes,
            "due": dueString,
            "parent": parent
        ]

        let cleanBody = body.compactMapValues { $0 }
        return try await authenticatedRequest(urlString: urlString, method: "POST", body: cleanBody)
    }

    /// Updates an existing task (PATCH for partial updates)
    func updateTask(taskListId: String, taskId: String, title: String? = nil, notes: String? = nil, status: String? = nil, due: Date? = nil) async throws -> GoogleTask {
        let urlString = "\(AppConstants.API.baseURL)/lists/\(taskListId)/tasks/\(taskId)"

        let dueString: String?
        if let due = due {
            dueString = due.googleDateString
        } else {
            dueString = nil
        }

        let body: [String: Any?] = [
            "title": title,
            "notes": notes,
            "status": status,
            "due": dueString
        ]

        let cleanBody = body.compactMapValues { $0 }
        return try await authenticatedRequest(urlString: urlString, method: "PATCH", body: cleanBody)
    }

    /// Moves a task to a new position or parent
    func moveTask(taskListId: String, taskId: String, parent: String? = nil, previous: String? = nil) async throws -> GoogleTask {
        var components = URLComponents(string: "\(AppConstants.API.baseURL)/lists/\(taskListId)/tasks/\(taskId)/move")!
        var queryItems: [URLQueryItem] = []
        if let parent = parent {
            queryItems.append(URLQueryItem(name: "parent", value: parent))
        }
        if let previous = previous {
            queryItems.append(URLQueryItem(name: "previous", value: previous))
        }
        components.queryItems = queryItems

        guard let urlString = components.url?.absoluteString else {
            throw GoogleTasksAPIError.invalidURL
        }

        return try await authenticatedRequest(urlString: urlString, method: "POST")
    }

    /// Deletes a task
    func deleteTask(taskListId: String, taskId: String) async throws {
        let urlString = "\(AppConstants.API.baseURL)/lists/\(taskListId)/tasks/\(taskId)"
        try await authenticatedRequestVoid(urlString: urlString, method: "DELETE")
    }

    /// Clears all completed tasks from a task list
    func clearCompletedTasks(taskListId: String) async throws {
        let urlString = "\(AppConstants.API.baseURL)/lists/\(taskListId)/clear"
        try await authenticatedRequestVoid(urlString: urlString, method: "POST")
    }

    // MARK: - Private Helpers

    private func authenticatedRequest<T: Decodable>(urlString: String, method: String = "GET", body: Encodable? = nil) async throws -> T {
        let data = try await authenticatedRequestData(urlString: urlString, method: method, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GoogleTasksAPIError.decodingError(error)
        }
    }

    private func authenticatedRequest<T: Decodable>(urlString: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let jsonBody: Data?
        if let body = body {
            jsonBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            jsonBody = nil
        }
        let data = try await authenticatedRequestData(urlString: urlString, method: method, jsonBody: jsonBody)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GoogleTasksAPIError.decodingError(error)
        }
    }

    private func authenticatedRequestVoid(urlString: String, method: String = "GET") async throws {
        _ = try await authenticatedRequestData(urlString: urlString, method: method)
    }

    private func authenticatedRequestData(urlString: String, method: String = "GET", body: Encodable? = nil) async throws -> Data {
        let jsonBody: Data?
        if let body = body {
            jsonBody = try encoder.encode(AnyEncodable(body))
        } else {
            jsonBody = nil
        }
        return try await authenticatedRequestData(urlString: urlString, method: method, jsonBody: jsonBody)
    }

    private func authenticatedRequestData(urlString: String, method: String, jsonBody: Data? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw GoogleTasksAPIError.invalidURL
        }

        let accessToken = try await AuthManager.shared.getAccessToken()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleTasksAPIError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
            switch httpResponse.statusCode {
            case 401:
                throw GoogleTasksAPIError.unauthorized
            case 404:
                throw GoogleTasksAPIError.notFound
            case 400...499:
                throw GoogleTasksAPIError.clientError(statusCode: httpResponse.statusCode, message: errorBody)
            default:
                throw GoogleTasksAPIError.serverError(statusCode: httpResponse.statusCode, message: errorBody)
            }
        }

        return data
    }

    /// Organizes flat task list into a parent-child hierarchy
    private func buildTaskHierarchy(tasks: [GoogleTask]) -> [GoogleTask] {
        var tasksById: [String: GoogleTask] = [:]
        var rootTasks: [GoogleTask] = []
        var childTasksByParent: [String: [GoogleTask]] = [:]

        for task in tasks {
            let cleanTask = GoogleTask(
                id: task.id,
                title: task.title,
                updated: task.updated,
                selfLink: task.selfLink,
                parent: task.parent,
                position: task.position,
                notes: task.notes,
                status: task.status,
                due: task.due,
                completed: task.completed,
                deleted: task.deleted,
                hidden: task.hidden,
                links: task.links,
                subtasks: nil
            )
            tasksById[task.id] = cleanTask

            if let parent = task.parent, !parent.isEmpty {
                childTasksByParent[parent, default: []].append(cleanTask)
            } else {
                rootTasks.append(cleanTask)
            }
        }

        func attachSubtasks(to tasks: [GoogleTask]) -> [GoogleTask] {
            tasks.map { task in
                var updatedTask = task
                if let children = childTasksByParent[task.id] {
                    updatedTask.subtasks = attachSubtasks(to: children)
                        .sorted { ($0.position ?? "0").compare($1.position ?? "0", options: .numeric) == .orderedAscending }
                }
                return updatedTask
            }
        }

        rootTasks = attachSubtasks(to: rootTasks)
        rootTasks.sort { ($0.position ?? "0").compare($1.position ?? "0", options: .numeric) == .orderedAscending }

        return rootTasks
    }
}

// MARK: - Helper for Encoding Any Encodable

struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init<T: Encodable>(_ wrapped: T) {
        self._encode = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
