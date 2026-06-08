import Foundation
import UserNotifications

// MARK: - Notification Manager

/// Schedules local notifications for tasks that are due today.
/// Scans all cached task lists > tasks, finds incomplete items with due dates
/// matching today, and fires a time-of-day notification for each batch.
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

    /// Scans all task data for items due today and schedules a notification.
    /// Clears any previously scheduled notifications first so we don't get stale alerts.
    func scheduleDueDateNotifications(
        taskLists: [TaskList],
        tasksByListId: [String: [GoogleTask]]
    ) async {
        guard authorizationGranted else { return }

        // Clear old notifications
        center.removeAllPendingNotificationRequests()

        // Flatten all incomplete tasks with due dates
        let today = Calendar.current.startOfDay(for: Date())
        let todayEnd = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        var dueTasks: [(title: String, listName: String)] = []

        for list in taskLists {
            guard let tasks = tasksByListId[list.id] else { continue }
            for task in tasks {
                guard !task.isCompleted,
                      let dueDate = task.dueDate else { continue }

                // Check if due date falls on today
                let taskDay = Calendar.current.startOfDay(for: dueDate)
                if taskDay == today {
                    dueTasks.append((title: task.title, listName: list.displayTitle))
                }

                // Also check overdue tasks (due before today, not yet completed)
                if taskDay < today {
                    dueTasks.append((title: task.title, listName: list.displayTitle))
                }
            }
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
            content.body = dueTasks.map { $0.title }.joined(separator: ", ")
        } else {
            content.title = "\(dueTasks.count) tasks due today"
            content.body = "\(dueTasks.prefix(2).map { $0.title }.joined(separator: ", ")), and \(dueTasks.count - 2) more"
        }

        // Schedule time-of-day trigger: 9 AM
        var dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: today)
        dateComponents.hour = 9
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: "com.google.tasks.due-today",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            print("[NotificationManager] Failed to schedule notification: \(error.localizedDescription)")
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
