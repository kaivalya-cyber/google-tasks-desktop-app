import SwiftUI

// MARK: - Menu View (Main Panel)

struct MenuView: View {
    @EnvironmentObject var dataManager: DataManager
    @State private var showNewTaskForm = false
    @State private var showNewListForm = false
    @State private var searchQuery = ""
    @State private var selectedTaskIds: Set<String> = []
    @State private var showEditSheetForSelected = false
    @State private var detailTask: GoogleTask? = nil
    @State private var showTodayOnly = false
    @State private var showWeeklyReview = false
    @State private var compactMode = false
    @State private var showBatchMovePicker = false
    @State private var quickCaptureText = ""

    var body: some View {
        VStack(spacing: 0) {
            headerView

            // Quick-capture field
            if dataManager.authManager.isAuthenticated && dataManager.selectedTaskListId != nil {
                quickCaptureBar
                Divider()
            }

            if !dataManager.authManager.isAuthenticated {
                signInView
            } else if dataManager.isLoading && dataManager.taskLists.isEmpty {
                loadingView
            } else if dataManager.taskLists.isEmpty {
                emptyListsView
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        if !compactMode {
                            taskListSidebar
                            Divider()
                        }
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
        .sheet(isPresented: $showEditSheetForSelected) {
            if let taskId = selectedTaskIds.first,
               let task = dataManager.allTasksInSelectedList.first(where: { $0.id == taskId }) {
                EditTaskFormView(isPresented: $showEditSheetForSelected, task: task)
                    .environmentObject(dataManager)
            }
        }
        .popover(item: $detailTask) { task in
            TaskDetailPopover(task: task)
                .environmentObject(dataManager)
        }
        .onAppear {
            Task {
                if dataManager.authManager.isAuthenticated && dataManager.taskLists.isEmpty {
                    await dataManager.refreshAll()
                }
            }
        }
        .onChange(of: dataManager.selectedTaskListId) { _ in
            searchQuery = ""
            selectedTaskIds = []
        }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.Notifications.newTaskShortcut)) { _ in
            if dataManager.authManager.isAuthenticated && dataManager.selectedTaskListId != nil {
                showNewTaskForm = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.Notifications.editSelectedTaskShortcut)) { _ in
            if !selectedTaskIds.isEmpty {
                showEditSheetForSelected = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.Notifications.deleteSelectedTaskShortcut)) { _ in
            if !selectedTaskIds.isEmpty {
                Task { await dataManager.batchDeleteTasks(taskIds: selectedTaskIds) }
                selectedTaskIds = []
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
                // Weekly review toggle
                Button {
                    showWeeklyReview.toggle()
                    if showWeeklyReview { showTodayOnly = false }
                    selectedTaskIds = []
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showWeeklyReview ? "chart.bar.fill" : "chart.bar")
                            .font(.system(size: 10))
                        Text("Review")
                            .font(.system(size: 9, weight: showWeeklyReview ? .bold : .regular))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(showWeeklyReview ? Color.green.opacity(0.15) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundColor(showWeeklyReview ? .green : .secondary)
                .help("Review tasks completed this week")

                // Today toggle
                Button {
                    showTodayOnly.toggle()
                    if showTodayOnly { showWeeklyReview = false }
                    selectedTaskIds = []
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showTodayOnly ? "calendar.badge.checkmark" : "calendar")
                            .font(.system(size: 10))
                        Text("Today")
                            .font(.system(size: 9, weight: showTodayOnly ? .bold : .regular))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(showTodayOnly ? Color.blue.opacity(0.15) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundColor(showTodayOnly ? .blue : .secondary)
                .help("Show only today's tasks across all lists")

                // Compact mode toggle
                Button {
                    compactMode.toggle()
                    NotificationCenter.default.post(name: AppConstants.Notifications.toggleCompactMode, object: nil)
                } label: {
                    Image(systemName: compactMode ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(compactMode ? "Expand panel" : "Compact panel")

                Button {
                    Task { await dataManager.refreshAll() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .disabled(dataManager.isLoading)

                // Export button
                Button {
                    exportTasks()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Export tasks as Markdown")

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

    // MARK: - Quick Capture

    private var quickCaptureBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 11))
                .foregroundColor(.blue.opacity(0.6))
            TextField("Quick capture — press Enter to add", text: $quickCaptureText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit {
                    let text = quickCaptureText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    Task {
                        _ = await dataManager.createTask(title: text)
                    }
                    quickCaptureText = ""
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Export

    private func exportTasks() {
        let md = dataManager.exportTasksAsMarkdown()
        let savePanel = NSSavePanel()
        savePanel.title = "Export Tasks"
        savePanel.nameFieldStringValue = "Google Tasks.md"
        savePanel.allowedContentTypes = [.plainText]
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? md.write(to: url, atomically: true, encoding: .utf8)
            }
        }
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
                    let counts = dataManager.taskCountsByListId[list.id]
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(list.displayTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        if let counts = counts, counts.total > 0 {
                            Text(counts.incomplete == counts.total
                                ? "\(counts.total)"
                                : "\(counts.incomplete)/\(counts.total)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(counts.incomplete > 0 ? .blue.opacity(0.7) : .secondary.opacity(0.5))
                        }
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

    /// Filtered tasks for search (searches all tasks including nested subtasks)
    private var filteredTasks: [GoogleTask] {
        let tasks = dataManager.allTasksInSelectedList
        guard !searchQuery.isEmpty else { return dataManager.selectedListTasks }
        return tasks.filter { $0.title.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: - Task Content

    private var taskContentView: some View {
        VStack(spacing: 0) {
            if showWeeklyReview {
                weeklyReviewView
            } else if showTodayOnly {
                todayTaskView
            } else if let selectedList = dataManager.selectedTaskList {
                listTaskView(selectedList: selectedList)
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

    // MARK: - Weekly Review View

    private var weeklyReviewView: some View {
        let completedTasks = dataManager.allTasksCompletedThisWeek

        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
                Text("This Week")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(completedTasks.count) done")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if completedTasks.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No tasks completed this week")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(completedTasks) { task in
                            TaskRowView(task: task, selectedTaskIds: $selectedTaskIds, onDoubleClick: { detailTask = $0 })
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Today View

    private var todayTaskView: some View {
        let todayTasks = dataManager.allTasksDueToday

        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                Text("Today")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(todayTasks.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if todayTasks.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.green.opacity(0.5))
                    Text("All caught up!")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(todayTasks) { task in
                            TaskRowView(task: task, selectedTaskIds: $selectedTaskIds, onDoubleClick: { detailTask = $0 })
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - List Task View

    @ViewBuilder
    private func listTaskView(selectedList: TaskList) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(selectedList.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                // Clear completed button
                let completedCount = dataManager.selectedListTasks.filter { $0.isCompleted }.count
                if completedCount > 0 {
                    Button {
                        Task { await dataManager.clearCompletedTasks() }
                    } label: {
                        Text("Clear \(completedCount) done")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Remove all completed tasks")
                }

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
                            TaskRowView(task: task, selectedTaskIds: $selectedTaskIds, onDoubleClick: { detailTask = $0 })
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if !selectedTaskIds.isEmpty {
                // Multi-select toolbar
                Button {
                    Task {
                        await dataManager.batchDeleteTasks(taskIds: selectedTaskIds)
                        selectedTaskIds = []
                    }
                } label: {
                    Label("Delete \(selectedTaskIds.count)", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)

                if dataManager.taskLists.count > 1 {
                    Button {
                        showBatchMovePicker = true
                    } label: {
                        Label("Move \(selectedTaskIds.count)", systemImage: "arrow.right.to.line")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }

                Button {
                    selectedTaskIds = []
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            } else if dataManager.authManager.isAuthenticated && dataManager.selectedTaskListId != nil {
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
        .popover(isPresented: $showBatchMovePicker) {
            VStack(spacing: 12) {
                Text("Move \(selectedTaskIds.count) tasks to:")
                    .font(.system(size: 12, weight: .medium))
                List(dataManager.taskLists.filter { $0.id != dataManager.selectedTaskListId }) { list in
                    Button(list.displayTitle) {
                        Task {
                            await dataManager.batchMoveTasks(taskIds: selectedTaskIds, toListId: list.id)
                            selectedTaskIds = []
                            showBatchMovePicker = false
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 150)
            }
            .padding()
            .frame(width: 200)
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
