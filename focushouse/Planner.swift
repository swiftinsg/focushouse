import Foundation
import FoundationModels

@Generable struct DraftPlan {
    @Guide(description: "Short title naming the work, 2 to 5 words, no full stop, e.g. \"Chemistry exam revision\" or \"Tuesday to-dos\"")
    var title: String
    @Guide(description: "One item per thing the user asked for, in the order they should be done", .count(1...15))
    var items: [DraftItem]
}

/// One thing the student asked for. Big work comes with subtasks; each subtask
/// becomes its own scheduled task in the app, grouped under the item's title.
@Generable struct DraftItem {
    @Guide(description: "Short, concrete action starting with a verb")
    var title: String
    @Guide(description: "Task category", .anyOf(Planner.categories))
    var category: String
    @Guide(description: "Realistic minutes a typical student needs for the whole item", .range(5...240))
    var minutes: Int
    @Guide(description: "Which day of the plan to do it on, starting at 1", .range(1...30))
    var day: Int
    @Guide(description: "high only if the user marked this item urgent, important, \"!\" or due today or tomorrow; low if they said it can wait; otherwise normal. A deadline for the whole goal is not a reason for high.",
           .anyOf(Planner.priorities))
    var priority: String
    @Guide(description: "Steps for a big piece of work (essay, project, revision, a long homework, a study-material section): 2 to 5 steps. Empty for a quick, simple job.",
           .count(0...5))
    var subtasks: [DraftStep]
}

@Generable struct DraftStep {
    @Guide(description: "Short, concrete action starting with a verb")
    var title: String
    @Guide(description: "Realistic minutes a typical student needs for this step", .range(5...120))
    var minutes: Int
}

enum Planner {
    static let categories = ["homework", "study", "revision", "reading", "writing",
                             "project", "chores", "exercise", "other"]

    static let priorities = ["high", "normal", "low"]

    static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    /// Shared by the first draft and the follow-up asks (dropped lines, thin plans).
    /// Kept short: it shares the small context window with the prompt and the answer.
    static let instructions = """
        You help a student or teenager plan their work. Turn each thing the user asked for \
        into one item. Use only what the user wrote: never add a task they didn't ask for. \
        Quick jobs (a small errand or chore) take 5 to 20 minutes with no subtasks. Big work (an essay, a project, exam revision, \
        a long homework) or anything over 60 minutes gets 2 to 5 subtasks of 20 to 90 minutes. \
        Estimate like a typical secondary or junior college student: a tutorial or worksheet \
        45 to 90 minutes, studying for a test 60 to 120, an essay draft 90 to 180, reading a \
        chapter 30 to 60. Use any time the user gives. Skill practice (an instrument, \
        vocabulary, a sport) is 15 to 45 minutes a session. \
        Slang: "mug" is study hard, "tys" is past-year papers, "pw" is Project Work, "cca" is \
        a school club. Exercise: at most one 20 to 60 minute session a day, and a rest day at \
        least every third day. \
        Never leave out anything the user asked for. Spread work evenly across all the days, \
        within each day's free time. \
        Priority is high only if the user marked that thing urgent, important, "!" or due \
        today or tomorrow; low only if they said it can wait or maybe; otherwise normal. \
        If study material is given, make one item per section, in order, titled with its \
        short name, with its tasks as subtasks.
        """

