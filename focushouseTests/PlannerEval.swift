import Foundation
import Testing
@testable import focushouse

/// AI accuracy eval: runs the on-device model on realistic student inputs and scores
/// every plan it makes. It is slow (about 20 s a plan) and needs Apple Intelligence, so
/// it only runs when AI_EVAL=1 is set for the test runner:
///
///     TEST_RUNNER_AI_EVAL=1 TEST_RUNNER_AI_EVAL_RUNS=3 xcodebuild test -scheme focushouse \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
///       -only-testing:focushouseTests/PlannerEval
///
/// (In Xcode: Edit Scheme → Test → Arguments → Environment Variables → AI_EVAL = 1.)
/// AI_EVAL_RUNS repeats each case (default 3) because the model doesn't answer the same
/// way every time. The report goes to reports/ai-eval-latest.md and the test log.
enum AIEval {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AI_EVAL"] == "1" && Planner.isAvailable
    }
}

@Suite(.serialized, .enabled(if: AIEval.enabled))
@MainActor struct PlannerEval {

    static var runs: Int {
        max(1, Int(ProcessInfo.processInfo.environment["AI_EVAL_RUNS"] ?? "") ?? 3)
    }

    /// Share of all checks that must pass. Raise it as the planner improves.
    static let target = 0.8

    // MARK: Cases

    struct Case {
        var name: String
        var mode: PlanMode
        var input: String
        var materials = ""
        var days = 1
        var free: (from: Int, until: Int)?   // minutes since midnight; nil = default routine
        var checks: [Check]
    }

    /// Keywords are word stems: "electrochem" matches "Electrochemistry" and
    /// "electrochemical". "a|b" means either alternative; all words of one must appear.
    enum Check {
        case covers(String)                    // some item or step mentions it
        case avoids(String)                    // no item or step mentions it
        case noPlaceholders                    // Today: no line left as a 30-min placeholder
        case items(ClosedRange<Int>)           // number of items
        case minutes(String, ClosedRange<Int>) // the matching item's total minutes
        case total(ClosedRange<Int>)           // whole plan's minutes
        case priority(String, String)          // the matching item's priority
        case allPriority(String)
        case subtasks(String, ClosedRange<Int>)
        case spread(Double)                    // share of plan days that have work, at least
        case restDay                           // at least one day with no work
        case maxStep(Int)                      // no single task longer than this
        case order([String])                   // these come in this order
        case category(String)                  // every item has it
        case fitsFreeTime                      // no day holds more than its free time
        case finishesInTime                    // scheduled work ends by the last day
    }

