import Foundation
import SwiftUI

// MARK: - Task Priority

enum TaskPriority: String, CaseIterable {
    case none = ""
    case low = "!"
    case medium = "!!"
    case high = "!!!"

    var prefix: String { rawValue.isEmpty ? "" : "\(rawValue) " }
    var label: String {
        switch self {
        case .none: return "None"
        case .low: return "! Low"
        case .medium: return "!! Medium"
        case .high: return "!!! High"
        }
    }

    var color: Color {
        switch self {
        case .none: return .secondary
        case .low: return .blue
        case .medium: return .orange
        case .high: return .red
        }
    }
}

// MARK: - Task List

struct TaskList: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let updated: String?
    let selfLink: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case updated
        case selfLink
    }

    var lastUpdatedDate: Date? {
        guard let updated = updated else { return nil }
        return Date.parseRFC3339(updated)
    }

    var displayTitle: String {
        title.isEmpty ? "Untitled List" : title
    }

    static func == (lhs: TaskList, rhs: TaskList) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.updated == rhs.updated
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Task

struct GoogleTask: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let updated: String?
    let selfLink: String?
    let parent: String?
    let position: String?
    var notes: String?
    var status: String?
    var due: String?
    var completed: String?
    var deleted: Bool?
    var hidden: Bool?
    var links: [TaskLink]?
    var subtasks: [GoogleTask]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case updated
        case selfLink
        case parent
        case position
        case notes
        case status
        case due
        case completed
        case deleted
        case hidden
        case links
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        updated = try container.decodeIfPresent(String.self, forKey: .updated)
        selfLink = try container.decodeIfPresent(String.self, forKey: .selfLink)
        parent = try container.decodeIfPresent(String.self, forKey: .parent)
        position = try container.decodeIfPresent(String.self, forKey: .position)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        completed = try container.decodeIfPresent(String.self, forKey: .completed)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden)
        links = try container.decodeIfPresent([TaskLink].self, forKey: .links)
        subtasks = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(updated, forKey: .updated)
        try container.encodeIfPresent(selfLink, forKey: .selfLink)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encodeIfPresent(position, forKey: .position)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(due, forKey: .due)
        try container.encodeIfPresent(completed, forKey: .completed)
        try container.encodeIfPresent(deleted, forKey: .deleted)
        try container.encodeIfPresent(hidden, forKey: .hidden)
        try container.encodeIfPresent(links, forKey: .links)
    }

    init(id: String, title: String, updated: String?, selfLink: String?, parent: String?, position: String?, notes: String?, status: String?, due: String?, completed: String?, deleted: Bool?, hidden: Bool?, links: [TaskLink]? = nil, subtasks: [GoogleTask]? = nil) {
        self.id = id
        self.title = title
        self.updated = updated
        self.selfLink = selfLink
        self.parent = parent
        self.position = position
        self.notes = notes
        self.status = status
        self.due = due
        self.completed = completed
        self.deleted = deleted
        self.hidden = hidden
        self.links = links
        self.subtasks = subtasks
    }

    var isCompleted: Bool {
        status == "completed"
    }

    var hasSubtasks: Bool {
        subtasks != nil && !subtasks!.isEmpty
    }

    var dueDate: Date? {
        guard let due = due else { return nil }
        return Date.parseGoogleDate(due)
    }

    var completedDate: Date? {
        guard let completed = completed else { return nil }
        return Date.parseRFC3339(completed)
    }

    var isOverdue: Bool {
        guard let dueDate = dueDate else { return false }
        return !isCompleted && dueDate < Date()
    }

    /// Strips priority prefix (!, !!, !!!) from the title for display
    var displayTitle: String {
        if title.hasPrefix("!!! ") { return String(title.dropFirst(4)) }
        if title.hasPrefix("!!!") { return String(title.dropFirst(3)) }
        if title.hasPrefix("!! ") { return String(title.dropFirst(3)) }
        if title.hasPrefix("!!") { return String(title.dropFirst(2)) }
        if title.hasPrefix("! ") { return String(title.dropFirst(2)) }
        if title.hasPrefix("!") { return String(title.dropFirst(1)) }
        return title
    }

    /// Parsed priority level from title prefix convention
    var priority: TaskPriority {
        if title.hasPrefix("!!! ") || title.hasPrefix("!!!") { return .high }
        if title.hasPrefix("!! ") || title.hasPrefix("!!") && !title.hasPrefix("!!!") { return .medium }
        if title.hasPrefix("! ") || title.hasPrefix("!") && !title.hasPrefix("!!") { return .low }
        return .none
    }

    /// Returns a copy with specified fields replaced. Used for optimistic local updates.
    func with(
        title: String? = nil,
        notes: String?? = nil,
        status: String? = nil,
        due: String?? = nil,
        completed: String?? = nil
    ) -> GoogleTask {
        GoogleTask(
            id: id,
            title: title ?? self.title,
            updated: nil,
            selfLink: selfLink,
            parent: parent,
            position: position,
            notes: notes ?? self.notes,
            status: status ?? self.status,
            due: due ?? self.due,
            completed: completed ?? self.completed,
            deleted: deleted,
            hidden: hidden
        )
    }
}

// MARK: - Task Link

struct TaskLink: Codable, Equatable {
    let type: String
    let link: String
    let description: String?
}

// MARK: - API Response Wrappers

struct TaskListsResponse: Decodable {
    let items: [TaskList]?
    let nextPageToken: String?
}

struct TasksResponse: Decodable {
    let items: [GoogleTask]?
    let nextPageToken: String?
}

// MARK: - Task Create/Update Request Body

struct TaskListRequestBody: Encodable {
    let title: String
}

// MARK: - Date Extensions

extension Date {
    static func parseRFC3339(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Parses Google Tasks date format (YYYY-MM-DD) or RFC 3339
    static func parseGoogleDate(_ string: String) -> Date? {
        if let date = parseRFC3339(string) {
            return date
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }

    var googleDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: self)
    }
}
