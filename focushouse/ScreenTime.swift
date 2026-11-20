import DeviceActivity
import FamilyControls
import Foundation

/// Counts rest with Apple's Screen Time: each waking hour (wake-up to bedtime,
/// from the routine) is watched, and the RestMonitor extension records an hour
/// of rest when the phone was barely used. Needs the student's permission.
@MainActor enum ScreenTime {
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: "screenTimeRest")
            && AuthorizationCenter.shared.authorizationStatus == .approved
    }

    /// Asks for Screen Time permission and starts watching. False if refused.
    static func enable() async -> Bool {
        do { try await AuthorizationCenter.shared.requestAuthorization(for: .individual) }
        catch { return false }
        schedule(force: true)
        return true
    }

    static func disable() {
        DeviceActivityCenter().stopMonitoring()
        UserDefaults.standard.removeObject(forKey: "restScheduled")
    }

    /// (Re)starts one daily-repeating activity per waking hour, so a changed
    /// routine is picked up. An event with no apps chosen covers all phone use.
    /// Only when the routine changed: restarting mid-hour forgets phone use so far.
    static func schedule(force: Bool = false) {
        let routine = Routine.current
        let key = "\(routine.wake)-\(routine.bed)"
        guard force || UserDefaults.standard.string(forKey: "restScheduled") != key else { return }
        UserDefaults.standard.set(key, forKey: "restScheduled")
        let center = DeviceActivityCenter()
        center.stopMonitoring()
        for block in RestHours.blocks(wake: routine.wake, bed: routine.bed) {
            let time = { (m: Int) in DateComponents(hour: m / 60 % 24, minute: m % 60) }
            try? center.startMonitoring(
                DeviceActivityName(RestHours.name(block)),
                during: DeviceActivitySchedule(intervalStart: time(block.start), intervalEnd: time(block.end), repeats: true),
                events: [DeviceActivityEvent.Name("used"): DeviceActivityEvent(threshold: DateComponents(minute: RestHours.glanceMinutes))])
        }
    }
}
