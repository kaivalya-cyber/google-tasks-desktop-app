# Google Tasks for macOS

A native macOS menu bar application for managing Google Tasks. Built with Swift and SwiftUI.

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0%2B-blue" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Xcode-15.0%2B-blue" alt="Xcode 15.0+">
  <img src="https://img.shields.io/badge/Swift-5.9%2B-orange" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

## Features

- **Menu Bar Integration** — Quick access from the macOS menu bar
- **Task Management** — Create, edit, complete, and delete tasks
- **Task Lists** — Multiple lists with a sidebar selector
- **Subtasks** — Recursive parent-child hierarchy
- **Due Dates** — "Today", "Tomorrow", "Overdue" badges
- **Google OAuth2** — Secure sign-in with PKCE
- **Keychain Storage** — Encrypted token storage via macOS Keychain
- **Offline Support** — Local JSON cache with mutation queue for offline use
- **Auto-Sync** — Offline changes auto-replay when connectivity returns
- **Zero Dependencies** — Pure Swift/SwiftUI, one external package (HotKey for shortcuts)
- **Due Date Notifications** — Local notification at 9 AM when tasks are due today or overdue

## Requirements

| Requirement | Minimum Version |
|-------------|----------------|
| macOS | 13.0 (Ventura) |
| Xcode | 15.0 |
| Swift | 5.9 |

You also need a **Google Cloud project** with the Tasks API enabled and an OAuth 2.0 client ID. Follow the setup guide below.

---

## Setup Guide

### Step 1: Create a Google Cloud Project

