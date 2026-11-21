import SwiftUI
import SwiftData
import PhotosUI

struct PlanView: View {
    @Bindable var plan: Plan
    @State private var isWorking = false
    @State private var error: String?
    @State private var calendarMessage: String?
    @AppStorage("autoAddToCalendar") private var autoAddToCalendar = false
    @AppStorage("showTimeline") private var showTimeline = false
    @State private var editing: SubtaskEdit?
    @State private var confirmDelete = false
    @State private var timelineDay = Calendar.current.startOfDay(for: .now)   // the day the timeline shows
    @AppStorage("showFinished") private var showFinished = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var reading = false          // pulling text out of an attachment
    @State private var materialNote: String?
    @FocusState private var materialsFocused: Bool
    @State private var materialsBefore = ""     // to re-plan only when typing changed it
    @State private var dealt = 0                // rows dealt in so far
    @State private var dealing = false          // a fresh plan's rows are landing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    /// What the subtask editor sheet opens with.
    private struct SubtaskEdit: Identifiable {
        let id = UUID()
        var name: String
        var tasks: [PlanTask]
    }

    init(plan: Plan) {
        _plan = Bindable(plan)
        // A plan the AI just made starts with its rows off the table, so nothing
        // flashes in before the deal.
        _dealing = State(initialValue: FreshPlan.contains(plan))
    }

    var body: some View {
        Group {
            if showTimeline { PlanTimeline(plan: plan, day: $timelineDay) } else { list }
        }
        .overlay {
            // The list shows its own empty row, so this never covers the goal section.
            if plan.tasks.isEmpty && showTimeline {
                ContentUnavailableView {
                    Label("No tasks yet", systemImage: "plus.circle")
                } actions: {
                    Button("Add task", action: addTask)
                }
            }
        }
        .navigationTitle(showTimeline ? plan.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .paperBackground()
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $showTimeline) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Timeline", systemImage: "calendar.day.timeline.left").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            toolbarItems
        }
        .sheet(item: $editing) { SubtaskEditor(plan: plan, name: $0.name, subtasks: $0.tasks) }
        .task {
            // Blank tasks are leftovers (a subtask sheet closed without saving): drop them,
            // as saveSubtasks does. Then pick up Calendar changes made since last time.
            let blank = plan.tasks.filter { !$0.done && $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            if blank.isEmpty { plan.reflow() } else { plan.delete(blank) }
            if FreshPlan.consume(plan) { dealIn() }
        }
    }

