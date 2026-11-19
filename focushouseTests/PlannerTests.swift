import Foundation
import Testing
@testable import focushouse

struct PlannerTests {
    @Test func splitsToDoDump() {
        #expect(Planner.items("maths hw, read ch 4;\n- tidy room\n\n") == ["maths hw", "read ch 4", "tidy room"])
    }

    private func item(_ title: String, _ category: String = "homework", steps: Int = 0) -> DraftItem {
        DraftItem(title: title, category: category, minutes: 30, day: 1, priority: "normal",
                  subtasks: (0..<steps).map { DraftStep(title: "Step \($0)", minutes: 10) })
    }

    @Test func restoresDroppedItemsAndPriorities() {
        var draft = DraftPlan(title: "To-dos", items: [item("Tidy room", "chores"), item("Write essay draft")])
        Planner.reconcile(["clean room", "essay draft due tmr", "maths hw!!", "maths hw", "gym maybe", "4"], in: &draft)
        #expect(draft.items.map(\.title) == ["Tidy room", "Write essay draft", "Maths hw!!", "Gym maybe"])
        #expect(draft.items.map(\.priority) == ["normal", "high", "high", "low"])
    }

    @Test func unmarkedLinesAreNormalAndRestoredOnesAreReported() {
        var draft = DraftPlan(title: "x", items: [item("Maths homework")])
        draft.items[0].priority = "high"   // the model guessing
        let restored = Planner.reconcile(["maths homework", "call grandma"], in: &draft)
        #expect(draft.items.map(\.priority) == ["normal", "normal"])
        #expect(restored == [1])
    }

    @Test func fillsPlaceholdersFromTheFollowUp() {
        var draft = DraftPlan(title: "x", items: [item("Math hw"), item("Pack bag", "other"), item("Econs essay can wait", "other")])
        draft.items[2].priority = "low"
        Planner.fill([1, 2], in: &draft, from: [
            DraftItem(title: "Write econs essay", category: "writing", minutes: 120, day: 1, priority: "high",
                      subtasks: [DraftStep(title: "Outline", minutes: 30), DraftStep(title: "Draft", minutes: 90)]),
            DraftItem(title: "Get ready for school", category: "chores", minutes: 10, day: 1, priority: "normal", subtasks: [])])
        #expect(draft.items.map(\.title) == ["Math hw", "Pack bag", "Econs essay"])   // the student's words
        #expect(draft.items.map(\.minutes) == [30, 10, 120])
        #expect(draft.items.map(\.category) == ["homework", "chores", "writing"])
        #expect(draft.items[2].priority == "low")   // the student's mark, not the model's
        #expect(draft.items[2].subtasks.count == 2)
    }

    @Test func keepsTheSubjectWhenTheModelDropsIt() {
        var draft = DraftPlan(title: "x", items: [item("GP essay"), item("Draft essay introduction")])
        Planner.reconcile(["GP essay", "econs essay can wait"], in: &draft)
        #expect(draft.items.map(\.title) == ["GP essay", "Econs essay"])
        #expect(draft.items[1].priority == "low")

        var kept = DraftPlan(title: "x", items: [item("Complete chemistry tutorial")])
        Planner.reconcile(["chem tutorial due tmr!!"], in: &kept)
        #expect(kept.items[0].title == "Complete chemistry tutorial")   // chem ~ chemistry
    }

