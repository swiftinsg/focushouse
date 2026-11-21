import SwiftUI
import TipKit
import SwiftData
import EventKit
import EventKitUI

/// Home: a month calendar, then everything on the picked day. That's the
/// scheduled tasks from every plan, plus inbox to-dos due that day.
struct CalendarView: View {
    @Query private var tasks: [PlanTask]
    @Query(filter: #Predicate<TodoItem> { !$0.isDone }) private var todos: [TodoItem]
    @State private var day = Date.now
    @State private var events: [EKEvent] = []
    @State private var deleting: EKEvent?   // a repeating event, asking which ones
    @State private var calendarError: String?
    @State private var addingEvent = false
    @State private var deletingPlan: Plan?
    @Environment(\.modelContext) private var context
    /// Calendar events ticked off here ("id|start", newline-separated). They stay in
    /// Calendar; focushouse just stops showing them. ponytail: grows forever, prune old days if it ever matters.
    @AppStorage("doneEvents") private var doneEvents = ""

    private let cal = Calendar.current

    private var tasksOnDay: [PlanTask] {
        tasks.filter { !$0.done && ($0.start.map { cal.isDate($0, inSameDayAs: day) } ?? false) }
            .sorted { $0.start! < $1.start! }
    }
    /// How many unfinished things each day has, for the rings.
    private var counts: [Date: Int] {
        let days = tasks.filter { !$0.done }.compactMap { $0.start.map(cal.startOfDay) }
            + todos.map { cal.startOfDay(for: $0.dueDate) }
        return days.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
    private var todosOnDay: [TodoItem] { todos.filter { cal.isDate($0.dueDate, inSameDayAs: day) } }

    var body: some View {
        NavigationStack {
            PixelList {
                // Inline, not a popover: a popover covers the day below and blocks scrolling.
                TipView(Hint.calendar)
                MonthGrid(day: $day, counts: counts)

                Section(pixel: day.formatted(.dateTime.weekday(.wide).day().month())) {
                    ForEach(tasksOnDay) { taskRow($0) }
                    ForEach(todosOnDay) { todoRow($0) }
                    if tasksOnDay.isEmpty && todosOnDay.isEmpty && shownEvents.isEmpty {
                        Text("Nothing on this day").foregroundStyle(.secondary)
                    }
                }

                if !shownEvents.isEmpty {
                    Section(pixel: "In your Calendar") {
                        ForEach(shownEvents, id: \.calendarItemIdentifier) { event in
                            eventRow(event)
                                .transition(.gone)
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        if event.hasRecurrenceRules { deleting = event } else { delete(event) }
                                    }
                                }
                        }
                    }
                }
            }
            .pixelTitle("Calendar")
            .toolbar {
                Button("Add event", systemImage: "plus") {
                    Task { if await CalendarSync.requestAccess() { addingEvent = true } else { calendarError = "Allow Calendar access in Settings to add events." } }
                }
            }
            .sheet(isPresented: $addingEvent, onDismiss: { Task { await loadEvents() } }) {
                EventEditor(start: newEventStart).ignoresSafeArea()
            }
            .task(id: day) { await loadEvents() }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in Task { await loadEvents() } }
            .confirmationDialog("This is a repeating event.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { event in
                Button("Delete This Event Only", role: .destructive) { delete(event) }
                Button("Delete All Future Events", role: .destructive) { delete(event, future: true) }
            }
            .confirmationDialog("Delete \(deletingPlan.map { $0.title.isEmpty ? "this plan" : "“\($0.title)”" } ?? "")?",
                                isPresented: Binding(get: { deletingPlan != nil }, set: { if !$0 { deletingPlan = nil } }),
                                titleVisibility: .visible, presenting: deletingPlan) { plan in
                Button("Delete plan", role: .destructive) { withAnimation { plan.deletePlan() } }
            } message: { _ in Text("All its tasks, reminders and Calendar events go too.") }
            .alert("Calendar", isPresented: Binding(get: { calendarError != nil }, set: { if !$0 { calendarError = nil } })) {
                Button("OK") {}
            } message: { Text(calendarError ?? "") }
            .navigationDestination(for: Plan.self) { PlanView(plan: $0) }
        }
    }

    /// The picked day at the next whole hour (or 9 AM for a day with no time yet today).
    private var newEventStart: Date {
        let now = Date.now
        if cal.isDateInToday(day) { return cal.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    private func loadEvents() async {
        await CalendarSync.requestAccess()
        events = CalendarSync.events(on: day, excluding: Set(tasks.compactMap(\.eventID)))
    }

    private func delete(_ event: EKEvent, future: Bool = false) {
        do { try CalendarSync.delete(event, future: future) }
        catch { calendarError = error.localizedDescription }
        Task { await loadEvents() }
    }

    private func taskRow(_ task: PlanTask) -> some View {
        HStack(spacing: 12) {
            BouncyCheck(done: task.done, label: task.done ? "Mark not done" : "Mark done") {
                CheckIn.shared.toggle(task)
                task.plan?.reflow()   // re-arm reminders, as in PlanView
            }

            if let plan = task.plan {
                NavigationLink(value: plan) { row(task) }
            } else {
                row(task)
            }
        }
        .transition(.gone)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTask(task) }
            if task.eventID != nil {
                Button("Remove from Calendar", systemImage: "calendar.badge.minus") {
                    CalendarSync.remove([task])
                }
            }
        }
        .contextMenu {
            Button("Delete task", systemImage: "trash", role: .destructive) { deleteTask(task) }
            if let plan = task.plan {
                Button("Delete whole plan", systemImage: "trash", role: .destructive) { deletingPlan = plan }
            }
        }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        HStack(spacing: 12) {
            TodoTick(todo: todo, size: .title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.name)
                Text("Due · not planned yet").font(.caption).foregroundStyle(.orange)
            }
        }
        .transition(.gone)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { withAnimation { context.delete(todo) } }
        }
        .contextMenu {
            Button("Delete to-do", systemImage: "trash", role: .destructive) { withAnimation { context.delete(todo) } }
        }
    }

    private func deleteTask(_ task: PlanTask) {
        withAnimation {
            if let plan = task.plan { plan.delete([task]) }
            else { CalendarSync.remove([task]); Reminders.cancel([task]); context.delete(task) }
        }
    }

    private func key(_ event: EKEvent) -> String {
        "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSinceReferenceDate)"
    }
    private var shownEvents: [EKEvent] {
        let done = Set(doneEvents.split(separator: "\n").map(String.init))
        return events.filter { !done.contains(key($0)) }
    }

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 12) {
            // BouncyCheck runs this inside withAnimation, so the row pops then slides away.
            BouncyCheck(done: false, label: "Mark done") { doneEvents += key(event) + "\n" }
            Rectangle().fill(Color(cgColor: event.calendar.cgColor)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Event")
                Text(event.isAllDay ? "All day · \(event.calendar.title)"
                     : "\(event.startDate.formatted(date: .omitted, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened)) · \(event.calendar.title)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ task: PlanTask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
            Text("\(task.start!.formatted(date: .omitted, time: .shortened))–\(task.end!.formatted(date: .omitted, time: .shortened)) · \(task.plan?.title ?? "")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A month of days. A ring around each date fills up as the day gets busier:
/// a dot for one thing to do, a full circle at `full`.
struct MonthGrid: View {
    @Binding var day: Date
    var counts: [Date: Int]
    private let full = 6   // ponytail: fixed scale; base it on the student's busiest day if 6 feels wrong
    @State private var month = Date.now
    @State private var revealed = false   // rings sweep in when the grid appears / the month changes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button("Previous month", systemImage: "chevron.left") { shift(-1) }
                Button("Next month", systemImage: "chevron.right") { shift(1) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(Self.weekdaySymbols(cal).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(Array(Self.days(in: month, calendar: cal).enumerated()), id: \.offset) { index, date in
                    if let date { cell(date, index: index) } else { Color.clear.frame(height: 40) }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear { reveal() }
        .onChange(of: month) { reveal() }
        .onChange(of: day) { if !cal.isDate(day, equalTo: month, toGranularity: .month) { month = day } }
        .sensoryFeedback(.selection, trigger: day)
    }

    private func cell(_ date: Date, index: Int) -> some View {
        let selected = cal.isDate(date, inSameDayAs: day)
        let today = cal.isDateInToday(date)
        let count = counts[date] ?? 0
        let fill = Self.fill(count, full: full)
        return Button { day = date } label: {
            Text(date.formatted(.dateTime.day()))
                .font(.callout.weight(today || selected ? .bold : .regular))
                .foregroundStyle(selected ? Color.white : today ? Color.accentColor : .primary)
                .frame(width: 32, height: 32)
                .background(selected ? Color.accentColor : .clear, in: .circle)
                .overlay {
                    Circle().stroke(.fill.tertiary, lineWidth: 3).opacity(count > 0 ? 1 : 0)
                    Circle().trim(from: 0, to: revealed ? fill : 0)
                        .stroke(Color.grass, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        // A day at a time: the small delay makes the fill ripple across the month.
                        // The reset back to 0 is instant (animation is nil while revealed is false).
                        .animation(reduceMotion || !revealed ? nil : .easeOut(duration: 0.4).delay(Double(index) * 0.02),
                                   value: revealed)
                }
                .padding(3)
                .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (count > 0 ? ", \(count) to do" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Rings jump back to empty, then sweep in day by day. With Reduce Motion
    /// they simply appear at their fill.
    private func reveal() {
        guard !reduceMotion else { revealed = true; return }
        revealed = false
        // Let the empty frame render before the sweep, so changing month doesn't
        // just crossfade the old month's rings.
        Task { @MainActor in revealed = true }
    }

    private func shift(_ months: Int) {
        month = cal.date(byAdding: .month, value: months, to: month)!
    }

    /// How far round the ring goes: nothing for 0, a dot for 1 (a tiny arc with
    /// round caps), then evenly up to a full circle at `full` or more.
    static func fill(_ count: Int, full: Int) -> CGFloat {
        count <= 0 ? 0 : count == 1 ? 0.001 : min(CGFloat(count) / CGFloat(full), 1)
    }

    /// Very short weekday names, starting on the locale's first weekday.
    static func weekdaySymbols(_ cal: Calendar) -> [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        return Array(s[(cal.firstWeekday - 1)...] + s[..<(cal.firstWeekday - 1)])
    }

    /// The month's days (at start of day), led by nils so day 1 sits under its weekday.
    static func days(in month: Date, calendar cal: Calendar) -> [Date?] {
        let first = cal.dateInterval(of: .month, for: month)!.start
        let blanks = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: first)!.count
        return Array(repeating: nil, count: blanks) + (0..<count).map { cal.date(byAdding: .day, value: $0, to: first) }
    }
}

extension AnyTransition {
    /// A ticked row leaving: slides right, shrinks and fades.
    static var gone: AnyTransition {
        .asymmetric(insertion: .opacity,
                    removal: .move(edge: .trailing).combined(with: .scale(scale: 0.6)).combined(with: .opacity))
    }
}

/// Apple's own new-event screen, starting at `start` for an hour.
struct EventEditor: UIViewControllerRepresentable {
    let start: Date
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let event = EKEvent(eventStore: CalendarSync.store)
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        event.calendar = CalendarSync.store.defaultCalendarForNewEvents
        let editor = EKEventEditViewController()
        editor.eventStore = CalendarSync.store
        editor.event = event
        editor.editViewDelegate = context.coordinator
        return editor
    }

    func updateUIViewController(_ editor: EKEventEditViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        // The editor saves the event itself on Add.
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { dismiss() }
    }
}

