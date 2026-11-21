import SwiftUI

/// The "the AI is planning" loader: a little brick wall that builds itself one
/// brick at a time, clears, and starts again, with a friendly line under it that
/// changes every couple of seconds. Reduce Motion shows the finished wall.
struct BrickLoader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date.now

    /// One sprite pixel, in points.
    private static let px: CGFloat = 2
    private static let brick = CGSize(width: 9 * px, height: 5 * px)
    private static let rows = 3
    private static let step = 0.14    // seconds per brick
    private static let hold = 0.6     // the finished wall rests
    private static let fade = 0.3     // then clears
    private static let drop = 0.18    // a brick falls into place

    /// Bottom row first: four bricks, then three offset by half a brick.
    private static let spots: [CGPoint] = (0..<rows).flatMap { row in
        let count = row.isMultiple(of: 2) ? 4 : 3
        let inset = row.isMultiple(of: 2) ? 0 : brick.width / 2
        return (0..<count).map { CGPoint(x: inset + CGFloat($0) * brick.width,
                                         y: CGFloat(rows - 1 - row) * brick.height) }
    }
    private static var size: CGSize {
        CGSize(width: 4 * brick.width, height: CGFloat(rows) * brick.height)
    }
    private static var build: Double { Double(spots.count) * step }
    private static var cycle: Double { build + hold + fade }

    private static let messages = ["Reading your goal…", "Splitting it into steps…",
                                   "Timing each task…", "Fitting it around your day…"]

    var body: some View {
        if reduceMotion {
            content(at: nil)
        } else {
            // 12 fps on purpose: smooth motion looks wrong on pixel art.
            TimelineView(.animation(minimumInterval: 1 / 12)) { timeline in
                content(at: max(0, timeline.date.timeIntervalSince(started)))
            }
        }
    }

    private func content(at time: Double?) -> some View {
        let t = time.map { $0.truncatingRemainder(dividingBy: Self.cycle) }
        return VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                ForEach(Self.spots.indices, id: \.self) { i in
                    Image("icon.brick").pixelArt()
                        .frame(width: Self.brick.width, height: Self.brick.height)
                        .opacity(Self.opacity(i, t))
                        .offset(y: Self.fall(i, t))
                        .offset(x: Self.spots[i].x, y: Self.spots[i].y)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .padding(.top, Self.px * 4)   // room for bricks falling in from above

            Text(time.map { Self.messages[Int($0 / 2) % Self.messages.count] }
                 ?? "Planning your tasks…")
                .font(.pixel(15, relativeTo: .footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Planning your tasks")
    }

    /// 0 until the brick's turn, then 1; the whole wall fades as it clears.
    private static func opacity(_ index: Int, _ t: Double?) -> Double {
        guard let t else { return 1 }
        if t < Double(index) * step { return 0 }
        let clear = build + hold
        return t > clear ? max(0, 1 - (t - clear) / fade) : 1
    }

    /// A brick drops the last few pixels into its spot, snapped to the sprite grid.
    private static func fall(_ index: Int, _ t: Double?) -> CGFloat {
        guard let t else { return 0 }
        let left = 1 - (t - Double(index) * step) / drop
        return left > 0 ? -(left * 4).rounded() * px : 0
    }
}
