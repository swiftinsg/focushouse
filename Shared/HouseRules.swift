import Foundation

/// How demanding something is, from its 1–10 score.
enum Effort: Int, Codable, CaseIterable { case easy, normal, hard, intense }

/// How stressful something is, 1–10, saved by title. The student's own pre-task
/// score (`mine`) is the baseline; otherwise the AI's score from the title. After
/// check-ins, `nudge` moves it one step either way from how it really felt.
/// Ranges decide the effort: 1–3 easy, 4–6 normal, 7–8 hard, 9–10 intense.
/// Priority is a different thing and never feeds stress.
struct Rating: Codable, Equatable {
    var score: Int
    /// Can't be skipped (exams, lessons, set deadlines): counts half toward stress.
    var compulsory = false
    /// The student's own score from the stress slider, set before the task.
    var mine: Int?
    /// −1, 0 or +1 from check-ins (the AI's judgement, or plain code without it).
    var nudge: Int?

    init(score: Int, compulsory: Bool = false, mine: Int? = nil, nudge: Int? = nil) {
        self.score = min(10, max(1, score))
        self.compulsory = compulsory
        self.mine = mine
        self.nudge = nudge
    }

    /// The score before reflections: the student's, else the AI's.
    var base: Int { mine ?? score }
    /// What counts: the base moved by the check-ins' nudge.
    var current: Int { min(10, max(1, base + (nudge ?? 0))) }

    var effort: Effort { score <= 3 ? .easy : score <= 6 ? .normal : score <= 8 ? .hard : .intense }

    /// Scaled by how long this kind of work really takes the student
    /// (actual ÷ estimate, from the adaptive estimates): slower = harder for them.
    func personal(_ pace: Double) -> Rating {
        Rating(score: Int((Double(score) * pace).rounded()), compulsory: compulsory)
    }
}

/// The house on Home. Several stressful days in a row knock it down a step at a
/// time (calm → stressed → overloaded → crumbling); real rest, time away from the
/// phone, repairs one step per rested day. Bricks (points) come from finished
/// tasks: earned all-time they fix the run-down house up (`level`), and they buy
/// furniture; they never heal stress damage.
/// Stress and bricks are plain deterministic code; only the effort rating uses AI.
enum House {
    enum State: String, CaseIterable {
        case calm, stressed, overloaded, crumbling, resting
    }

    // ponytail: tuning knobs, first guesses until students try it.
    /// Weighted minutes in one day that make it a stressful day.
    static let stressfulMinutes = 120
    /// How much one minute of each effort adds to stress (easy adds nothing).
    static let weight: [Effort: Double] = [.easy: 0, .normal: 0.5, .hard: 1, .intense: 1.5]
    /// An item from the Tasks tab counts as this much time on its due day.
    static let todoMinutes = 30
    /// Rest in one day (waking hours) that repairs one step.
    static let restGoal: TimeInterval = 3 * 3600
    static let todoBricks = 3
    /// To-dos that pay in one day, so a list of fake ones doesn't.
    static let todoDailyCount = 10
    static let dailyBrickCap = 100
    /// Full rate up to here each day, then half, so grinding stops paying long before the cap.
    static let fullRateBricks = 60
    /// Minutes one task can pay for, so typing in an 8-hour task doesn't.
    static let maxTaskMinutes = 120

