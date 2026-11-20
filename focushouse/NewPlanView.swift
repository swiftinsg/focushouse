import PhotosUI
import SwiftUI
import SwiftData

struct NewPlanView: View {
    var initialInput = ""
    var onCreate: (Plan) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var mode = PlanMode.today
    @State private var input = ""
    @State private var materials = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var reading = false   // pulling text out of an attachment
    @State private var materialNote: String?
    @State private var start = Date.nextFiveMinutes
    @State private var due = Calendar.current.date(byAdding: .day, value: 6, to: .now)!
    @State private var isWorking = false
    @State private var error: String?
    @State private var question: String?   // the planner needs one more detail
    @AppStorage("askFreeTime") private var askFreeTime = false
    @AppStorage("autoAddToCalendar") private var autoAddToCalendar = false
    @AppStorage("bed") private var bed = 22 * 60
    @State private var freeFrom = Date.now
    @State private var freeUntil = Date.now

    var body: some View {
        NavigationStack {
            PixelList {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(PlanMode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(mode == .today ? "Input your messy to-do list into a timed plan for today."
                                        : "Break one big goal into multiple tasks over several days.")
                }

                Section {
                    TextField(mode == .today ? "maths hw, read ch 4, tidy room…" : "Revise for my biology exam",
                              text: $input, axis: .vertical)
                        .lineLimit(4...10)
                        .onChange(of: input) { question = nil }
                } header: {
                    Text(mode == .today ? "Dump your to-do list" : "What's your goal?").pixelHeader()
                } footer: {
                    if let question {
                        Label(question, systemImage: "questionmark.bubble.fill").foregroundStyle(.orange)
                    }
                }

                if Planner.distressed(input) {
                    Section {
                        Label {
                            Text("It sounds like things are really hard right now. You don't have to deal with it alone. Talk to someone you trust, or reach Samaritans of Singapore any time: call 1767 or WhatsApp 9151 1767. If you're in danger, call 995.")
                        } icon: {
                            Image(systemName: "heart.fill").foregroundStyle(.pink)
                        }
                    } footer: {
                        Text("That line won't be added as a task.")
                    }
                }

                if mode == .today, let vent = Planner.lines(input).first(where: Planner.venting) {
                    Section {} footer: {
                        Text("\"\(vent)\" sounds like a feeling, not a task, so it won't be planned. Hang in there.")
                    }
                }

                Section {
                    DatePicker("Start", selection: $start, in: Date.now...,
                               displayedComponents: [.date, .hourAndMinute])
                    if mode == .goal {
                        DatePicker("Finish by", selection: $due,
                                   in: start...Calendar.current.date(byAdding: .day, value: 29, to: start)!,
                                   displayedComponents: .date)
                        Text("\(days) day\(days == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("When").pixelHeader()
                } footer: {
                    Text("Plan ahead by picking a later start, and times are fitted around your routine and calendar.")
                }

                if Planner.isAvailable {
                    Section {
                        TextField("Section 1: arenes, electrophilic substitution\nSection 2: other substituents…",
                                  text: $materials, axis: .vertical)
                            .lineLimit(3...12)
                        HStack {
                            PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .images) {
                                Label("Photos", systemImage: "photo")
                            }
                            Spacer()
                            if reading { ProgressView() }
                            Spacer()
                            Button { importing = true } label: { Label("PDF or file", systemImage: "doc") }
                        }
                        .buttonStyle(.borderless)
                        .disabled(reading)
                    } header: {
                        Text("Study material (optional)").pixelHeader()
                    } footer: {
                        if let materialNote { Text(materialNote).foregroundStyle(.orange) }
                        else {
                            Text("Paste your own notes or a syllabus, or attach a PDF or photos of it (read on your phone, nothing uploaded). Each section becomes a task with subtasks. Label priorities in your list with words like \"urgent\" or \"can wait\".")
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

                if askFreeTime {
                    Section(pixel: "When are you free?") {
                        DatePicker("From", selection: $freeFrom, displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: $freeUntil, displayedComponents: .hourAndMinute)
                    }
                }

                Section {
                    VStack(spacing: 12) {
                        if Planner.isAvailable {
                            Button {
                                Task { await makePlan() }
                            } label: {
                                HStack(spacing: 8) {
                                    if isWorking { ProgressView() } else { Image(systemName: "sparkles") }
                                    Text(isWorking ? "Planning…" : "Make my plan")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.pixel)
                            .disabled(isWorking || reading || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Button("Enter tasks myself", action: makeManual)
                            .disabled(isWorking)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    if let error { Text(error).foregroundStyle(.red) }
                    else if !Planner.isAvailable {
                        Text("Apple Intelligence isn't available on this device, so you'll add tasks yourself.")
                    }
                }
            }
            .pixelTitle("New plan")
            .onAppear {
                if input.isEmpty { input = initialInput }
                freeFrom = start
                freeUntil = Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(bed * 60))
            }
            .onChange(of: start) { if due < start { due = start } }
            .task {
                await CalendarSync.requestAccess()
                await Reminders.requestAccess()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    /// Plan length in days: 1 for Today, start day through "Finish by" for Goal.
    private var days: Int {
        guard mode == .goal else { return 1 }
        let cal = Calendar.current
        return max(1, (cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: due)).day ?? 0) + 1)
    }

    private func makePlan() async {
        isWorking = true
        error = nil
        question = nil
        defer { isWorking = false }
        do {
            let plan = newPlan(title: "", input: input, insert: false)
            let history = Reflections.history(in: context)
            plan.breakMinutes = Reflections.breakMinutes(history)
            let draft = try await Planner.draft(for: plan, history: history)
            plan.title = Planner.planTitle(draft.title, input: input, items: draft.items.map(\.title))
            context.insert(plan)
            plan.replaceTasks(with: draft)
            if autoAddToCalendar { _ = try? await CalendarSync.add(plan) }
            onCreate(plan)
        } catch let asked as PlannerError where asked.isQuestion {
            question = asked.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Adds an attachment's text (or its outline) under what's already in the box.
    private func attach(_ read: () async throws -> String) async {
        reading = true
        materialNote = nil
        defer { reading = false }
        do {
            let (text, note) = await StudyMaterial.prepared(try await read())
            if !text.isEmpty { materials = materials.isEmpty ? text : materials + "\n" + text }
            materialNote = note
        } catch {
            materialNote = error.localizedDescription
        }
    }

    private func makeManual() {
        let firstLine = input.split(separator: "\n").first.map(String.init) ?? ""
        let plan = newPlan(title: firstLine, input: "")   // blank shows the grey "Plan name" hint
        plan.breakMinutes = Reflections.breakMinutes(Reflections.history(in: context))
        onCreate(plan)
    }

    private func newPlan(title: String, input: String, insert: Bool = true) -> Plan {
        let plan = Plan(title: title, mode: mode, input: input, days: days, start: max(start, .now))   // form may sit open past the start
        plan.materials = input.isEmpty ? "" : materials
        if askFreeTime {
            let minutes = { (d: Date) in Calendar.current.component(.hour, from: d) * 60 + Calendar.current.component(.minute, from: d) }
            plan.freeFrom = minutes(freeFrom)
            plan.freeUntil = minutes(freeUntil)
        }
        if insert { context.insert(plan) }
        return plan
    }
}

extension Plan {
    /// Swap in the model's tasks and schedule them.
    @MainActor func replaceTasks(with draft: DraftPlan) {
        replace(tasks, with: draft)
    }

    /// Re-plan with AI: rebuild only the unfinished tasks, starting now.
    @MainActor func replaceRemaining(with draft: DraftPlan) {
        let now = Date.nextFiveMinutes
        if now > start {
            let cal = Calendar.current
            let elapsed = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: now)).day ?? 0
            days = max(1, days - elapsed)
            start = now
        }
        replace(tasks.filter { !$0.done }, with: draft)
    }

    @MainActor private func replace(_ old: [PlanTask], with draft: DraftPlan) {
        CalendarSync.remove(old)
        Reminders.cancel(old)
        KeptTask.keep(old)
        old.forEach { modelContext?.delete($0) }
        let kept = tasks.filter { t in !old.contains { $0 === t } }
        // "tuition at 7pm": that item stays one task, pinned at 7 PM.
        let pins = mode == .today ? Planner.pins(Planner.items(input), titles: draft.items.map(\.title), after: start) : [:]
        // Each subtask is a normal task, grouped under its item's title.
        let made = draft.items.enumerated().flatMap { n, item in
            let pin = pins[n]
            let steps = item.subtasks.isEmpty || pin != nil ? [DraftStep(title: item.title, minutes: item.minutes)] : item.subtasks
            return steps.map { step in
                let task = PlanTask(title: step.title, category: item.category, minutes: step.minutes,
                                    day: mode == .today ? 1 : min(max(item.day, 1), days), order: 0)
                task.priority = Planner.priorities.firstIndex(of: item.priority) ?? 1
                task.estimate = step.minutes
                task.parent = steps.count > 1 ? item.title : ""
                task.pinned = pin
                return task
            }
        }
        // Higher priority first within each day; otherwise keep the AI's order (stable sort).
        tasks = kept.sorted { $0.order < $1.order } + made.enumerated()
            .sorted { ($0.element.day, $0.element.priority, $0.offset) < ($1.element.day, $1.element.priority, $1.offset) }
            .map(\.element)
        for (i, task) in tasks.enumerated() { task.order = i }
        reflow()
        addFreeTime()
    }
}
