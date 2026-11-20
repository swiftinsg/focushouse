import Foundation
import FoundationModels

/// Fallback rest when Screen Time is off: time away from this app. When
/// focushouse goes to the background the time is saved; when it's opened again
/// the gap is added (waking hours only, 30+ min).
extension RestLog {
    mutating func add(from: Date, to: Date, routine: Routine, calendar: Calendar = .current) {
        add(from: from, to: to, wake: routine.wake, bed: routine.bed, calendar: calendar)
    }

    static func appLeft(at date: Date = .now) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: "leftAt")
    }

    static func appOpened(at date: Date = .now) {
        let d = UserDefaults.standard
        guard d.object(forKey: "leftAt") != nil else { return }
        let left = Date(timeIntervalSinceReferenceDate: d.double(forKey: "leftAt"))
        d.removeObject(forKey: "leftAt")
        update { $0.add(from: left, to: date, routine: .current) }
    }
}

/// Effort ratings by title, saved in UserDefaults ("ratings") so each task or
/// event is only rated once. Home reads it through @AppStorage.
enum Ratings {
    static func key(_ title: String) -> String { title.trimmingCharacters(in: .whitespaces).lowercased() }
    /// Emotionally heavy events the small model rates as light (a funeral scored 1–3).
    /// Plain code, so it also holds without Apple Intelligence and for old cached ratings.
    // ponytail: word list; add words as students hit them.
    static func heavy(_ title: String) -> Bool {
        title.lowercased().contains(/\b(funeral|memorial|wake(?!\s+up)|cremation|burial|hospital|surgery|icu|passed\saway)\b/)
    }

    static func load(_ data: Data) -> [String: Rating] { (try? JSONDecoder().decode([String: Rating].self, from: data)) ?? [:] }

    /// Asks the on-device model to rate `titles` and saves the answers.
    // ponytail: ratings are never pruned; drop old titles if the store ever gets big.
    @MainActor static func rate(_ titles: [String]) async {
        guard Planner.isAvailable, !titles.isEmpty else { return }
        let d = UserDefaults.standard
        var saved = load(d.data(forKey: "ratings") ?? Data())
        for chunk in stride(from: 0, to: titles.count, by: 15).map({ Array(titles[$0..<min($0 + 15, titles.count)]) }) {
            let session = LanguageModelSession(instructions: """
                You score how demanding things in a student's day are, from 1 to 10, from their titles. \
                1-3: quick, light or fun (reply to a message, tidy desk, lunch with friends). \
                4-6: ordinary homework, chores, practice, a regular club. \
                7-8: long or difficult work, big assignments, revision, presentations, competitions. \
                9-10: exams, major tests, deadlines due very soon, high-stakes performances. \
                Emotionally heavy things are 8-10 even when short: a funeral, a wake, a hospital \
                visit, a family emergency. \
                compulsory is true for things the student can't skip: exams, tests, school lessons, \
                assignments or deadlines set by a teacher.
                """)
            let prompt = "Rate each of these:\n" + chunk.map { "- \($0)" }.joined(separator: "\n")
            guard let reply = try? await session.respond(to: prompt, generating: DraftRatings.self).content else { continue }
            for r in reply.ratings { saved[key(r.title)] = Rating(score: r.score, compulsory: r.compulsory) }
        }
        d.set((try? JSONEncoder().encode(saved)) ?? Data(), forKey: "ratings")
    }
}

@Generable struct DraftRatings {
    @Guide(description: "One rating per title, in the same order", .count(1...15))
    var ratings: [DraftRating]
}

@Generable struct DraftRating {
    @Guide(description: "The title exactly as given")
    var title: String
    @Guide(description: "How demanding it is for a typical student, 1 (very light) to 10 (exam-level)", .range(1...10))
    var score: Int
    @Guide(description: "true if the student can't skip it: exams, tests, school lessons, teacher-set assignments or deadlines")
    var compulsory: Bool
}

/// A finished plan task, kept when its plan or the task itself is deleted, so its
/// bricks and stress stay counted. Also the shape `HouseStatus` reads live tasks in.
struct KeptTask: Codable, Equatable {
    var title: String
    var category: String
    var priority: Int
    var minutes: Int
    var estimate: Int?
    var start: Date?
    var day: Date?         // the day its bricks count: when it was ticked
    var earns: Bool
    var actual: Int? = nil
    var photo: Bool? = nil   // a check-in photo matched: small brick bonus
}

