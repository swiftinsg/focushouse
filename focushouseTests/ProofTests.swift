import Foundation
import Testing
@testable import focushouse

struct ProofTests {
    @Test func bonusIsSmallAndOnlyOnEarnedBricks() {
        #expect(Proof.bonus(0) == 0)     // easy or early ticks stay at 0
        #expect(Proof.bonus(3) == 4)     // at least 1
        #expect(Proof.bonus(10) == 12)   // +20%
    }

    @Test func oldKeptTasksStillLoad() {
        let old = #"[{"title":"Essay","category":"writing","priority":1,"minutes":60,"earns":true}]"#
        let kept = KeptTask.load(Data(old.utf8))
        #expect(kept.count == 1)
        #expect(kept[0].photo == nil)
    }
}
