import DeviceActivity
import Foundation
import WidgetKit

/// Screen Time runs this in the background at the start and end of each waking
/// hour focushouse watches. Hours with no phone use build a run; only runs of
/// `RestLog.minBreak` (3h) or more count as rest.
// ponytail: Screen Time callbacks can be late or skipped; a missed hour just
// isn't counted, which errs on the side of less rest.
final class RestMonitor: DeviceActivityMonitor {
    private func usedKey(_ activity: DeviceActivityName) -> String { "used." + activity.rawValue }

    override func intervalDidStart(for activity: DeviceActivityName) {
        RestLog.defaults.removeObject(forKey: usedKey(activity))
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        RestLog.defaults.set(true, forKey: usedKey(activity))
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        let now = Date.now
        let used = RestLog.defaults.bool(forKey: usedKey(activity))
        if !used { QuietHours.add(endingAt: now) }   // focus bonus, even during a task
        // Phone used, or phone down during a scheduled task or lesson: not rest, run over.
        guard !used,
              !WidgetSnapshot.load().blocksRest(from: now.addingTimeInterval(-3600), to: now) else {
            RestRun().save()
            return
        }
        var run = RestRun.load()
        RestLog.update { $0.restedHour(endingAt: now, run: &run) }
        run.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
