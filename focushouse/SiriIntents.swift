import AppIntents
import CoreSpotlight
import Foundation
import GeoToolbox
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Siri and Spotlight: plan tasks and to-dos are shared as reminders (Apple's
/// reminders schema, so the new Siri understands them) with their stress score,
/// "How's my house?" answers with the house and today's load, and "Remind me to…
/// in focushouse" adds a to-do. All on device: Siri reads the on-device index.

// MARK: "How's my house?"

struct HouseCheckIntent: AppIntent {
    static let title: LocalizedStringResource = "Check my house"
    static let description = IntentDescription("How stressed you are: your house, today's hard tasks and what's next.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication   // task names only when unlocked
    @Dependency var container: ModelContainer

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let now = Date.now
        let (status, tasks, todos) = SiriContext.status(container.mainContext, now: now)
        let state = House.state(streak: status.streak, log: RestLog.load(RestLog.defaults.data(forKey: "restLog") ?? Data()), now: now)
        let cal = Calendar.current
        let today = tasks.filter { $0.start.map { cal.isDate($0, inSameDayAs: now) } ?? false }
            .map { SiriContext.Item(title: $0.title, start: $0.start, score: status.rating($0.title, priority: $0.priority, category: $0.category).score, done: $0.done) }
            + todos.filter { cal.isDate($0.dueDate, inSameDayAs: now) }
            .map { SiriContext.Item(title: $0.name, start: nil, score: status.rating($0.name, priority: $0.priority.level).score, done: $0.isDone) }
        let text = SiriContext.summary(state: state, streak: status.streak, items: today, now: now)
        return .result(dialog: "\(text)") {
            VStack(spacing: 8) {
                Image("house." + state.rawValue).pixelArt().frame(height: 120)
                Text(state.rawValue.capitalized).font(.headline)
            }
            .padding()
        }
    }
}

struct FocusHouseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: HouseCheckIntent(),
                    phrases: ["How's my house in \(.applicationName)",
                              "How stressed am I in \(.applicationName)",
                              "Check my \(.applicationName)"],
                    shortTitle: "Check my house", systemImageName: "house")
    }
}

// MARK: "Remind me to … in focushouse"

/// Siri's create-reminder action: becomes a to-do on the Schedule tab.
@AppIntent(schema: .reminders.createReminder)
struct AddTodoIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter var title: String
    @Parameter var dueDate: DateComponents?
    // The schema's other inputs; a to-do only keeps the title and due date.
    @Parameter var note: AttributedString?
    @Parameter var isFlagged: Bool?
    @Parameter var list: TaskListEntity?
    @Parameter var section: TaskSectionEntity?
    @Parameter var locationTrigger: PlaceEntity?
    @Parameter var recurrence: Calendar.RecurrenceRule?
    @Parameter(default: []) var tags: Set<String>
    @Parameter(default: []) var urls: [URL]
    @Parameter(default: [], supportedContentTypes: [.image]) var images: [IntentFile]
    @Dependency var container: ModelContainer

    @MainActor func perform() async throws -> some ReturnsValue<TaskEntity> {
        let todo = TodoItem(name: title, selectedTag: "Work", dueDate: dueDate.flatMap(Calendar.current.date(from:)) ?? .now)
        container.mainContext.insert(todo)
        try container.mainContext.save()
        let (status, _, _) = SiriContext.status(container.mainContext)
        return .result(value: SiriContext.entity(todo, status))
    }
}

// MARK: Tasks as reminders

@AppEntity(schema: .reminders.reminder)
struct TaskEntity: IndexedEntity {
    static let defaultQuery = TaskQuery()
    var id: String
    var title: String
    var note: AttributedString?        // "Stress 7/10 (hard), 45 min"
    var dueDate: DateComponents?
    var creationDate: Date?
    var completionDate: Date?
    var isCompleted: Bool
    var isFlagged: Bool?
    var list: TaskListEntity
    var locationTrigger: PlaceEntity?  // the schema needs these; focushouse doesn't use them
    var recurrence: Calendar.RecurrenceRule?
    var tags: Set<String>              // effort ("hard") and "stress 7"
    var urls: [URL]

