import SwiftUI

// MARK: - Task Row View

struct TaskRowView: View {
    let task: GoogleTask
    @EnvironmentObject var dataManager: DataManager
    @State private var isHovering = false
    @State private var showEditSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    Task { await dataManager.toggleTaskCompletion(task: task) }
                } label: {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundColor(task.isCompleted ? .green : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 12, weight: .medium))
                        .strikethrough(task.isCompleted, color: .secondary)
                        .foregroundColor(task.isCompleted ? .secondary : .primary)
                        .lineLimit(2)

                    if let notes = task.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    if let dueDate = task.dueDate {
                        HStack(spacing: 4) {
                            Image(systemName: task.isOverdue ? "exclamationmark.triangle.fill" : "calendar")
                                .font(.system(size: 8))
                            Text(formatDueDate(dueDate))
                                .font(.system(size: 9))
                        }
                        .foregroundColor(task.isOverdue ? .red : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(task.isOverdue ? Color.red.opacity(0.1) : Color.gray.opacity(0.1))
                        )
                    }
                }

                Spacer()

                if isHovering {
                    HStack(spacing: 4) {
                        // Reorder buttons (top-level tasks only)
                        if task.parent == nil {
                            Button {
                                Task { await dataManager.moveTaskUp(taskId: task.id) }
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .help("Move up")

                            Button {
                                Task { await dataManager.moveTaskDown(taskId: task.id) }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .help("Move down")
                        }

                        Button {
                            showEditSheet = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)

                        Button {
                            Task { await dataManager.deleteTask(taskId: task.id) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .background(
                isHovering ? Color.primary.opacity(0.04) : Color.clear
            )
            .sheet(isPresented: $showEditSheet) {
                EditTaskFormView(isPresented: $showEditSheet, task: task)
                    .environmentObject(dataManager)
            }

            if let subtasks = task.subtasks, !subtasks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(subtasks) { subtask in
                        TaskRowView(task: subtask)
                            .padding(.leading, 20)
                    }
                }
            }

            Divider()
                .padding(.leading, 32)
        }
    }

    private func formatDueDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            return "Today"
        } else if Calendar.current.isDateInTomorrow(date) {
            return "Tomorrow"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

// MARK: - New Task Form

struct NewTaskFormView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var dataManager: DataManager

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var parentTaskId: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            Text("New Task")
                .font(.headline)

            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $notes)
                .font(.system(size: 12))
                .frame(height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Notes (optional)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            Toggle("Set due date", isOn: $hasDueDate)

            if hasDueDate {
                DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }

            // Parent task picker for subtask creation
            let availableParents = dataManager.allTasksInSelectedList
            if !availableParents.isEmpty {
                Picker("Parent task", selection: $parentTaskId) {
                    Text("None (top-level)").tag(nil as String?)
                    ForEach(availableParents) { task in
                        Text(task.title).tag(task.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 12))
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Create") {
                    Task {
                        _ = await dataManager.createTask(
                            title: title,
                            notes: notes.isEmpty ? nil : notes,
                            due: hasDueDate ? dueDate : nil,
                            parent: parentTaskId
                        )
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - Edit Task Form

struct EditTaskFormView: View {
    @Binding var isPresented: Bool
    let task: GoogleTask
    @EnvironmentObject var dataManager: DataManager

    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var moveToListId: String? = nil

    init(isPresented: Binding<Bool>, task: GoogleTask) {
        self._isPresented = isPresented
        self.task = task
        self._title = State(initialValue: task.title)
        self._notes = State(initialValue: task.notes ?? "")
        self._hasDueDate = State(initialValue: task.dueDate != nil)
        self._dueDate = State(initialValue: task.dueDate ?? Date())
    }

    /// Other lists (excluding the currently selected one)
    private var otherLists: [TaskList] {
        dataManager.taskLists.filter { $0.id != dataManager.selectedTaskListId }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Task")
                .font(.headline)

            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $notes)
                .font(.system(size: 12))
                .frame(height: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            Toggle("Set due date", isOn: $hasDueDate)

            if hasDueDate {
                DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
            }

            // Move to different list
            if !otherLists.isEmpty {
                Divider()

                HStack {
                    Picker("Move to list", selection: $moveToListId) {
                        Text("Select list...").tag(nil as String?)
                        ForEach(otherLists) { list in
                            Text(list.displayTitle).tag(list.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 12))
                    .labelsHidden()

                    Button("Move") {
                        if let toListId = moveToListId {
                            Task {
                                await dataManager.moveTaskToList(taskId: task.id, toListId: toListId)
                                isPresented = false
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(moveToListId == nil)
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    Task {
                        _ = await dataManager.updateTask(
                            taskId: task.id,
                            title: title,
                            notes: notes.isEmpty ? nil : notes,
                            due: hasDueDate ? dueDate : nil
                        )
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - New List Form

struct NewListFormView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var dataManager: DataManager
    @State private var title = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("New Task List")
                .font(.headline)

            TextField("List name", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                Spacer()
                Button("Create") {
                    Task {
                        _ = await dataManager.createTaskList(title: title)
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}

// MARK: - Preview

#Preview {
    TaskRowView(task: GoogleTask(
        id: "1",
        title: "Sample Task",
        updated: nil,
        selfLink: nil,
        parent: nil,
        position: "1",
        notes: "Some notes",
        status: "needsAction",
        due: "2026-06-10T00:00:00Z",
        completed: nil,
        deleted: nil,
        hidden: nil
    ))
    .environmentObject(DataManager.shared)
    .frame(width: 300)
    .padding()
}
