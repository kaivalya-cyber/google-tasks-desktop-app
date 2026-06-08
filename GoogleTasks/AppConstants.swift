import Foundation
import CoreGraphics

enum AppConstants {
    // MARK: - OAuth2 Configuration
    enum OAuth {
        /// Google OAuth2 client ID - MUST be configured in Google Cloud Console
        static let clientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"
        /// OAuth2 redirect URI (must match Google Cloud Console)
        static let redirectURI = "com.google.tasks.desktop:/oauth2callback"
        /// OAuth2 authorization endpoint
        static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
        /// OAuth2 token endpoint
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"
        /// OAuth2 scopes required
        static let scopes = [
            "https://www.googleapis.com/auth/tasks",
            "https://www.googleapis.com/auth/tasks.readonly"
        ]
    }

    // MARK: - Google Tasks API
    enum API {
        static let baseURL = "https://tasks.googleapis.com/tasks/v1"
        static let maxResults = 100
    }

    // MARK: - Keychain
    enum Keychain {
        static let service = "com.google.tasks.desktop"
        static let accessTokenKey = "google_tasks_access_token"
        static let refreshTokenKey = "google_tasks_refresh_token"
        static let tokenExpiryKey = "google_tasks_token_expiry"
    }

    // MARK: - Menu Bar Panel
    enum MenuBar {
        static let width: CGFloat = 380
        static let compactWidth: CGFloat = 300
        static let height: CGFloat = 560
    }

    // MARK: - Settings Window
    enum SettingsWindow {
        static let width: CGFloat = 420
        static let height: CGFloat = 380
    }

    // MARK: - Notifications
    enum Notifications {
        static let didSignIn = Notification.Name("didSignIn")
        static let didSignOut = Notification.Name("didSignOut")
        static let tasksDidUpdate = Notification.Name("tasksDidUpdate")
        static let taskListsDidUpdate = Notification.Name("taskListsDidUpdate")
        static let closeMenuBarPanel = Notification.Name("closeMenuBarPanel")
        static let connectivityChanged = Notification.Name("connectivityChanged")
        static let newTaskShortcut = Notification.Name("newTaskShortcut")
        static let editSelectedTaskShortcut = Notification.Name("editSelectedTaskShortcut")
        static let deleteSelectedTaskShortcut = Notification.Name("deleteSelectedTaskShortcut")
        static let toggleCompactMode = Notification.Name("toggleCompactMode")
    }
}
