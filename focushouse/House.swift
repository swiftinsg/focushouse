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

    static func saved() -> [String: Rating] { load(UserDefaults.standard.data(forKey: "ratings") ?? Data()) }
    static func save(_ saved: [String: Rating]) {
        UserDefaults.standard.set((try? JSONEncoder().encode(saved)) ?? Data(), forKey: "ratings")
    }

    /// The score that counts for a title (the student's or the AI's, plus the
    /// check-ins' nudge), or nil while it has none.
    static func score(_ title: String, in saved: [String: Rating] = saved()) -> Int? {
        saved[key(title)]?.current
    }

    /// The student's own pre-task score from the stress slider: the new baseline,
    /// so old nudges go. `rate` skips titles already saved, so the AI never
    /// overwrites it.
    static func set(_ titles: [String], score: Int) {
        var saved = saved()
        for t in titles where !t.isEmpty {
            saved[key(t)] = Rating(score: saved[key(t)]?.score ?? score, compulsory: saved[key(t)]?.compulsory ?? false, mine: score)
        }
        save(saved)
    }

    /// The score how it felt suggests (1 drained → 9, 3 OK → 5, 5 energised → 1).
    static func felt(_ feelings: [Int]) -> Int? {
        guard !feelings.isEmpty else { return nil }
        let average = Double(feelings.reduce(0, +)) / Double(feelings.count)
        return min(10, max(1, Int((11 - 2 * average).rounded())))
    }

    /// Without the AI: one step toward how it felt, when that's 2+ away from the base.
    static func plainNudge(base: Int, feeling: Int) -> Int {
        let diff = felt([feeling])! - base
        return abs(diff) < 2 ? 0 : diff > 0 ? 1 : -1
    }

    /// After a check-in. With the AI, once there are a few check-ins to compare,
    /// it judges which tasks hit the student harder or softer than their score
    /// (one step either way, never more). Without it, plain code nudges the task
    /// toward how it felt.
    /// One answered check-in, copied out of SwiftData so the model can run after.
    struct Check {
        var title: String, feeling: Int, actual: Int?, estimate: Int?, note: String, at: Date
        @MainActor init?(_ t: PlanTask) {
            guard let feeling = t.feeling else { return nil }
            self.title = t.title; self.feeling = feeling; actual = t.actual; estimate = t.estimate
            note = t.note; at = t.reflectedAt ?? .distantPast
        }
    }

    @MainActor static func reflect(_ check: Check, history: [Check]) async {
        var saved = saved()
        let k = key(check.title)
        let base = saved[k]?.base ?? felt(history.filter { key($0.title) == k }.map(\.feeling)) ?? 5
        guard Planner.isAvailable else {
            saved[k] = Rating(score: saved[k]?.score ?? base, compulsory: saved[k]?.compulsory ?? false,
                              mine: saved[k]?.mine, nudge: plainNudge(base: base, feeling: check.feeling))
            return save(saved)
        }
        guard history.count >= Reflections.minAnswers else { return }   // watch the first few first
        // The latest check-in per title, newest first, up to 15.
        var seen = Set<String>()
        let recent = history.sorted { $0.at > $1.at }.filter { seen.insert(key($0.title)).inserted }.prefix(15)
        let lines = recent.map { t in
            "- \(t.title): stress \(saved[key(t.title)]?.base ?? base)/10, felt \(t.feeling)/5"
                + (t.actual.map { a in ", took \(a)" + (t.estimate.map { " of \($0)" } ?? "") + " min" } ?? "")
                + (t.note.isEmpty ? "" : ", note: \(t.note)")
        }
        let session = LanguageModelSession(instructions: """
            A student scored how stressful each task would be (1-10) before doing it, then said \
            how it felt after (1 drained, 3 OK, 5 energised), how long it took and maybe a note. \
            For each task, say if their score should change: 1 if it clearly hit them harder \
            than the score says (drained, took much longer, a stressed note), -1 if it was \
            clearly easier (energised, quick), 0 if the score fits or you aren't sure.
            """)
        guard let reply = try? await session.respond(to: "Their check-ins:\n" + lines.joined(separator: "\n"),
                                                     generating: DraftNudges.self).content else { return }
        saved = Ratings.saved()   // the student may have changed something while the model ran
        for n in reply.nudges where seen.contains(key(n.title)) {
            let k = key(n.title), r = saved[k]
            saved[k] = Rating(score: r?.score ?? base, compulsory: r?.compulsory ?? false, mine: r?.mine,
                              nudge: min(1, max(-1, n.change)))
        }
        save(saved)
    }

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
            for r in reply.ratings {
                let old = saved[key(r.title)]
                saved[key(r.title)] = Rating(score: r.score, compulsory: r.compulsory, mine: old?.mine, nudge: old?.nudge)
            }
        }
        d.set((try? JSONEncoder().encode(saved)) ?? Data(), forKey: "ratings")
    }
}

