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

extension [TodoItem] {
    /// The to-dos ordered by `option`.
    func sorted(by option: TaskSortOption) -> [TodoItem] {
        sorted { lhs, rhs in
            switch option {
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

    /// The to-dos as a Today-mode dump, one per line. "!" and "can wait"
    /// set priority (the planner reads them). Avoid the word "due": it marks high.
    var dump: String {
        map { t in
            let by = " (by \(t.dueDate.formatted(.dateTime.weekday().day().month())))"
            switch t.priority {
            case .high: return t.name + " !" + by
            case .low: return t.name + " (can wait)" + by
            case .medium: return t.name + by
            }
        }.joined(separator: "\n")
    }
}

/// A to-do row on Schedule: tap to edit, tick to finish.
struct TodoRow: View {
    let todo: TodoItem
    let edit: () -> Void

    var body: some View {
        HStack {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(todo.name)
                    HStack(spacing: 4) {
                        Text(String(repeating: "!", count: todo.priority.exclamationCount))
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        Text(todo.dueDate, format: .dateTime.day().month(.abbreviated).year())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Double-tap to edit")
            TodoTick(todo: todo, size: .body)
        }
    }
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
            Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                .font(size)
                .foregroundStyle(shown ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .scaleEffect(popping && !reduceMotion ? 1.25 : 1)
                .contentTransition(.symbolEffect(.replace))
                .background {   // burst ring, sized to the icon (a bare Circle fills the row)
                    Circle().stroke(.green, lineWidth: 2)
                        .scaleEffect(popping && !reduceMotion ? 1.9 : 1)
                        .opacity(popping && !reduceMotion ? 0 : 0.001)
                        .animation(.easeOut(duration: 0.5), value: popping)
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
        BouncyCheck(done: todo.isDone, label: "Mark \(todo.name) done", size: size) { todo.isDone = true; todo.doneAt = .now }
    }
}
