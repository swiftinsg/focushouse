import SwiftUI

/// "How did it go?" after a task is ticked: time it took, how it felt (1–5) and
/// an optional note. Saving or skipping removes the task from the queue, which
/// closes the sheet, so it never dismisses itself.
struct CheckInSheet: View {
    let task: PlanTask
    @State private var minutes: Int
    @State private var feeling: Int?
    @State private var note = ""
    @State private var photo: UIImage?
    @State private var verdict: String?
    @State private var checking = false
    @State private var camera = false

    /// The time starts at what was recorded before, else the estimate.
    init(task: PlanTask) {
        self.task = task
        _minutes = State(initialValue: task.actual ?? task.minutes)
        let id = task.uid?.uuidString
        _photo = State(initialValue: id.flatMap(Proof.image))
        _verdict = State(initialValue: id.map(Proof.matched) == true ? "Photo matched: bonus bricks" : nil)
    }

    private static let feelings = [("😫", "Drained"), ("😕", "Tiring"), ("😐", "OK"), ("🙂", "Good"), ("😄", "Energised")]

    var body: some View {
        NavigationStack {
            PixelList {
                Section {
                    Text("How did it go?")
                        .font(.pixel(26, relativeTo: .title))
                    Text(task.title).font(.headline)
                    if task.tickedEarly {   // never true in Tester mode
                        Text("Ticked before it started, so it won't earn bricks. Untick it and tick again once you've done it in its slot.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Stepper(value: $minutes, in: 5...480, step: 5) {
                        LabeledContent("How much time it take?", value: hoursAndMinutes(minutes))
                    }
                } footer: {
                    Text("Planned \(hoursAndMinutes(task.estimate ?? task.minutes))")
                }

                Section(pixel: "How did the tasks feel?") {
                    HStack(spacing: 8) {
                        ForEach(Self.feelings.indices, id: \.self) { i in
                            let (emoji, caption) = Self.feelings[i]
                            FeelingButton(emoji: emoji, caption: caption, selected: feeling == i + 1) {
                                feeling = i + 1
                            }
                        }
                    }
                }

                Section {
                    TextField("What are some of the challenges that you faced, or did anything helped you during your tasks?", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Note (optional)").pixelHeader()
                } footer: {
                    Text("It stays on your phone. Your notes are deleted after 30 days.")
                }

                if Proof.hasCamera || photo != nil {
                    Section {
                        if let photo {
                            Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 220)
                        }
                        if checking { ProgressView("Checking the photo…") }
                        else if let verdict { Text(verdict).font(.subheadline) }
                        if Proof.hasCamera {
                            Button(photo == nil ? "Take a photo of your work" : "Retake photo", systemImage: "camera") { camera = true }
                                .disabled(checking)
                        }
                    } header: {
                        Text("Photo (optional)").pixelHeader()
                    } footer: {
                        Text("A photo that shows the work earns a small bonus. No photo is fine: not every task has something to show. Photos stay on your phone and are deleted after \(Proof.keepDays) days.")
                    }
                }
            }
            // Save and Skip stay at the bottom of the screen, under the form.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        CheckIn.shared.save(task, minutes: minutes, feeling: feeling!, note: note)
                    } label: {
                        Text("Save")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pixel)
                    .disabled(feeling == nil)

                    Button("Skip (no bricks)") { CheckIn.shared.skip(task) }
                    Text("Bricks are added once you answer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.paper)   // the form scrolls under it, not through it
            }
            .paperBackground()
        }
        .fullScreenCover(isPresented: $camera) {
            CameraView { image in Task { await took(image) } }.ignoresSafeArea()
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(feeling != nil)
    }
}

/// One feeling face: it wiggles when tapped, and the chosen one pops.
private struct FeelingButton: View {
    let emoji: String
    let caption: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wiggling = false

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.15, dampingFraction: 0.45)) { wiggling = true }
            Task {
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.35)) { wiggling = false }
            }
            action()
        } label: {
            VStack(spacing: 4) {
                Text(emoji).font(.largeTitle)
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .overlay(Rectangle().strokeBorder(selected ? Color.ink : .clear, lineWidth: 3))
            .rotationEffect(.degrees(wiggling && !reduceMotion ? -7 : 0))
            .scaleEffect(selected && !reduceMotion ? 1.12 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.45), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(caption)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension CheckInSheet {
    /// Saves the photo as the task's record, then asks the model if it shows the work.
    private func took(_ image: UIImage) async {
        let id = task.key
        try? Proof.save(image, for: id)
        photo = Proof.image(id)
        guard let photo else { return }
        checking = true
        defer { checking = false }
        guard let result = await Proof.check(photo, title: task.title) else {
            verdict = Proof.canCheck ? "Couldn't check it this time. The photo is saved." : "Saved. Checking photos needs Apple Intelligence."
            return
        }
        Proof.setMatched(id, result.matches)
        verdict = result.matches ? "Photo matched: bonus bricks"
            : "Couldn't tell this shows \(task.title) (it looks like \(result.seen.lowercased())). No bricks lost."
    }
}

#Preview { CheckInSheet(task: PlanTask(title: "Maths homework", category: "school", minutes: 45, day: 0, order: 0)) }