extension KeptTask {
    @MainActor init(_ t: PlanTask) {
        self.init(title: t.title, category: t.category, priority: t.priority, minutes: t.minutes,
                  estimate: t.estimate, start: t.start, day: t.doneAt ?? t.start ?? t.plan?.start,
                  earns: t.earnsBricks, actual: t.actual, photo: t.uid.map { Proof.matched($0.uuidString) })
    }

    static let key = "keptTasks"
    static func load(_ data: Data) -> [KeptTask] { (try? JSONDecoder().decode([KeptTask].self, from: data)) ?? [] }

    /// Call before deleting tasks: the done ones are saved for good.
    // ponytail: grows by one row per deleted done task; trim to the last few months if it ever matters.
    @MainActor static func keep(_ tasks: [PlanTask]) {
        let done = tasks.filter(\.done).map(KeptTask.init)
        guard !done.isEmpty else { return }
        let d = UserDefaults.standard
        let all = load(d.data(forKey: key) ?? Data()) + done
        d.set((try? JSONEncoder().encode(all)) ?? Data(), forKey: key)
    }
}

/// Home's stress streak and earned bricks from the saved tasks, Tasks-tab items
/// and Calendar events. The widgets get the same numbers through `WidgetSync`.
// ponytail: scans every task each time; fine for a student's few hundred.
@MainActor struct HouseStatus {
    private(set) var streak = 0
    private(set) var earned = 0
    private let ratings: [String: Rating]
    private let pace: [String: Double]

    init(tasks: [PlanTask], todos: [TodoItem], events: [(title: String, start: Date, minutes: Int)],
         ratings: [String: Rating], kept: [KeptTask] = KeptTask.load(UserDefaults.standard.data(forKey: KeptTask.key) ?? Data()),
         quiet: QuietHours = .load(), now: Date = .now) {
        self.ratings = ratings
        pace = Dictionary(Planner.pace().map { ($0.category, $0.ratio) }, uniquingKeysWith: { a, _ in a })
        var load: [(day: Date, minutes: Int)] = []
        var bricks: [(day: Date, bricks: Int)] = []
        // Stress per day from what the student does and attends: plan tasks at their
        // time, Tasks-tab items on their due day, Calendar events.
        for t in tasks.map(KeptTask.init) + kept {
            let r = rating(t.title, priority: t.priority, category: t.category)
            if let start = t.start { load.append((start, House.stress(minutes: t.minutes, r))) }
            if t.earns, let day = t.day {
                let focused = t.start.map { quiet.covers(start: $0, minutes: t.minutes) } ?? false
                let earned = House.bricks(minutes: t.estimate ?? t.minutes, actual: t.actual, r.effort, focused: focused)
                bricks.append((day, t.photo == true ? Proof.bonus(earned) : earned))
            }
        }
        var todosPaid: [Date: Int] = [:]   // per tick day, up to House.todoDailyCount
        for t in todos {
            let r = rating(t.name, priority: t.priority.level)
            load.append((t.dueDate, House.stress(minutes: House.todoMinutes, r)))
            guard t.isDone, r.effort != .easy else { continue }
            let day = Calendar.current.startOfDay(for: t.doneAt ?? t.dueDate)
            todosPaid[day, default: 0] += 1
            if todosPaid[day]! <= House.todoDailyCount { bricks.append((day, House.todoBricks)) }
        }
        load += events.map { ($0.start, House.stress(minutes: $0.minutes, rating($0.title, priority: 1))) }
        streak = House.streak(load, now: now)
        earned = House.total(bricks)
    }

    /// The AI's rating for a title, or one from priority until it's rated;
    /// for plan tasks, scaled by the student's pace in that category.
    func rating(_ title: String, priority: Int, category: String? = nil) -> Rating {
        var r = ratings[Ratings.key(title)] ?? Rating(priority: priority)
        if Ratings.heavy(title) { r.score = max(r.score, 8) }
        guard let category, let p = pace[category] else { return r }
        return r.personal(p)
    }
}

extension Priority {
    /// The plan tasks' scale: 0 high, 1 normal, 2 low.
    var level: Int { self == .high ? 0 : self == .low ? 2 : 1 }
}