    private var list: some View {
        PixelList {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Plan name", text: $plan.title)
                        .font(.largeTitle.bold())
                        .submitLabel(.done)
                    if !plan.tasks.isEmpty {
                        Text(summary)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        ProgressView(value: Double(doneCount), total: Double(plan.tasks.count))
                            .tint(.green)
                            .accessibilityLabel("Progress")
                    }
                    DatePicker("Starts", selection: $plan.start, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .font(.subheadline)
                        .onChange(of: plan.start) { plan.reflow() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
            }

            if isWorking {
                Section {
                    BrickLoader()
                        .padding(.vertical, 4)
                }
            }

            if plan.mode == .goal { goalSection }

            if plan.tasks.isEmpty {
                Section {
                    Button("Add task", systemImage: "plus", action: addTask)
                } header: {
                    Text("No tasks yet").pixelHeader()
                }
            }

            ForEach(groups, id: \.day) { group in
                Section {
                    ForEach(blocks(group.tasks), id: \.tasks.first!.persistentModelID) { block in
                        if !block.parent.isEmpty {
                            // Counts every subtask of this parent, even ones on other days.
                            let subtasks = plan.ordered.filter { $0.parent == block.parent }
                            ParentRow(title: block.parent, tasks: subtasks,
                                      onChange: { plan.reflow() },
                                      onEdit: { editing = SubtaskEdit(name: block.parent, tasks: subtasks) },
                                      onDelete: { plan.delete(subtasks) })
                                .dealIn(shown: dealtIn(block.tasks[0]))
                        }
                        ForEach(block.tasks) { task in
                            TaskRow(task: task, onChange: { plan.reflow() }, onPushBack: { plan.pushBack(task, by: $0) },
                                    onEdit: { editSubtasks(of: task) }, onDelete: { plan.delete([task]) },
                                    onAddBreaks: { plan.addBreaks(to: task, rest: $0) })
                                .padding(.leading, block.parent.isEmpty ? 0 : 28)
                                .dealIn(shown: dealtIn(task))
                        }
                        .onDelete { plan.delete($0.map { block.tasks[$0] }) }
                        .onMove { from, to in
                            // Reorder within the block; moved tasks lose their drop time and pin,
                            // so the list order decides.
                            var day = block.tasks
                            day.move(fromOffsets: from, toOffset: to)
                            from.forEach { block.tasks[$0].notBefore = nil; block.tasks[$0].pinned = nil }
                            var list = plan.ordered
                            let first = list.firstIndex { $0 === block.tasks[0] } ?? 0
                            list.removeAll { t in block.tasks.contains { $0 === t } }
                            list.insert(contentsOf: day, at: first)
                            renumber(list)
                        }
                    }
                } header: {
                    HStack {
                        Text(dayTitle(group.day)).pixelHeader()
                        Spacer()
                        Text(hoursAndMinutes(group.tasks.reduce(0) { $0 + $1.minutes }))
                            .monospacedDigit()
                        if let day = group.day {
                            Button("Add task to \(dayTitle(day))", systemImage: "plus") { plan.addTask(on: day) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    if let day = group.day {
                        let work = group.tasks.filter { $0.category != Plan.freeTime }.reduce(0) { $0 + $1.minutes }
                        let limit = WorkLimit.minutes(on: day, routine: plan.routine)
                        if work > limit {
                            Text("\(hoursAndMinutes(work)) of work is over your \(hoursAndMinutes(limit)) limit for this day. Plan in a break, or move something to another day.")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            if doneCount > 0 {
                Section {
                    Button(showFinished ? "Hide finished tasks" : "Show \(doneCount) finished", systemImage: showFinished ? "eye.slash" : "checkmark.circle") {
                        withAnimation { showFinished.toggle() }
                    }
                }
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }

            calendarSection

            Section {
                Button("Delete plan", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    // On the button, so the popup points at it rather than the middle of the list.
                    .confirmationDialog("Delete \(plan.title.isEmpty ? "this plan" : "“\(plan.title)”")?",
                                        isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete plan", role: .destructive) {
                            plan.deletePlan()
                            dismiss()
                        }
                    } message: {
                        Text("Its tasks, reminders and Calendar events go too.")
                    }
            }
        }
        .animation(.smooth, value: plan.ordered.map(\.start))
    }

    /// The goal itself stays editable: what it is, the study material, and the
    /// finish date. Re-plan rebuilds the tasks from the edited goal.
    private var goalSection: some View {
        Section {
            TextField("Goal", text: $plan.input, axis: .vertical)
            DatePicker("Finish by", selection: finishBy, in: plan.start..., displayedComponents: .date)
            if !plan.materials.isEmpty || Planner.isAvailable {
                // A text box, not a growing field: long material scrolls inside it
                // with a visible scroll bar that flashes on open, so it reads as scrollable.
                TextEditor(text: $plan.materials)
                    .focused($materialsFocused)
                    .frame(height: materialsHeight)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.visible)
                    .scrollIndicatorsFlash(onAppear: true)
                    .padding(.trailing, Planner.isAvailable ? 36 : 0)   // room for the clip
                    .overlay(alignment: .topLeading) {
                        if plan.materials.isEmpty {
                            Text("Study material (optional)").foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if Planner.isAvailable { attachMenu.padding(.top, 4) }
                    }
                    // Typed changes re-plan once the student leaves the box, like Finish by reflows.
                    .onChange(of: materialsFocused) {
                        if materialsFocused { materialsBefore = plan.materials }
                        else if plan.materials != materialsBefore { replanFromGoal() }
                    }
            }
            if Planner.isAvailable {
                Button("Re-plan from this goal", systemImage: "sparkles", action: replanFromGoal)
                    .disabled(isWorking || plan.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Goal").pixelHeader()
        } footer: {
            if let materialNote { Text(materialNote).foregroundStyle(.orange) }
            else {
                Text(Planner.isAvailable ? "Changed your goal? Re-plan to rebuild the tasks you haven't finished. Adding study material re-plans by itself."
                                         : "Changing the finish date reschedules your tasks.")
            }
        }
        .onChange(of: photos) {
            guard !photos.isEmpty else { return }
            let items = photos
            photos = []
            Task { await attach { try await StudyMaterial.text(fromPhotos: items) } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await attach { try await StudyMaterial.text(fromFiles: urls) } }
            case .failure(let error): materialNote = error.localizedDescription
            }
        }
    }

    /// The clip on the study material box: photos or a PDF/image file, read on device.
    private var attachMenu: some View {
        Menu {
            PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .images) {
                Label("Photos", systemImage: "photo")
            }
            Button("PDF or file", systemImage: "doc") { importing = true }
        } label: {
            Group {
                if reading { ProgressView() } else { Image(systemName: "paperclip").font(.title3) }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .disabled(reading || isWorking)
        .accessibilityLabel("Attach study material")
    }

    /// Adds an attachment's text (or its outline) under the material, then re-plans
    /// the unfinished tasks from it.
    private func attach(_ read: () async throws -> String) async {
        reading = true
        materialNote = nil
        defer { reading = false }
        do {
            let (text, note) = await StudyMaterial.prepared(try await read())
            materialNote = note
            guard !text.isEmpty else { return }
            plan.materials = plan.materials.isEmpty ? text : plan.materials + "\n" + text
            replanFromGoal()
        } catch {
            materialNote = error.localizedDescription
        }
    }

    /// Rebuilds the tasks from the goal and its material. Finished tasks (and the bricks they earned) stay.
    private func replanFromGoal() {
        guard Planner.isAvailable, !isWorking, !plan.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            await run {
                let draft = try await Planner.draft(for: plan, history: Reflections.history(in: plan.modelContext))
                if plan.tasks.contains(where: \.done) { plan.replaceRemaining(with: draft) } else { plan.replaceTasks(with: draft) }
            }
        }
    }

    /// Grows with the material up to about 6 lines, then scrolls.
    // ponytail: line count from newlines + ~38 chars per line; close enough at body size.
    private var materialsHeight: CGFloat {
        let lines = plan.materials.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 37) / 38) }
        return CGFloat(min(max(lines, 1), 6)) * 22 + 16
    }

    /// The last day of the plan, as a date; setting it changes `days`.
    private var finishBy: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .day, value: max(plan.days, 1) - 1, to: plan.start) ?? plan.start },
            set: { date in
                let cal = Calendar.current
                plan.days = max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: plan.start), to: cal.startOfDay(for: date)).day ?? 0) + 1)
                for task in plan.tasks where task.day > plan.days { task.day = plan.days }
                plan.reflow()
            })
    }

    /// End of the plan: once the student is happy with it, add it to Calendar.
    /// It can also be done later from the plan's long-press menu on the home list.
    @ViewBuilder private var calendarSection: some View {
        if !plan.tasks.isEmpty {
            let upToDate = CalendarSync.isUpToDate(plan)
            Section {
                if upToDate {
                    Label("In Calendar", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Button(isInCalendar ? "Update Calendar" : "Add to Calendar", systemImage: "calendar.badge.plus") {
                        Task { await addToCalendar() }
                    }
                }
            } footer: {
                if let calendarMessage {
                    Text(calendarMessage).foregroundStyle(.red)
                } else if !upToDate {
                    Text(isInCalendar ? "You changed the plan since adding it."
                                      : "Happy with your plan? Add it now, or later by long-pressing it on the Plans screen.")
                }
            }
        }
    }

    /// Tasks by the day they're scheduled on. `ordered` follows start time, so days are contiguous.
    /// Finished tasks are left out unless "Show finished" is on.
    private var groups: [(day: Date?, tasks: [PlanTask])] {
        var out: [(day: Date?, tasks: [PlanTask])] = []
        for task in plan.ordered where showFinished || !task.done {
            let day = task.start.map(Calendar.current.startOfDay(for:))
            if !out.isEmpty, out[out.count - 1].day == day {
                out[out.count - 1].tasks.append(task)
            } else {
                out.append((day, [task]))
            }
        }
        return out
    }

    /// Consecutive tasks with the same parent ("" = standalone tasks).
    private func blocks(_ tasks: [PlanTask]) -> [(parent: String, tasks: [PlanTask])] {
        var out: [(parent: String, tasks: [PlanTask])] = []
        for task in tasks {
            if !out.isEmpty, out[out.count - 1].parent == task.parent {
                out[out.count - 1].tasks.append(task)
            } else {
                out.append((task.parent, [task]))
            }
        }
        return out
    }

    private func dayTitle(_ day: Date?) -> String {
        guard let day else { return "Not scheduled" }
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }

    private var doneCount: Int { plan.tasks.filter(\.done).count }

    /// "2 of 5 done · 1 h 45 min left", or "All done".
    private var summary: String {
        let left = plan.tasks.filter { !$0.done }.reduce(0) { $0 + $1.minutes }
        if left == 0 { return "All done" }
        return "\(doneCount) of \(plan.tasks.count) done · \(hoursAndMinutes(left)) left"
            + (plan.breakMinutes > 0 ? " · \(plan.breakMinutes) min breaks after a tiring day" : "")
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if Planner.isAvailable && (!plan.input.isEmpty || hasPending) {
            ToolbarItem {
                Menu {
                    if hasPending {
                        Button("Re-plan the rest with AI", systemImage: "sparkles") {
                            Task { await run { plan.replaceRemaining(with: try await Planner.replan(plan)) } }
                        }
                    }
                    if !plan.input.isEmpty {
                        Button("Try a different plan", systemImage: "arrow.clockwise") {
                            Task {
                                await run {
                                    // Show the AI the current plan so it makes a different one.
                                    plan.replaceTasks(with: try await Planner.draft(for: plan, previous: plan.ordered,
                                                                                    history: Reflections.history(in: plan.modelContext)))
                                }
                            }
                        }
                    }
                } label: {
                    if isWorking { ProgressView() } else { Label("Re-plan", systemImage: "arrow.clockwise") }
                }
                .disabled(isWorking)
            }
        }
        if !showTimeline { ToolbarItem { EditButton() } }
        ToolbarItem { Button("Add task", systemImage: "plus", action: addTask) }
    }

    private var isInCalendar: Bool { plan.tasks.contains { $0.eventID != nil } }

    private func addToCalendar() async {
        do {
            _ = try await CalendarSync.add(plan)
            calendarMessage = nil   // the bar switches to "In Calendar"
        } catch {
            calendarMessage = error.localizedDescription
        }
    }

    /// Opens the subtask editor for a task's parent, or for a plain task on its own.
    private func editSubtasks(of task: PlanTask) {
        editing = task.parent.isEmpty
            ? SubtaskEdit(name: task.title, tasks: [task])
            : SubtaskEdit(name: task.parent, tasks: plan.ordered.filter { $0.parent == task.parent })
    }

    private func renumber(_ list: [PlanTask]) {
        for (i, task) in list.enumerated() { task.order = i }
        plan.reflow()
    }

    /// The toolbar's +: the day the timeline shows; in the list, today, or the
    /// plan's nearest day when today is outside it.
    private func addTask() {
        if showTimeline { plan.addTask(on: timelineDay); return }
        let cal = Calendar.current
        let first = cal.startOfDay(for: plan.start)
        let last = cal.date(byAdding: .day, value: max(plan.days, 1) - 1, to: first) ?? first
        plan.addTask(on: min(max(cal.startOfDay(for: .now), first), last))
    }

    private var hasPending: Bool { plan.tasks.contains { !$0.done } }

    /// Whether this row is on the table yet; all of them unless a deal is running.
    private func dealtIn(_ task: PlanTask) -> Bool {
        guard dealing else { return true }
        return (plan.ordered.firstIndex { $0 === task } ?? 0) < dealt
    }

    /// Deals the rows in from the right, one every 60 ms: for the plan the AI just
    /// made, and after a re-plan. Only then, never on a redraw or reflow.
    private func dealIn() {
        let count = plan.ordered.count
        dealt = 0
        dealing = count > 0 && !reduceMotion
        guard dealing else { return }   // Reduce Motion: the end state, no motion
        Task {
            for i in 1...count {
                try? await Task.sleep(for: .milliseconds(60))
                dealt = i
            }
            dealing = false
        }
    }

    /// Runs an AI re-plan with a spinner, then re-adds to Calendar if auto-add is on.
    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await work()
            dealIn()   // the new rows land once the loader goes
            if autoAddToCalendar { await addToCalendar() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ParentRow: View {
    let title: String
    let tasks: [PlanTask]
    var onChange: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var allDone: Bool { tasks.allSatisfy(\.done) }
    private var doneCount: Int { tasks.filter(\.done).count }
    private var total: Int { tasks.reduce(0) { $0 + $1.minutes } }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            BouncyCheck(done: allDone, label: allDone ? "Mark all not done" : "Mark all done") {
                let newValue = !allDone
                tasks.forEach { newValue ? CheckIn.shared.tick($0) : CheckIn.shared.untick($0) }
                onChange()   // re-arm reminders
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .strikethrough(allDone)
                    .foregroundStyle(allDone ? .secondary : .primary)
                Text("\(doneCount) of \(tasks.count) subtasks · \(hoursAndMinutes(total))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture(perform: onEdit)
        .contextMenu {
            Button("Edit subtasks", systemImage: "list.bullet.indent", action: onEdit)
            Button("Delete with subtasks", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .moveDisabled(true)
        .accessibilityAction(named: "Edit subtasks", onEdit)
    }
}

private struct TaskRow: View {
    @Bindable var task: PlanTask
    var onChange: () -> Void
    var onPushBack: (Int) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onAddBreaks: (Int) -> Void

    @FocusState private var editingTitle: Bool
    @State private var titleBefore = ""

    private var isLong: Bool { !task.done && task.minutes > Plan.longTask && task.category != Plan.freeTime }

    private var startPicker: some View {
        DatePicker("Start time", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
    }

    /// The student's stress for this task (sets their own score for its title).
    private var stress: Binding<Int> {
        Binding(get: { Ratings.score(task.title) ?? 5 }, set: { Ratings.set([task.title], score: $0) })
    }

    /// Setting a new time fixes the task there (same as pinning).
    private var time: Binding<Date> {
        Binding(get: { task.start ?? .now }, set: { task.pinned = $0; onChange() })
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            BouncyCheck(done: task.done, label: task.done ? "Mark not done" : "Mark done") {
                CheckIn.shared.toggle(task)
                onChange()   // re-arm reminders; a finished task keeps its time
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if task.priority == 0 {
                        Image(systemName: "exclamationmark")
                            .font(.subheadline.weight(.heavy)).foregroundStyle(.red)
                            .accessibilityLabel("High priority")
                    } else if task.priority == 2 {
                        Image(systemName: "arrow.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .accessibilityLabel("Low priority")
                    }
                    TextField("Task", text: $task.title)
                        .focused($editingTitle)
                        .onChange(of: editingTitle) {
                            // Clearing the name and leaving keeps the old one, so no blank task is left behind.
                            if editingTitle { titleBefore = task.title }
                            else if task.title.trimmingCharacters(in: .whitespaces).isEmpty {
                                task.title = titleBefore.isEmpty ? "New task" : titleBefore
                            } else if let stress = task.plan?.stress, task.title != "New task", Ratings.score(task.title) == nil {
                                Ratings.set([task.title], score: stress)   // the plan's slider, for typed-in tasks
                            }
                        }
                        .strikethrough(task.done)
                        .foregroundStyle(task.done ? .secondary : .primary)
                    if task.pinned != nil {
                        Image(systemName: "pin.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityLabel("Fixed time")
                    }
                }
                if let start = task.start, let end = task.end {
                    if task.done {
                        Text((start..<end).formatted(.interval.hour().minute()))
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        // Time only: the section header already says the day. Indented subtasks
                        // in Edit mode are too narrow for the end time too, so it drops there
                        // instead of pushing the duration into the drag handle.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) {
                                startPicker
                                Text("– \(end.formatted(date: .omitted, time: .shortened))")
                                    .foregroundStyle(.secondary).monospacedDigit()
                                    .fixedSize()
                            }
                            startPicker
                        }
                        .font(.subheadline)
                    }
                }
                if isLong {
                    Menu {
                        ForEach([5, 10, 15], id: \.self) { rest in
                            Button("\(rest) min break every hour") { onAddBreaks(rest) }
                        }
                    } label: {
                        Label("Long tasks still need breaks. Add some?", systemImage: "cup.and.saucer")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }

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
            .accessibilityLabel("Duration, \(hoursAndMinutes(task.minutes))")
            .onChange(of: task.minutes) { onChange() }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(task.parent.isEmpty ? "Add subtasks" : "Edit subtasks", systemImage: "list.bullet.indent", action: onEdit)
            Picker("Priority", selection: $task.priority) {
                Label("High", systemImage: "exclamationmark").tag(0)
                Label("Normal", systemImage: "minus").tag(1)
                Label("Low", systemImage: "arrow.down").tag(2)
            }
            .pickerStyle(.menu)
            if task.category != Plan.freeTime {
                Picker("Stress", systemImage: "bolt", selection: stress) {
                    ForEach((1...10).reversed(), id: \.self) { Text("\($0)/10 · \(Rating(score: $0).effort)").tag($0) }
                }
                .pickerStyle(.menu)
            }
            if !task.done {
                Section(pixel: "Need more time?") {
                    ForEach([15, 30, 60], id: \.self) { minutes in
                        Button("+\(minutes) min", systemImage: "clock.arrow.circlepath") { onPushBack(minutes) }
                    }
                }
            }
            if isLong {
                Menu("Add breaks", systemImage: "cup.and.saucer") {
                    ForEach([5, 10, 15], id: \.self) { rest in
                        Button("\(rest) min break every hour") { onAddBreaks(rest) }
                    }
                }
            }
            if task.pinned == nil, !task.done, let start = task.start {
                Button("Pin to \(start.formatted(date: .omitted, time: .shortened))", systemImage: "pin") {
                    task.pinned = start
                    onChange()
                }
            }
            if task.pinned != nil {
                Button("Unpin time", systemImage: "pin.slash") {
                    task.pinned = nil
                    onChange()
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        // A custom swipe turns off .onDelete's swipe, so Delete is added back explicitly.
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .swipeActions(edge: .leading) {
            if !task.done {
                Button("+15 min", systemImage: "clock.arrow.circlepath") { onPushBack(15) }
                    .tint(.orange)
            }
        }
    }
}

/// Duration choices for a task, up to 8 h (the check-in's cap too).
let taskDurations = [5, 10, 15, 20, 25, 30, 40, 45, 50, 60, 75, 90, 105, 120, 150, 180, 210, 240, 300, 360, 420, 480]

/// "45 min", "1 h", "1 h 30 min".
func hoursAndMinutes(_ minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) min" }
    return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
}

/// The plan the AI just made: PlanView deals its rows in on first show.
// ponytail: a hand-off set rather than a flag on the model, so no schema change.
@MainActor enum FreshPlan {
    private static var ids: Set<PersistentIdentifier> = []
    static func mark(_ plan: Plan) { ids.insert(plan.persistentModelID) }
    static func contains(_ plan: Plan) -> Bool { ids.contains(plan.persistentModelID) }
    static func consume(_ plan: Plan) -> Bool { ids.remove(plan.persistentModelID) != nil }
}

/// A row dealt in from the right like a card: slides in with a slight tilt and
/// settles. Reduce Motion shows it in place.
private struct DealIn: ViewModifier {
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(x: shown || reduceMotion ? 0 : 80)
            .rotationEffect(.degrees(shown || reduceMotion ? 0 : 4))
            .opacity(shown || reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75), value: shown)
    }
}

private extension View {
    func dealIn(shown: Bool) -> some View { modifier(DealIn(shown: shown)) }
}