    /// Splits the plan's input into tasks. `previous` is the plan the student
    /// rejected with "Start over": the AI is asked for a genuinely different one.
    /// `history`: answered check-ins, so the plan fits how tasks really feel to them.
    @MainActor static func draft(for plan: Plan, previous: [PlanTask] = [], history: [PlanTask] = []) async throws -> DraftPlan {
        guard !isVague(plan.input), plan.mode == .goal || !items(plan.input).isEmpty else { throw PlannerError.vague }
        guard plan.mode == .today || !needsList(plan.input) || !materialTopics(plan.materials).isEmpty else { throw PlannerError.list }
        if plan.mode == .today, let line = passedTime(items(plan.input), start: plan.start) { throw PlannerError.passed(line) }
        var session = LanguageModelSession(instructions: instructions)
        let topics = plan.mode == .goal ? goalTopics(plan.input) : []
        let sections = plan.mode == .goal ? materialTopics(plan.materials) : []
        var prompt = switch plan.mode {
        case .today:
            """
            Tidy this messy to-do list into items for day 1. Every line must become an item. \
            Only merge exact duplicates. Set day to 1 for every item.

            \(items(plan.input).map { "- " + $0 }.joined(separator: "\n"))
            """
        case .goal:
            """
            Goal: \(plan.input)
            Spread the items over days 1 to \(plan.days), earlier steps first. \
            The goal must be done by the end of day \(plan.days).
            """ + (topics.isEmpty ? "" : "\nThe goal has \(topics.count) parts. Give every part at least one item, none left out:\n"
                + topics.map { "- " + cleanTopic($0) }.joined(separator: "\n"))
        }
        prompt += "\n\nFree time:\n" + freeTime(for: plan)
        // ponytail: the on-device model has a small context window; long material is cut,
        // upgrade by drafting one section at a time if students paste whole chapters.
        let material = plan.materials.trimmingCharacters(in: .whitespacesAndNewlines)
        if !material.isEmpty { prompt += "\n\nStudy material:\n" + material.prefix(6000) }
        let lean = prompt   // what a retry keeps when the context fills up
        prompt += examples(for: plan.input + " " + material.prefix(2000))
        prompt += paceNote()
        prompt += Reflections.promptNote(history)

        var options = GenerationOptions()
        var rejected = ""
        if !previous.isEmpty {
            let old = previous.map { "- \($0.parent.isEmpty ? "" : $0.parent + ": ")\($0.title) (\($0.minutes) min, day \($0.day))" }.joined(separator: "\n")
            rejected = """


                The student didn't like this plan and wants a different one:
                \(old)
                Make a genuinely different alternative that still covers everything: break \
                the work down differently (bigger or smaller chunks, a different study method \
                such as practice questions, flashcards or summaries), group or order it \
                differently, and use different task names. Don't repeat the plan above.
                """
            prompt += rejected
            options = GenerationOptions(samplingMode: .random(probabilityThreshold: 0.9), temperature: 1.0)
        }
        do {
            var draft: DraftPlan
            do {
                draft = try await session.respond(to: prompt, generating: DraftPlan.self, options: options).content
            } catch LanguageModelError.contextSizeExceeded {
                // Short inputs hit this too, when an answer runs away: one fresh try with
                // the optional extras (saved examples, pace, reflections) left out.
                session = LanguageModelSession(instructions: instructions)
                draft = try await session.respond(to: lean + rejected, generating: DraftPlan.self,
                                                  options: GenerationOptions(samplingMode: .random(probabilityThreshold: 0.9), temperature: 0.7)).content
            }
            if plan.mode == .today {
                let restored = reconcile(items(plan.input), in: &draft)
                if !restored.isEmpty { await refill(restored, in: &draft) }
                await addSteps(to: &draft)
            } else {
                if let floor = effortFloor(draft, days: plan.days) {
                    // Same session, so the model sees its own thin plan and the goal.
                    let ask = """
                        That plan has only \(totalMinutes(draft)) minutes of work over \(plan.days) days, \
                        too little for this goal. Make a fuller plan for the same goal with about \
                        \(floor) to \(floor * 2) minutes in total: more steps that fit this goal, each \
                        under 90 minutes, spread over days 1 to \(plan.days).
                        """
                    if let more = try? await session.respond(to: ask, generating: DraftPlan.self, options: options).content,
                       totalMinutes(more) > totalMinutes(draft) {
                        draft = more
                    }
                }
                for i in draft.items.indices { draft.items[i].day = min(max(draft.items[i].day, 1), max(plan.days, 1)) }
                cover(topics, goal: plan.input, days: plan.days, in: &draft)
                cover(sections, goal: plan.input, days: plan.days, inOrder: true, in: &draft)
                spread(&draft, days: plan.days)
                goalPriorities(topics, goal: plan.input, in: &draft)
                await addSteps(to: &draft)
            }
            return tidied(draft)
        } catch {
            throw friendly(error)
        }
    }

    /// The to-do dump as separate items. The model skips items in long comma lists,
    /// but keeps them reliably one per line.
    static func items(_ input: String) -> [String] {
        lines(input).filter { !distressed($0) && !venting($0) }
    }

    static func lines(_ input: String) -> [String] {
        input.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-•*"))) }
            .filter { !$0.isEmpty }
    }

