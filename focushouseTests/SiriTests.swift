import Foundation
import Testing
@testable import focushouse

struct SiriTests {
    @Test func summarySaysHouseProgressHardestAndNext() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let items = [
            SiriContext.Item(title: "Maths worksheet", start: now.addingTimeInterval(-7200), score: 5, done: true),
            SiriContext.Item(title: "Chem revision", start: now.addingTimeInterval(3600), score: 8, done: false),
            SiriContext.Item(title: "Bio TYS", start: now.addingTimeInterval(7200), score: 9, done: false),
            SiriContext.Item(title: "Reply Jay", start: nil, score: 2, done: false),
        ]
        let text = SiriContext.summary(state: .stressed, streak: 2, items: items, now: now)
        #expect(text.hasPrefix("Your house is stressed: 2 busy days in a row."))
        #expect(text.contains("Today: 1 of 4 done."))
        #expect(text.contains("2 hard ones left, the hardest is Bio TYS."))
        #expect(text.contains("Next: Chem revision at"))

        #expect(SiriContext.summary(state: .calm, streak: 0, items: [], now: now) == "Your house is calm. Nothing planned today.")
        let done = [SiriContext.Item(title: "A", start: now, score: 5, done: true)]
        #expect(SiriContext.summary(state: .resting, streak: 1, items: done, now: now).hasSuffix("All done. Time to rest."))
    }

    @Test func stressLineNamesScoreEffortAndMinutes() {
        #expect(SiriContext.stressLine(Rating(score: 8, compulsory: true), minutes: 45) == "Stress 8/10 (hard, compulsory), 45 min")
        #expect(SiriContext.stressLine(Rating(score: 2, compulsory: false), minutes: 10) == "Stress 2/10 (easy), 10 min")
    }
}
