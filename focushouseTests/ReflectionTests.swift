import Foundation
import SwiftData
import Testing
@testable import focushouse

@MainActor struct ReflectionTests {
    let cal = Calendar.current
    /// Saturday 14 Nov 2026 (no school) at h:m.
    func at(_ h: Int, _ m: Int = 0, day: Int = 14) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    func answered(_ category: String = "study", at start: Date, felt: Int, note: String = "", reflected: Date? = nil) -> PlanTask {
        let t = PlanTask(title: "T", category: category, minutes: 30, day: 1, order: 0)
        t.start = start
        t.feeling = felt
        t.note = note
        t.reflectedAt = reflected ?? start
        t.checkIn = PlanTask.CheckInState.answered.rawValue
        return t
    }

    @Test func bestTimeNeedsThreeAnswersAndAGap() {
        var h = (0..<3).map { _ in answered(at: at(15), felt: 4) } + (0..<3).map { _ in answered(at: at(21), felt: 2) }
        let t = Reflections.bestTime(h)
        #expect(t?.best == .afternoon && t?.worst == .night)
        #expect(Reflections.promptNote(h, now: at(22)).contains("put hard or high-effort items first"))
        h.removeLast()   // night has only 2 answers now
        #expect(Reflections.bestTime(h) == nil)
    }

    @Test func drainingCategoriesAndHardDay() {
        let h = (0..<3).map { _ in answered("writing", at: at(16), felt: 1) } + (0..<3).map { _ in answered("reading", at: at(16), felt: 4) }
        #expect(Reflections.draining(h) == ["writing"])
        #expect(Reflections.wasHardDay(h.prefix(3).map { $0 }, now: at(20)))
        #expect(!Reflections.wasHardDay(h, now: at(20)))                         // average 2.5
        #expect(!Reflections.wasHardDay(h.prefix(3).map { $0 }, now: at(20, day: 17)))   // too long ago
        #expect(Reflections.breakMinutes(h.prefix(3).map { $0 }, now: at(20)) == 10)
    }

    @Test func notesDeletedAfter30DaysFeelingsKept() {
        let old = answered(at: at(15), felt: 2, note: "tired after CCA")
        let new = answered(at: at(15), felt: 3, note: "ok", reflected: at(15, day: 30))
        Reflections.purgeNotes([old, new], now: at(16, day: 30).addingTimeInterval(16 * 86_400))
        #expect(old.note.isEmpty && old.feeling == 2)
        #expect(new.note == "ok")
    }

    @Test func bricksOnlyOnceAnswered() {
        let t = PlanTask(title: "Essay", category: "writing", minutes: 30, day: 1, order: 0)
        CheckIn.shared.tick(t)
        #expect(t.done && !t.earnsBricks)                    // waiting for an answer
        CheckIn.shared.save(t, minutes: 40, feeling: 3, note: " fine ")
        #expect(t.earnsBricks && t.note == "fine" && t.actual == 40)
        let s = PlanTask(title: "Maths", category: "homework", minutes: 30, day: 1, order: 0)
        CheckIn.shared.tick(s)
        CheckIn.shared.skip(s)
        #expect(s.done && !s.earnsBricks)
        CheckIn.shared.untick(s); CheckIn.shared.tick(s)   // skipped stays skipped: no new ask
        #expect(!CheckIn.shared.queue.contains { $0 === s } && !s.earnsBricks)
        let legacy = PlanTask(title: "Old", category: "study", minutes: 30, day: 1, order: 0)
        legacy.done = true                                  // done before check-ins existed
        #expect(legacy.earnsBricks)
        let free = PlanTask(title: "Free time", category: Plan.freeTime, minutes: 30, day: 1, order: 0)
        CheckIn.shared.tick(free)
        #expect(!CheckIn.shared.queue.contains { $0 === free } && !free.earnsBricks)
    }

    @Test func correctedTimeReplacesPace() {
        let category = "test-\(UUID())"
        Planner.recordPace(category: category, estimate: 30, actual: 30)
        Planner.correctPace(category: category, estimate: 30, from: 30, to: 45)
        #expect(Planner.savedPace()[category] == [1.5])
    }

