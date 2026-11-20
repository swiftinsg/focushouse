import SwiftUI

/// First-visit tour of Home: dims the screen, spotlights one part at a time and
/// explains it. Toolbar and tab bar sit outside the overlay, so those steps
/// point at them with an arrow instead of a spotlight.
enum TourStep: Int, CaseIterable {
    case house, door, status, stress, rest, next, settings, bricks, tabs

    var title: String {
        switch self {
        case .house: "This house is you"
        case .door: "Go inside"
        case .status: "How you're doing"
        case .stress: "Stress this week"
        case .rest: "Rest today"
        case .next: "Your next task"
        case .settings: "Settings"
        case .bricks: "Bricks"
        case .tabs: "Schedule · Calendar"
        }
    }

    var text: String {
        switch self {
        case .house: "It shows the state your mental health. Multiple stressful days in a row wear the house down, and rest builds it back up. Look after yourself by having a good work life balance and it stays standing, proud and tall."
        case .door: "The glowing door is a button. Tap it any time to step inside your house, where the furniture you buy with bricks can make you decorate your house."
        case .status: "The house's state is based on how many hard days you've had in a row. Resting means you rested enough today to repair your house."
        case .stress: "It fills the bar for each stressful day in a row."
        case .rest: "Time with your phone down for \(HomeView.duration(RestLog.minBreak)) in a row counts as rest. Reach \(HomeView.duration(House.restGoal)) in a day to repair your house!"
        case .next: "Tick the box when you finish your tasks to earn bricks, then say how your experience went so future plans fit the different tasks that you do."
        case .settings: "Tap the gear for your routine, school hours, daily work limit and how rest is counted."
        case .bricks: "Earned by finishing tasks. Spend them on furniture inside your house. Bricks fix up your run-down house and buy furniture, but only rest heals the damage from hard days."
        case .tabs: "Schedule: your to-dos and plans. Tap + to add a to-do, or turn a goal or to-do list into a timed plan.\nCalendar: your month at a glance."
        }
    }

    /// Where the arrow points when there's nothing to spotlight.
    var arrow: (symbol: String, edge: Alignment)? {
        switch self {
        case .settings: ("arrow.up", .topLeading)
        case .bricks: ("arrow.up", .topTrailing)
        case .tabs: ("arrow.down", .bottom)
        default: nil
        }
    }
}

struct TourAnchors: PreferenceKey {
    static let defaultValue: [TourStep: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourStep: Anchor<CGRect>], nextValue: () -> [TourStep: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as the spotlight for `step`.
    func tour(_ step: TourStep) -> some View {
        // Merges, so the door inside the house keeps its own spotlight.
        transformAnchorPreference(key: TourAnchors.self, value: .bounds) { $0[step] = $1 }
    }

    /// Runs the Home tour over this view until it's finished or skipped.
    func homeTour(isOn: Binding<Bool>) -> some View {
        overlayPreferenceValue(TourAnchors.self) { anchors in
            if isOn.wrappedValue {
                GeometryReader { proxy in
                    TourOverlay(rects: anchors.mapValues { proxy[$0] }, size: proxy.size) { isOn.wrappedValue = false }
                }
            }
        }
    }
}

private struct TourOverlay: View {
    let rects: [TourStep: CGRect]
    let size: CGSize
    let finish: () -> Void
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Spotlight steps whose view isn't on screen (e.g. no next task) are skipped.
    private var steps: [TourStep] { TourStep.allCases.filter { $0.arrow != nil || rects[$0] != nil } }

    var body: some View {
        let step = steps[min(index, steps.count - 1)]
        let hole = rects[step]?.insetBy(dx: step == .door ? -10 : -6, dy: step == .door ? -10 : -6)   // the door is small: more room
        let last = index >= steps.count - 1

        ZStack {
            // With nothing to spotlight, the hole shrinks to a point by the arrow's target.
            Spotlight(hole: hole ?? CGRect(origin: target(step), size: .zero))
                .fill(.black.opacity(0.65), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture(perform: advance)

            if let hole {
                Rectangle().strokeBorder(Color.gold, lineWidth: 3)
                    .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.7) }
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false)
                if step == .door {   // a small target: glow around it and point at it
                    Rectangle().strokeBorder(Color.gold, lineWidth: 6)
                        .blur(radius: 6)
                        .frame(width: hole.width + 8, height: hole.height + 8)
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)
                    Image(systemName: "arrow.down").font(.largeTitle.weight(.heavy)).foregroundStyle(Color.gold)
                        .symbolEffect(.bounce, options: .repeating, isActive: !reduceMotion)
                        .position(x: hole.midX, y: hole.minY - 28)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if let arrow = step.arrow, arrow.edge != .bottom { arrowImage(arrow.symbol, arrow.edge) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.title).font(.pixel(22, relativeTo: .headline).weight(.bold))
                    Text(step.text).font(.subheadline)
                    HStack {
                        Text("\(index + 1) of \(steps.count)").font(.footnote).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        Spacer()
                        if !last { Button("Skip", action: finish).font(.subheadline) }
                        Button(last ? "Done" : "Next", action: advance)
                            .font(.pixel(18, relativeTo: .headline).weight(.bold))
                            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 0))
                    }
                }
                .padding()
                .pixelBox()
                if let arrow = step.arrow, arrow.edge == .bottom { arrowImage(arrow.symbol, arrow.edge) }
            }
            .id(step)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cardAlignment(step, hole))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.25), value: index)
        .tint(.navy)
    }

    private func arrowImage(_ symbol: String, _ edge: Alignment) -> some View {
        Image(systemName: symbol).font(.largeTitle.weight(.bold)).foregroundStyle(Color.gold)
            .symbolEffect(.bounce, options: .repeating, isActive: !reduceMotion)
            .frame(maxWidth: .infinity, alignment: edge == .topTrailing ? .trailing : edge == .bottom ? .center : .leading)
            .accessibilityHidden(true)
    }

    /// Where an arrow step points: the toolbar corners or the tab bar.
    private func target(_ step: TourStep) -> CGPoint {
        switch step.arrow?.edge {
        case .topTrailing: CGPoint(x: size.width - 30, y: 0)
        case .bottom: CGPoint(x: size.width / 2, y: size.height)
        default: CGPoint(x: 30, y: 0)
        }
    }

    /// Card goes on the other half of the screen from the spotlight.
    private func cardAlignment(_ step: TourStep, _ hole: CGRect?) -> Alignment {
        if let hole { return hole.midY > size.height / 2 ? .top : .bottom }
        return step.arrow?.edge == .bottom ? .bottom : .top
    }

    private func advance() {
        if index >= steps.count - 1 { finish() } else { index += 1 }
    }
}

/// The dimmed screen with a rectangular hole that glides between steps.
private struct Spotlight: Shape {
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.minX, hole.minY), .init(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        p.addRect(hole)
        return p
    }
}