@Generable struct DraftNudges {
    @Guide(description: "One per task, in the same order", .count(1...15))
    var nudges: [DraftNudge]
}

@Generable struct DraftNudge {
    @Guide(description: "The task title exactly as given")
    var title: String
    @Guide(description: "-1 easier than scored, 0 fits, 1 harder than scored", .range(-1...1))
    var change: Int
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
    /// How things felt in check-ins, as a 1–10 score: for titles and kinds of work
    /// with no score yet.
    private let feltTitle: [String: Int]
    private let feltCategory: [String: Int]
    /// Apple Intelligence on: bricks by time × effort; off: by stress score.
    private let ai: Bool

    /// A finished plan task's bricks before the photo bonus.
    func bricks(minutes: Int, actual: Int?, _ r: Rating, focused: Bool) -> Int {
        ai ? House.bricks(minutes: minutes, actual: actual, r.effort, focused: focused)
           : House.bricks(score: r.score, focused: focused)
    }

    init(tasks: [PlanTask], todos: [TodoItem], events: [(title: String, start: Date, minutes: Int)],
         ratings: [String: Rating], kept: [KeptTask] = KeptTask.load(UserDefaults.standard.data(forKey: KeptTask.key) ?? Data()),
         quiet: QuietHours = .load(), now: Date = .now, ai: Bool = Planner.isAvailable) {
        self.ratings = ratings
        self.ai = ai
        let answered = tasks.filter { $0.feeling != nil }
        feltTitle = Dictionary(grouping: answered) { Ratings.key($0.title) }.compactMapValues { Ratings.felt($0.compactMap(\.feeling)) }
        feltCategory = Dictionary(grouping: answered, by: \.category).filter { $0.value.count >= Reflections.minAnswers }
            .compactMapValues { Ratings.felt($0.compactMap(\.feeling)) }
        pace = Dictionary(Planner.pace().map { ($0.category, $0.ratio) }, uniquingKeysWith: { a, _ in a })
        var load: [(day: Date, minutes: Int)] = []
        var bricks: [(day: Date, bricks: Int)] = []
        // Stress per day from what the student does and attends: plan tasks at their
        // time, Tasks-tab items on their due day, Calendar events.
        for t in tasks.map(KeptTask.init) + kept {
            let r = rating(t.title, category: t.category)
            if let start = t.start { load.append((start, House.stress(minutes: t.minutes, r))) }
            if t.earns, let day = t.day {
                let focused = t.start.map { quiet.covers(start: $0, minutes: t.minutes) } ?? false
                let earned = self.bricks(minutes: t.estimate ?? t.minutes, actual: t.actual, r, focused: focused)
                bricks.append((day, t.photo == true ? Proof.bonus(earned) : earned))
            }
        }
        var todosPaid: [Date: Int] = [:]   // per tick day, up to House.todoDailyCount
        for t in todos {
            let r = rating(t.name)
            load.append((t.dueDate, House.stress(minutes: House.todoMinutes, r)))
            guard t.isDone, r.effort != .easy else { continue }
            let day = Calendar.current.startOfDay(for: t.doneAt ?? t.dueDate)
            todosPaid[day, default: 0] += 1
            if todosPaid[day]! <= House.todoDailyCount { bricks.append((day, House.todoBricks)) }
        }
        load += events.map { ($0.start, House.stress(minutes: $0.minutes, rating($0.title))) }
        streak = House.streak(load, now: now)
        earned = House.total(bricks)
    }

    /// The student's pre-task score, else the AI's, moved by the check-ins' nudge.
    /// With neither yet, how this title or kind of work felt in check-ins (5 when
    /// nothing's known). The AI's score is scaled by the student's pace in that
    /// category; their own score isn't, it's already theirs.
    func rating(_ title: String, category: String? = nil) -> Rating {
        let saved = ratings[Ratings.key(title)]
        let fallback = feltTitle[Ratings.key(title)] ?? category.flatMap { feltCategory[$0] } ?? 5
        var r = Rating(score: saved?.current ?? fallback, compulsory: saved?.compulsory ?? false)
        if Ratings.heavy(title) { r.score = max(r.score, 8) }
        guard saved?.mine == nil, let category, let p = pace[category] else { return r }
        return r.personal(p)
    }
}

