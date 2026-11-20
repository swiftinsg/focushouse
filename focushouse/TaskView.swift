//
//  TaskView.swift
//  focushouse
//
//  Created by T Krobot on 11/11/26.
//

import SwiftData
import SwiftUI
import Foundation

enum TaskSortOption: String, CaseIterable, Identifiable {
    case priority = "Priority"
    case dueDate = "Due Date"
    case tag = "Tag"

    var id: String { rawValue }
}

struct TaskView: View {
    @Environment(\.modelContext) private var modelContext
    @Query var tasks: [TodoItem]
    @State private var isAddingTask = false
    @State private var sortOption: TaskSortOption = .priority
    @State private var isPlanning = false
    @State private var editingTodo: TodoItem?
    @State private var path: [Plan] = []

    /// The inbox as a Today-mode dump, one to-do per line. "!" and "can wait"
    /// set priority (the planner reads them). Avoid the word "due": it marks high.
    private var dump: String {
        sortedTasks.map { t in
            let by = " (by \(t.dueDate.formatted(.dateTime.weekday().day().month())))"
            switch t.priority {
            case .high: return t.name + " !" + by
            case .low: return t.name + " (can wait)" + by
            case .medium: return t.name + by
            }
        }.joined(separator: "\n")
    }

    /// Tasks currently shown, ordered by the selected sort option.
    private var sortedTasks: [TodoItem] {
        tasks.sorted { lhs, rhs in
            switch sortOption {
            case .priority:
                if lhs.priority != rhs.priority {
                    return lhs.priority.exclamationCount > rhs.priority.exclamationCount
                }
                return lhs.dueDate > rhs.dueDate

            case .dueDate:
                if lhs.dueDate != rhs.dueDate {
                    return lhs.dueDate < rhs.dueDate
                }
                return lhs.priority.exclamationCount > rhs.priority.exclamationCount

            case .tag:
                if lhs.selectedTag != rhs.selectedTag {
                    if lhs.selectedTag == "Work" { return true }
                    if rhs.selectedTag == "Work" { return false }
                    return lhs.selectedTag < rhs.selectedTag
                }
                return lhs.priority.exclamationCount > rhs.priority.exclamationCount
            }
        }
    }
    
    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(sortedTasks) { task in
                    HStack {
                        Button { editingTodo = task } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.name)

                            HStack(spacing: 4) {
                                Text(String(repeating: "!", count: task.priority.exclamationCount))
                                    .font(.caption.bold())
                                    .foregroundStyle(.red)

                                Text(task.dueDate, format: .dateTime.day().month(.abbreviated).year())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Double-tap to edit")
                        
                        Spacer()
                        
                        TodoTick(todo: task, size: .body)
                    }
                }
                .onDelete(perform: deleteTasks)
            }
            .pixelTitle("Tasks")
            .navigationDestination(for: Plan.self) { PlanView(plan: $0) }
            .safeAreaInset(edge: .bottom) {
                if !tasks.isEmpty {
                    Button { isPlanning = true } label: {
                        Label("Plan these", systemImage: "sparkles").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding()
                }
            }
            .sheet(isPresented: $isPlanning) {
                NewPlanView(initialInput: dump) { plan in
                    // Planned to-dos now live in the plan. Manual mode ignores the
                    // text, so an empty plan keeps them in the inbox.
                    if !plan.tasks.isEmpty { tasks.forEach(modelContext.delete) }
                    isPlanning = false
                    path.append(plan)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort by", selection: $sortOption) {
                            ForEach(TaskSortOption.allCases, id: \.self) { option in
                                Text(option.rawValue)
                                    .tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add task", systemImage: "plus") {
                        isAddingTask = true
                    }
                }
            }
            .overlay {
                if tasks.isEmpty {
                    ContentUnavailableView("No tasks yet", systemImage: "eye.slash", description: Text("Tap + to add new task."))
                }
            }
            .sheet(isPresented: $isAddingTask) {
                NewTaskView()
            }
            .sheet(item: $editingTodo) { NewTaskView(editing: $0) }
        }
    }
    
    init(minimumDueDate: Date, sortOrder: [SortDescriptor<TodoItem>]) {
        _tasks = Query(filter: #Predicate<TodoItem> { task in
            task.dueDate >= minimumDueDate && !task.isDone
        }, sort: sortOrder)
    }
    
    func deleteTasks(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sortedTasks[index])
        }
    }
}

#Preview {
    TaskView(minimumDueDate: .distantPast, sortOrder: [SortDescriptor(\TodoItem.name)])
        .modelContainer(for: TodoItem.self, inMemory: true)
}

/// The bouncy tick: the circle pops into a green check with a ring burst, and
/// `action` runs once it's been seen, so the row doesn't vanish (or the check-in
/// sheet cover it) mid-animation. Unticking is instant.
struct BouncyCheck: View {
    let done: Bool
    var label: String
    var size: Font = .title2
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popping = false

    private var shown: Bool { done || popping }

    var body: some View {
        Button {
            if done { action(); return }
            guard !popping else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { popping = true }
            Task {
                try? await Task.sleep(for: .seconds(reduceMotion ? 0.3 : 0.9))
                withAnimation(.snappy) { action() }
                withAnimation(.spring) { popping = false }
            }
        } label: {
            ZStack {
                Circle().stroke(.green, lineWidth: 2)   // burst ring
                    .scaleEffect(popping && !reduceMotion ? 1.9 : 1)
                    .opacity(popping && !reduceMotion ? 0 : 0.001)
                    .animation(.easeOut(duration: 0.5), value: popping)
                Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                    .font(size)
                    .foregroundStyle(shown ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .scaleEffect(popping && !reduceMotion ? 1.25 : 1)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: popping) { _, on in on }
        .accessibilityLabel(label)
    }
}

/// Tick for a to-do: marked done (and leaves the list) after the bouncy check.
struct TodoTick: View {
    let todo: TodoItem
    var size: Font = .title2

    var body: some View {
        BouncyCheck(done: todo.isDone, label: "Mark \(todo.name) done", size: size) { todo.isDone = true }
    }
}