    static let cases: [Case] = [
        // Today mode
        Case(name: "Today: quick jobs", mode: .today,
             input: "pay mum back\ntidy room\nreply to jia hui\nfeed the cat",
             checks: [.noPlaceholders, .items(4...4), .covers("pay|mum"), .covers("tidy|room"), .covers("reply|jia"), .covers("feed|cat"),
                      .minutes("mum", 5...25), .minutes("room", 5...45), .minutes("jia", 5...20), .minutes("cat", 5...20),
                      .subtasks("room", 0...0), .subtasks("mum", 0...0)]),
        Case(name: "Today: priorities", mode: .today,
             input: "chem tutorial due tmr!!\nread ch 4 history\ngym maybe\nwash uniform",
             checks: [.noPlaceholders, .priority("chem", "high"), .priority("gym", "low"), .priority("histor", "normal"),
                      .minutes("chem", 45...150), .minutes("histor", 20...90), .order(["chem", "gym"])]),
        Case(name: "Today: long comma list", mode: .today,
             input: "math hw, physics practical writeup, GP essay outline, return library book, buy stationery, call grandma, econs case study, pack bag",
             checks: [.noPlaceholders, .items(8...9), .covers("math"), .covers("physics"), .covers("essay"), .covers("library"),
                      .covers("stationery"), .covers("grandma"), .covers("econ|case"), .covers("bag"),
                      .minutes("library", 5...30), .minutes("bag", 5...20)]),
        Case(name: "Today: big work plus a chore", mode: .today,
             input: "GP essay draft due friday urgent\nlaundry",
             checks: [.noPlaceholders, .priority("essay", "high"), .subtasks("essay", 2...5), .minutes("essay", 60...240),
                      .subtasks("laundry", 0...0), .minutes("laundry", 5...60)]),
        Case(name: "Today: exact duplicates", mode: .today,
             input: "math hw\nmath hw\ntidy desk",
             checks: [.items(2...2), .covers("math"), .covers("desk")]),
        Case(name: "Today: urgent and can wait", mode: .today,
             input: "econs essay can wait\nrevise organic chem urgent\ncall grandma\nstuff for cca",
             checks: [.noPlaceholders, .priority("organic", "high"), .priority("econ", "low"), .priority("grandma", "normal"),
                      .minutes("organic", 60...240), .minutes("grandma", 5...45), .order(["organic", "econ"])]),
        Case(name: "Today: too much for 2 hours", mode: .today,
             input: "revise 3 chapters of chem\nh2 math tutorial\nphysics lab report\nGP essay\necons essay",
             free: (20 * 60, 22 * 60),
             checks: [.noPlaceholders, .items(5...5), .covers("chem"), .covers("math"), .covers("physics"), .covers("gp|essay"), .covers("econ")]),
        Case(name: "Today: student gives the time", mode: .today,
             input: "practise piano 30 min\nfinish art project\nclean shoes",
             checks: [.noPlaceholders, .minutes("piano", 25...35), .minutes("shoes", 5...30), .minutes("art", 30...180)]),
        Case(name: "Today: counted work", mode: .today,
             input: "read 20 pages of my novel, do 2 math worksheets, email teacher about absence",
             checks: [.noPlaceholders, .items(3...3), .minutes("email", 5...20), .minutes("novel", 15...60), .minutes("worksheet", 30...120)]),
        Case(name: "Today: Singapore slang", mode: .today,
             input: "do tys qns for math\nmug for chem test\nsubmit pw reflection",
             checks: [.noPlaceholders, .covers("math"), .covers("chem"), .covers("reflection"), .minutes("chem", 45...180), .minutes("reflection", 10...90)]),

        // Goal mode
        Case(name: "Goal: chem exam with 3 topics", mode: .goal,
             input: "Revise for my H2 Chemistry exam on Wednesday: organic chemistry, chemical equilibrium and electrochemistry",
             days: 6,
             checks: [.covers("organic"), .covers("equilib"), .covers("electrochem"), .spread(0.5), .total(300...1800),
                      .allPriority("normal"), .fitsFreeTime, .finishesInTime]),
        Case(name: "Goal: history essay", mode: .goal,
             input: "Write my 2000-word history essay on the causes of the Cold War", days: 5,
             checks: [.covers("research|read|source"), .covers("outline|plan"), .covers("draft|write"), .covers("edit|proofread|review|revise"),
                      .order(["outline|plan", "edit|proofread|review"]), .spread(0.6), .total(300...1200), .allPriority("normal"), .finishesInTime]),
        Case(name: "Goal: run 5 km", mode: .goal,
             input: "Be able to run 5km without stopping", days: 7,
             checks: [.category("exercise"), .restDay, .maxStep(60), .spread(0.4), .allPriority("normal")]),
        Case(name: "Goal: one-day room clean", mode: .goal,
             input: "Clean and organise my bedroom", days: 1,
             checks: [.total(30...240), .category("chores"), .finishesInTime, .allPriority("normal")]),
        Case(name: "Goal: PW written report", mode: .goal,
             input: "Finish my Project Work written report", days: 4,
             checks: [.covers("draft|write"), .covers("edit|proofread|review|check"), .spread(0.5), .total(180...900), .finishesInTime]),
        Case(name: "Goal: two subjects", mode: .goal,
             input: "Revise maths and physics for promos", days: 4,
             checks: [.covers("math|algebra|equation|calcul|function"), .covers("physics|mechanic|force|newton"), .spread(0.5), .total(240...1200), .allPriority("normal"), .fitsFreeTime]),
        Case(name: "Goal: tight deadline", mode: .goal,
             input: "Revise all of H2 Math for prelims", days: 2,
             checks: [.spread(1.0), .total(180...900), .fitsFreeTime, .finishesInTime]),
        Case(name: "Goal: learn guitar chords", mode: .goal,
             input: "Learn to play G, C, D and Em chords on guitar", days: 7,
             checks: [.maxStep(60), .spread(0.5), .total(90...600), .allPriority("normal")]),
        Case(name: "Goal: application essay", mode: .goal,
             input: "Write my university application personal statement", days: 10,
             checks: [.covers("draft|write"), .covers("edit|proofread|review|revise"), .order(["draft|write", "edit|proofread|review"]),
                      .spread(0.4), .total(240...1200), .finishesInTime]),
        Case(name: "Goal: student-marked priorities", mode: .goal,
             input: "Prepare for exams: chemistry is urgent, history can wait, physics", days: 5,
             checks: [.covers("chem"), .covers("histor"), .covers("physics"), .priority("chem", "high"),
                      .priority("histor", "low"), .priority("physics", "normal"), .spread(0.6)]),
        Case(name: "Goal: holiday homework", mode: .goal,
             input: "Finish holiday homework: math worksheet pack, 2 GP essays, chem tutorials 1-5, read one novel", days: 10,
             checks: [.covers("math"), .covers("essay"), .covers("chem|tutorial"), .covers("novel|read"), .spread(0.5),
                      .total(480...2400), .allPriority("normal"), .finishesInTime]),
        Case(name: "Goal: Chinese vocab", mode: .goal,
             input: "Learn 50 new Chinese vocabulary words for my spelling test", days: 5,
             checks: [.spread(0.6), .maxStep(60), .total(60...400), .allPriority("normal")]),
        Case(name: "Goal: science fair project", mode: .goal,
             input: "Complete my science fair project on plant growth and light", days: 14,
             checks: [.covers("experiment|measure|observ|record"), .covers("present|poster|report|board"), .spread(0.3), .total(300...1800), .finishesInTime]),

        // Study material
        Case(name: "Material: 3 organic sections", mode: .goal,
             input: "Revise organic chemistry for my class test",
             materials: "Section 1: Arenes - electrophilic substitution, nitration and halogenation of benzene\nSection 2: Phenols - acidity, reaction with bromine water and NaOH\nSection 3: Carbonyls - nucleophilic addition of HCN, 2,4-DNPH and Tollens' tests",
             days: 4,
             checks: [.covers("arene|benzene"), .covers("phenol"), .covers("carbonyl|hcn|tollens|dnph"), .order(["arene|benzene", "phenol", "carbonyl|hcn|tollens|dnph"]),
                      .items(3...5), .spread(0.5), .allPriority("normal"), .finishesInTime]),
        Case(name: "Material: 5 biology topics", mode: .goal,
             input: "Revise biology for my end-of-year exam",
             materials: "Topic 1: Cell structure\nTopic 2: Enzymes\nTopic 3: Photosynthesis\nTopic 4: Respiration\nTopic 5: Genetics",
             days: 5,
             checks: [.covers("cell"), .covers("enzyme"), .covers("photosynth"), .covers("respirat"), .covers("genetic"),
                      .order(["cell", "enzyme", "photosynth", "respirat", "genetic"]), .spread(0.6), .finishesInTime]),

        // Nonsense: impossible or silly goals still get a sane, doable plan
        Case(name: "Nonsense: go to the moon today", mode: .today,
             input: "go to the moon",
             checks: [.noPlaceholders, .items(1...3), .total(10...240), .maxStep(120), .covers("look moon|read moon|learn moon|research moon|watch moon"), .avoids("book|launch|arrange travel|spaceship|transform")]),
        Case(name: "Nonsense: explore outer space", mode: .goal,
             input: "Explore outer space", days: 5,
             checks: [.covers("space|planet|star|astronom|rocket|universe|solar|galax|nasa"), .spread(0.4), .total(60...900),
                      .maxStep(120), .fitsFreeTime, .finishesInTime, .avoids("book|launch|arrange travel|spaceship|transform")]),
        Case(name: "Nonsense: mixed with real work", mode: .today,
             input: "math hw\nbecome a dragon\nfly to mars\nwash uniform",
             checks: [.noPlaceholders, .covers("math"), .covers("uniform"), .minutes("math", 20...120), .total(30...360), .maxStep(120),
                      .covers("look dragon|read dragon|learn dragon|draw dragon"), .covers("look mars|read mars|learn mars|research mars|watch mars"), .avoids("book|launch|arrange travel|spaceship|transform")]),
        Case(name: "Nonsense: keyboard mash", mode: .today,
             input: "asdfgh qwerty zxcv\npack bag",
             checks: [.items(1...1), .covers("bag"), .avoids("asdfgh|qwerty")]),
        Case(name: "Nonsense: become president by friday", mode: .goal,
             input: "Become president of the world by Friday", days: 3,
             checks: [.total(30...600), .maxStep(120), .fitsFreeTime, .finishesInTime,
                      .avoids("arrange travel|attend event|past paper|past year"), .avoids("book|launch|arrange travel|spaceship|transform")]),
    ]