    @Test func setPaceCountsNowAndKeepsLearning() {
        let category = "test-\(UUID())"
        Planner.setPace(category: category, ratio: 1.5)
        #expect(Planner.pace().first { $0.category == category }?.ratio == 1.5)
        for _ in 0..<6 { Planner.recordPace(category: category, estimate: 30, actual: 30) }
        #expect(Planner.pace().first { $0.category == category }?.ratio == 1)
    }

    @Test func gapBetweenTasks() {
        let starts = Scheduler.schedule([(30, 1), (30, 1)], from: at(10), routine: .loose, gap: 10)
        #expect(starts == [at(10), at(10, 40)])
    }

    @Test func longTaskSplitsWithBreaks() throws {
        let container = try ModelContainer(for: Plan.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let plan = Plan(title: "t", mode: .today, input: "", days: 1, start: at(9))
        container.mainContext.insert(plan)
        plan.freeFrom = 9 * 60; plan.freeUntil = 23 * 60
        let essay = PlanTask(title: "Essay", category: "study", minutes: 150, day: 1, order: 0)
        plan.tasks = [essay, PlanTask(title: "Maths", category: "study", minutes: 30, day: 1, order: 1)]
        plan.reflow()
        plan.addBreaks(to: essay, rest: 10)
        #expect(plan.ordered.map(\.title) == ["Essay (1/3)", "Break", "Essay (2/3)", "Break", "Essay (3/3)", "Maths"])
        #expect(plan.ordered.map(\.minutes) == [60, 10, 60, 10, 30, 30])
        #expect(plan.ordered.last?.start == at(11, 50))   // 150 min work + 20 min breaks after 9:00
        #expect(plan.ordered[1].category == Plan.freeTime)
    }

    @Test func freeTimeAddedOnceWhenOverLimit() throws {
        let container = try ModelContainer(for: Plan.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let plan = Plan(title: "t", mode: .today, input: "", days: 1, start: at(9))
        container.mainContext.insert(plan)
        plan.freeFrom = 9 * 60; plan.freeUntil = 23 * 60
        plan.tasks = (0..<4).map { PlanTask(title: "W\($0)", category: "study", minutes: 60, day: 1, order: $0) }
        plan.reflow()
        plan.addFreeTime { _ in 120 }    // 2 h limit: crossed by W2
        #expect(plan.ordered.map(\.title) == ["W0", "W1", "W2", "Free time", "W3"])
        #expect(plan.ordered[3].start == at(12))
        plan.addFreeTime { _ in 120 }    // already has one that day
        #expect(plan.tasks.count == 5)
    }

    @Test func weekStatsCountTheLastSevenDays() {
        let now = at(21, day: 20)
        func item(_ title: String, day: Int, _ minutes: Int, stress: Int, done: Bool = true, felt: Int? = nil,
                  event: Bool = false, actual: Int? = nil) -> WeekStats.Item {
            WeekStats.Item(title: title, day: at(16, day: day), minutes: minutes, stress: stress, isEvent: event,
                           done: done, feeling: felt, estimate: actual == nil ? nil : minutes, actual: actual)
        }
        let items = [
            item("Chem revision", day: 20, 150, stress: 150, felt: 2, actual: 180),
            item("Chem revision", day: 19, 150, stress: 150, felt: 2, actual: 180),
            item("Maths", day: 18, 60, stress: 30, done: false, felt: nil),
            item("Piano", day: 17, 30, stress: 15, felt: 5, actual: 30),
            item("CCA", day: 16, 120, stress: 60, event: true),
            item("Old essay", day: 10, 300, stress: 300),          // over a week ago
            item("Tomorrow's test", day: 21, 60, stress: 60),     // not yet
        ]
        let stats = WeekStats(items: items, rest: { $0 == self.cal.startOfDay(for: now) ? 4 * 3600 : 3600 }, now: now)
        #expect(stats.days.count == 7)
        #expect(stats.stressfulDays == 2)
        #expect(stats.restedDays == 1)
        #expect(stats.planned == 4 && stats.done == 3)            // the CCA event isn't a task
        #expect(stats.top.first?.title == "Chem revision" && stats.top.first?.share == 74)
        #expect(stats.drained == ["Chem revision"] && stats.energised == ["Piano"])
        #expect(stats.overrun == 18)                              // 390 min for 330 planned
        #expect(stats.facts.contains("- Tasks finished: 3 of 4."))
    }
}
