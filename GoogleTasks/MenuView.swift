import SwiftUI

// MARK: - Menu View (Main Panel)

struct MenuView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showNewTaskForm = false
    @State private var showNewListForm = false
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if !dataManager.authManager.isAuthenticated {
                signInView
            } else if dataManager.isLoading && dataManager.taskLists.isEmpty {
                loadingView
            } else if dataManager.taskLists.isEmpty {
                emptyListsView
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        taskListSidebar
                        Divider()
                        taskContentView
                    }
                    .frame(minHeight: AppConstants.MenuBar.height - 100)
                }
            }

            Divider()

            bottomBar
        }
        .frame(width: AppConstants.MenuBar.width, height: AppConstants.MenuBar.height)
        .background(
            VisualEffectView(material: .menu, blendingMode: .behindWindow)
                .cornerRadius(12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .sheet(isPresented: $showNewTaskForm) {
            NewTaskFormView(isPresented: $showNewTaskForm)
                .environmentObject(dataManager)
        }
        .sheet(isPresented: $showNewListForm) {
            NewListFormView(isPresented: $showNewListForm)
                .environmentObject(dataManager)
        }
        .onAppear {
            Task {
                if dataManager.authManager.isAuthenticated && dataManager.taskLists.isEmpty {
                    await dataManager.refreshAll()
                }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.blue)

            Text("Google Tasks")
                .font(.system(size: 14, weight: .semibold))

            // Offline / pending indicator
            if dataManager.authManager.isAuthenticated && dataManager.isOffline {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 9))
                    if dataManager.pendingMutations > 0 {
                        Text("\(dataManager.pendingMutations)")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.orange.opacity(0.1))
                )
            }

            // Sync indicator (replaying mutations after reconnection)
            if dataManager.authManager.isAuthenticated && dataManager.isSyncing {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("Syncing")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue.opacity(0.1))
                )
            }

            Spacer()

            if dataManager.authManager.isAuthenticated {
                Button {
                    Task { await dataManager.refreshAll() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .disabled(dataManager.isLoading)

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Sign In

    private var signInView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundColor(.blue.opacity(0.6))

            Text("Sign in to Google Tasks")
                .font(.system(size: 16, weight: .semibold))

            Text("Manage your tasks right from the menu bar")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await dataManager.signIn() }
            } label: {
                Label("Sign in with Google", systemImage: "person.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(dataManager.authManager.authState == .signingIn)

            if dataManager.authManager.authState == .signingIn {
                ProgressView()
                    .scaleEffect(0.7)
            }

            if let error = dataManager.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .padding()
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("Loading tasks...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Empty Lists

    private var emptyListsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No task lists yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            Button {
                showNewListForm = true
            } label: {
                Label("Create List", systemImage: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .padding()
    }

    // MARK: - Task List Sidebar

    private var taskListSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $dataManager.selectedTaskListId) {
                ForEach(dataManager.taskLists) { list in
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(list.displayTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(list.id)
                }
            }
            .listStyle(.plain)
            .frame(width: 120)

            Divider()

            HStack {
                Button {
                    showNewListForm = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                    Text("New List")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    /// Filtered tasks for search
    private var filteredTasks: [GoogleTask] {
        let tasks = dataManager.selectedListTasks
        guard !searchQuery.isEmpty else { return tasks }
        return tasks.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: - Task Content

    private var taskContentView: some View {
        VStack(spacing: 0) {
            if let selectedList = dataManager.selectedTaskList {
                HStack {
                    Text(selectedList.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Spacer()

                    Text("\(dataManager.selectedListTasks.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.5))
                    TextField("Search tasks...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()

                if dataManager.selectedListTasks.isEmpty {
                    VStack {
                        Spacer()
                        Text("No tasks yet")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button {
                            showNewTaskForm = true
                        } label: {
                            Text("Add a task")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if !searchQuery.isEmpty && filteredTasks.isEmpty {
                    VStack {
                        Spacer()
                        Text("No tasks match \"\(searchQuery)\"")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredTasks) { task in
                                TaskRowView(task: task)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select a list")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if dataManager.authManager.isAuthenticated && dataManager.selectedTaskListId != nil {
                Button {
                    showNewTaskForm = true
                } label: {
                    Label("New Task", systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }

            Spacer()

            if dataManager.authManager.isAuthenticated {
                Button {
                    if let url = URL(string: "https://tasks.google.com/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                    Text("Open in Browser")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Preview

#Preview {
    MenuView()
        .environmentObject(DataManager.shared)
}
