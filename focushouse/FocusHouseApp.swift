import SwiftUI
import SwiftData
import EventKit

@main
struct FocusHouseApp: App {
    let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do { container = try ModelContainer(for: Plan.self, TodoItem.self) }
        catch { fatalError("Couldn't open saved plans: \(error)") }
        Reminders.shared.setUp(container: container)
        CheckIn.shared.restore(container.mainContext)
        Theme.registerFonts()
        Hint.setUp()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Home", image: "tab.home") { HomeView() }
                Tab("Schedule", image: "tab.schedule") { ContentView() }
                Tab("Calendar", image: "tab.calendar") { CalendarView() }
            }
            .tint(.brick)
            .onOpenURL { WidgetSync.open($0, container.mainContext) }
            // Calendar edits made outside the app (or on a synced Google calendar).
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in pullCalendar() }
            .sheet(item: Binding(get: { CheckIn.shared.queue.first },
                                 set: { if $0 == nil, let t = CheckIn.shared.queue.first { CheckIn.shared.later(t) } })) {
                CheckInSheet(task: $0)
            }
        }
            .modelContainer(container)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { WidgetSync.apply(container.mainContext); pullCalendar() }
                if phase == .background { WidgetSync.write(container.mainContext) }
                // Rest for the house: Screen Time when it's on, else time away from the app.
                if ScreenTime.isOn {
                    if phase == .active { ScreenTime.schedule() }   // picks up routine changes
                } else {
                    if phase == .background { RestLog.appLeft() }
                    if phase == .active { RestLog.appOpened() }
                }
            }
    }

    private func pullCalendar() {
        let tasks = (try? container.mainContext.fetch(FetchDescriptor<PlanTask>())) ?? []
        CalendarSync.pull(tasks).forEach { $0.reflow() }
    }
}
