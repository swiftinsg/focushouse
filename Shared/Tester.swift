import Foundation

/// Beta testing ("Tester mode" in Settings, on by default): relaxes the
/// anti-gaming rules so testers can try bricks, furniture and rest quickly.
/// The strict rules are untouched underneath; each relaxed spot is marked `TESTER:`.
/// Before the final release: delete this file, the Settings toggle, and every
/// `Tester.on` (grep "TESTER:") — see NOTES.md "Tester mode".
enum Tester {
    static var on: Bool {
        // Unit tests always check the strict rules.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        return RestLog.defaults.object(forKey: "testerMode") as? Bool ?? true
    }
}
