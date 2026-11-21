import Foundation
import SwiftData
import UserNotifications

/// Local notifications: a reminder when a task starts, a check-in when it should
/// end ("Done" / "+15, +30, +60 min"), follow-ups if that goes unanswered, and
/// "How did it go?" answered right on the notification. All handled even if the
/// app is closed; a task's notifications go away once it's ticked or answered.
@MainActor final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Reminders()
    private var container: ModelContainer?

    private static let checkIn = "CHECKIN"
    private static let followUp = "FOLLOWUP"
    private static let review = "REVIEW"
    private static let done = "DONE"
    private static let notStarted = "NOTSTARTED"
    private static let more = [15, 30, 60]
    /// Minutes after the end to ask again when the check-in goes unanswered.
    private static let followUps = [30, 120]
    /// Review answers: action id → how it felt (1–5).
    private static let feelings = [("FEEL5", "Great 😀", 5), ("FEEL3", "Okay 😐", 3), ("FEEL1", "Tough 😣", 1)]
    private static let note = "NOTE"
    private static let suffixes = [".start", ".end", ".review"] + followUps.indices.map { ".follow\($0)" }

    func setUp(container: ModelContainer) {
        self.container = container
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let doneAction = UNNotificationAction(identifier: Self.done, title: "Done ✓")
        let actions = [doneAction] + Self.more.map { UNNotificationAction(identifier: "MORE\($0)", title: "Need \($0) more min") }
        let follow = [doneAction,
                      UNNotificationAction(identifier: "MORE30", title: "Still going, 30 more min"),
                      UNNotificationAction(identifier: Self.notStarted, title: "Haven't started, plan it from now")]
        let answers = Self.feelings.map { UNNotificationAction(identifier: $0.0, title: $0.1) }
            + [UNTextInputNotificationAction(identifier: Self.note, title: "Add a note", textInputButtonTitle: "Send", textInputPlaceholder: "How did it go?")]
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.checkIn, actions: actions, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.followUp, actions: follow, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.review, actions: answers, intentIdentifiers: []),
        ])
    }

    static func requestAccess() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Replace this plan's pending reminders with ones matching its current times.
    // ponytail: iOS keeps only the 64 soonest pending notifications; fine for a
    // few plans, schedule a rolling window if students keep many long goal plans.
    static func sync(_ plan: Plan) {
        cancel(plan.tasks)
        let now = Date.now
        for task in plan.tasks where !task.done {
            guard let start = task.start, let end = task.end else { continue }
            if start > now {
                add(id: task.key + ".start", at: start, title: "Time for: \(task.title)",
                    body: "\(task.minutes) min, until \(end.formatted(date: .omitted, time: .shortened))" + (task.minutes > Plan.longTask && task.category != Plan.freeTime ? ". Long tasks still need breaks: stand up and stretch every hour." : ""),
                    task: task)
            }
            if end > now {
                add(id: task.key + ".end", at: end, title: "Done with \(task.title)?",
                    body: "Mark it done, or take a bit more time.", task: task, category: checkIn)
            }
            // Unanswered check-in: ask again. Ticking or pushing back reschedules these.
            for (i, after) in followUps.enumerated() {
                let at = end.addingTimeInterval(Double(after) * 60)
                guard at > now else { continue }
                add(id: task.key + ".follow\(i)", at: at, title: i == 0 ? "Still on \(task.title)?" : "How's \(task.title) going?",
                    body: i == 0 ? "It was due to finish \(end.formatted(date: .omitted, time: .shortened)). Done, or need longer?"
                                 : "Not ticked yet. Done, still going, or not started?",
                    task: task, category: followUp)
            }
        }
    }

    /// Clears a task's notifications, waiting and already shown (but not the
    /// "How did it go?" one unless `review`).
    static func cancel(_ tasks: [PlanTask], review: Bool = false) {
        let ids = tasks.flatMap { t in suffixes.filter { review || $0 != ".review" }.map { t.key + $0 } }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// "How did it go?" right after Done on a notification, answered in place.
    static func askReview(_ task: PlanTask) {
        add(id: task.key + ".review", at: nil, title: "How did \(task.title) go?",
            body: "Answer here for your bricks.", task: task, category: review)
    }

    private static func add(id: String, at date: Date?, title: String, body: String,
                            task: PlanTask, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["task": task.key]
        if let category { content.categoryIdentifier = category }
        let trigger = date.map { UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0), repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let key = response.notification.request.content.userInfo["task"] as? String else { return }
        await handle(action: action, key: key, text: (response as? UNTextInputNotificationResponse)?.userText)
    }

    private func handle(action: String, key: String, text: String?) {
        guard let context = container?.mainContext, let uid = UUID(uuidString: key),
              let task = try? context.fetch(FetchDescriptor<PlanTask>(predicate: #Predicate { $0.uid == uid })).first,
              let plan = task.plan else { return }
        if action == Self.done {
            CheckIn.shared.tick(task)
            plan.reflow()
            if task.checkIn == PlanTask.CheckInState.waiting.rawValue { Self.askReview(task) }
        } else if action.hasPrefix("MORE"), let minutes = Int(action.dropFirst(4)) {
            plan.pushBack(task, by: minutes)
        } else if action == Self.notStarted {
            plan.move(task, to: .now)
        } else if let feeling = Self.feelings.first(where: { $0.0 == action })?.2 ?? (action == Self.note ? 3 : nil),
                  task.checkIn == PlanTask.CheckInState.waiting.rawValue {
            // Time taken isn't asked here: the planned time stands in (or what setDone recorded).
            CheckIn.shared.save(task, minutes: task.actual ?? task.minutes, feeling: feeling, note: text ?? "")
        }
        try? context.save()
        WidgetSync.write(context)
    }
}
