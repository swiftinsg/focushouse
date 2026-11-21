import SwiftUI
import Observation

/// Bricks earned at a check-in fly up into the brick counter. `fire` starts a
/// flight; `BrickBurstOverlay` at the app root draws it. The counter's own pop
/// comes from its value changing, not from here.
@MainActor @Observable final class BrickBurst {
    static let shared = BrickBurst()

    struct Flight: Equatable {
        let id: UUID
        let count: Int
        let start: Date
    }

    private(set) var flight: Flight?

    /// A handful of bricks (3–8, more for a bigger check-in) for a check-in that
    /// earned `bricks`. Nothing for a check-in that earned none.
    func fire(_ bricks: Int) {
        guard bricks > 0 else { return }
        // ponytail: starts a third of a second late, so the check-in sheet has slid away first.
        flight = Flight(id: UUID(), count: min(8, max(3, 3 + bricks / 2)), start: .now.addingTimeInterval(0.35))
    }

    func clear() { flight = nil }
}

/// The flight: pixel bricks burst from the middle-bottom of the screen and arc
/// up to the counter at the top right, shrinking as they go, each landing with a
/// light tap. Full screen over every tab, but never in the way of a touch. Off
/// with Reduce Motion: the counter still updates.
struct BrickBurstOverlay: View {
    private let burst = BrickBurst.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = 0

    /// The brick drawn 4× its 9×5 pixels, so one sprite pixel is 4 pt.
    private static let brickWidth: CGFloat = 36
    private static let pixel: CGFloat = 4
    private static let stagger = 0.07   // seconds between bricks
    private static let duration = 0.9   // one brick's flight

    var body: some View {
        GeometryReader { geo in
            if let flight = burst.flight, !reduceMotion {
                // 10 fps on purpose: smooth motion looks wrong on pixel art.
                TimelineView(.animation(minimumInterval: 1 / 10)) { timeline in
                    let t = timeline.date.timeIntervalSince(flight.start)
                    ForEach(0..<flight.count, id: \.self) { i in
                        let p = (t - Double(i) * Self.stagger) / Self.duration
                        if p >= 0, p < 1 {
                            Image("icon.brick").pixelArt()
                                .frame(width: Self.brickWidth)
                                .scaleEffect(1 - 0.4 * p)
                                .position(Self.point(p, i, of: flight.count, in: geo.size, top: geo.safeAreaInsets.top))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .light), trigger: landed) { _, n in n > 0 }
        .task(id: burst.flight?.id) { await land() }
    }

    /// A light tap as each brick reaches the counter, then the flight clears.
    @MainActor
    private func land() async {
        guard let flight = burst.flight else { return }
        if reduceMotion { burst.clear(); return }   // no flight to land
        let lead = max(0, flight.start.timeIntervalSince(.now))
        for i in 0..<flight.count {
            try? await Task.sleep(for: .seconds(lead + Double(i) * Self.stagger + Self.duration))
            guard !Task.isCancelled else { return }
            landed += 1
        }
        burst.clear()
    }

    /// Where brick `i` is at progress `p` (0 burst, 1 landed), on its own arc
    /// from the bottom middle to the counter, snapped to whole brick pixels.
    static func point(_ p: Double, _ i: Int, of count: Int, in size: CGSize, top: CGFloat) -> CGPoint {
        let from = CGPoint(x: size.width / 2 + CGFloat(i % 3 - 1) * 14, y: size.height - 110)
        let to = CGPoint(x: size.width - 46, y: top + 24)
        // Each brick bows its own way, so they fan out on the way up.
        let fan = (Double(i) / Double(max(1, count - 1)) - 0.5) * 220
        let control = CGPoint(x: (from.x + to.x) / 2 + fan, y: to.y + (from.y - to.y) * 0.15)
        let q = 1 - p
        let x = q * q * from.x + 2 * q * p * control.x + p * p * to.x
        let y = q * q * from.y + 2 * q * p * control.y + p * p * to.y
        return CGPoint(x: (x / pixel).rounded() * pixel, y: (y / pixel).rounded() * pixel)
    }
}