    /// A feeling, not a task ("ugh so tired", "i hate chem"): a feeling word and
    /// nothing to do. Any work word keeps the line ("tired but must finish essay").
    // ponytail: word lists; unknown venting slips through as a task the student can delete.
    static func venting(_ line: String) -> Bool {
        let tokens = line.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter }).map(String.init)
        let feelings: Set<String> = ["ugh", "urgh", "argh", "sigh", "hate", "tired", "sian", "stressed", "stressing",
                                     "bored", "sleepy", "exhausted", "annoyed", "sad", "angry", "fml", "lazy",
                                     "dead", "dying", "why", "help", "cannot", "cant", "omg", "sucks", "depressed"]
        let work = ["hw", "homework", "worksheet", "tutorial", "essay", "revis", "study", "studie", "finish", "do",
                    "read", "writ", "submit", "practi", "tys", "test", "exam", "project", "pw", "assignment", "notes",
                    "quiz", "prep", "complet", "start", "call", "buy", "pay", "pack", "wash", "clean", "tidy",
                    "reply", "email", "send", "go", "run", "gym", "train", "make", "fix", "book", "return", "cook",
                    "review", "learn", "memori", "paper", "lab", "report", "present", "slides", "chapter", "ch",
                    "cca", "tuition", "lesson", "class", "meet", "walk", "swim", "feed", "visit", "plan", "draw"]
        guard tokens.contains(where: feelings.contains) else { return false }
        return !tokens.contains { t in work.contains { t == $0 || ($0.count >= 3 && t.hasPrefix($0)) } }
    }

    /// Words that sound like the student is really struggling ("i want to die lol
    /// this week is too much"). Those lines are never scheduled as tasks, and New
    /// Plan shows a support note instead.
    // ponytail: phrase list, not a classifier; misses indirect wording, errs towards showing the note.
    static func distressed(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let phrases = ["want to die", "wanna die", "kill myself", "suicid", "self harm", "self-harm", "hurt myself",
                       "end my life", "end it all", "don't want to live", "dont want to live", "no reason to live",
                       "cut myself", "better off dead", "better off without me"]
        return phrases.contains(where: t.contains)   // not "kms": that's also "run 5 kms"
    }

    /// The model's errors in words a student can act on.
    static func friendly(_ error: Error) -> Error {
        switch error {
        case LanguageModelError.contextSizeExceeded: PlannerError.tooLong
        case LanguageModelError.guardrailViolation, LanguageModelError.refusal: PlannerError.blocked
        case LanguageModelError.unsupportedLanguageOrLocale: PlannerError.language
        case LanguageModelError.rateLimited: PlannerError.busy
        case let e as LanguageModelSession.GenerationError:
            switch e {
            case .exceededContextWindowSize: PlannerError.tooLong
            case .guardrailViolation, .refusal: PlannerError.blocked
            case .unsupportedLanguageOrLocale: PlannerError.language
            case .rateLimited, .concurrentRequests: PlannerError.busy
            default: error
            }
        default: error
        }
    }

    /// Fixes what the small model gets wrong with to-do lists: it drops items and
    /// ignores "urgent". Each line's priority words win; a dropped line comes back
    /// as its own 30-minute task. Each line needs its own item: "GP essay" and
    /// "econs essay" share a word, but one model item can't stand in for both.
    /// Lines with the same words are duplicates. Returns the restored items' indices.
    // ponytail: word-overlap match; a dropped item sharing a word with an unclaimed task
    // ("clean room" vs "tidy room") counts as kept. Fine for to-do lists.
    @discardableResult
    static func reconcile(_ lines: [String], in draft: inout DraftPlan) -> [Int] {
        var restored: [Int] = []
        var claimed = Set<Int>()
        var seen: [Set<String>: Int] = [:]   // a line's words → the item it matched
        for line in lines {
            let key = lineKey(line)
            guard !key.isEmpty else { continue }
            let marked = marker(line)
            if let i = seen[key] {   // a duplicate line: a mark on either counts
                if let marked { draft.items[i].priority = marked }
                continue
            }
            let overlap = draft.items.map { lineKey($0.title).intersection(key).count }
            let match = overlap.indices.filter { !claimed.contains($0) && overlap[$0] > 0 }
                .max { overlap[$0] < overlap[$1] }
            let i: Int
            if let match {
                i = match
                draft.items[i].priority = marked ?? "normal"   // the model marks unmarked work high
                // "econs essay" matched "Draft essay introduction" on "essay": put back the
                // word that tells it apart from the other lines.
                let others = lines.filter { words($0) != key }.reduce(into: Set<String>()) { $0.formUnion(words($1)) }
                let subject = words(cleanTopic(line)).subtracting(others)
                let title = words(draft.items[i].title)
                if !subject.isEmpty, !subject.contains(where: { s in title.contains { similar(s, $0) } }) {
                    draft.items[i].title = studentTitle(line)
                }
            } else {
                draft.items.append(DraftItem(title: line.prefix(1).uppercased() + line.dropFirst(),
                                             category: "other", minutes: 30, day: 1,
                                             priority: marked ?? "normal", subtasks: []))
                i = draft.items.count - 1
                restored.append(i)
            }
            claimed.insert(i)
            seen[key] = i
        }
        // Items matching no line are the model's own ideas, often copied from the
        // instructions' examples ("tidy room" for a list that never said it): drop them.
        let kept = draft.items.indices.filter(claimed.contains)
        draft.items = kept.map { draft.items[$0] }
        return restored.compactMap { kept.firstIndex(of: $0) }
    }

    /// What tells a to-do line apart: its words plus any numbers ("read ch 4" vs
    /// "read ch 5" aren't duplicates), or its short words when it has nothing else
    /// ("hw", "pe"). Empty for a line of only numbers or symbols.
    static func lineKey(_ s: String) -> Set<String> {
        let tokens = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var key = words(s)
        if key.isEmpty { key = Set(tokens.filter { $0.first?.isLetter == true }) }
        return key.isEmpty ? [] : key.union(tokens.filter { $0.allSatisfy(\.isNumber) })
    }

    /// Input with nothing concrete in it ("tasks", "get my stuff done today"). The
    /// model fills those with tasks from its instructions, so ask the student instead.
    static func isVague(_ input: String) -> Bool {
        let filler: Set<String> = ["tasks", "task", "stuff", "things", "thing", "todo", "todos", "to", "do",
                                   "list", "get", "my", "i", "need", "have", "want", "gotta", "done", "finish",
                                   "all", "everything", "some", "the", "a", "and", "of", "for", "it", "work",
                                   "plan", "today", "tonight", "tomorrow", "this", "week", "day"]
        return input.lowercased().split(whereSeparator: { !$0.isLetter }).allSatisfy { filler.contains(String($0)) }
    }

    /// "Revise every subject for O levels" with no list: the model picks two subjects.
    /// Ask which ones, so the goal-topics net can cover each.
    /// Same for an exam goal that never names a subject ("revise for my exam", "study for O levels").
    static func needsList(_ goal: String) -> Bool {
        guard goalTopics(goal).isEmpty else { return false }
        if goal.contains(/(?i)\b(every|each|all)(\s+(my|the|of my|of the))?\s+(subjects?|topics?|chapters?|modules?|units?)\b/) { return true }
        let exam: Set<String> = ["exam", "exams", "test", "tests", "quiz", "paper", "papers", "prelims", "finals",
                                 "levels", "level", "o", "n", "eoy", "wa", "sa", "ca", "midyear", "common"]
        let filler: Set<String> = ["revise", "revision", "study", "prepare", "prep", "for", "my", "the", "a", "an",
                                   "i", "need", "to", "upcoming", "next", "final", "mid", "year", "end", "of",
                                   "school", "all", "get", "ready", "pass", "do", "well", "in", "and", "this", "week"]
        let tokens = goal.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return tokens.contains(where: exam.contains) && tokens.allSatisfy { exam.contains($0) || filler.contains($0) }
    }

    /// A to-do line whose time has already gone by today ("bake at 9am" at 4 PM).
    static func passedTime(_ lines: [String], start: Date, calendar: Calendar = .current) -> String? {
        lines.first { clockTime($0, after: calendar.startOfDay(for: start), calendar: calendar) != nil
            && clockTime($0, after: start, calendar: calendar) == nil }
    }

    /// A time the student wrote in a line ("tuition at 7pm", "cca 3:30", "@8"), as the
    /// next such time on `start`'s day at or after `start`. Bare hours ("at 7") are
    /// 7 AM or 7 PM, whichever comes first. Nil when there's no time or it's passed.
    static func clockTime(_ line: String, after start: Date, calendar: Calendar = .current) -> Date? {
        for m in line.matches(of: /(?i)(\bat\s+|@\s*)?\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b/) {
            guard m.1 != nil || m.3 != nil || m.4 != nil, let h = Int(m.2), h <= 23,
                  let minute = Int(m.3 ?? "0"), minute < 60 else { continue }
            let hours: [Int] = switch m.4?.lowercased() ?? "" {
            case "pm": h < 12 ? [h + 12] : [h]
            case "am": [h % 12]
            default: h >= 1 && h <= 11 ? [h, h + 12] : [h]
            }
            return hours.compactMap { calendar.date(bySettingHour: $0, minute: minute, second: 0, of: start) }
                .first { $0 >= start }
        }
        return nil
    }

    /// Which draft item each timed line belongs to (by shared words), and its time.
    // ponytail: word overlap like `reconcile`; a timed line the model renamed beyond recognition stays unpinned.
    static func pins(_ lines: [String], titles: [String], after start: Date, calendar: Calendar = .current) -> [Int: Date] {
        let skip: Set<String> = ["at", "am", "pm", "to", "do", "go", "my", "in", "on", "the", "and", "for"]
        let tokens = { (s: String) in Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)).subtracting(skip) }
        var pins: [Int: Date] = [:]
        for line in lines {
            guard let at = clockTime(line, after: start, calendar: calendar) else { continue }
            let key = tokens(line)
            let score = titles.map { title in tokens(title).filter { t in key.contains { similar(t, $0) } }.count }
            if let i = score.indices.filter({ pins[$0] == nil && score[$0] > 0 }).max(by: { score[$0] < score[$1] }) {
                pins[i] = at
            }
        }
        return pins
    }

    /// A second, smaller ask for the lines the model dropped, so they get real estimates
    /// instead of 30-minute placeholders. The student's priority stays; on failure the
    /// placeholders stay too.
    @MainActor static func refill(_ restored: [Int], in draft: inout DraftPlan) async {
        // Without "can wait" or "maybe": the model reads those as leave-it-out.
        let lines = restored.map { cleanTopic(draft.items[$0].title) }
        let prompt = """
            Make one item for each of these to-do lines, in this order, all for day 1. \
            Keep each line's meaning; don't merge or skip any.

            \(lines.map { "- " + $0 }.joined(separator: "\n"))
            """
        guard let extra = try? await LanguageModelSession(instructions: instructions)
            .respond(to: prompt, generating: DraftPlan.self).content else { return }
        fill(restored, in: &draft, from: extra.items)
    }

    /// Puts the follow-up's estimates into the placeholders: by shared words first, then
    /// the rest in order if exactly as many are left on both sides.
    // ponytail: a restored line the follow-up doesn't answer stays a 30-minute placeholder.
    static func fill(_ restored: [Int], in draft: inout DraftPlan, from extra: [DraftItem]) {
        var taken = Set<Int>()
        var left: [Int] = []
        for i in restored {
            let line = words(draft.items[i].title)
            let score = extra.map { words($0.title).intersection(line).count }
            guard let j = score.indices.filter({ !taken.contains($0) && score[$0] > 0 }).max(by: { score[$0] < score[$1] }) else {
                left.append(i)
                continue
            }
            taken.insert(j)
            use(extra[j], for: i, in: &draft)
        }
        let rest = extra.indices.filter { !taken.contains($0) }
        guard rest.count == left.count else { return }
        for (i, j) in zip(left, rest) { use(extra[j], for: i, in: &draft) }
    }

    /// Big items the model left as one block (a 2-hour essay draft) get steps from one
    /// small follow-up ask, scaled to the item's minutes. Nothing changes if it fails.
    @MainActor static func addSteps(to draft: inout DraftPlan) async {
        let big = draft.items.indices.filter { i in
            let item = draft.items[i]
            return item.subtasks.isEmpty && item.minutes > 60 && !["chores", "exercise"].contains(item.category)
        }
        guard !big.isEmpty else { return }
        let prompt = """
            Break each of these into 2 to 4 steps a student can tick off one by one. \
            One item per line below, with the same title, in this order:

            \(big.map { "- \(draft.items[$0].title) (\(draft.items[$0].minutes) min)" }.joined(separator: "\n"))
            """
        guard let answer = try? await LanguageModelSession(instructions: instructions)
            .respond(to: prompt, generating: DraftPlan.self).content else { return }
        steps(big, in: &draft, from: answer.items)
    }

    /// Copies the follow-up's steps onto the big items (by title, or in order when the
    /// counts match), scaled so they still add up to the item's minutes. For a single
    /// big item the model often answers with the steps as items, not subtasks.
    static func steps(_ big: [Int], in draft: inout DraftPlan, from answer: [DraftItem]) {
        if big.count == 1, answer.count >= 2, answer.allSatisfy({ $0.subtasks.isEmpty }) {
            setSteps(answer.map { DraftStep(title: $0.title, minutes: $0.minutes) }, on: big[0], in: &draft)
            return
        }
        var taken = Set<Int>()
        for (n, i) in big.enumerated() {
            let title = words(draft.items[i].title)
            let score = answer.map { words($0.title).intersection(title).count }
            let byTitle = score.indices.filter { !taken.contains($0) && score[$0] > 0 }.max { score[$0] < score[$1] }
            guard let j = byTitle ?? (answer.count == big.count && !taken.contains(n) ? n : nil),
                  answer[j].subtasks.count >= 2 else { continue }
            taken.insert(j)
            setSteps(answer[j].subtasks, on: i, in: &draft)
        }
    }

    private static func setSteps(_ steps: [DraftStep], on i: Int, in draft: inout DraftPlan) {
        let sum = max(steps.map(\.minutes).reduce(0, +), 1)
        let total = draft.items[i].minutes
        draft.items[i].subtasks = steps.prefix(5).map { step in
            DraftStep(title: step.title, minutes: max(5, Int((Double(step.minutes * total) / Double(sum)).rounded())))
        }
    }

    /// The student's own line as a title, without "can wait", "!" and the like.
    static func studentTitle(_ line: String) -> String {
        let clean = cleanTopic(line)
        return clean.prefix(1).uppercased() + clean.dropFirst()
    }

    /// Takes the follow-up's estimate, keeping the student's wording as the title: the
    /// model's title can lose the subject ("Draft essay outline" for "econs essay").
    private static func use(_ found: DraftItem, for i: Int, in draft: inout DraftPlan) {
        draft.items[i].title = studentTitle(draft.items[i].title)
        draft.items[i].category = found.category
        draft.items[i].minutes = found.minutes
        draft.items[i].subtasks = found.subtasks
    }

    /// Lowercased words of 3+ letters, minus filler, for loose matching.
    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count >= 3 && !["the", "and", "for", "with", "due", "tmr"].contains($0) })
    }

    /// Chores and one-step items stay as a single task: no subtasks. An exercise
    /// session is at most an hour (the model plans 2-hour runs for beginners).
    static func tidied(_ draft: DraftPlan) -> DraftPlan {
        var draft = draft
        for i in draft.items.indices where draft.items[i].category == "chores" || draft.items[i].subtasks.count < 2 {
            draft.items[i].subtasks = []
        }
        for i in draft.items.indices where draft.items[i].category == "exercise" {
            draft.items[i].minutes = min(draft.items[i].minutes, 60)
            let steps = draft.items[i].subtasks.map(\.minutes).reduce(0, +)
            for j in draft.items[i].subtasks.indices where steps > 60 {
                draft.items[i].subtasks[j].minutes = max(5, draft.items[i].subtasks[j].minutes * 60 / steps)
            }
        }
        return draft
    }

    /// "Day 1 (Wed 11 Nov, from 4:30 PM): about 3 h 15 min free", from the routine
    /// and Calendar, so estimates and spreading fit the student's real days.
    @MainActor static func freeTime(for plan: Plan) -> String {
        let cal = Calendar.current
        let first = cal.startOfDay(for: plan.start)
        let busy = CalendarSync.busy(from: plan.start, days: plan.days, excluding: Set(plan.tasks.compactMap(\.eventID)))
        // ponytail: lists at most 14 days to save context; later days follow the same pattern.
        return (0..<min(max(plan.days, 1), 14)).compactMap { i -> String? in
            guard let day = cal.date(byAdding: .day, value: i, to: first) else { return nil }
            let free = plan.routine.windows(on: day, calendar: cal)
                .flatMap { Scheduler.free($0, minus: busy) }
                .compactMap { w -> Range<Date>? in
                    let s = max(w.lowerBound, plan.start)
                    return s < w.upperBound ? s..<w.upperBound : nil
                }
            let minutes = Int(free.reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) } / 60)
            let from = i == 0 ? ", from \(plan.start.formatted(date: .omitted, time: .shortened))" : ""
            return "Day \(i + 1) (\(day.formatted(.dateTime.weekday().day().month()))\(from)): about \(minutes / 60) h \(minutes % 60) min free"
        }.joined(separator: "\n")
    }
}

