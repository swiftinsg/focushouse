import Foundation
import FoundationModels
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import Vision

@available(iOS 26, *) @Generable struct MaterialOutline {
    @Guide(description: "The material's sections or topics, in the order they appear", .count(1...8))
    var sections: [MaterialSection]
}

@available(iOS 26, *) @Generable struct MaterialSection {
    @Guide(description: "Short name of the section or topic, 1 to 5 words, e.g. \"Arenes\" or \"Causes of WW1\"")
    var name: String
    @Guide(description: "Its key subtopics, comma separated, under 12 words")
    var points: String
}

/// Attached PDFs and photos → text for the Study material box, all on device:
/// PDFKit for PDFs with real text, Vision for photos and scanned pages. Long
/// text is shrunk to one "Name - points" line per section, the shape the
/// planner turns into one item per section. Files aren't kept, only the text.
@available(iOS 26, *) @MainActor enum StudyMaterial {
    static let rawLimit = 1500    // shorter text goes in as it is
    static let chunkSize = 4000   // characters per outline ask, to fit the small context window
    static let maxChunks = 6      // ponytail: ~24k characters (about 10 pages) read; attach later chapters separately

    static func text(fromPhotos items: [PhotosPickerItem]) async throws -> String {
        var texts: [String] = []
        for item in items {
            guard let data = try await item.loadTransferable(type: Data.self) else { continue }
            texts.append(reading(try await RecognizeTextRequest().perform(on: data)))
        }
        return texts.joined(separator: "\n")
    }

    static func text(fromFiles urls: [URL]) async throws -> String {
        var texts: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                texts.append(try await text(fromPDF: url))
            } else {
                texts.append(reading(try await RecognizeTextRequest().perform(on: try Data(contentsOf: url))))
            }
        }
        return texts.joined(separator: "\n")
    }

    static func text(fromPDF url: URL) async throws -> String {
        guard let doc = PDFDocument(url: url) else { throw MaterialError.unreadable }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard pages.joined().count < chunkSize * maxChunks, let page = doc.page(at: i) else { break }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count >= 20 { pages.append(text); continue }
            // A scanned page has no text layer: read its picture instead.
            let size = page.bounds(for: .mediaBox).size
            let scale = 2000 / max(size.width, size.height, 1)
            let image = page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
            if let cg = image.cgImage { pages.append(reading(try await RecognizeTextRequest().perform(on: cg))) }
        }
        return pages.joined(separator: "\n")
    }

    /// Vision's lines top to bottom, left to right (its y runs up from the bottom).
    // ponytail: single-column order; two-column handouts read across the columns.
    static func reading(_ found: [RecognizedTextObservation]) -> String {
        found.sorted {
            let (a, b) = ($0.boundingBox.origin, $1.boundingBox.origin)
            return (-(a.y * 100).rounded(), a.x) < (-(b.y * 100).rounded(), b.x)   // rows of 1% height
        }
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
    }

    /// What goes in the Study material box, plus a note for the student when
    /// something was left out. Short text stays as it is; long text becomes an outline.
    static func prepared(_ text: String) async -> (text: String, note: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", "No text found. Try a clearer photo, or type the main topics.") }
        guard text.count > rawLimit else { return (text, nil) }
        var sections: [MaterialSection] = []
        for piece in chunks(text) {
            // One fresh session per piece; a piece the safety filter blocks is skipped.
            let session = LanguageModelSession(instructions: """
                You outline a student's study material into its sections or topics, in order. \
                Use only what the text says. Skip page numbers, headers and exercises' answers.
                """)
            if let outline = try? await session.respond(to: "Outline this study material:\n\n" + piece,
                                                        generating: MaterialOutline.self).content {
                sections += outline.sections
            }
        }
        guard !sections.isEmpty else {
            return (String(text.prefix(6000)), "Couldn't outline it, so the start of the text was added. Trim it to the main topics.")
        }
        let cut = text.count > chunkSize * maxChunks
        return (lines(sections), cut ? "Long file: only the first part was read. Attach later chapters separately." : nil)
    }

    /// Text in pieces of at most `size` characters, split between lines where it can.
    static func chunks(_ text: String, size: Int = chunkSize, limit: Int = maxChunks) -> [String] {
        let lines = text.split(separator: "\n").flatMap { line in
            stride(from: 0, to: line.count, by: size).map { String(line.dropFirst($0).prefix(size)) }
        }
        var out: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > size { out.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { out.append(current) }
        return Array(out.prefix(limit))
    }

    /// One "Name - points" line per section. A section split across two pieces comes
    /// back twice in a row: merged. At most 15, the planner's section limit.
    static func lines(_ sections: [MaterialSection]) -> String {
        var merged: [MaterialSection] = []
        for s in sections where !s.name.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = merged.last, last.name.lowercased() == s.name.lowercased() {
                merged[merged.count - 1].points += ", " + s.points
            } else {
                merged.append(s)
            }
        }
        return merged.prefix(15).map { $0.points.isEmpty ? $0.name : "\($0.name) - \($0.points)" }.joined(separator: "\n")
    }
}

enum MaterialError: LocalizedError {
    case unreadable
    var errorDescription: String? { "Couldn't open that file. Try another PDF or a photo." }
}
