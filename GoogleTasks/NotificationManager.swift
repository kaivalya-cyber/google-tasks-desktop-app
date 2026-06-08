import Foundation
import UserNotifications

// MARK: - Notification Manager

/// Schedules local notifications for tasks that are due today.
/// Scans all cached task lists and recursively walks subtasks,
/// finds incomplete items with due dates matching today, and fires
/// a 9 AM notification. Skips rescheduling if today's notification
/// was already delivered.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private var authorizationGranted = false

    private override init() {
        super.init()
        center.delegate = self
    }

    // MARK: - Public API

    /// Requests notification permission from the user
    func requestAuthorization() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorizationGranted = granted
        } catch {
            print("[NotificationManager] Authorization failed: \(error.localizedDescription)")
        }
    }

    /// Scans all task data for items due today or overdue and schedules a notification.
    /// Clears stale pending notifications, but skips rescheduling if today's alert
    /// was already delivered (avoids duplicates on repeated refresh).
    func scheduleDueDateNotifications(
        taskLists: [TaskList],
        tasksByListId: [String: [GoogleTask]]
    ) async {
        guard authorizationGranted else { return }

        // Don't reschedule if today's notification was already delivered
        let today = Calendar.current.startOfDay(for: Date())
        let dayOfMonth = Calendar.current.component(.day, from: today)
        let todayRequestID = "com.google.tasks.due-today-\(dayOfMonth)"
        let delivered = await center.deliveredNotifications()
        if delivered.contains(where: { $0.request.identifier == todayRequestID }) {
            return
        }

        // Clear old pending notifications
        center.removeAllPendingNotificationRequests()

        // Flatten all incomplete tasks (including subtasks) with due dates
        var dueTasks: [(title: String, listName: String)] = []

        for list in taskLists {
            guard let tasks = tasksByListId[list.id] else { continue }
            collectDueTasks(from: tasks, listName: list.displayTitle, today: today, into: &dueTasks)
        }

        guard !dueTasks.isEmpty else { return }

        // Build notification content
        let content = UNMutableNotificationContent()
        content.sound = .default

        if dueTasks.count == 1 {
            let task = dueTasks[0]
            content.title = "Task due today"
            content.body = "\(task.title) — \(task.listName)"
        } else if dueTasks.count <= 3 {
            content.title = "\(dueTasks.count) tasks due today"
            content.body = dueTasks.map { "• \($0.title)" }.joined(separator: "\n")
        } else {
            content.title = "\(dueTasks.count) tasks due today"
            content.body = dueTasks.prefix(3).map { "• \($0.title)" }.joined(separator: "\n")
                + "\nand \(dueTasks.count - 3) more"
        }

        // Schedule time-of-day trigger: 9 AM
        var dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: today)
        dateComponents.hour = 9
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: todayRequestID,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            print("[NotificationManager] Failed to schedule notification: \(error.localizedDescription)")
        }
    }

    /// Schedules a notification for a single task at its exact due time
    func scheduleTaskDueNotification(taskId: String, dueDate: Date, title: String, listName: String) async {
        guard authorizationGranted else { return }

        // Don't schedule if due date is in the past
        guard dueDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Due now — \(listName)"
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: "task-due-\(taskId)",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            print("[NotificationManager] Failed to schedule task notification: \(error.localizedDescription)")
        }
    }

    /// Cancels a previously scheduled notification for a task
    func cancelTaskNotification(taskId: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["task-due-\(taskId)"])
    }

    // MARK: - Private Helpers

    /// Recursively collects incomplete tasks with due dates matching today or past-due
    private func collectDueTasks(
        from tasks: [GoogleTask],
        listName: String,
        today: Date,
        into result: inout [(title: String, listName: String)]
    ) {
        for task in tasks {
            guard !task.isCompleted else { continue }

            if let dueDate = task.dueDate {
                let taskDay = Calendar.current.startOfDay(for: dueDate)
                if taskDay <= today {
                    result.append((title: task.title, listName: listName))
                }
            }

            // Recurse into subtasks
            if let subtasks = task.subtasks, !subtasks.isEmpty {
                collectDueTasks(from: subtasks, listName: listName, today: today, into: &result)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