extension Planner {
    /// Re-plan with AI: the student is behind, so rebuild what's left.
    @MainActor static func replan(_ plan: Plan) async throws -> DraftPlan {
        let left = plan.ordered.filter { !$0.done }.map { t in
            "- \(t.title) (\(t.minutes) min, \(priorities[min(max(t.priority, 0), 2)]) priority"
                + (t.parent.isEmpty ? ")" : ", part of: \(t.parent))")
        }
        let cal = Calendar.current
        let elapsed = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: plan.start), to: cal.startOfDay(for: .now)).day ?? 0)
        let daysLeft = max(1, plan.days - elapsed)
        let when = plan.mode == .today || daysLeft == 1
            ? "Fit them into the rest of today; set day to 1 for every task."
            : "Spread them over the next \(daysLeft) days, starting today as day 1."
        let session = LanguageModelSession(instructions: """
            You help a student who is running behind on their plan. Rebuild a realistic plan \
            for their remaining tasks. Keep every high-priority task. You may merge small \
            tasks, shorten or split long ones, and reorder them, but don't invent new work. \
            Keep each task's priority. Tasks that are part of the same thing go back together \
            as the subtasks of one item titled with that name; other tasks are items with no subtasks.
            """)
        let prompt = """
            It is now \(Date.now.formatted(date: .omitted, time: .shortened)). Remaining tasks:
            \(left.joined(separator: "\n"))

            \(when)
            """
        do {
            return tidied(try await session.respond(to: prompt, generating: DraftPlan.self).content)
        } catch {
            throw friendly(error)
        }
    }
}

