import Foundation
import SwiftData
import Testing
@testable import focushouse

@Suite(.serialized) struct HouseTests {   // rest tests share the App Group "restMinBreak"
    let cal = Calendar.current
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 18))!
    func daysAgo(_ n: Int, hour: Int = 16) -> Date {
        cal.date(bySettingHour: hour, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -n, to: now)!)!
    }

    @MainActor @Test func heavyEventsAreNeverLight() {
        let status = HouseStatus(tasks: [], todos: [], events: [], ratings: [Ratings.key("Grandpa's funeral"): Rating(score: 2),
                                                                             Ratings.key("Lunch with friends"): Rating(score: 2)])
        #expect(status.rating("Grandpa's funeral").effort == .hard)
        #expect(status.rating("Hospital visit").effort == .hard)   // unrated, no AI
        #expect(status.rating("Lunch with friends").effort == .easy)
        #expect(!Ratings.heavy("wake up early"))
    }

    @MainActor @Test func deletedDoneTasksKeepBricksAndStress() {
        let kept = [KeptTask(title: "Maths homework", category: "homework", priority: 0, minutes: 200,
                             estimate: 60, start: daysAgo(0), day: daysAgo(0), earns: true)]
        let status = HouseStatus(tasks: [], todos: [], events: [], ratings: [Ratings.key("Maths homework"): Rating(score: 8)], kept: kept, now: now)
        #expect(status.earned > 0)
        #expect(status.streak == 1)
        #expect(HouseStatus(tasks: [], todos: [], events: [], ratings: [:], kept: [], now: now).earned == 0)
    }

    /// End to end: a new task, ticked and answered, earns bricks; a new to-do too.
    @MainActor @Test func newTaskTickedAndAnsweredEarnsBricks() throws {
        let container = try ModelContainer(for: Plan.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let task = PlanTask(title: "Maths homework", category: "homework", minutes: 60, day: 1, order: 0)
        container.mainContext.insert(task)
        task.start = Date.now.addingTimeInterval(-3600)
        let earned = { (ai: Bool) in HouseStatus(tasks: [task], todos: [], events: [], ratings: [:], kept: [], quiet: QuietHours(), ai: ai).earned }
        #expect(earned(true) == 0)
        CheckIn.shared.tick(task)
        #expect(earned(true) == 0)   // waiting for "How did it go?"
        CheckIn.shared.save(task, minutes: 60, feeling: 3, note: "")
        #expect(earned(true) == 6)   // normal: 1 per 10 min
        #expect(earned(false) == 5)  // no Apple Intelligence: its stress score (felt OK → 5)

        let todo = TodoItem(name: "Pack bag", selectedTag: "", dueDate: .now)
        todo.isDone = true; todo.doneAt = .now
        #expect(HouseStatus(tasks: [], todos: [todo], events: [], ratings: [:], kept: [], quiet: QuietHours()).earned == House.todoBricks)
    }

    @Test func streakCountsStressfulDaysInARow() {
        let load = [(daysAgo(0), 120), (daysAgo(1), 60), (daysAgo(1), 60), (daysAgo(2), 150), (daysAgo(4), 300)]
        #expect(House.streak(load, now: now) == 3)   // day 3 is light, so day 4 doesn't count
    }

    @Test func streakSurvivesALightMorning() {
        #expect(House.streak([(daysAgo(1), 200), (daysAgo(2), 200), (daysAgo(0), 30)], now: now) == 2)
        #expect(House.streak([(daysAgo(0), 30)], now: now) == 0)
    }

    @Test func damageStepsAndRestRepairs() {
        #expect(House.state(streak: 1, restedDays: 0, restedToday: false) == .calm)
        #expect(House.state(streak: 2, restedDays: 0, restedToday: false) == .stressed)
        #expect(House.state(streak: 9, restedDays: 0, restedToday: false) == .crumbling)
        #expect(House.state(streak: 6, restedDays: 1, restedToday: false) == .overloaded)
        #expect(House.state(streak: 6, restedDays: 1, restedToday: true) == .resting)
        #expect(House.state(streak: 0, restedDays: 0, restedToday: true) == .calm)   // nothing to repair
        #expect(House.state(streak: 2, restedDays: 3, restedToday: false) == .calm)
    }

    @Test func stressWeightsEffortAndHalvesCompulsory() {
        #expect(House.stress(minutes: 60, Rating(score: 2)) == 0)
        #expect(House.stress(minutes: 60, Rating(score: 5)) == 30)
        #expect(House.stress(minutes: 120, Rating(score: 10)) == 180)
        #expect(House.stress(minutes: 120, Rating(score: 10, compulsory: true)) == 90)   // exam
    }

    /// The student's pre-task score is the baseline, check-ins move it one step,
    /// and with no score stress comes from how it felt, never from priority.
    @MainActor @Test func preTaskStressAndReflections() {
        let ratings = [Ratings.key("Essay"): Rating(score: 3, mine: 7, nudge: 1),
                       Ratings.key("Quiz"): Rating(score: 6, nudge: -1)]
        let felt = PlanTask(title: "Piano", category: "practice", minutes: 30, day: 1, order: 0)
        felt.feeling = 1   // drained
        let status = HouseStatus(tasks: [felt], todos: [], events: [], ratings: ratings, kept: [])
        #expect(status.rating("Essay", category: "homework").score == 8)   // the student's 7, +1
        #expect(status.rating("Quiz").score == 5)
        #expect(status.rating("Piano").score == 9)                          // felt drained
        #expect(status.rating("Something new").score == 5)                  // nothing known
        #expect(Ratings.plainNudge(base: 5, feeling: 1) == 1 && Ratings.plainNudge(base: 5, feeling: 3) == 0
                && Ratings.plainNudge(base: 8, feeling: 5) == -1)
        #expect(Rating(score: 10, nudge: 1).current == 10 && Rating(score: 1, nudge: -1).current == 1)
    }

    @Test func scoreRangesAndPersonalPace() {
        #expect([1, 3, 4, 6, 7, 8, 9, 10].map { Rating(score: $0).effort }
                == [.easy, .easy, .normal, .normal, .hard, .hard, .intense, .intense])
        #expect(Rating(score: 5).personal(1.5).effort == .hard)     // takes this student 1.5× longer
        #expect(Rating(score: 5).personal(0.6).effort == .easy)     // they're quick at it
        #expect(Rating(score: 9).personal(2).score == 10)           // capped
    }

    @Test func bricksFromEstimateByEffortAndDailyCap() {
        #expect(House.bricks(minutes: 45, .normal) == 4)
        #expect(House.bricks(minutes: 40, .hard) == 6)
        #expect(House.bricks(minutes: 40, .intense) == 8)
        #expect(House.bricks(minutes: 5, .normal) == 1)
        #expect(House.bricks(minutes: 90, .easy) == 0)
        #expect(House.bricks(score: 1, focused: false) == 1 && House.bricks(score: 10, focused: false) == 10)   // no Apple Intelligence
        let earned = Array(repeating: (daysAgo(0), 30), count: 5) + [(daysAgo(1), 7)]
        #expect(House.total(earned) == 107)   // today's 150 capped at 100
    }

    @MainActor @Test func bricksCountOnTheTickDaySoFutureTasksCantDodgeTheCap() {
        // A month of tasks, scheduled on 30 different days, all ticked today.
        let kept = (0..<30).map { i in
            KeptTask(title: "Revise \(i)", category: "revision", priority: 1, minutes: 60, estimate: 60,
                     start: daysAgo(-i), day: now, earns: true)
        }
        let status = HouseStatus(tasks: [], todos: [], events: [], ratings: [:], kept: kept, quiet: QuietHours(), now: now)
        #expect(status.earned == House.dailyBrickCap)
    }

    @MainActor @Test func tickingBeforeTheStartEarnsNothing() {
        let task = PlanTask(title: "Essay", category: "essay", minutes: 60, day: 0, order: 0)
        task.start = now
        task.setDone(true, now: now.addingTimeInterval(-3600))
        #expect(task.tickedEarly && !task.earnsBricks)
        task.setDone(false)
        task.setDone(true, now: now.addingTimeInterval(3600))
        #expect(!task.tickedEarly && task.earnsBricks)
    }

    @Test func taskBricksCapMinutesUseTheShorterTimeAndRewardFocus() {
        #expect(House.bricks(minutes: 480, actual: nil, .normal, focused: false) == 12)   // capped at 2 h
        #expect(House.bricks(minutes: 60, actual: 20, .normal, focused: false) == 2)      // took 20 min
        #expect(House.bricks(minutes: 60, actual: 90, .normal, focused: false) == 6)      // longer never pays more
        #expect(House.bricks(minutes: 60, actual: nil, .normal, focused: true) == 9)      // phone down: ×1.5
    }

    @Test func quietHoursCoverEveryHourTheTaskTouches() {
        let start = cal.date(bySettingHour: 10, minute: 30, second: 0, of: now)!
        var q = QuietHours()
        q.hours = [QuietHours.hour(start)]
        #expect(q.covers(start: start, minutes: 30))     // 10:30–11:00
        #expect(!q.covers(start: start, minutes: 45))    // runs into 11:00, not quiet
        q.hours.insert(QuietHours.hour(start) + 1)
        #expect(q.covers(start: start, minutes: 45))
    }

    @Test func halfRateAfterSixtyThenTheCap() {
        #expect(House.dayTotal(50) == 50)
        #expect(House.dayTotal(80) == 70)
        #expect(House.dayTotal(500) == House.dailyBrickCap)
    }

    @MainActor @Test func onlyTenToDosADayPay() {
        let todos = (0..<15).map { i in
            let t = TodoItem(name: "Chore \(i)", selectedTag: "School", dueDate: now, priority: .high)
            t.isDone = true; t.doneAt = now
            return t
        }
        let status = HouseStatus(tasks: [], todos: todos, events: [], ratings: [:], kept: [], quiet: QuietHours(), now: now)
        #expect(status.earned == House.todoDailyCount * House.todoBricks)
    }

    @Test func restCountsOnlyThreeHourWakingStretches() {
        var r = Routine()
        r.wake = 7 * 60
        r.bed = 22 * 60
        var log = RestLog()
        log.add(from: daysAgo(0, hour: 13), to: daysAgo(0, hour: 15), routine: r)
        #expect(log.seconds(on: now) == 0)   // 2 h isn't rest
        log.add(from: daysAgo(1, hour: 20), to: daysAgo(0, hour: 9), routine: r)   // overnight
        #expect(log.seconds(on: daysAgo(1)) == 0)   // only 2 h awake each side
        #expect(log.seconds(on: now) == 0)
        log.add(from: daysAgo(1, hour: 18), to: daysAgo(0, hour: 10), routine: r)
        #expect(log.seconds(on: daysAgo(1)) == 4 * 3600)   // 6 PM–10 PM
        #expect(log.seconds(on: now) == 3 * 3600)          // 7 AM–10 AM, sleep skipped
        #expect(RestLog.load(log.data) == log)
    }

    @Test func screenTimeRestNeedsThreeHoursInARow() {
        var log = RestLog()
        var run = RestRun()
        let at = { (h: Int) in daysAgo(0, hour: h) }
        log.restedHour(endingAt: at(9), run: &run)
        log.restedHour(endingAt: at(10), run: &run)
        #expect(log.seconds(on: now) == 0)            // 2 h in a row
        run = RestRun()                               // phone used 10–11
        log.restedHour(endingAt: at(12), run: &run)
        log.restedHour(endingAt: at(13), run: &run)
        log.restedHour(endingAt: at(14), run: &run)
        #expect(log.seconds(on: now) == 3 * 3600)     // the 3 h stretch counts
        log.restedHour(endingAt: at(15), run: &run)
        #expect(log.seconds(on: now) == 4 * 3600)     // and each hour after
        log.restedHour(endingAt: at(18), run: &run)   // gap: starts a new run
        #expect(run.hours == 1 && log.seconds(on: now) == 4 * 3600)
    }

    @Test func screenTimeIgnoresHoursStoppedEarly() {
        let at = { (h: Int, m: Int) in daysAgo(0, hour: h).addingTimeInterval(TimeInterval(m * 60)) }
        #expect(RestHours.endedOnTime("rest.840", at: at(15, 0)))       // 14:00–15:00 ends on time
        #expect(RestHours.endedOnTime("rest.840", at: at(15, 40)))      // a little late
        #expect(!RestHours.endedOnTime("rest.840", at: at(14, 20)))     // stopped by a reschedule
        #expect(RestHours.endedOnTime("rest.1380", at: at(0, 5)))       // 23:00–24:00 across midnight
        #expect(!RestHours.endedOnTime("rest.1380", at: at(23, 30)))
    }

    @Test func restBreakSettingNeverUnderFifteenMinutes() {
        defer { RestLog.defaults.removeObject(forKey: "restMinBreak") }
        RestLog.defaults.set(5, forKey: "restMinBreak")
        #expect(RestLog.minBreak == 15 * 60)
        RestLog.defaults.set(30, forKey: "restMinBreak")
        var log = RestLog()
        var r = Routine(); r.wake = 7 * 60; r.bed = 22 * 60
        log.add(from: daysAgo(0, hour: 13), to: daysAgo(0, hour: 13).addingTimeInterval(20 * 60), routine: r)
        #expect(log.seconds(on: now) == 0)            // 20 min < 30 min
        log.add(from: daysAgo(0, hour: 14), to: daysAgo(0, hour: 14).addingTimeInterval(40 * 60), routine: r)
        #expect(log.seconds(on: now) == 40 * 60)
        var run = RestRun()
        log.restedHour(endingAt: daysAgo(0, hour: 18), run: &run)
        #expect(log.seconds(on: now) == 40 * 60 + 3600)   // Screen Time: one quiet hour is enough
    }

    @Test func houseFixesUpWithBricksEarned() {
        #expect(House.level(earned: 0) == 0 && House.toNextLevel(earned: 0) == 40)
        #expect(House.level(earned: 39) == 0 && House.level(earned: 40) == 1)
        #expect(House.level(earned: 599) == 4 && House.toNextLevel(earned: 599) == 1)
        #expect(House.level(earned: 5000) == 5 && House.toNextLevel(earned: 5000) == nil)
        #expect(House.levelNames.count == House.levelBricks.count)
        #expect(House.progress(earned: 0) == 0 && House.progress(earned: 6) == 0.15)   // moves with each task
        #expect(House.progress(earned: 40) == 0 && House.progress(earned: 5000) == 1)
    }

    @Test func restHoursAreHourlyBlocksCappedAtTwenty() {
        let b = RestHours.blocks(wake: 7 * 60, bed: 22 * 60)
        #expect(b.count == 15 && b.first?.start == 420 && b.last?.end == 1320)
        #expect(RestHours.blocks(wake: 6 * 60, bed: 2 * 60).count == 20)   // bedtime after midnight
    }

    @Test func catalogLoadsEveryFileWithWholeSprites() {
        #expect(Shop.items.contains { $0.name == "Focus Clock" })     // furniture_more.json
        #expect(Set(Shop.items.map(\.name)).count == Shop.items.count)
        for item in Shop.items {
            #expect(item.grid.count == 24 && item.grid.allSatisfy { $0.count == 24 }, "\(item.name)")
            if item.level > 1 { #expect(Shop.items.contains { $0.group == item.group && $0.level == item.level - 1 }, "\(item.name)") }
        }
    }

    @Test func shopNeedsLevelOneAndEnoughBricks() {
        let desk = Furniture(name: "Desk", tag: "Work", description: "", hobby: "desk", level: 1, cost: 40, grid: [], wall: nil)
        let deluxe = Furniture(name: "Deluxe", tag: "Work", description: "", hobby: "desk", level: 2, cost: 120, grid: [], wall: nil)
        let all = [desk, deluxe]
        #expect(Shop.state(desk, owned: [], balance: 39, in: all) == .short(1))
        #expect(Shop.state(desk, owned: [], balance: 40, in: all) == .buy)
        #expect(Shop.state(deluxe, owned: [], balance: 500, in: all) == .needs("Desk"))
        #expect(Shop.state(deluxe, owned: ["Desk"], balance: 120, in: all) == .buy)
        #expect(Shop.state(desk, owned: ["Desk"], balance: 0, in: all) == .owned)
        #expect(Shop.spent(["Desk", "Deluxe"], in: all) == 160)
        #expect(Shop.items.count == 50)   // 10 + 24 hobbies + 16 more   // both JSON files bundled
    }

    @Test func roomSpotsCapSwapAndReplace() {
        var raw = ""
        for g in ["A", "B", "C", "D", "E", "F", "G", "H"] { raw = Shop.toggle(g, in: raw) }
        #expect(Shop.slots(raw) == ["A", "B", "C", "D", "E", "F", "G", "", "", "", ""])   // 7 floor spots; H doesn't fit
        raw = Shop.toggle("Board", wall: true, in: raw)
        #expect(Shop.slots(raw)[7] == "Board")                   // boards take a wall spot
        raw = Shop.put("A", at: 2, in: raw)
        #expect(Shop.slots(raw).prefix(3) == ["C", "B", "A"])     // moving swaps
        raw = Shop.put("H", at: 1, in: raw)
        #expect(Shop.slots(raw).prefix(3) == ["C", "H", "A"])     // new replaces
        raw = Shop.toggle("A", in: raw)
        #expect(Shop.slots(raw).prefix(3) == ["C", "H", ""])      // spot stays put
    }

    @Test func upgradeThatHangsMovesToAWall() {
        let group = "Planning & focus"   // Hourglass Timer (floor) → Focus Clock (wall)
        let raw = Shop.toggle(group, in: "")
        #expect(Shop.placed(raw, owned: ["Hourglass Timer"]).first??.name == "Hourglass Timer")
        let after = Shop.refit(raw, owned: ["Hourglass Timer", "Focus Clock"])
        #expect(Shop.slots(after)[0] == "")
        #expect(Shop.spots[Shop.slots(after).firstIndex(of: group)!].wall)
        #expect(Shop.placed(after, owned: ["Hourglass Timer", "Focus Clock"]).contains { $0?.name == "Focus Clock" })
    }
}
