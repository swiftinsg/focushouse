//
//  NewTaskView.swift
//  focushouse
//
//  Created by T Krobot on 11/11/26.
//

import Foundation
import SwiftUI
import SwiftData

struct NewTaskView: View {
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss
    /// A to-do to change instead of making a new one.
    var editing: TodoItem?

    @State private var name = ""
    @State private var selectedTag = "Work"
    let tags = ["Work", "Hobbies", "Others"]
    @State private var dueDate = Date.now
    @State private var priority: Priority = .medium

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            PixelList {
                TextField("Name", text: $name)
            
                Picker("Tag", selection: $selectedTag) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                    }
                }

                // Today or later; an old overdue to-do keeps its date when edited.
                DatePicker("Due date", selection: $dueDate,
                           in: min(Calendar.current.startOfDay(for: .now), editing?.dueDate ?? .now)...,
                           displayedComponents: .date)

                Picker("Priority", selection: $priority) {
                    ForEach(Priority.allCases, id: \.self) { priority in
                        Text(priority.rawValue)
                            .tag(priority)
                    }
                }
            }
            .pixelTitle(editing == nil ? "New to-do" : "Edit to-do")
            .onAppear {
                guard let editing else { return }
                name = editing.name
                selectedTag = tags.contains(editing.selectedTag) ? editing.selectedTag : "Work"
                dueDate = editing.dueDate
                priority = editing.priority
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    func save() {
        if let editing {
            editing.name = trimmedName
            editing.selectedTag = selectedTag
            editing.dueDate = dueDate
            editing.priority = priority
            dismiss()
            return
        }
        let task = TodoItem(
            name: trimmedName,
            selectedTag: selectedTag,
            dueDate: dueDate,
            priority: priority
        )

        modelContext.insert(task)
        dismiss()
    }
}

#Preview {
    NewTaskView()
        .modelContainer(for: TodoItem.self, inMemory: true)
}
