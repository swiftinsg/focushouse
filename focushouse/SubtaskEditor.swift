import SwiftUI
import SwiftData

/// Edit or write your own subtasks for one task. Saved breakdowns teach the AI
/// to suggest similar subtasks next time.
struct SubtaskEditor: View {
    let plan: Plan
    @State var name: String          // the parent task's name
    @State var subtasks: [PlanTask]  // current subtasks (or the single plain task)
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: PersistentIdentifier?
    @State private var stress: Int?   // nil until the slider is moved
    @State private var own: [PersistentIdentifier: Int] = [:]   // one subtask's stress, set on its row
    @AppStorage("ratings") private var ratingData = Data()

    var body: some View {
        NavigationStack {
            PixelList {
                Section(pixel: "Task") {
                    TextField("Task name", text: $name)
                        .font(.headline)
                    // The hardest subtask's score, so it's never below what the student set;
                    // it moves as the AI rates subtasks they add or rename.
                    StressSlider(score: $stress, fallback: subtasks.compactMap { Ratings.score($0.title, in: Ratings.load(ratingData)) }.max() ?? 5)
                }

                Section {
                    ForEach(subtasks) { task in
                        SubtaskField(task: task, focused: $focused, stress: Binding(
                            get: { own[task.persistentModelID] ?? stress ?? Ratings.score(task.title, in: Ratings.load(ratingData)) ?? 5 },
                            set: { own[task.persistentModelID] = $0 }))
                    }
                    .onDelete { offsets in
                        let gone = offsets.map { subtasks[$0] }
                        subtasks.remove(atOffsets: offsets)
                        plan.delete(gone)
                    }
                    .onMove { subtasks.move(fromOffsets: $0, toOffset: $1) }
                    .deleteDisabled(subtasks.count == 1)   // keep one, so "Add subtask" has a place

                    Button("Add subtask", systemImage: "plus.circle.fill") { add() }
                } header: {
                    Text("Subtasks").pixelHeader()
                } footer: {
                    Text("Tap a subtask's ⚡︎ to set its own stress; the slider above sets them all. Your subtasks are saved, so next time the AI suggests similar ones for similar tasks.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .pixelTitle("Subtasks")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onDisappear(perform: save)   // Done and swipe-to-close both save
        .task(id: subtasks.map(\.title)) {
            // Rate new or renamed subtasks once typing pauses.
            try? await Task.sleep(for: .seconds(1))
            let rated = Ratings.load(ratingData)
            await Ratings.rate(subtasks.map(\.title).filter { !$0.isEmpty && rated[Ratings.key($0)] == nil })
        }
    }

    private func add() {
        guard let last = subtasks.last else { return }
        let task = plan.addSubtask(after: last)
        subtasks.append(task)
        focused = task.persistentModelID
    }

    private func save() {
        // Put the subtasks back, in the editor's order, where the first of them was.
        let all = plan.ordered
        var list = all.filter { t in !subtasks.contains { $0 === t } }
        let at = all.firstIndex { t in subtasks.contains { $0 === t } } ?? list.count
        list.insert(contentsOf: subtasks, at: min(at, list.count))
        for (i, task) in list.enumerated() { task.order = i }
        plan.saveSubtasks(subtasks, name: name)
        if let stress { Ratings.set(subtasks.map(\.title), score: stress) }
        for task in subtasks { if let score = own[task.persistentModelID] { Ratings.set([task.title], score: score) } }
    }
}

/// One subtask row: done toggle, title field, stress and duration pickers.
private struct SubtaskField: View {
    @Bindable var task: PlanTask
    var focused: FocusState<PersistentIdentifier?>.Binding
    @Binding var stress: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(task.done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            TextField("Subtask", text: $task.title)
                .focused(focused, equals: task.persistentModelID)
                .submitLabel(.next)

            Menu {
                Picker("Stress", selection: $stress) {
                    ForEach((1...10).reversed(), id: \.self) { Text("\($0)/10 · \(Rating(score: $0).effort)").tag($0) }
                }
            } label: {
                Text("\(Image(systemName: "bolt.fill")) \(stress)")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.fill.tertiary, in: .capsule)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Stress, \(stress) out of 10")

            Menu {
                Picker("Duration", selection: $task.minutes) {
                    ForEach(Set(taskDurations + [task.minutes]).sorted(), id: \.self) {
                        Text(hoursAndMinutes($0)).tag($0)
                    }
                }
            } label: {
                Text(hoursAndMinutes(task.minutes))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.fill.tertiary, in: .capsule)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }
}