    /// Stressful days in a row, ending today, or yesterday when today isn't
    /// stressful (yet), so the streak doesn't reset every morning.
    static func streak(_ load: [(day: Date, minutes: Int)], now: Date, calendar: Calendar = .current) -> Int {
        var perDay: [Date: Int] = [:]
        for l in load { perDay[calendar.startOfDay(for: l.day), default: 0] += l.minutes }
        let stressful = { (day: Date) in perDay[day, default: 0] >= stressfulMinutes }
        var day = calendar.startOfDay(for: now)
        if !stressful(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while stressful(day) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    /// Damage steps 0...3 before rest: every 2 stressful days in a row is one step.
    static func strain(streak: Int) -> Int { min(3, streak / 2) }

    /// `restedDays`: days with enough rest during the streak, today included.
    static func state(streak: Int, restedDays: Int, restedToday: Bool) -> State {
        let strain = strain(streak: streak)
        if restedToday && strain > 0 { return .resting }
        return [.calm, .stressed, .overloaded, .crumbling][max(0, strain - restedDays)]
    }

    /// Stress from doing or attending something: its minutes × effort weight,
    /// halved when it's compulsory.
    static func stress(minutes: Int, _ r: Rating) -> Int {
        Int(Double(minutes) * weight[r.effort]! * (r.compulsory ? 0.5 : 1))
    }

    /// Bricks for a finished task: 1 per 10 estimated minutes, ×1.5 hard, ×2
    /// intense, nothing for easy ones. From the estimate, so taking longer never pays more.
    static func bricks(minutes: Int, _ effort: Effort) -> Int {
        let base = max(1, minutes / 10)
        switch effort {
        case .easy: return 0
        case .normal: return base
        case .hard: return base * 3 / 2
        case .intense: return base * 2
        }
    }

    /// Bricks for a finished plan task: on the estimate or the time it really
    /// took, whichever is less, up to `maxTaskMinutes`; ×1.5 when the phone stayed
    /// down the whole time (Screen Time's quiet hours).
    static func bricks(minutes: Int, actual: Int?, _ effort: Effort, focused: Bool) -> Int {
        let cap = Tester.on ? Int.max : maxTaskMinutes   // TESTER: no 2 h cap per task
        let b = bricks(minutes: min(cap, minutes, actual ?? minutes), effort)
        return focused ? b * 3 / 2 : b
    }

    /// One day's bricks: full rate up to `fullRateBricks`, half after, at most `dailyBrickCap`.
    static func dayTotal(_ bricks: Int) -> Int {
        if Tester.on { return bricks }   // TESTER: no half rate or daily cap
        return min(dailyBrickCap, bricks <= fullRateBricks ? bricks : fullRateBricks + (bricks - fullRateBricks) / 2)
    }

    /// Total bricks, day by day (the day each thing was ticked) through `dayTotal`,
    /// so making up tasks doesn't pay.
    static func total(_ earned: [(day: Date, bricks: Int)], calendar: Calendar = .current) -> Int {
        Dictionary(grouping: earned) { calendar.startOfDay(for: $0.day) }
            .values.reduce(0) { $0 + dayTotal($1.reduce(0) { $0 + $1.bricks }) }
    }
}

extension House {
    /// The house's condition (sprite level 0-5) from bricks earned all-time, so
    /// spending them never undoes it: run-down at first, fixed up step by step,
    /// level 4 is the house as designed, 5 adds flowers. Separate from stress damage.
    // ponytail: thresholds are first guesses (strict rules pay at most 100 a day).
    static let levelBricks = [0, 40, 120, 240, 400, 600]
    static let levelNames = ["Run-down", "Patched up", "Mended", "Cleaned up", "Like new", "Dream home"]

    static func level(earned: Int) -> Int { levelBricks.lastIndex { earned >= $0 } ?? 0 }

    /// Home's house meter: how far to the next level (0–1), full at the top.
    static func progress(earned: Int) -> Double {
        let l = level(earned: earned)
        guard l + 1 < levelBricks.count else { return 1 }
        return Double(earned - levelBricks[l]) / Double(levelBricks[l + 1] - levelBricks[l])
    }

    /// Bricks still needed for the next level, or nil at the top.
    static func toNextLevel(earned: Int) -> Int? {
        let next = level(earned: earned) + 1
        return next < levelBricks.count ? levelBricks[next] - earned : nil
    }

    /// Today's house from the stress streak and the rest log (Home and the widgets).
    static func state(streak: Int, log: RestLog, now: Date, calendar: Calendar = .current) -> State {
        let restedDays = (0...streak).filter {
            log.seconds(on: calendar.date(byAdding: .day, value: -$0, to: now)!, calendar: calendar) >= restGoal
        }.count
        return state(streak: streak, restedDays: restedDays, restedToday: log.seconds(on: now, calendar: calendar) >= restGoal)
    }
}
