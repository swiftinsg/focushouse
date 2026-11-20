import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Plan.createdAt, order: .reverse) private var plans: [Plan]
    @State private var path: [Plan] = []
    @State private var showNew = false
    @AppStorage("seenCalendarTip") private var seenCalendarTip = false
    @State private var calendarError: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(plans) { plan in
                    NavigationLink(value: plan) {
                        HStack(spacing: 14) {
                            ProgressRing(done: plan.tasks.filter(\.done).count, total: plan.tasks.count)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.title.isEmpty ? "Untitled plan" : plan.title).font(.headline)
                                Text("\(plan.mode.rawValue) · \(plan.start.formatted(.dateTime.weekday().day().month())) · \(plan.tasks.count) task\(plan.tasks.count == 1 ? "" : "s")")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete([plan]) }
                    }
                    .contextMenu {
                        if !plan.tasks.isEmpty {
                            if CalendarSync.isUpToDate(plan) {
                                Label("In Calendar", systemImage: "checkmark.circle")
                            } else {
                                Button(plan.tasks.contains { $0.eventID != nil } ? "Update Calendar" : "Add to Calendar",
                                       systemImage: "calendar.badge.plus") {
                                    Task {
                                        do { _ = try await CalendarSync.add(plan) }
                                        catch { calendarError = error.localizedDescription }
                                    }
                                }
                            }
                            if plan.tasks.contains(where: { $0.eventID != nil }) {
                                Button("Remove from Calendar", systemImage: "calendar.badge.minus", role: .destructive) {
                                    CalendarSync.remove(plan.tasks)
                                }
                            }
                        }
                        Button("Delete plan", systemImage: "trash", role: .destructive) { delete([plan]) }
                    }
                }
                .onDelete { delete($0.map { plans[$0] }) }
            }
            .overlay {
                if plans.isEmpty {
                    ContentUnavailableView("No plans yet", systemImage: "checklist",
                                           description: Text("Tap + to plan your day or a goal."))
                }
            }
            .pixelTitle("Schedule")
            .navigationDestination(for: Plan.self) { PlanView(plan: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New plan", systemImage: "plus") { showNew = true }
                }
            }
            .alert("Couldn't add to Calendar", isPresented: Binding(get: { calendarError != nil }, set: { if !$0 { calendarError = nil } })) {
                Button("OK") {}
            } message: { Text(calendarError ?? "") }
            // Closed once (Got it or swiped down) = never shown again; Settings still has it.
            .sheet(isPresented: Binding(get: { !seenCalendarTip }, set: { if !$0 { seenCalendarTip = true } })) {
                NavigationStack {
                    CalendarTipView()
                        .toolbar { Button("Got it") { seenCalendarTip = true } }
                }
            }
            .sheet(isPresented: $showNew) {
                NewPlanView { plan in
                    showNew = false
                    path.append(plan)
                }
            }
        }
    }
}

/// How much of a plan is done, as a small ring that fills green.
private struct ProgressRing: View {
    var done: Int
    var total: Int

    var body: some View {
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        ZStack {
            Circle().stroke(.fill.tertiary, lineWidth: 4)
            Circle().trim(from: 0, to: fraction)
                .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if total > 0, done == total {
                Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityElement()
        .accessibilityLabel("\(done) of \(total) done")
    }
}

extension ContentView {
    private func delete(_ gone: [Plan]) { gone.forEach { $0.deletePlan() } }
}

#Preview {
    ContentView().modelContainer(for: Plan.self, inMemory: true)
}