    init(id: String, title: String, note: String, due: Date?, doneAt: Date?, done: Bool, flagged: Bool,
         list: TaskListEntity, tags: Set<String>) {
        self.id = id
        self.title = title
        self.note = AttributedString(note)
        self.dueDate = due.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        self.creationDate = nil
        self.completionDate = doneAt
        self.isCompleted = done
        self.isFlagged = flagged
        self.list = list
        self.locationTrigger = nil
        self.recurrence = nil
        self.tags = tags
        self.urls = []
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: note.map { "\(String($0.characters))" })
    }

    /// The stress line goes into Spotlight's description, so Siri can answer "what's my hardest task?".
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.contentDescription = note.map { String($0.characters) }
        set.keywords = Array(tags)
        return set
    }
}

struct TaskQuery: EntityStringQuery {
    @Dependency var container: ModelContainer

    @MainActor func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        SiriContext.entities(container.mainContext).filter { identifiers.contains($0.id) }
    }

    @MainActor func entities(matching string: String) async throws -> [TaskEntity] {
        SiriContext.entities(container.mainContext).filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    /// What's left, soonest first.
    @MainActor func suggestedEntities() async throws -> [TaskEntity] {
        let date = { (e: TaskEntity) in e.dueDate.flatMap(Calendar.current.date(from:)) ?? .distantFuture }
        let from = Date.now.addingTimeInterval(-3600)
        return Array(SiriContext.entities(container.mainContext)
            .filter { !$0.isCompleted && date($0) >= from }
            .sorted { date($0) < date($1) }
            .prefix(10))
    }
}

@AppEntity(schema: .reminders.list)
struct TaskListEntity {
    static let defaultQuery = TaskListQuery()
    static let plans = TaskListEntity(id: "plans", name: "Plans", type: .standard)
    static let todos = TaskListEntity(id: "todos", name: "To-dos", type: .standard)
    var id: String
    var name: String
    var type: ListKind

    init(id: String, name: String, type: ListKind) {
        self.id = id
        self.name = name
        self.type = type
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TaskListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskListEntity] {
        [TaskListEntity.plans, .todos].filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [TaskListEntity] {
        [TaskListEntity.plans, .todos].filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [TaskListEntity] { [.plans, .todos] }
}

@AppEntity(schema: .reminders.section)
struct TaskSectionEntity {
    static let defaultQuery = TaskSectionQuery()
    var id: String
    var name: String
    var list: TaskListEntity
    var displayRepresentation: DisplayRepresentation { "Section" }
}

struct TaskSectionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TaskSectionEntity] { [] }
    func entities(matching string: String) async throws -> [TaskSectionEntity] { [] }
}

@AppEnum(schema: .reminders.listType)
enum ListKind: String {
    case standard
    static let caseDisplayRepresentations: [ListKind: DisplayRepresentation] = [.standard: "List"]
}

@AppEntity(schema: .reminders.locationTrigger)
struct PlaceEntity {
    static let defaultQuery = PlaceQuery()
    var id: String
    var place: PlaceDescriptor
    var event: TriggerEvent
    var displayRepresentation: DisplayRepresentation { "Place" }
}

struct PlaceQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlaceEntity] { [] }
    func entities(matching string: String) async throws -> [PlaceEntity] { [] }
}

@AppEnum(schema: .reminders.locationTriggerEvent)
enum TriggerEvent: String {
    case arrive, depart
    static let caseDisplayRepresentations: [TriggerEvent: DisplayRepresentation] = [.arrive: "Arrive", .depart: "Leave"]
}

// MARK: Building and indexing

@MainActor enum SiriContext {
    struct Item { var title: String; var start: Date?; var score: Int; var done: Bool }

    /// Same numbers as Home and the widgets (see `WidgetSync.write`).
    static func status(_ context: ModelContext, now: Date = .now) -> (HouseStatus, [PlanTask], [TodoItem]) {
        let tasks = ((try? context.fetch(FetchDescriptor<PlanTask>())) ?? []).filter { $0.category != Plan.freeTime }
        let todos = (try? context.fetch(FetchDescriptor<TodoItem>())) ?? []
        let events = CalendarSync.attended(from: now.addingTimeInterval(-14 * 86_400), to: now.addingTimeInterval(2 * 86_400),
                                           excluding: Set(tasks.compactMap(\.eventID)))
        let status = HouseStatus(tasks: tasks, todos: todos, events: events,
                                 ratings: Ratings.load(UserDefaults.standard.data(forKey: "ratings") ?? Data()), now: now)
        return (status, tasks, todos)
    }