    @Test func bigItemsGetStepsScaledToTheirTime() {
        var draft = DraftPlan(title: "x", items: [item("GP essay draft", "writing"), item("Laundry", "chores")])
        draft.items[0].minutes = 120
        Planner.steps([0], in: &draft, from: [
            DraftItem(title: "GP essay draft", category: "writing", minutes: 60, day: 1, priority: "normal",
                      subtasks: [DraftStep(title: "Outline", minutes: 20), DraftStep(title: "Write body", minutes: 40)])])
        #expect(draft.items[0].subtasks.map(\.minutes) == [40, 80])
        #expect(draft.items[1].subtasks.isEmpty)

        // The same steps answered as separate items.
        var flat = DraftPlan(title: "x", items: [item("GP essay draft", "writing")])
        flat.items[0].minutes = 90
        Planner.steps([0], in: &flat, from: [
            DraftItem(title: "Outline the essay", category: "writing", minutes: 20, day: 1, priority: "normal", subtasks: []),
            DraftItem(title: "Write the body", category: "writing", minutes: 40, day: 1, priority: "normal", subtasks: [])])
        #expect(flat.items[0].subtasks.map(\.title) == ["Outline the essay", "Write the body"])
        #expect(flat.items[0].subtasks.map(\.minutes) == [30, 60])
    }

    @Test func dropsItemsTheStudentNeverWrote() {
        // What the on-device model really did with "maths hw": it added an
        // example from its instructions.
        var draft = DraftPlan(title: "Day 1 Tasks", items: [item("Tidy room", "chores"), item("Maths hw")])
        let restored = Planner.reconcile(["maths hw", "feed cat"], in: &draft)
        #expect(draft.items.map(\.title) == ["Maths hw", "Feed cat"])
        #expect(restored == [1])
    }

    @Test func shortLinesAndNumberedLinesStayApart() {
        var hw = DraftPlan(title: "hw", items: [item("Do hw")])
        Planner.reconcile(["hw"], in: &hw)
        #expect(hw.items.map(\.title) == ["Do hw"])   // not dropped as unmatched

        var chapters = DraftPlan(title: "x", items: [item("Read chapter 5"), item("Read chapter 4")])
        Planner.reconcile(["read ch 4", "read ch 5", "chem tutorial 1", "chem tutorial 2"], in: &chapters)
        #expect(chapters.items.map(\.title) == ["Read chapter 5", "Read chapter 4", "Chem tutorial 1", "Chem tutorial 2"])
    }

    @Test func distressIsNeverATask() {
        let input = "i want to die lol this week is too much\nphysics test revision\nrun 5 kms"
        #expect(Planner.items(input) == ["physics test revision", "run 5 kms"])
        #expect(Planner.distressed(input))
        #expect(Planner.distressed("I don’t want to live like this"))
        #expect(!Planner.distressed("kill time before tuition\nshoot hoops\ndissect a frog"))
    }

    @Test func vagueInputIsNotPlanned() {
        #expect(Planner.isVague("tasks"))
        #expect(Planner.isVague("get my stuff done today"))
        #expect(Planner.isVague("  "))
        #expect(!Planner.isVague("hw"))
        #expect(!Planner.isVague("clean up"))
        #expect(!Planner.isVague("tasks: maths hw"))
    }

    @Test func eachLineNeedsItsOwnItem() {
        var draft = DraftPlan(title: "x", items: [item("Write GP essay")])
        Planner.reconcile(["GP essay", "econs essay"], in: &draft)
        #expect(draft.items.map(\.title) == ["Write GP essay", "Econs essay"])
    }

    @Test func choresAndOneStepItemsHaveNoSubtasks() {
        let draft = Planner.tidied(DraftPlan(title: "x", items: [
            item("Tidy room", "chores", steps: 3), item("Maths hw", steps: 1), item("Essay", "writing", steps: 3)
        ]))
        #expect(draft.items.map(\.subtasks.count) == [0, 0, 3])
    }

    @Test func picksMatchingSubtaskExamples() {
        let saved = [Planner.Example(item: "English essay", steps: ["Find quotes (15 min)"]),
                     Planner.Example(item: "Maths problem set", steps: ["Easy ones first (20 min)"]),
                     Planner.Example(item: "Clean bike", steps: ["Wash (10 min)"])]
        let text = Planner.examples(for: "history essay, physics problem set", from: saved)
        #expect(text.contains("Maths problem set"))
        #expect(text.contains("English essay"))
        #expect(!text.contains("Clean bike"))
        #expect(Planner.examples(for: "feed cat", from: saved).isEmpty)
    }
}

