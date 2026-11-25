import FoundationModels
import SwiftUI
import UIKit

@available(iOS 26, *) @Generable struct PhotoVerdict {
    @Guide(description: "What the photo shows, in under 12 words")
    var seen: String
    @Guide(description: "true if the photo shows this task's work, done or in progress, even if messy; false if it's unrelated, blank or unclear")
    var matches: Bool
}

/// Optional photo at check-in, a record of the work: taken with the camera (so
/// it's fresh), checked by the on-device model, kept on the phone for 30 days.
/// A match adds a small brick bonus; no photo or no match never costs bricks,
/// since plenty of tasks (reading, practice) have nothing to photograph.
// ponytail: a model can't prove the work is the student's own or new; the bonus stays small for that reason.
@MainActor enum Proof {
    static let keepDays = 30
    static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    /// Looking at photos needs the iOS 27 model.
    static var canCheck: Bool {
        guard #available(iOS 27, *) else { return false }
        let model = SystemLanguageModel.default
        return model.availability == .available && model.capabilities.contains(.vision)
    }

    static let folder = URL.applicationSupportDirectory.appending(path: "proof", directoryHint: .isDirectory)
    static func url(_ id: String) -> URL { folder.appending(path: id + ".jpg") }
    static func image(_ id: String) -> UIImage? { UIImage(contentsOfFile: url(id).path()) }

    /// Saved upright and at most 1600 px, locked while the phone is locked.
    static func save(_ image: UIImage, for id: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scale = min(1, 1600 / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let upright = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = upright.jpegData(compressionQuality: 0.7) else { return }
        try data.write(to: url(id), options: [.atomic, .completeFileProtection])
    }

    /// Nil when the model can't look at images here, or the check fails.
    static func check(_ image: UIImage, title: String) async -> (matches: Bool, seen: String)? {
        guard canCheck, #available(iOS 27, *), let cg = image.cgImage else { return nil }
        let session = LanguageModelSession(instructions: """
            You look at a photo a student took after a task and say whether it shows that task's work. \
            Be fair: rough, messy or half-done work counts if it's clearly this task.
            """)
        return (try? await session.respond(to: Prompt {
            "Task: \(title)\nDoes this photo show this task's work?"
            Attachment(cg)
        }, generating: PhotoVerdict.self).content).map { ($0.matches, $0.seen) }
    }

    // Matched tasks by id, kept after the photo is deleted so the bonus stays.
    // ponytail: grows by one id per matched photo; trim if it ever matters.
    private static let matchedKey = "photoMatched"
    static func matched(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: matchedKey) ?? []).contains(id) }
    static func setMatched(_ id: String, _ yes: Bool) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: matchedKey) ?? [])
        if yes { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: matchedKey)
    }

    /// +20% (at least 1) on a task that earns bricks.
    nonisolated static func bonus(_ bricks: Int) -> Int { bricks > 0 ? bricks + max(1, bricks / 5) : 0 }

    /// Deletes photos older than 30 days. Called at launch.
    static func purge(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// The system camera, full screen.
struct CameraView: UIViewControllerRepresentable {
    var onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