1. Open the [Google Cloud Console](https://console.cloud.google.com/)
2. Click the project dropdown at the top and select **New Project**
3. Name it (e.g., `Google Tasks Desktop`) and click **Create**
4. Wait for the project to be created, then select it from the dropdown

### Step 2: Enable the Google Tasks API

1. In the sidebar, go to **APIs & Services** → **Library**
2. Search for **Google Tasks API**
3. Click on it, then click **Enable**

> ⚠️ The API may take a few minutes to activate.

### Step 3: Configure the OAuth Consent Screen

1. Go to **APIs & Services** → **OAuth consent screen**
2. Choose **External** (unless you're in a Google Workspace org)
3. Fill in the required fields:
   - **App name**: `Google Tasks Desktop`
   - **User support email**: Your email
   - **Developer contact information**: Your email
4. Click **Save and Continue**
5. On the **Scopes** page, click **Add or Remove Scopes** and add:
   - `https://www.googleapis.com/auth/tasks`
   - `https://www.googleapis.com/auth/tasks.readonly`
6. Click **Save and Continue**
7. On the **Test users** page, click **Add Users** and add your email
8. Click **Save and Continue**, then **Back to Dashboard**

> ℹ️ If you chose **External**, your app will be in "Testing" mode. You'll need to add test users (your own Google account is enough for personal use).

### Step 4: Create OAuth 2.0 Credentials

1. Go to **APIs & Services** → **Credentials**
2. Click **Create Credentials** → **OAuth client ID**
3. Select application type: **Desktop application**
4. Set the name to `Google Tasks Desktop`
5. Under **Authorized redirect URIs**, add:
   ```
   com.google.tasks.desktop:/oauth2callback
   ```
   > ⚠️ This MUST match exactly what's in `AppConstants.swift`. The `:/` after the scheme is intentional — it's the macOS URL scheme format.
6. Click **Create**
7. A popup will show your **Client ID**. Copy it — you'll need it in the next step.

Your Client ID looks like:
```
123456789-abc123def456.apps.googleusercontent.com
```

### Step 5: Configure the App

Open `GoogleTasks/AppConstants.swift` and find this line:

```swift
static let clientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"
```

Replace the placeholder with your actual Client ID:

```swift
static let clientID = "123456789-abc123def456.apps.googleusercontent.com"
```

That's it — you're ready to build.

### Step 6: Build and Run

```bash
# Open in Xcode
open GoogleTasks.xcodeproj
```

Then press **Cmd+R** to build and run.

The app will appear as a checklist icon (☑) in your macOS menu bar. Click it, sign in with your Google account, and your tasks will load.

### Alternative: Build from Command Line

```bash
xcodebuild -project GoogleTasks.xcodeproj \
  -scheme GoogleTasks \
  -configuration Release \
  build

# Built app location:
# ~/Library/Developer/Xcode/DerivedData/GoogleTasks-*/Build/Products/Release/GoogleTasks.app
```

---

## Troubleshooting

### "Sign in was cancelled" or blank screen after sign-in

Make sure the redirect URI in **Step 4** exactly matches:
```
com.google.tasks.desktop:/oauth2callback
```
Check for typos, extra slashes, or missing colons.

### "API key is invalid" or "Unauthorized"

- Verify the Client ID is correctly pasted in `AppConstants.swift`
- Make sure the Tasks API is enabled in **Step 2**
- Wait a few minutes after enabling the API — propagation can be slow

### App doesn't appear in menu bar

The app runs as a menu bar agent (no Dock icon). Look for the ☑ checklist icon in the top-right of your screen, near the clock.

### "This app isn't verified" warning

If you chose "External" in the OAuth consent screen, Google shows this warning in testing mode. Click **Continue** — your own account is a test user and can safely proceed.

### Tasks not loading / Network error

Check your internet connection. If you're offline, the app will show cached data with an orange indicator. Tasks will sync when connectivity returns.

---

## Configuration Reference

All settings are in `GoogleTasks/AppConstants.swift`:

| Constant | What it does | Default |
|----------|-------------|---------|
| `OAuth.clientID` | Your Google OAuth 2.0 client ID | *Must be set* |
| `OAuth.redirectURI` | OAuth callback URL scheme | `com.google.tasks.desktop:/oauth2callback` |
| `OAuth.scopes` | Requested API permissions | Read + write tasks |
| `API.baseURL` | Google Tasks API endpoint | `https://tasks.googleapis.com/tasks/v1` |
| `API.maxResults` | Max tasks per API call | 100 |
| `MenuBar.width` | Panel width (points) | 380 |
| `MenuBar.height` | Panel height (points) | 560 |
| `SettingsWindow.width` | Settings window width | 420 |
| `SettingsWindow.height` | Settings window height | 380 |

You can also set the Client ID via the **Settings → General** tab in the running app. Changes are saved to UserDefaults.

---

## Project Structure

```
google-tasks-desktop-app/
├── GoogleTasks/                    # All source code
│   ├── GoogleTasksApp.swift        # @main entry point
│   ├── AppDelegate.swift           # Menu bar, NSStatusItem, NSPanel, keyboard shortcuts
│   ├── DataManager.swift           # Central state, offline cache, mutation replay, auto-refresh
│   ├── AuthManager.swift           # OAuth2 PKCE, Keychain token storage, refresh + continuation queue
│   ├── APIService.swift            # Google Tasks REST API v1 client (full CRUD)
│   ├── LocalCache.swift            # JSON file-based snapshot cache + offline mutation queue + NWPathMonitor
│   ├── NotificationManager.swift   # UNUserNotificationCenter — due date alerts at 9 AM
│   ├── Models.swift                # TaskList, GoogleTask, API responses, Date extensions, with() helper
│   ├── AppConstants.swift          # OAuth, API URLs, Keychain keys, layout dimensions, notification names
│   ├── MenuView.swift              # Main floating panel UI (sidebar, task list, sign-in flow, offline badge)
│   ├── TaskRowView.swift           # Task row with hover actions, NewTaskForm, EditTaskForm, NewListForm
│   ├── SettingsView.swift          # General / Account / About tabs
│   ├── Info.plist                  # LSUIElement = YES (menu bar only, no Dock icon)
│   └── GoogleTasks.entitlements    # Network client + file access entitlements
├── GoogleTasks.xcodeproj/          # Xcode project + scheme
├── Package.swift                   # Swift package manifest
├── README.md
├── LICENSE
└── .gitignore
```

## Architecture

```
┌─────────────────────────────────────────────┐
│                  MenuView                    │
│         (SwiftUI floating panel)             │
└────────────────┬────────────────────────────┘
                 │ @EnvironmentObject
┌────────────────▼────────────────────────────┐
│               DataManager                    │
│     @MainActor ObservableObject              │
│     - taskLists, tasksByListId               │
│     - selectedTaskListId                     │
│     - isOffline, pendingMutations            │
│     - cache-first load, optimistic updates   │
│     - mutation replay, auto-refresh          │
└──┬─────────────┬──────────────┬─────────────┘
   │             │              │
┌──▼──┐   ┌──────▼──────┐  ┌──▼──────────┐
│Auth │   │  APIService  │  │ LocalCache   │
│Mgr  │   │  (REST v1)   │  │ (JSON cache) │
│OAuth│   │  Tasks CRUD   │  │ Offline queue│
│PKCE │   │  List CRUD    │  │ NWPathMonitor│
└─────┘   └──────────────┘  └──────────────┘
```

- **Auth**: `ASWebAuthenticationSession` → OAuth2 PKCE → Keychain
- **API**: `URLSession` + Bearer token → `https://tasks.googleapis.com/tasks/v1`
- **Cache**: `~/Library/Application Support/com.google.tasks.desktop/cache/`
- **Offline**: Mutations queued to JSON file, replayed on reconnect

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Toggle tasks panel | **Ctrl+Opt+T** (global, works from any app) |
| Open panel from menu bar | Click menu bar icon |
| Context menu | Right-click menu bar icon |
| Close panel | Esc |

## Contributing

Contributions are welcome! Feel free to submit issues and pull requests.

## License

MIT — see [LICENSE](LICENSE) for details.

---

Built with ❤️ using Swift and SwiftUI.