struct GoalTests {
    private func item(_ title: String, _ category: String = "revision", minutes: Int = 30, day: Int = 1,
                      priority: String = "high") -> DraftItem {
        DraftItem(title: title, category: category, minutes: minutes, day: day, priority: priority, subtasks: [])
    }

    private let chem = "Revise for my H2 Chemistry exam on Wednesday: organic chemistry, chemical equilibrium and electrochemistry"

    @Test func splitsGoalIntoTopics() {
        #expect(Planner.goalTopics(chem) == ["organic chemistry", "chemical equilibrium", "electrochemistry"])
        #expect(Planner.goalTopics("maths, physics; chemistry") == ["maths", "physics", "chemistry"])
        #expect(Planner.goalTopics("Be able to run 5km without stopping").isEmpty)
        #expect(Planner.goalTopics("Clean and organise my bedroom").isEmpty)   // no list: one goal
        #expect(Planner.goalTopics("Finish by 5:30").isEmpty)
        #expect(Planner.cleanTopic("chemistry is urgent!!") == "chemistry")
    }

    @Test func addsDroppedTopicOnLightestDay() {
        var draft = DraftPlan(title: "Chem", items: [item("Organic chemistry basics", minutes: 60, day: 1),
                                                     item("Chemical equilibrium", minutes: 75, day: 2),
                                                     item("Past paper", minutes: 90, day: 4)])
        Planner.cover(Planner.goalTopics(chem), goal: chem, days: 4, in: &draft)
        #expect(draft.items.map(\.title) == ["Organic chemistry basics", "Chemical equilibrium", "Revise electrochemistry", "Past paper"])
        #expect(draft.items[2].day == 3)        // the empty day
        #expect(draft.items[2].minutes == 75)   // the plan's median item
    }

    @Test func keepsTopicsTheModelCoveredUnderOtherWords() {
        var draft = DraftPlan(title: "Chem", items: [item("Organic reactions"), item("Equilibria practice"),
                                                     item("Electrochemical cells")])
        Planner.cover(Planner.goalTopics(chem), goal: chem, days: 3, in: &draft)
        #expect(draft.items.count == 3)
    }

