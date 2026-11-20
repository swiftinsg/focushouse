import Foundation

/// Rest per day, in seconds, shared between the app and the Screen Time monitor
/// extension through the app group. Home reads it through @AppStorage.
struct RestLog: Codable, Equatable {
    static let group = "group.sg.swiftin.2am"
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }
    /// Rest only counts in unbroken phone-free stretches this long or longer.
    /// Set in Settings (minutes, App Group key "restMinBreak"); never under 15 min.
    static let floorMinutes = 15, defaultMinutes = 180
    static var minBreak: TimeInterval {
        let m = defaults.integer(forKey: "restMinBreak")
        return TimeInterval(max(floorMinutes, m == 0 ? defaultMinutes : m) * 60)
    }

    var seconds: [String: TimeInterval] = [:]

    static func key(_ day: Date, _ calendar: Calendar) -> String {
        String(Int(calendar.startOfDay(for: day).timeIntervalSinceReferenceDate))
    }

    func seconds(on day: Date, calendar: Calendar = .current) -> TimeInterval {
        seconds[Self.key(day, calendar)] ?? 0
    }

    mutating func add(_ rest: TimeInterval, on day: Date, calendar: Calendar = .current) {
        seconds[Self.key(day, calendar), default: 0] += rest
    }

    /// A gap away from the phone, counting only waking hours (`wake`/`bed` in
    /// minutes since midnight), so sleep isn't rest from the phone.
    mutating func add(from: Date, to: Date, wake: Int, bed: Int, calendar: Calendar = .current) {
        guard to.timeIntervalSince(from) >= Self.minBreak else { return }
        let bedMinutes = bed <= wake ? bed + 24 * 60 : bed   // bedtime after midnight
        var day = calendar.startOfDay(for: from)
        while day < to {
            let start = day.addingTimeInterval(TimeInterval(wake * 60))
            let end = day.addingTimeInterval(TimeInterval(bedMinutes * 60))
            let overlap = min(to, end).timeIntervalSince(max(from, start))
            if overlap >= Self.minBreak { add(overlap, on: day, calendar: calendar) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
    }

    static func load(_ data: Data) -> RestLog { (try? JSONDecoder().decode(RestLog.self, from: data)) ?? RestLog() }
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func update(_ change: (inout RestLog) -> Void) {
        var log = load(defaults.data(forKey: "restLog") ?? Data())
        change(&log)
        defaults.set(log.data, forKey: "restLog")
    }
}

/// Clock hours with (almost) no phone use, recorded by the Screen Time monitor
/// whether or not they count as rest. A task inside quiet hours gets the focus bonus.
struct QuietHours: Codable, Equatable {
    var hours: Set<Int> = []   // hour number: whole hours since the reference date

    static func hour(_ date: Date) -> Int { Int((date.timeIntervalSinceReferenceDate / 3600).rounded(.down)) }

    /// Every clock hour the task touches was quiet.
    func covers(start: Date, minutes: Int) -> Bool {
        guard minutes > 0 else { return false }
        let last = start.addingTimeInterval(TimeInterval(minutes * 60 - 1))
        return (Self.hour(start)...Self.hour(last)).allSatisfy(hours.contains)
    }

    static func load() -> QuietHours {
        RestLog.defaults.data(forKey: "quietHours").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? QuietHours()
    }

    /// The monitor's hour that just ended was quiet. Keeps two weeks.
    static func add(endingAt end: Date) {
        var q = load()
        let h = hour(end.addingTimeInterval(-1800))   // the callback can run a little late
        q.hours.insert(h)
        q.hours = q.hours.filter { $0 > h - 14 * 24 }
        RestLog.defaults.set(try? JSONEncoder().encode(q), forKey: "quietHours")
    }
}

/// Phone-free hours in a row so far, kept by the Screen Time monitor.
struct RestRun: Codable, Equatable {
    var hours = 0
    var lastEnd: Date?

    static func load() -> RestRun {
        RestLog.defaults.data(forKey: "restRun").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? RestRun()
    }
    func save() { RestLog.defaults.set(try? JSONEncoder().encode(self), forKey: "restRun") }
}

extension RestLog {
    /// A watched hour ending at `end` passed without phone use. It continues the
    /// run if it follows the last one; once the run reaches `minBreak` the whole
    /// stretch counts, and each later hour adds one more. A used hour resets the run.
    mutating func restedHour(endingAt end: Date, run: inout RestRun, calendar: Calendar = .current) {
        // ponytail: 75 min tolerance for late Screen Time callbacks; a skipped one breaks the run.
        let follows = run.lastEnd.map { end.timeIntervalSince($0) < 75 * 60 } ?? false
        run.hours = follows ? run.hours + 1 : 1
        run.lastEnd = end
        // Screen Time watches whole hours, so a shorter break still needs one quiet hour.
        let need = max(1, Int((Self.minBreak / 3600).rounded(.up)))
        let day = end.addingTimeInterval(-60)
        if run.hours == need { add(TimeInterval(need * 3600), on: day, calendar: calendar) }
        else if run.hours > need { add(3600, on: day, calendar: calendar) }
    }
}

/// The waking hours Screen Time watches. Any phone use in an hour (from
/// `glanceMinutes`, the smallest Screen Time threshold) means it isn't rest.
enum RestHours {
    static let glanceMinutes = 1
    /// Screen Time monitors at most 20 activities per app.
    static let maxBlocks = 20

    /// Start and end in minutes since midnight; `end` may pass 24:00 for late bedtimes.
    struct Block: Equatable { var start: Int; var end: Int }

    static func blocks(wake: Int, bed: Int) -> [Block] {
        let end = bed <= wake ? bed + 24 * 60 : bed
        guard end - wake >= 60 else { return [] }
        return stride(from: wake, through: end - 60, by: 60).prefix(maxBlocks).map { Block(start: $0, end: $0 + 60) }
    }

    static func name(_ block: Block) -> String { "rest.\(block.start)" }
}