/// Adaptive subtasks: the breakdowns the student writes themselves are saved and
/// shown to the AI as examples next time a similar item comes up.
extension Planner {
    struct Example: Codable, Equatable {
        var item: String
        var steps: [String]   // "Outline essay (20 min)"
    }

    private static let examplesKey = "subtaskExamples"

    // ponytail: last 40 breakdowns as JSON in UserDefaults; move to SwiftData if it needs to grow.
    static func remember(item: String, steps: [(title: String, minutes: Int)]) {
        var all = savedExamples().filter { $0.item.lowercased() != item.lowercased() }
        all.append(Example(item: item, steps: steps.map { "\($0.title) (\($0.minutes) min)" }))
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(all.suffix(40))), forKey: examplesKey)
    }

    static func savedExamples() -> [Example] {
        UserDefaults.standard.data(forKey: examplesKey)
            .flatMap { try? JSONDecoder().decode([Example].self, from: $0) } ?? []
    }

    /// Up to 3 saved breakdowns sharing words with `text` (most overlap, then newest),
    /// as a prompt section; empty when none match.
    static func examples(for text: String, from saved: [Example] = savedExamples()) -> String {
        let wanted = words(text)
        let matches = saved.reversed().enumerated()
            .map { (rank: words($0.element.item).intersection(wanted).count, age: $0.offset, example: $0.element) }
            .filter { $0.rank > 0 }
            .sorted { ($0.rank, -$0.age) > ($1.rank, -$1.age) }
            .prefix(3)
        guard !matches.isEmpty else { return "" }
        return "\n\nThis student has broken down similar work like this before. For matching items, use the same kind of steps and durations:\n"
            + matches.map { "- \($0.example.item): " + $0.example.steps.joined(separator: "; ") }.joined(separator: "\n")
    }
}