    @Test func addsDroppedStudySectionAfterTheOneBefore() {
        let material = """
            Section 1: Arenes - electrophilic substitution, nitration and halogenation of benzene
            Section 2: Phenols - acidity, reaction with bromine water and NaOH
            Section 3: Carbonyls - nucleophilic addition of HCN, 2,4-DNPH and Tollens' tests
            """
        let sections = Planner.materialTopics(material)
        #expect(sections.count == 3)
        var draft = DraftPlan(title: "x", items: [item("Electrophilic substitution of benzene", day: 1),
                                                  item("Acidity of phenols", day: 2), item("Past paper", day: 4)])
        Planner.cover(sections, goal: "Revise organic chemistry for my class test", days: 4, inOrder: true, in: &draft)
        #expect(draft.items.map(\.title) == ["Electrophilic substitution of benzene", "Acidity of phenols",
                                             "Revise Section 3: Carbonyls", "Past paper"])
        #expect(draft.items[2].day == 2)
        #expect(Planner.materialTopics("Just one line of notes").isEmpty)
    }

    @Test func spreadsAPlanPackedIntoDayOne() {
        var packed = DraftPlan(title: "x", items: [item("Outline essay", minutes: 60), item("Draft essay", minutes: 70)])
        Planner.spread(&packed, days: 5)
        #expect(packed.items.map(\.day) == [1, 3])

        var fine = DraftPlan(title: "x", items: [item("A", day: 1), item("B", day: 2), item("C", day: 3)])
        Planner.spread(&fine, days: 6)
        #expect(fine.items.map(\.day) == [1, 2, 3])   // already one item a day: left alone
    }

    @Test func thinStudyPlansGetAFloor() {
        let thin = DraftPlan(title: "x", items: [item("Outline essay", "writing", minutes: 60), item("Research", "study", minutes: 70)])
        #expect(Planner.effortFloor(thin, days: 5) == 250)
        #expect(Planner.effortFloor(thin, days: 2) == nil)
        #expect(Planner.effortFloor(DraftPlan(title: "x", items: [item("Easy run", "exercise")]), days: 7) == nil)
    }

    @Test func exerciseSessionsAreAtMostAnHour() {
        var run = item("Long run", "exercise", minutes: 120)
        let one = Planner.tidied(DraftPlan(title: "x", items: [run])).items[0]
        #expect(one.minutes == 60)
        run.subtasks = [DraftStep(title: "Warm up", minutes: 20), DraftStep(title: "Run", minutes: 100)]
        let steps = Planner.tidied(DraftPlan(title: "x", items: [run])).items[0].subtasks.map(\.minutes)
        #expect(steps == [10, 50])
    }

    @Test func shortFormsMatch() {
        #expect(Planner.similar("chem", "chemistry"))
        #expect(Planner.similar("electrochemistry", "electrochemical"))
        #expect(!Planner.similar("org", "organic"))   // too short to trust
        #expect(!Planner.similar("chemical", "electrochemical"))
    }

    @Test func goalPrioritiesComeOnlyFromStudentWords() {
        let goal = "Prepare for exams: chemistry is urgent, history can wait, physics"
        var draft = DraftPlan(title: "x", items: [item("Chemistry past paper"), item("History essay plan"),
                                                  item("Physics formulas"), item("Rest and review")])
        Planner.goalPriorities(Planner.goalTopics(goal), goal: goal, in: &draft)
        #expect(draft.items.map(\.priority) == ["high", "low", "normal", "normal"])

        var deadlineOnly = DraftPlan(title: "x", items: [item("Outline essay"), item("Draft essay")])
        Planner.goalPriorities(Planner.goalTopics("Write my essay due Friday"), goal: "Write my essay due Friday", in: &deadlineOnly)
        #expect(deadlineOnly.items.map(\.priority) == ["normal", "normal"])
    }
}

struct PaceTests {
    @Test func notesOnlyCategoriesThatAreOff() {
        let saved = ["writing": [1.4, 1.6, 1.5, 1.5, 1.45], "homework": [1.0, 1.05, 0.95, 1, 1],
                     "chores": [0.5, 0.5, 0.5, 0.5]]   // 4 < runway of 5
        let note = Planner.paceNote(from: saved)
        #expect(note.contains("writing: takes longer than typical, ×1.5 (a typical 30 min writing task takes them about 45 min)"))
        #expect(!note.contains("homework"))   // on pace
        #expect(!note.contains("chores"))     // too few tasks
        #expect(Planner.paceNote(from: ["homework": [1, 1, 1, 1, 1]]).isEmpty)
    }

    @Test func recordsActualOnlyOnceAndOnlyAfterStart() {
        let start = Date(timeIntervalSince1970: 0)
        let task = PlanTask(title: "Essay", category: "test-\(UUID())", minutes: 40, day: 1, order: 0)
        task.estimate = 30
        task.start = start
        task.setDone(true, now: start - 60)          // before it started: unknown
        #expect(task.actual == nil)
        task.setDone(false)
        task.setDone(true, now: start + 20 * 60)     // mid-task: time so far
        #expect(task.actual == 20)
        task.setDone(false)
        task.setDone(true, now: start + 99 * 60)     // already recorded
        #expect(task.actual == 20)
        let late = PlanTask(title: "x", category: "test-\(UUID())", minutes: 45, day: 1, order: 0)
        late.estimate = 30; late.start = start
        late.setDone(true, now: start + 3600)        // after the end: its (pushed-back) length
        #expect(late.actual == 45)
    }
}
