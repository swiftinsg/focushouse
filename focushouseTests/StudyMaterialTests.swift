import Testing
@testable import focushouse

@MainActor struct StudyMaterialTests {
    @Test func chunksSplitBetweenLinesAndCapLength() {
        let text = (1...10).map { "line \($0) " + String(repeating: "x", count: 30) }.joined(separator: "\n")
        let pieces = StudyMaterial.chunks(text, size: 100, limit: 3)
        #expect(pieces.count == 3)                          // capped
        #expect(pieces.allSatisfy { $0.count <= 100 })
        #expect(pieces[0].hasPrefix("line 1 "))
        #expect(pieces.allSatisfy { $0.split(separator: "\n").allSatisfy { $0.hasPrefix("line ") } })   // lines kept whole
        // One huge line is cut into pieces of `size`.
        #expect(StudyMaterial.chunks(String(repeating: "y", count: 250), size: 100).map(\.count) == [100, 100, 50])
    }

    @Test func linesMergeRepeatsAndCapAtFifteen() {
        let s = { (n: String, p: String) in MaterialSection(name: n, points: p) }
        let out = StudyMaterial.lines([s("Arenes", "benzene"), s("arenes", "nitration"), s("", "junk"), s("Carbonyls", "")])
        #expect(out == "Arenes - benzene, nitration\nCarbonyls")
        let many = (1...20).map { s("Topic \($0)", "p") }
        #expect(StudyMaterial.lines(many).split(separator: "\n").count == 15)
        #expect(Planner.materialTopics(StudyMaterial.lines(many)).count == 15)   // the planner's safety net takes it
    }
}