/// Adaptive estimates: each finished AI-estimated task saves actual ÷ estimate
/// for its category, and the typical ratio goes into the prompt.
extension Planner {
    private static let paceKey = "paceRatios"

    // ponytail: last 20 ratios per category as JSON in UserDefaults; enough to track a pace.
    static func recordPace(category: String, estimate: Int, actual: Int) {
        guard estimate > 0 else { return }
        var all = savedPace()
        all[category, default: []].append(Double(actual) / Double(estimate))
        all[category] = Array(all[category]!.suffix(20))
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: paceKey)
    }

    /// The student corrected a recorded time in the check-in: swap that ratio.
    static func correctPace(category: String, estimate: Int, from old: Int, to new: Int) {
        guard estimate > 0 else { return }
        var all = savedPace()
        if let i = all[category]?.lastIndex(of: Double(old) / Double(estimate)) {
            all[category]![i] = Double(new) / Double(estimate)
            UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: paceKey)
        } else {
            recordPace(category: category, estimate: estimate, actual: new)
        }
    }

    static func savedPace() -> [String: [Double]] {
        UserDefaults.standard.data(forKey: paceKey)
            .flatMap { try? JSONDecoder().decode([String: [Double]].self, from: $0) } ?? [:]
    }

    static func resetPace() { UserDefaults.standard.removeObject(forKey: paceKey) }

    /// Finished tasks a category needs before its pace counts: a longer runway,
    /// so a couple of odd tasks (or students tweaking times) don't skew it.
    static let paceRunway = 5

    /// Median actual ÷ estimate per category with `paceRunway`+ finished tasks.
    static func pace(from saved: [String: [Double]] = savedPace()) -> [(category: String, ratio: Double, count: Int)] {
        saved.filter { $0.value.count >= paceRunway }.map { category, ratios in
            let sorted = ratios.sorted()
            let mid = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            return (category, median, ratios.count)
        }.sorted { $0.category < $1.category }
    }

    /// Prompt section for categories where the student is 10%+ off the estimates;
    /// empty when they match. Spells out an example so the small model can scale.
    static func paceNote(from saved: [String: [Double]] = savedPace()) -> String {
        let off = pace(from: saved).filter { abs($0.ratio - 1) >= 0.1 }
        guard !off.isEmpty else { return "" }
        return "\n\nThis student's real pace from past tasks. Scale your estimates for these categories:\n"
            + off.map { p in
                let example = Int((30 * p.ratio / 5).rounded()) * 5
                return "- \(p.category): takes \(p.ratio > 1 ? "longer" : "less time") than typical, ×\(p.ratio.formatted(.number.precision(.fractionLength(1)))) (a typical 30 min \(p.category) task takes them about \(max(5, example)) min)"
            }.joined(separator: "\n")
    }
}

