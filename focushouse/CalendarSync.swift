import EventKit

/// Reads busy time from, and writes plan tasks to, the iPhone Calendar
/// (which includes Google calendars synced through iOS).
@MainActor enum CalendarSync {
    static let store = EKEventStore()

    static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asks once; later calls return the saved answer without a prompt.
    @discardableResult static func requestAccess() async -> Bool {
        if hasAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Timed events that block time, skipping all-day events, "free" events
    /// and the events this plan wrote itself.
    static func busy(from start: Date, days: Int, excluding own: Set<String>) -> [Range<Date>] {
        guard hasAccess else { return [] }
        let from = start.addingTimeInterval(-86_400)
        let to = start.addingTimeInterval(TimeInterval(max(days, 1) + 60) * 86_400)
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            .filter { !$0.isAllDay && $0.availability != .free && !own.contains($0.eventIdentifier ?? "") }
            .compactMap { $0.startDate < $0.endDate ? $0.startDate..<$0.endDate : nil }
    }

    /// Timed events the student attends between `from` and `to` (not "free" ones,
    /// not the ones focushouse wrote for tasks), for stress on Home.
    static func attended(from: Date, to: Date, excluding own: Set<String>) -> [(title: String, start: Date, minutes: Int)] {
        guard hasAccess else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            .filter { !$0.isAllDay && $0.availability != .free && !own.contains($0.eventIdentifier ?? "") }
            .map { ($0.title ?? "", $0.startDate, Int($0.endDate.timeIntervalSince($0.startDate) / 60)) }
    }

    /// Creates or updates one event per scheduled task. Returns how many were written.
    static func add(_ plan: Plan) async throws -> Int {
        guard await requestAccess() else { throw CalendarError.noAccess }
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarError.noCalendar }
        var count = 0
        for task in plan.ordered {
            guard let start = task.start, let end = task.end else { continue }
            let event = task.eventID.flatMap(store.event(withIdentifier:)) ?? EKEvent(eventStore: store)
            if event.calendar == nil { event.calendar = calendar }
            event.title = task.title
            event.startDate = start
            event.endDate = end
            event.notes = "From focushouse · \(plan.title)"
            try store.save(event, span: .thisEvent, commit: false)
            task.eventID = event.eventIdentifier
            count += 1
        }
        try store.commit()
        for task in plan.tasks where task.eventID != nil { task.syncedAt = .now }
        return count
    }

    /// True when every scheduled task already has a matching Calendar event,
    /// so "Update Calendar" would change nothing.
    static func isUpToDate(_ plan: Plan) -> Bool {
        guard hasAccess else { return false }
        return plan.tasks.allSatisfy { t in
            guard let start = t.start, let end = t.end else { return true }
            guard let event = t.eventID.flatMap(store.event(withIdentifier:)) else { return false }
            return event.startDate == start && event.endDate == end && event.title == t.title
        }
    }

    /// Removes the Calendar events of these tasks (the tasks stay in the app).
    static func remove(_ tasks: [PlanTask]) {
        guard hasAccess else { return }
        for task in tasks {
            if let event = task.eventID.flatMap(store.event(withIdentifier:)) {
                try? store.remove(event, span: .thisEvent, commit: false)
            }
            task.eventID = nil
        }
        try? store.commit()
    }

    /// Every event on `day` except the ones focushouse wrote for tasks
    /// (those show as tasks already), all-day ones first.
    static func events(on day: Date, excluding own: Set<String>) -> [EKEvent] {
        guard hasAccess else { return [] }
        let start = Calendar.current.startOfDay(for: day)
        return store.events(matching: store.predicateForEvents(withStart: start, end: start.addingTimeInterval(86_400), calendars: nil))
            .filter { !own.contains($0.eventIdentifier ?? "") }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
    }

    /// Deletes a Calendar event; `future` also deletes later repeats.
    static func delete(_ event: EKEvent, future: Bool = false) throws {
        try store.remove(event, span: future ? .futureEvents : .thisEvent, commit: true)
    }

    /// Two-way sync for tasks already in Calendar: an event deleted in Calendar
    /// unlinks its task (so it isn't treated as added), and an event moved or
    /// renamed there pins the task to the new time and title. Returns the plans
    /// that changed, so they can be reflowed.
    static func pull(_ tasks: [PlanTask]) -> [Plan] {
        guard hasAccess else { return [] }   // no access looks like "deleted"; leave links alone
        var changed: [Plan] = []
        for task in tasks where task.eventID != nil && !task.done {
            guard let event = store.event(withIdentifier: task.eventID!) else {
                task.eventID = nil
                continue
            }
            // Only edits made in Calendar since our last write; in-app edits not
            // yet sent with "Update Calendar" win otherwise.
            guard let edited = event.lastModifiedDate, edited > (task.syncedAt ?? .distantPast).addingTimeInterval(2) else { continue }
            task.syncedAt = .now
            let minutes = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
            guard event.startDate != task.start || minutes != task.minutes || event.title != task.title else { continue }
            task.title = event.title ?? task.title
            task.pinned = event.startDate
            task.minutes = max(minutes, 5)
            if let plan = task.plan, !changed.contains(where: { $0 === plan }) { changed.append(plan) }
        }
        return changed
    }
}

enum CalendarError: LocalizedError {
    case noAccess, noCalendar
    var errorDescription: String? {
        switch self {
        case .noAccess: "focushouse needs Calendar access. Turn it on in Settings → Apps → focushouse."
        case .noCalendar: "There's no calendar to add events to."
        }
    }
}
