# Google Tasks for macOS

A native macOS menu bar application for managing Google Tasks. Built with Swift and SwiftUI.

## Features

- **Menu Bar Integration**: Quick access to your Google Tasks from the menu bar
- **Task Management**: Create, edit, complete, and delete tasks
- **Task Lists**: Manage multiple task lists with a sidebar
- **Subtasks**: Support for task hierarchy with parent-child relationships
- **Due Dates**: Set and view due dates with overdue highlighting
- **Google OAuth2**: Secure authentication using Google's OAuth 2.0 with PKCE
- **Keychain Storage**: Tokens stored securely in the macOS Keychain
- **Auto-Refresh**: Tasks automatically refresh every 60 seconds
- **Native & Lightweight**: Pure Swift/SwiftUI, minimal resource usage

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15.0 or later (for building)
- A Google Cloud Platform project with the Tasks API enabled

## Quick Start

### 1. Set up Google Cloud Project

1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or use an existing one)
3. Enable the **Google Tasks API**:
   - Navigate to **APIs & Services → Library**
   - Search for "Google Tasks API"
   - Click **Enable**
4. Create OAuth 2.0 credentials:
   - Go to **APIs & Services → Credentials**
   - Click **Create Credentials → OAuth client ID**
   - Select **Desktop Application**
   - Set the name (e.g., "Google Tasks Desktop")
   - For the redirect URI, add: `com.google.tasks.desktop:/oauth2callback`
   - Click **Create**
5. Copy your **Client ID**

### 2. Configure the App

1. Open `GoogleTasks/AppConstants.swift`
2. Replace `YOUR_CLIENT_ID.apps.googleusercontent.com` with your actual client ID:

```swift
static let clientID = "123456789-abc123def456.apps.googleusercontent.com"
```

### 3. Build and Run

1. Open the project in Xcode:
   ```bash
   open GoogleTasks.xcodeproj
   ```
2. Select the **GoogleTasks** scheme
3. Build and run (Cmd+R)
4. Click the checklist icon in your menu bar
5. Sign in with your Google account

## Building from Command Line

```bash
# Build
xcodebuild -project GoogleTasks.xcodeproj -scheme GoogleTasks -configuration Release build

# The built app will be in:
# ~/Library/Developer/Xcode/DerivedData/GoogleTasks-*/Build/Products/Release/GoogleTasks.app
```

## Project Structure

```
GoogleTasks/
├── GoogleTasksApp.swift    # App entry point (SwiftUI @main)
├── AppDelegate.swift       # Menu bar, panel management, lifecycle
├── DataManager.swift       # Central state management
├── AuthManager.swift       # OAuth2 authentication + Keychain
├── APIService.swift        # Google Tasks REST API client
├── Models.swift            # Data models (TaskList, GoogleTask)
├── AppConstants.swift      # Configuration constants
├── MenuView.swift          # Main menu bar panel UI
├── TaskRowView.swift       # Task row + create/edit forms
├── SettingsView.swift      # Settings window
├── Info.plist              # App metadata
├── GoogleTasks.entitlements # App sandbox entitlements
└── GoogleTasks.xcodeproj/   # Xcode project
```

## Architecture

- **UI Framework**: SwiftUI with AppKit integration
- **Authentication**: OAuth 2.0 with PKCE via `ASWebAuthenticationSession`
- **Token Storage**: macOS Keychain (secure, encrypted)
- **Networking**: `URLSession` with Bearer token authentication
- **State Management**: `@MainActor` + `@Published` + `ObservableObject`
- **API**: Google Tasks REST API v1

## OAuth2 Scopes

- `https://www.googleapis.com/auth/tasks` — Full read/write access
- `https://www.googleapis.com/auth/tasks.readonly` — Read-only access

## Keyboard Shortcuts

- **Click menu bar icon**: Toggle tasks panel
- **Right-click menu bar icon**: Context menu
- **Esc**: Close panel

## Configuration

All configurable values are in `GoogleTasks/AppConstants.swift`:

| Constant | Description | Default |
|----------|-------------|---------|
| `OAuth.clientID` | Google OAuth2 client ID | *Must be configured* |
| `OAuth.redirectURI` | OAuth2 redirect URI | `com.google.tasks.desktop:/oauth2callback` |
| `API.maxResults` | Max tasks per API call | 100 |
| `MenuBar.width` | Panel width | 380 |
| `MenuBar.height` | Panel height | 560 |

## Contributing

Contributions are welcome! Feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Trademarks

Google and Google Tasks are trademarks of Google LLC.