    // MARK: Tests

    @Test(.timeLimit(.minutes(120)))
    func accuracy() async throws {
        let stash = Self.stashAdaptiveData()
        defer { Self.restore(stash) }
        // AI_EVAL_ONLY=Nonsense runs just the cases whose name starts with it.
        let cases = Self.cases.filter { $0.name.hasPrefix(ProcessInfo.processInfo.environment["AI_EVAL_ONLY"] ?? "") }
        var lines = ["# bricked up AI eval", "",
                     "\(Date.now.formatted()) · \(cases.count) cases × \(Self.runs) runs", ""]
        var passed = 0, total = 0
        var byKind: [String: (pass: Int, all: Int)] = [:]

        for c in cases {
            for run in 1...Self.runs {
                let plan = Self.makePlan(c)
                var results: [(String, Bool, String)] = []
                do {
                    let draft = try await Planner.draft(for: plan)
                    var checks = c.checks
                    if c.mode == .goal { checks.append(.finishesInTime) }   // also catches day > plan length
                    for check in checks {
                        let (ok, detail) = Self.score(check, draft: draft, plan: plan, c: c)
                        results.append((Self.label(check), ok, detail))
                    }
                    lines.append("## \(c.name) (run \(run))")
                    lines.append("Plan: **\(draft.title)**, \(Self.totalMinutes(draft)) min")
                    lines.append(contentsOf: Self.describe(draft))
                } catch {
                    results.append(("model answered", false, "\(error)"))
                    lines.append("## \(c.name) (run \(run))")
                }
                for (name, ok, detail) in results {
                    total += 1
                    if ok { passed += 1 }
                    let kind = String(name.prefix { $0 != " " })
                    byKind[kind, default: (0, 0)].all += 1
                    if ok { byKind[kind, default: (0, 0)].pass += 1 }
                    lines.append("- \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                }
                lines.append("")
            }
        }

        let rate = total == 0 ? 0 : Double(passed) / Double(total)
        var summary = ["## Summary", "",
                       "**\(passed)/\(total) checks passed (\(Int((rate * 100).rounded()))%)**, target \(Int(Self.target * 100))%", "",
                       "| Check | Passed |", "|---|---|"]
        for (kind, n) in byKind.sorted(by: { $0.key < $1.key }) {
            summary.append("| \(kind) | \(n.pass)/\(n.all) |")
        }
        lines.insert(contentsOf: summary + [""], at: 4)
        Self.save(lines.joined(separator: "\n"))
        #expect(rate >= Self.target, "AI eval: \(passed)/\(total) checks passed")
    }

    /// "Try again" must give a genuinely different plan, not the same one renamed.
    @Test(.timeLimit(.minutes(20)))
    func tryAgainIsDifferent() async throws {
        let stash = Self.stashAdaptiveData()
        defer { Self.restore(stash) }
        let c = Self.cases.first { $0.name == "Goal: history essay" }!
        let plan = Self.makePlan(c)
        let first = try await Planner.draft(for: plan)
        let old = Self.tasks(from: first)
        let second = try await Planner.draft(for: plan, previous: old)
        let a = Set(Self.steps(first).flatMap { Planner.words($0.title) })
        let b = Set(Self.steps(second).flatMap { Planner.words($0.title) })
        let overlap = Double(a.intersection(b).count) / Double(max(a.union(b).count, 1))
        let sameTimes = Self.steps(first).map(\.minutes) == Self.steps(second).map(\.minutes)
        #expect(overlap < 0.6, "Try again reused \(Int(overlap * 100))% of the words")
        #expect(!sameTimes, "Try again kept exactly the same durations")
    }

    // MARK: Scoring

    static func score(_ check: Check, draft: DraftPlan, plan: Plan, c: Case) -> (Bool, String) {
        switch check {
        case .covers(let key):
            return (items(matching: key, in: draft).isEmpty == false, "")
        case .avoids(let key):
            let hit = items(matching: key, in: draft)
            return (hit.isEmpty, hit.map(\.title).joined(separator: ", "))
        case .noPlaceholders:
            let lines = Planner.items(c.input)
            let dropped = draft.items.filter { item in
                item.category == "other" && item.minutes == 30 && item.subtasks.isEmpty
                    && lines.contains { $0.prefix(1).uppercased() + $0.dropFirst() == item.title }
            }
            return (dropped.isEmpty, dropped.isEmpty ? "" : "restored by reconcile: " + dropped.map(\.title).joined(separator: ", "))
        case .items(let range):
            return (range.contains(draft.items.count), "\(draft.items.count) items")
        case .minutes(let key, let range):
            guard let item = items(matching: key, in: draft).first else { return (false, "no item for \(key)") }
            let m = minutes(item)
            return (range.contains(m), "\(item.title): \(m) min")
        case .total(let range):
            let m = totalMinutes(draft)
            return (range.contains(m), "\(m) min")
        case .priority(let key, let want):
            guard let item = items(matching: key, in: draft).first else { return (false, "no item for \(key)") }
            return (item.priority == want, "\(item.title): \(item.priority)")
        case .allPriority(let want):
            let off = draft.items.filter { $0.priority != want }
            return (off.isEmpty, off.isEmpty ? "" : "\(off.count) not \(want): " + off.map { "\($0.title) (\($0.priority))" }.joined(separator: ", "))
        case .subtasks(let key, let range):
            guard let item = items(matching: key, in: draft).first else { return (false, "no item for \(key)") }
            return (range.contains(item.subtasks.count), "\(item.title): \(item.subtasks.count) steps")
        case .spread(let share):
            let used = Set(draft.items.map(\.day)).count
            return (Double(used) / Double(max(c.days, 1)) >= share - 0.0001, "work on \(used) of \(c.days) days")
        case .restDay:
            let used = Set(draft.items.map(\.day)).count
            return (used < c.days, "work on \(used) of \(c.days) days")
        case .maxStep(let limit):
            let long = steps(draft).filter { $0.minutes > limit }
            return (long.isEmpty, long.map { "\($0.title) \($0.minutes) min" }.joined(separator: ", "))
        case .order(let keys):
            let flat = steps(draft)
            let positions = keys.map { key in flat.firstIndex { matches(key, $0.title + " " + $0.parent) } }
            guard positions.allSatisfy({ $0 != nil }) else { return (false, "missing one of \(keys.joined(separator: ", "))") }
            let p = positions.compactMap { $0 }
            return (p == p.sorted(), "positions \(p)")
        case .category(let want):
            let off = draft.items.filter { $0.category != want }
            return (off.isEmpty, off.map { "\($0.title) (\($0.category))" }.joined(separator: ", "))
        case .fitsFreeTime:
            var over: [String] = []
            for day in 1...max(c.days, 1) {
                let work = draft.items.filter { $0.day == day }.map(minutes).reduce(0, +)
                let free = freeMinutes(plan, day: day)
                if work > free + 15 { over.append("day \(day): \(work) of \(free) min") }
            }
            return (over.isEmpty, over.joined(separator: ", "))
        case .finishesInTime:
            let flat = steps(draft)
            if let late = draft.items.first(where: { $0.day > max(c.days, 1) }) {
                return (false, "\(late.title) on day \(late.day) of \(c.days)")
            }
            let starts = Scheduler.schedule(flat.map { ($0.minutes, $0.day) }, from: plan.start, routine: plan.routine)
            guard let lastStart = starts.last, let last = flat.last else { return (true, "") }
            let end = lastStart.addingTimeInterval(TimeInterval(last.minutes * 60))
            let deadline = Calendar.current.date(byAdding: .day, value: max(c.days, 1), to: Calendar.current.startOfDay(for: plan.start))!
            return (end <= deadline, "ends \(end.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    static func label(_ check: Check) -> String {
        switch check {
        case .covers(let k): "covers \(k)"
        case .noPlaceholders: "noPlaceholders"
        case .avoids(let k): "avoids \(k)"
        case .items(let r): "items \(r)"
        case .minutes(let k, let r): "minutes \(k) in \(r)"
        case .total(let r): "total in \(r)"
        case .priority(let k, let p): "priority \(k) = \(p)"
        case .allPriority(let p): "allPriority \(p)"
        case .subtasks(let k, let r): "subtasks \(k) in \(r)"
        case .spread(let s): "spread ≥ \(Int(s * 100))% of days"
        case .restDay: "restDay"
        case .maxStep(let m): "maxStep \(m) min"
        case .order(let k): "order \(k.joined(separator: " → "))"
        case .category(let c): "category \(c)"
        case .fitsFreeTime: "fitsFreeTime"
        case .finishesInTime: "finishesInTime"
        }
    }

    // MARK: Helpers

    struct Step { var title: String; var parent: String; var minutes: Int; var day: Int }

    /// Tasks as the app schedules them: an item's subtasks, or the item itself.
    static func steps(_ draft: DraftPlan) -> [Step] {
        draft.items.flatMap { item in
            item.subtasks.isEmpty
                ? [Step(title: item.title, parent: "", minutes: item.minutes, day: item.day)]
                : item.subtasks.map { Step(title: $0.title, parent: item.title, minutes: $0.minutes, day: item.day) }
        }
    }

    static func minutes(_ item: DraftItem) -> Int {
        item.subtasks.isEmpty ? item.minutes : item.subtasks.map(\.minutes).reduce(0, +)
    }

    static func totalMinutes(_ draft: DraftPlan) -> Int { draft.items.map(minutes).reduce(0, +) }

    static func items(matching key: String, in draft: DraftPlan) -> [DraftItem] {
        draft.items.filter { item in
            matches(key, ([item.title] + item.subtasks.map(\.title)).joined(separator: " "))
        }
    }

    /// Every word of one "|" alternative starts some word of `text`.
    static func matches(_ key: String, _ text: String) -> Bool {
        let have = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return key.lowercased().split(separator: "|").contains { alt in
            alt.split(separator: " ").allSatisfy { stem in have.contains { $0.hasPrefix(stem) } }
        }
    }

    static func freeMinutes(_ plan: Plan, day: Int) -> Int {
        let cal = Calendar.current
        guard let date = cal.date(byAdding: .day, value: day - 1, to: cal.startOfDay(for: plan.start)) else { return 0 }
        return plan.routine.windows(on: date, calendar: cal).reduce(0) { sum, w in
            let s = max(w.lowerBound, plan.start)
            return sum + (s < w.upperBound ? Int(w.upperBound.timeIntervalSince(s) / 60) : 0)
        }
    }

    /// Every case starts next Monday at 4 PM, so free time is the same on every run.
    static func makePlan(_ c: Case) -> Plan {
        let cal = Calendar.current
        let monday = cal.nextDate(after: .now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        let start = cal.date(bySettingHour: 16, minute: 0, second: 0, of: monday)!
        let plan = Plan(title: "", mode: c.mode, input: c.input, days: c.mode == .today ? 1 : c.days, start: start)
        plan.materials = c.materials
        if let free = c.free {
            plan.freeFrom = free.from
            plan.freeUntil = free.until
            plan.start = cal.date(byAdding: .minute, value: free.from, to: cal.startOfDay(for: start))!
        }
        return plan
    }

    static func tasks(from draft: DraftPlan) -> [PlanTask] {
        steps(draft).enumerated().map { i, s in
            let task = PlanTask(title: s.title, category: "other", minutes: s.minutes, day: s.day, order: i)
            task.parent = s.parent
            return task
        }
    }

    static func describe(_ draft: DraftPlan) -> [String] {
        draft.items.flatMap { item in
            ["  - Day \(item.day) · \(item.title) · \(item.category) · \(minutes(item)) min · \(item.priority)"]
                + item.subtasks.map { "    - \($0.title) · \($0.minutes) min" }
        }
    }

    /// Saved breakdowns and pace ratios change the prompt, so the eval runs without them.
    static let adaptiveKeys = ["subtaskExamples", "paceRatios"]

    static func stashAdaptiveData() -> [String: Any] {
        var saved: [String: Any] = [:]
        for key in adaptiveKeys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        return saved
    }

    static func restore(_ saved: [String: Any]) {
        for key in adaptiveKeys { UserDefaults.standard.set(saved[key], forKey: key) }
    }

    static func save(_ report: String, as name: String = "ai-eval-latest.md") {
        print(report)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("reports/\(name)")
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            print("AI eval report: \(url.path)")
        } catch {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? report.write(to: tmp, atomically: true, encoding: .utf8)
            print("AI eval report: \(tmp.path) (couldn't write to the project: \(error.localizedDescription))")
        }
    }
}

/// Weekly summary eval: made-up weeks with known facts; the AI's summary must name
/// what weighed most, copy numbers exactly (no invented ones), match the week's mood
/// and stay kind. Report: reports/summary-eval-latest.md.
@Suite(.serialized, .enabled(if: AIEval.enabled))
@MainActor struct SummaryEval {
    struct Case {
        var name: String
        var items: [WeekStats.Item]
        var restHours: [Double]            // 7 days, oldest first
        var mentions: [String]             // stems; "a|b" either
        var never: [String] = []           // words that would be wrong for this week
    }

    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 21))!
    static func day(_ ago: Int, _ h: Int = 16) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: h, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -ago, to: now)!)!
    }
    static func task(_ title: String, _ ago: Int, _ minutes: Int, _ score: Int, done: Bool = true, felt: Int? = nil,
                     actual: Int? = nil, event: Bool = false, compulsory: Bool = false) -> WeekStats.Item {
        WeekStats.Item(title: title, day: day(ago), minutes: minutes,
                       stress: House.stress(minutes: minutes, Rating(score: score, compulsory: compulsory)), isEvent: event,
                       done: done, feeling: felt, estimate: actual == nil ? nil : minutes, actual: actual)
    }

    static let shaming = ["lazy", "should have", "failed", "disappoint", "not enough effort", "try harder", "no excuse"]

    static let cases: [Case] = [
        Case(name: "Exam week, little rest",
             items: (0..<6).flatMap { ago in [task("Chem exam revision", ago, 150, 9, felt: 2, actual: 170),
                                              task("Maths tutorial", ago, 60, 6, done: ago != 2, felt: 3)] },
             restHours: [1, 0.5, 0, 1, 0, 2, 0.5],
             mentions: ["chem"], never: ["calm week", "relaxed week", "easy week"]),
        Case(name: "Calm, rested week",
             items: [task("Read ch 3", 5, 30, 4, felt: 4), task("Tidy room", 3, 20, 2, felt: 4),
                     task("Piano practice", 1, 30, 5, felt: 5), task("Maths worksheet", 0, 45, 5, felt: 4)],
             restHours: [4, 5, 3.5, 4, 6, 3, 4],
             mentions: ["rest|balance|calm|relax"], never: ["stressful week", "overwhelm", "tough week", "drain"]),
        Case(name: "Busy but energised",
             items: (0..<5).flatMap { ago in [task("Robotics project", ago, 180, 7, felt: 5),
                                              task("Gym", ago, 45, 5, felt: 4)] },
             restHours: [3, 2, 3, 1, 3, 4, 2],
             mentions: ["robotic"], never: ["drained", "exhaust"]),
        Case(name: "Grandma's funeral",
             items: [task("Grandma's funeral", 3, 240, 9, event: true), task("Grandma's wake", 4, 180, 8, event: true),
                     task("Geography essay", 1, 90, 6, felt: 2), task("Maths homework", 0, 45, 5, done: false)],
             restHours: [2, 1, 1, 0, 2, 3, 2],
             mentions: ["grandma|funeral|wake|hard personal"], never: ["great week", "awesome", "fun week"]),
    ]

    @Test(.timeLimit(.minutes(30)))
    func accuracy() async throws {
        var lines = ["# bricked up weekly summary eval", "", "\(Date.now.formatted()) · \(Self.cases.count) cases × \(PlannerEval.runs) runs", ""]
        var passed = 0, total = 0
        for c in Self.cases {
            let stats = WeekStats(items: c.items, rest: { date in
                let ago = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                          to: Calendar.current.startOfDay(for: Self.now)).day ?? 0
                return (0...6).contains(ago) ? c.restHours[6 - ago] * 3600 : 0
            }, now: Self.now)
            lines += ["## \(c.name)", "Facts:"] + stats.facts + [""]
            for run in 1...PlannerEval.runs {
                guard let s = await Reflections.summary(stats) else {
                    total += 1
                    lines += ["### Run \(run)", "- ❌ model answered", ""]
                    continue
                }
                let text = s.summary + " " + s.encouragement
                let results = Self.score(text, stats: stats, c: c)
                lines += ["### Run \(run)", "> \(s.summary)", ">", "> \(s.encouragement)", ""]
                for (name, ok, detail) in results {
                    total += 1
                    if ok { passed += 1 }
                    lines.append("- \(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                }
                lines.append("")
            }
        }
        let rate = total == 0 ? 0 : Double(passed) / Double(total)
        lines.insert(contentsOf: ["**\(passed)/\(total) checks passed (\(Int((rate * 100).rounded()))%)**, target \(Int(PlannerEval.target * 100))%", ""], at: 4)
        PlannerEval.save(lines.joined(separator: "\n"), as: "summary-eval-latest.md")
        #expect(rate >= PlannerEval.target, "Summary eval: \(passed)/\(total) checks passed")
    }

    static func score(_ text: String, stats: WeekStats, c: Case) -> [(String, Bool, String)] {
        let lower = text.lowercased()
        var out: [(String, Bool, String)] = []
        for m in c.mentions {
            out.append(("mentions \(m)", PlannerEval.matches(m, text), ""))
        }
        // Every number the AI wrote must be one of the facts' numbers.
        let numbers = { (s: String) in Set(s.matches(of: /\d+(\.\d+)?/).map { String($0.output.0) }) }
        let allowed = numbers(stats.facts.joined(separator: " ")).union(["7"])
        let invented = numbers(text).subtracting(allowed)
        out.append(("noInventedNumbers", invented.isEmpty, invented.sorted().joined(separator: ", ")))
        // "6 of 7", "5 out of 7", "on 4 days": counts must be the real ones.
        let factText = stats.facts.joined(separator: " ")
        var badCounts = text.matches(of: /(\d+)\s+(?:out\s+)?of\s+(\d+)/)
            .map { "\($0.output.1) of \($0.output.2)" }.filter { !factText.contains($0) }
        let counts: Set<Int> = [stats.stressfulDays, stats.restedDays, 7 - stats.stressfulDays, 7 - stats.restedDays, 7]
        badCounts += text.matches(of: /(?i)(\d+)\s+(?:\w+\s+){0,2}days\b/)
            .filter { !counts.contains(Int($0.output.1)!) }.map { String($0.output.0) }
        out.append(("countsMatch", badCounts.isEmpty, badCounts.joined(separator: "; ")))
        let rule = text.matches(of: /(?i)(\d+)\s*(?:h|hours?)\+?\s+or\s+more/).filter { Int($0.output.1)! != Int(House.restGoal / 3600) }
        out.append(("restRule", rule.isEmpty, rule.map { String($0.output.0) }.joined(separator: "; ")))
        let voice = text.matches(of: /(?i)\b(them|they|their)\b/).map { String($0.output.0) }
        out.append(("saysYou", voice.isEmpty, voice.joined(separator: ", ")))
        out.append(("noLabels", !lower.contains("encouragement:") && !lower.contains("summary:"), ""))
        let wrong = c.never.filter(lower.contains)
        out.append(("moodMatches", wrong.isEmpty, wrong.joined(separator: ", ")))
        let shame = shaming.filter(lower.contains)
        out.append(("kind", shame.isEmpty, shame.joined(separator: ", ")))
        let words = text.split(whereSeparator: \.isWhitespace).count
        out.append(("short", (12...110).contains(words), "\(words) words"))
        return out
    }
}