/// Goal mode safety net, like `reconcile` for to-do lists: the small model drops parts
/// of a multi-part goal ("organic, equilibrium and electrochemistry") and marks almost
/// every step high because the goal has a deadline.
extension Planner {
    /// Parts of a goal listed after a colon or with commas; empty for a one-part goal
    /// like "run 5 km" or "clean and organise my room".
    static func goalTopics(_ goal: String) -> [String] {
        let text: String
        if let colon = goal.firstIndex(of: ":") { text = String(goal[goal.index(after: colon)...]) }
        else if goal.contains(where: { ",;\n".contains($0) }) { text = goal }
        else { return [] }
        let parts = text.replacing(/(?i)\s+(and|&)\s+/, with: ",")
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".-•*"))) }
            .filter { !words(cleanTopic($0)).isEmpty }
        return parts.count >= 2 ? parts : []
    }

    /// The topic without the student's priority words: "chemistry is urgent" → "chemistry".
    static func cleanTopic(_ topic: String) -> String {
        topic.replacing(/(?i)\b(is\s+)?(urgent|important|asap|can wait|later|maybe|if time)\b|!+/, with: "")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "!", urgent… → high; can wait, maybe… → low. `strict` leaves out "due", which in a
    /// goal is the whole goal's deadline, not this part's urgency.
    static func marker(_ line: String, strict: Bool = false) -> String? {
        let lower = line.lowercased()
        let high = strict ? ["urgent", "asap", "important"] : ["urgent", "asap", "due", "important"]
        if line.contains("!") || high.contains(where: lower.contains) { return "high" }
        if ["can wait", "later", "maybe", "if time"].contains(where: lower.contains) { return "low" }
        return nil
    }

    private static let studyWords: Set<String> = ["revise", "revision", "study", "learn", "practise", "practice",
                                                  "exam", "exams", "test", "tests", "chapter", "topic", "topics",
                                                  "section", "unit", "finish",
                                                  "work", "notes", "questions", "can", "wait", "urgent", "important",
                                                  "asap", "later", "maybe", "time"]

    /// Words that pick out this topic: not in the goal's lead ("Revise for my Chemistry
    /// exam:"), not shared with the other topics, not generic study words.
    static func keyWords(_ topic: String, among topics: [String], goal: String) -> Set<String> {
        let lead = goal.firstIndex(of: ":").map { words(String(goal[..<$0])) } ?? []
        let others = topics.filter { $0 != topic }.reduce(into: Set<String>()) { $0.formUnion(words($1)) }
        let keys = words(topic).subtracting(lead).subtracting(others).subtracting(studyWords)
        return keys.isEmpty ? words(topic).subtracting(studyWords) : keys
    }

    /// Same word, the same stem (electrochemistry ~ electrochemical, equilibrium ~ equilibria)
    /// or a short form of 4+ letters (chem ~ chemistry, math ~ mathematics).
    static func similar(_ a: String, _ b: String) -> Bool {
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return a == b || a.commonPrefix(with: b).count >= max(5, short.count - 3)
            || (short.count >= 4 && long.hasPrefix(short))
    }

    static func covers(_ keys: Set<String>, _ item: DraftItem) -> Bool {
        let text = words(([item.title] + item.subtasks.map(\.title)).joined(separator: " "))
        return keys.contains { key in text.contains { similar(key, $0) } }
    }

    static func minutes(_ item: DraftItem) -> Int {
        item.subtasks.isEmpty ? item.minutes : item.subtasks.map(\.minutes).reduce(0, +)
    }

    private static let leadingVerbs: Set<String> = ["read", "write", "do", "finish", "revise", "practise", "practice",
                                                    "learn", "complete", "prepare", "submit", "study", "make", "plan",
                                                    "review", "memorise", "memorize"]

    /// Pasted study material, one section per line ("Section 3: Carbonyls - HCN, Tollens'"),
    /// for the same safety net; empty unless there are 2 to 15 short lines (pasted notes
    /// with long paragraphs aren't a section list).
    static func materialTopics(_ material: String) -> [String] {
        let lines = material.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !words($0).isEmpty }
        return (2...15).contains(lines.count) && lines.allSatisfy({ $0.count <= 150 }) ? lines : []
    }

    /// "Section 3: Carbonyls - HCN, Tollens' tests" → "Section 3: Carbonyls".
    static func shortName(_ topic: String) -> String {
        let cut = topic.range(of: " - ") ?? topic.range(of: " – ") ?? topic.range(of: " — ")
        return cut.map { String(topic[..<$0.lowerBound]) } ?? topic
    }

    /// Adds an item for each goal topic the model left out: typical length for this plan,
    /// on its lightest day, slotted in by day so the schedule keeps the days in order.
    /// `inOrder` (study sections): right after the item for the section before it instead.
    static func cover(_ topics: [String], goal: String, days: Int, inOrder: Bool = false, in draft: inout DraftPlan) {
        for (k, topic) in topics.enumerated() {
            let keys = keyWords(topic, among: topics, goal: goal)
            guard !keys.isEmpty, !draft.items.contains(where: { covers(keys, $0) }) else { continue }
            let lengths = draft.items.map(minutes).sorted()
            let length = lengths.isEmpty ? 45 : lengths[lengths.count / 2]
            let category = Dictionary(grouping: draft.items, by: \.category)
                .max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key ?? "study"
            var load: [Int: Int] = [:]
            for item in draft.items { load[item.day, default: 0] += minutes(item) }
            var day = (1...max(days, 1)).min { (load[$0] ?? 0, $0) < (load[$1] ?? 0, $1) } ?? 1
            var at: Int?
            if inOrder {
                let earlier = topics.prefix(k).map { keyWords($0, among: topics, goal: goal) }
                let previous = draft.items.lastIndex { item in earlier.contains { covers($0, item) } }
                at = previous.map { $0 + 1 } ?? 0
                day = previous.map { draft.items[$0].day } ?? 1
            }
            let name = cleanTopic(shortName(topic))
            let first = name.split(separator: " ").first.map { $0.lowercased() } ?? ""
            let title = leadingVerbs.contains(first) ? name.prefix(1).uppercased() + name.dropFirst()
                : "\(["revision": "Revise", "study": "Revise", "reading": "Read", "writing": "Write"][category] ?? "Work on") \(name)"
            let item = DraftItem(title: title, category: category, minutes: min(max(length, 5), 240),
                                 day: day, priority: "normal", subtasks: [])
            draft.items.insert(item, at: at ?? draft.items.lastIndex(where: { $0.day <= day }).map { $0 + 1 } ?? 0)
        }
    }

    static func totalMinutes(_ draft: DraftPlan) -> Int { draft.items.map(minutes).reduce(0, +) }

    private static let deskWork: Set<String> = ["homework", "study", "revision", "reading", "writing", "project"]

    /// Minutes a study goal over 2+ days should have at least (50 a day); nil when the plan
    /// already has that much, or the goal isn't desk work (a run, tidying a room).
    static func effortFloor(_ draft: DraftPlan, days: Int) -> Int? {
        guard days >= 2, !draft.items.isEmpty else { return nil }
        let study = draft.items.filter { deskWork.contains($0.category) }.count
        guard study * 2 > draft.items.count else { return nil }
        let floor = 50 * days
        return totalMinutes(draft) < floor ? floor : nil
    }

    /// The small model packs a long goal into its first day or two. When it uses half the
    /// days or fewer, items move to the day where their share of the work starts, in order.
    static func spread(_ draft: inout DraftPlan, days: Int) {
        let used = Set(draft.items.map(\.day)).count
        guard days > 1, used < min(days, draft.items.count), used * 2 <= days else { return }
        let total = max(totalMinutes(draft), 1)
        var before = 0
        for i in draft.items.indices {
            draft.items[i].day = min(days, 1 + before * days / total)
            before += minutes(draft.items[i])
        }
    }

    /// Goal priorities come only from words the student wrote next to a part
    /// ("chemistry is urgent, history can wait"); everything else is normal.
    static func goalPriorities(_ topics: [String], goal: String, in draft: inout DraftPlan) {
        for i in draft.items.indices { draft.items[i].priority = "normal" }
        for topic in topics {
            guard let marked = marker(topic, strict: true) else { continue }
            let keys = keyWords(topic, among: topics, goal: goal)
            for i in draft.items.indices where covers(keys, draft.items[i]) { draft.items[i].priority = marked }
        }
    }
}

enum PlannerError: LocalizedError {
    case tooLong, vague, blocked, language, busy, list, passed(String)

    /// The plan needs one more detail from the student: New Plan shows it as a
    /// question under the input instead of a red error. Not a chat: they edit and retry.
    var isQuestion: Bool {
        switch self { case .vague, .list, .passed: true; default: false }
    }

    var errorDescription: String? {
        switch self {
        case .list: "Which subjects or topics? List them after a colon, like \"Revise for O levels: maths, chemistry, English\", so none get left out."
        case .passed(let line): "\"\(line)\": that time has already passed today. Change the time, or remove it and it'll be fitted in anywhere."
        case .blocked: "Apple's on-device AI wouldn't plan this. Its safety filter sometimes flags normal schoolwork, like history or biology topics. Try different words, or add the tasks yourself with + in the plan."
        case .language: "The on-device AI doesn't support this language yet. Try writing it in English."
        case .busy: "The on-device AI is busy. Wait a moment and try again."
        case .tooLong: "That's too much text for the on-device AI at once. Try a shorter list or fewer sections."
        case .vague: "What do you need to do? Name it, like \"maths worksheet\" or \"revise chemistry for Friday\"."
        }
    }
}