    // ponytail: rebuilt from SwiftData on every query; fine for a student's few hundred tasks.
    /// Empty while the phone is locked: task names and stress stay off the Lock Screen.
    static func entities(_ context: ModelContext) -> [TaskEntity] {
        guard UIApplication.shared.isProtectedDataAvailable else { return [] }
        let (status, tasks, todos) = status(context)
        return tasks.map { entity($0, status) } + todos.map { entity($0, status) }
    }

    static func entity(_ t: PlanTask, _ status: HouseStatus) -> TaskEntity {
        make(id: "task-" + t.key, title: t.title, due: t.start, done: t.done, doneAt: t.doneAt, minutes: t.minutes,
             rating: status.rating(t.title, priority: t.priority, category: t.category), list: .plans)
    }

    static func entity(_ t: TodoItem, _ status: HouseStatus) -> TaskEntity {
        make(id: "todo-" + todoID(t), title: t.name, due: t.dueDate, done: t.isDone, doneAt: t.doneAt, minutes: House.todoMinutes,
             rating: status.rating(t.name, priority: t.priority.level), list: .todos)
    }

    /// To-dos have no id of their own: their SwiftData id, as text.
    static func todoID(_ t: TodoItem) -> String {
        (try? JSONEncoder().encode(t.persistentModelID))?.base64EncodedString() ?? ""
    }

    private static func make(id: String, title: String, due: Date?, done: Bool, doneAt: Date?, minutes: Int,
                             rating: Rating, list: TaskListEntity) -> TaskEntity {
        TaskEntity(id: id, title: title, note: stressLine(rating, minutes: minutes), due: due, doneAt: doneAt,
                   done: done, flagged: rating.score >= 7, list: list,
                   tags: ["\(rating.effort)", "stress \(rating.score)"])
    }

    nonisolated static func stressLine(_ r: Rating, minutes: Int) -> String {
        "Stress \(r.score)/10 (\(r.effort)\(r.compulsory ? ", compulsory" : "")), \(minutes) min"
    }

    /// Puts the last week and the next month into the on-device Spotlight index,
    /// replacing what was there. Called when the app goes to the background.
    static func index(_ context: ModelContext, now: Date = .now) async {
        guard UIApplication.shared.isProtectedDataAvailable else { return }   // else it would empty the index
        let window = now.addingTimeInterval(-7 * 86_400)...now.addingTimeInterval(30 * 86_400)
        let all = entities(context).filter { e in
            e.dueDate.flatMap(Calendar.current.date(from:)).map(window.contains) ?? !e.isCompleted
        }
        try? context.save()   // `key` gives new tasks their id
        // Protected: Spotlight and Siri can only read it while the phone is unlocked.
        let index = CSSearchableIndex(name: "tasks", protectionClass: .complete)
        try? await index.deleteAppEntities(ofType: TaskEntity.self)
        try? await CSSearchableIndex.default().deleteAppEntities(ofType: TaskEntity.self)   // ponytail: clears e6ea597's unprotected copy; drop once test phones have run it
        try? await index.indexAppEntities(all)
    }

    /// What Siri says for "How's my house?": the house, today's progress, the
    /// hardest thing left and what's next.
    nonisolated static func summary(state: House.State, streak: Int, items: [Item], now: Date) -> String {
        var parts: [String] = []
        switch state {
        case .calm: parts.append("Your house is calm.")
        case .resting: parts.append("Your house is resting and repairing.")
        default: parts.append("Your house is \(state.rawValue): \(streak) busy day\(streak == 1 ? "" : "s") in a row.")
        }
        guard !items.isEmpty else { return (parts + ["Nothing planned today."]).joined(separator: " ") }
        let left = items.filter { !$0.done }
        parts.append("Today: \(items.count - left.count) of \(items.count) done.")
        let hard = left.filter { $0.score >= 7 }
        if let hardest = hard.max(by: { $0.score < $1.score }) {
            parts.append("\(hard.count) hard one\(hard.count == 1 ? "" : "s") left, the hardest is \(hardest.title).")
        }
        let upcoming = left.compactMap { i in i.start.map { (i, $0) } }.filter { $0.1 > now.addingTimeInterval(-3600) }
        if let (next, start) = upcoming.min(by: { $0.1 < $1.1 }) {
            parts.append("Next: \(next.title) at \(start.formatted(date: .omitted, time: .shortened)).")
        } else if left.isEmpty {
            parts.append("All done. Time to rest.")
        }
        return parts.joined(separator: " ")
    }
}
