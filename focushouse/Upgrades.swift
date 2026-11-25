import SwiftUI

/// Furniture bought with bricks. Sprites are 24×24 grids from `Art/furniture*.json`,
/// drawn at runtime, so the JSON is the only copy of the art.
struct Furniture: Decodable, Identifiable, Hashable {
    let name, tag, description: String
    let hobby: String?
    let level, cost: Int
    let grid: [String]
    let wall: Bool?   // hangs on a wall spot (boards, clocks) instead of standing on the floor
    var id: String { name }
    var onWall: Bool { wall ?? false }
    /// A Lv 2 item upgrades the Lv 1 item in the same group.
    var group: String { hobby ?? name }
}

/// The catalogue and the plain rules for buying. Bought items are saved by name
/// in UserDefaults ("owned"); spending is their total cost, taken off earned bricks.
enum Shop {
    enum State: Equatable { case owned, buy, needs(String), short(Int) }

    private struct File: Decodable { var palette: [String: String]?; var items: [Furniture] }

    static let catalog: (items: [Furniture], palette: [Character: Color]) = {
        let files = ["furniture", "furniture_hobbies", "furniture_more"].compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        }
        var palette: [Character: Color] = [:]
        for (k, v) in files.compactMap(\.palette).joined() {
            let n = UInt32(v.dropFirst(), radix: 16) ?? 0
            palette[Character(k)] = Color(red: Double(n >> 16 & 255) / 255, green: Double(n >> 8 & 255) / 255, blue: Double(n & 255) / 255)
        }
        return (files.flatMap(\.items), palette)
    }()
    static var items: [Furniture] { catalog.items }

    static func owned(_ raw: String) -> Set<String> { Set(raw.split(separator: "\n").map(String.init)) }

    static func spent(_ owned: Set<String>, in items: [Furniture] = items) -> Int {
        items.filter { owned.contains($0.name) }.reduce(0) { $0 + $1.cost }
    }

    static func state(_ item: Furniture, owned: Set<String>, balance: Int, in items: [Furniture] = items) -> State {
        if owned.contains(item.name) { return .owned }
        if let base = items.first(where: { $0.group == item.group && $0.level == item.level - 1 }),
           !owned.contains(base.name) { return .needs(base.name) }
        return balance >= item.cost ? .buy : .short(item.cost - balance)
    }

    /// What's in the room: the highest level bought in each group.
    static func room(_ owned: Set<String>) -> [Furniture] {
        Dictionary(grouping: items.filter { owned.contains($0.name) }, by: \.group).values
            .compactMap { $0.max { $0.level < $1.level } }
            .sorted { $0.name < $1.name }
    }

    /// A place in the house, in room pixels (top-left of a 24×24 sprite).
    struct Spot { let x, y: Int; let wall: Bool }

    /// Downstairs floor, upstairs floor, downstairs walls, upstairs walls. The
    /// first spots were the old one-room house's, so saved rooms keep their order.
    static let spots: [Spot] =
        [29, 53, 77].map { Spot(x: $0, y: RoomView.downstairs + RoomView.floorY, wall: false) }
        + [4, 28, 52, 76].map { Spot(x: $0, y: RoomView.floorY, wall: false) }
        + [29, 78].map { Spot(x: $0, y: RoomView.downstairs + RoomView.wallY, wall: true) }
        + [12, 68].map { Spot(x: $0, y: RoomView.wallY, wall: true) }

    /// How many things fit inside the house at once.
    static var roomCap: Int { spots.count }

    /// The house's spots, each a furniture group or "" when empty.
    /// Saved one per line in UserDefaults ("placed"), by group so upgrading
    /// Lv 1 → Lv 2 keeps its spot (if it still fits; see `refit`).
    static func slots(_ raw: String) -> [String] {
        let s = raw.components(separatedBy: "\n")
        return Array((s + Array(repeating: "", count: roomCap)).prefix(roomCap))
    }

    /// What stands in each spot (nil = empty). Something in the wrong kind of spot isn't shown.
    static func placed(_ raw: String, owned: Set<String>) -> [Furniture?] {
        let room = room(owned)
        return slots(raw).enumerated().map { i, g in room.first { $0.group == g && $0.onWall == spots[i].wall } }
    }

    /// Whether a group's current item (its highest level owned) hangs on the wall.
    static func onWall(_ group: String, owned: Set<String>) -> Bool {
        room(owned).first { $0.group == group }?.onWall ?? false
    }

    /// Whether `item` has an empty spot of its kind.
    static func hasRoom(for item: Furniture, _ raw: String, owned: Set<String>) -> Bool {
        let wall = onWall(item.group, owned: owned.union([item.name]))
        return placed(raw, owned: owned).enumerated().contains { $0.element == nil && spots[$0.offset].wall == wall }
    }

    /// After an upgrade changes kind (a floor hourglass becomes a wall clock), or for
    /// rooms saved before wall spots: move each misfit to a free spot of its kind, or out.
    static func refit(_ raw: String, owned: Set<String>) -> String {
        var s = slots(raw)
        for (i, g) in s.enumerated() where !g.isEmpty && room(owned).contains(where: { $0.group == g }) {
            let wall = onWall(g, owned: owned)
            guard wall != spots[i].wall else { continue }
            s[i] = ""
            if let j = s.indices.first(where: { s[$0].isEmpty && spots[$0].wall == wall && $0 != i }) { s[j] = g }
        }
        return s.joined(separator: "\n")
    }

    /// Drops a group on spot `i`. Moving within the house swaps with whatever is
    /// there; bringing something new in replaces it.
    static func put(_ group: String, at i: Int, in raw: String) -> String {
        var s = slots(raw)
        if let from = s.firstIndex(of: group) { s.swapAt(from, i) } else { s[i] = group }
        return s.joined(separator: "\n")
    }

    /// Takes a group out, or puts it in the first empty spot of its kind.
    static func toggle(_ group: String, wall: Bool = false, in raw: String) -> String {
        var s = slots(raw)
        if let i = s.firstIndex(of: group) { s[i] = "" }
        else if let i = s.indices.first(where: { s[$0].isEmpty && spots[$0].wall == wall }) { s[i] = group }
        return s.joined(separator: "\n")
    }
}

/// Inside the house: two storeys drawn at the furniture sprites' own pixel size.
/// Downstairs has the fireplace (under the chimney) and the stairs; each floor has
/// floor spots and wall spots for boards and clocks (`Shop.spots`). Long-press and
/// drag to move things between spots of the same kind, or drop something from
/// "Your things" onto a spot. Opens from the house's door on Home.
struct RoomView: View {
    @AppStorage("owned") private var ownedRaw = ""
    @AppStorage("placed") private var placedRaw = ""
    @State private var target: Int?

    /// The house in sprite pixels: two storeys of `storey` rows with a 2-row floor between.
    static let size = CGSize(width: 134, height: 202)
    static let storey = 100
    nonisolated static let downstairs = 102    // first row of the ground floor
    static let floorStart = 78     // within a storey: where the planks begin
    nonisolated static let floorY = 63         // a floor sprite's bottom row lands on row 86
    nonisolated static let wallY = 24
    static let stairsX = 104

    /// Fixed art and animation frames from `Art/room.json`, drawn by HY4 (via opencode).
    struct Art: Decodable {
        var fireplace: [String] = [], stairs: [String] = []
        var fire: [[String]] = [], catWalk: [[String]] = [], catSleep: [[String]] = [], catHang: [[String]] = []
    }
    static let art: Art = Bundle.main.url(forResource: "room", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Art.self, from: $0) } ?? Art()
    /// Where the fireplace's bottom row sits (on the downstairs floor).
    static var groundLine: Int { downstairs + floorY + 23 }

    var body: some View {
        let owned = Shop.owned(ownedRaw)
        let slots = Shop.placed(placedRaw, owned: owned)
        let items = slots.compactMap { $0 }

        GeometryReader { geo in
            let px = geo.size.width / Self.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in Self.draw(ctx, px: px, filled: slots.map { $0 != nil }) }
                if !Self.art.fireplace.isEmpty, !Self.art.stairs.isEmpty {
                    sprite(Self.art.fireplace, x: 2, bottom: Self.groundLine, px: px)
                    sprite(Self.art.stairs, x: Self.stairsX, bottom: Self.groundLine, px: px)
                }
                ForEach(slots.indices, id: \.self) { i in
                    spot(slots[i], wall: Shop.spots[i].wall, px: px)
                        .overlay { if target == i { Rectangle().strokeBorder(Color.gold, lineWidth: 3) } }
                        .dropDestination(for: String.self) { groups, _ in
                            // only things the student owns, not any text dragged in from elsewhere
                            guard let g = groups.first, Shop.room(owned).contains(where: { $0.group == g }),
                                  Shop.onWall(g, owned: owned) == Shop.spots[i].wall else { return false }   // boards on walls, the rest on floors
                            withAnimation(.snappy) { placedRaw = Shop.put(g, at: i, in: placedRaw) }
                            return true
                        } isTargeted: { on in
                            if on { target = i } else if target == i { target = nil }
                        }
                        .frame(width: 24 * px, height: 24 * px)
                        .position(x: (CGFloat(Shop.spots[i].x) + 12) * px, y: (CGFloat(Shop.spots[i].y) + 12) * px)
                }
                RoomLife(px: px)   // fire, embers, candle, the cat: on top, never in the way of a drop
            }
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .pixelBox(Color.wall)
        .sensoryFeedback(.selection, trigger: placedRaw)
        .onAppear { placedRaw = Shop.refit(placedRaw, owned: Shop.owned(ownedRaw)) }   // rooms saved before wall spots
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.isEmpty ? "Inside your house: empty" : "Inside your house: " + items.map(\.name).joined(separator: ", "))
    }

    /// Fixed art placed by its bottom-left pixel.
    private func sprite(_ grid: [String], x: Int, bottom: Int, px: CGFloat) -> some View {
        let w = CGFloat(grid[0].count), h = CGFloat(grid.count)
        return PixelSprite(grid: grid)
            .frame(width: w * px, height: h * px)
            .position(x: (CGFloat(x) + w / 2) * px, y: (CGFloat(bottom + 1) - h / 2) * px)
            .allowsHitTesting(false)
    }

    @ViewBuilder private func spot(_ item: Furniture?, wall: Bool, px: CGFloat) -> some View {
        if let item {
            PixelSprite(grid: item.grid)
                .draggable(item.group) { PixelSprite(grid: item.grid).frame(width: 72) }
        } else if wall {
            // an empty wall spot: a dashed picture-frame outline
            Rectangle().strokeBorder(Color(light: 0x8A6A45, dark: 0x8A6A45).opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                .padding(3 * px)
                .contentShape(Rectangle())
        } else {
            // an empty spot: a dashed footprint on the floor
            Rectangle().strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                .frame(height: 8 * px)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, -1 * px)
                .contentShape(Rectangle())
        }
    }

    /// The rooms themselves, in fixed pixel-art colours like the house sprites.
    static func draw(_ ctx: GraphicsContext, px: CGFloat, filled: [Bool]) {
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ hex: UInt32, _ opacity: Double = 1) {
            ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: CGFloat(w) * px + 0.5, height: CGFloat(h) * px + 0.5)),
                     with: .color(Color(light: hex, dark: hex).opacity(opacity)))
        }
        let w = Int(size.width)
        /// One storey from row `top`: wallpaper, beam, skirting, planks.
        func drawStorey(_ top: Int, paper: UInt32, stripe: UInt32) {
            fill(0, top, w, floorStart, paper)
            for x in stride(from: 3, to: w, by: 6) { fill(x, top + 2, 1, floorStart - 4, stripe) }
            fill(0, top, w, 2, 0x553A22)                                             // ceiling beam
            fill(0, top + floorStart - 3, w, 3, 0x6A4426); fill(0, top + floorStart - 3, w, 1, 0x91603A)   // skirting
            for (band, y) in stride(from: top + floorStart, to: top + storey, by: 3).enumerated() {
                let rows = min(3, top + storey - y)
                fill(0, y, w, rows, band % 2 == 0 ? 0x91603A : 0x7A5334)
                for x in stride(from: (band * 11) % 26, to: w, by: 26) { fill(x, y, 1, rows, 0x553A22) }
            }
        }
        drawStorey(0, paper: 0xDDE9E2, stripe: 0xC8DCD2)            // upstairs: cool mint
        drawStorey(downstairs, paper: 0xF4E7CE, stripe: 0xE6D3AF)   // downstairs: warm cream
        fill(0, storey, w, downstairs - storey, 0x3E2A18)       // the floor between

        // Downstairs window, between the two wall spots.
        let wy = downstairs + wallY + 3
        fill(54, wy, 23, 18, 0x6A4426)
        for (x, y, c) in [(56, wy + 2, 0x8ECFE6), (66, wy + 2, 0x8ECFE6), (56, wy + 9, 0x4D93B0), (66, wy + 9, 0x4D93B0)] as [(Int, Int, UInt32)] {
            fill(x, y, 9, 6, c)
        }
        fill(57, wy + 3, 1, 3, 0xF4FBFF); fill(67, wy + 3, 1, 3, 0xF4FBFF)   // glints
        fill(53, wy + 18, 25, 1, 0xE8F0FB)                                  // sill

        // Upstairs: the round attic window from the house's front.
        let cx = 52, cy = wallY + 12, r = 9
        for dy in -r...r {
            let half = Int((Double(r * r - dy * dy)).squareRoot().rounded())
            fill(cx - half, cy + dy, half * 2 + 1, 1, 0x6A4426)
            if abs(dy) < r - 1 {
                let inner = Int((Double((r - 2) * (r - 2) - dy * dy)).squareRoot().rounded())
                if (r - 2) * (r - 2) >= dy * dy { fill(cx - inner, cy + dy, inner * 2 + 1, 1, dy < 0 ? 0x8ECFE6 : 0x4D93B0) }
            }
        }
        fill(cx, cy - r + 1, 1, r * 2 - 1, 0x6A4426); fill(cx - r + 1, cy, r * 2 - 1, 1, 0x6A4426)   // cross bars
        fill(cx - 4, cy - 5, 1, 3, 0xF4FBFF)

        // The stairwell: an opening in the floor above the stairs.
        fill(stairsX, storey, w - stairsX, downstairs - storey, 0x2B2340, 0.5)

        for (i, on) in filled.enumerated() where on && !Shop.spots[i].wall {   // soft shadow under furniture
            fill(Shop.spots[i].x + 2, Shop.spots[i].y + 23, 20, 2, 0x2B2340, 0.25)
        }
    }
}

/// The room's moving bits, frames by HY4: the fire flickers, embers drift up,
/// the mantel candle glows, and Pommy wanders the ground floor then naps
/// by the fire (tap for hearts; drag to carry her by the scruff, she swings with
/// the finger's speed, and lands on the floor below). Still frames with Reduce Motion.
private struct RoomLife: View {
    let px: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pettedAt = Date.distantPast
    @State private var pets = 0
    @State private var held: CGPoint?          // finger, in room pixels, while carrying the cat
    @State private var swing = 0.0             // degrees; the body lags behind the finger
    @State private var settle: Task<Void, Never>?
    @State private var drop: Drop?

    /// Where the cat was let go: she falls to `bottom`, looks around, then walks home (downstairs) or naps there (upstairs).
    struct Drop { var x: Double, top: Double, bottom: Int, at: Date }
    static let gravity = 400.0                 // room px / s²

    private let art = RoomView.art
    private var fireTop: Int { RoomView.groundLine - art.fireplace.count + 1 }

    var body: some View {
        let falling = held != nil || drop.map { Date.now.timeIntervalSince($0.at) < 1.5 } ?? false
        TimelineView(.animation(minimumInterval: falling ? 1 / 30 : 1 / 8, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                if !art.fire.isEmpty {
                    let frame = art.fire[Int(t * 6) % art.fire.count]
                    place(frame, x: 2, y: CGFloat(fireTop + 71))
                }
                Canvas { ctx, _ in glow(ctx, t: t) }
                    .allowsHitTesting(false)
                cat(t: t, now: timeline.date)
            }
            .coordinateSpace(.named("room"))
        }
        .accessibilityHidden(true)
        .sensoryFeedback(.impact(weight: .light), trigger: pets)
    }

    /// A sprite with its top-left at room pixel (x, y).
    /// `swing` turns it about its top centre (the scruff), before it's positioned.
    private func place(_ grid: [String], x: CGFloat, y: CGFloat, flip: Bool = false, swing: Double = 0) -> some View {
        let w = CGFloat(grid.first?.count ?? 0), h = CGFloat(grid.count)
        return PixelSprite(grid: grid)
            .frame(width: w * px, height: h * px)
            .scaleEffect(x: flip ? -1 : 1)
            .rotationEffect(.degrees(swing), anchor: .top)
            .position(x: (x + w / 2) * px, y: (y + h / 2) * px)
            .allowsHitTesting(false)
    }

    /// Candle glow and rising embers, in room pixels.
    private func glow(_ ctx: GraphicsContext, t: Double) {
        func dot(_ x: Double, _ y: Double, _ size: Double, _ color: Color) {
            ctx.fill(Path(CGRect(x: x * px, y: y * px, width: size * px, height: size * px)), with: .color(color))
        }
        // candle on the mantel: a warm halo that breathes and flickers
        let flicker = 0.18 + 0.08 * sin(t * 9) + 0.05 * sin(t * 23)
        ctx.fill(Path(ellipseIn: CGRect(x: 10.5 * px, y: Double(fireTop + 52) * px, width: 7 * px, height: 7 * px)),
                 with: .color(Color(light: 0xF8E3A0, dark: 0xF8E3A0).opacity(flicker)))
        guard !reduceMotion else { return }
        // embers: three sparks, each rising ~14 px over its own 2.4 s loop
        for i in 0..<3 {
            let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
            let x = 13 + Double(i * 3) + 1.5 * sin(t * 3 + Double(i) * 2)
            let y = Double(fireTop + 72) - phase * 14
            dot(x.rounded(), y.rounded(), 1, Color(light: i == 1 ? 0xF8E3A0 : 0xE9B24A, dark: i == 1 ? 0xF8E3A0 : 0xE9B24A).opacity(1 - phase))
        }
    }

    /// 40 s loop: walk right from the hearth, pause, walk back, nap in front of the fire.
    /// After a drop the loop picks up from wherever she lands.
    private func pose(t: Double, now: Date) -> (x: Double, y: Double, grid: [String], flip: Bool) {
        let home = 27.0, far = 84.0, speed = 6.0            // room pixels, px per second
        let walk = (far - home) / speed                    // 13 s each way
        let loop = walk * 2 + 4 + 14
        let ground = RoomView.groundLine + 3              // a little in front of the furniture
        let walking = art.catWalk[Int(t * 6) % art.catWalk.count]
        let napping = art.catSleep[Int(t / 1.6) % art.catSleep.count]
        func looping(_ s: Double) -> (Double, [String], Bool) {
            reduceMotion || s >= walk * 2 + 4 ? (home, napping, false)            // napping, breathing
            : s < walk ? (home + s * speed, walking, false)                       // walking right
            : s < walk + 4 ? (far, art.catWalk[0], false)                         // a look around
            : (far - (s - walk - 4) * speed, walking, true)                       // walking home
        }
        if let held {   // hanging from the finger by the scruff
            let g = art.catHang[0]
            return (held.x - Double(g[0].count) / 2, held.y - 1, g, false)
        }
        guard let drop else {
            let (x, g, f) = looping(t.truncatingRemainder(dividingBy: loop))
            return (x, Double(ground - g.count + 1), g, f)
        }
        let d = reduceMotion ? 99 : now.timeIntervalSince(drop.at)
        let floorTop = Double(drop.bottom - art.catWalk[0].count + 1)
        let fall = (2 * max(0, floorTop - drop.top) / Self.gravity).squareRoot()
        if d < fall { return (drop.x, drop.top + Self.gravity * d * d / 2, art.catWalk[0], false) }
        if d < fall + 1.5 { return (drop.x, floorTop, art.catWalk[0], false) }      // lands, looks around
        if drop.bottom != ground {                                                     // upstairs: naps where she landed
            return (drop.x, Double(drop.bottom - napping.count + 1), napping, false)
        }
        let back = abs(drop.x - home) / speed, w = d - fall - 1.5
        if w < back { return (drop.x + (drop.x > home ? -w : w) * speed, floorTop, walking, drop.x > home) }
        let (x, g, f) = looping((w - back + walk * 2 + 4).truncatingRemainder(dividingBy: loop))
        return (x, Double(ground - g.count + 1), g, f)
    }

    @ViewBuilder private func cat(t: Double, now: Date) -> some View {
        if !art.catWalk.isEmpty, !art.catSleep.isEmpty, !art.catHang.isEmpty {
            let pose = pose(t: t, now: now)
            let w = Double(pose.grid.first?.count ?? 16), h = Double(pose.grid.count)
            let petted = now.timeIntervalSince(pettedAt)
            ZStack(alignment: .topLeading) {
                // held: follows the finger smoothly; otherwise snaps to the pixel grid
                place(pose.grid, x: held == nil ? pose.x.rounded() : pose.x, y: held == nil ? pose.y.rounded() : pose.y,
                      flip: pose.flip, swing: held == nil ? 0 : swing)
                if petted < 1.4, held == nil {   // little pink hearts float up
                    ForEach(0..<2, id: \.self) { i in
                        Text("♥").font(.system(size: 5 * px, weight: .black)).foregroundStyle(Color(light: 0xE3A3B4, dark: 0xE3A3B4))
                            .position(x: (pose.x + w / 3 + Double(i * 6)) * px, y: (pose.y - 2 - petted * 8 - Double(i * 2)) * px)
                            .opacity(1 - petted / 1.4)
                            .allowsHitTesting(false)
                    }
                }
                // the cat itself takes taps (pet her) and drags (carry her)
                Color.clear
                    .frame(width: w * px, height: h * px)
                    .contentShape(Rectangle())
                    .position(x: (pose.x + w / 2) * px, y: (pose.y + h / 2) * px)
                    .onTapGesture { pettedAt = .now; pets += 1 }
                    .gesture(carry)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Pick Pommy up by the scruff; her body swings against the finger's sideways speed.
    private var carry: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("room"))
            .onChanged { v in
                if held == nil { pets += 1 }
                held = CGPoint(x: min(max(v.location.x / px, 0), RoomView.size.width),
                               y: min(max(v.location.y / px, 0), RoomView.size.height))
                guard !reduceMotion else { return }
                withAnimation(.interactiveSpring(duration: 0.25)) { swing = min(max(v.velocity.width * 0.08, -55), 55) }
                settle?.cancel()
                settle = Task { @MainActor in   // finger stops: she swings back and forth to rest
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(duration: 0.9, bounce: 0.65)) { swing = 0 }
                }
            }
            .onEnded { _ in
                guard let held else { return }
                settle?.cancel()
                let walkW = Double(art.catWalk[0].first?.count ?? 18)
                let ground = RoomView.groundLine + 3
                drop = Drop(x: min(max(held.x - walkW / 2, 0), RoomView.size.width - walkW), top: held.y,
                            bottom: held.y < Double(RoomView.storey) ? ground - RoomView.downstairs : ground, at: .now)
                self.held = nil
                swing = 0
            }
    }
}

/// A furniture sprite, crisp at any size.
struct PixelSprite: View {
    let grid: [String]

    var body: some View {
        Canvas { ctx, size in
            let px = size.width / CGFloat(grid.first?.count ?? 24)
            for (y, row) in grid.enumerated() {
                for (x, c) in row.enumerated() where c != "." {
                    guard let color = Shop.catalog.palette[c] else { continue }
                    // a hair wider so neighbouring pixels never show a seam
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px + 0.5, height: px + 0.5)), with: .color(color))
                }
            }
        }
        .aspectRatio(CGFloat(grid.first?.count ?? 24) / CGFloat(max(grid.count, 1)), contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The furniture shop: wooden shelves of things to buy with bricks, and the
/// student's room on top. Opens from "Decorate with bricks" inside the house.
struct UpgradesView: View {
    let earned: Int
    @AppStorage("owned") private var ownedRaw = ""
    @AppStorage("placed") private var placedRaw = ""
    @State private var picked: Furniture?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let owned = Shop.owned(ownedRaw)
        let balance = earned - Shop.spent(owned)
        let room = Shop.room(owned)
        let placed = Shop.placed(placedRaw, owned: owned).compactMap { $0 }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Finish tasks to earn bricks, then spend them here. Bricks never repair the house: only rest does.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Inside your house \(placed.count)/\(Shop.roomCap)").font(.pixel(20, relativeTo: .headline).weight(.bold))
                        RoomView().frame(maxHeight: 340)
                        Text(room.isEmpty ? "Buy something from the shelves below, then put it inside."
                                          : "Hold and drag your things onto a spot, or tap one to put it in or take it out.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !room.isEmpty {
                        shelf("Your things", room, owned: owned, balance: balance, placed: placed)
                    }
                    ForEach(["Work", "Hobbies", "Rest"], id: \.self) { tag in
                        shelf(tag, Shop.items.filter { $0.tag == tag }, owned: owned, balance: balance)
                    }
                }
                .padding()
            }
            .background(Color.paper)
            .navigationTitle("Upgrades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Upgrades").font(.pixel(22, relativeTo: .headline).weight(.bold))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    BrickCount(value: max(0, balance))
                }
            }
            .sheet(item: $picked) { item in
                FurnitureDetail(item: item, state: Shop.state(item, owned: owned, balance: balance),
                                isPlaced: placed.contains { $0.group == item.group },
                                roomFull: !Shop.hasRoom(for: item, placedRaw, owned: owned)) {
                    let now = owned.union([item.name])
                    ownedRaw = now.sorted().joined(separator: "\n")
                    placedRaw = Shop.refit(placedRaw, owned: now)   // an upgrade may move from floor to wall
                    // new things go straight inside while there's space
                    if item.level == 1, !placed.contains(where: { $0.group == item.group }) {
                        placedRaw = Shop.toggle(item.group, wall: item.onWall, in: placedRaw)
                    }
                } place: {
                    placedRaw = Shop.toggle(item.group, wall: Shop.onWall(item.group, owned: owned), in: placedRaw)
                }
            }
            .sensoryFeedback(.success, trigger: ownedRaw)
        }
    }

    /// A titled wooden shelf with items standing on the plank.
    private func shelf(_ title: String, _ items: [Furniture], owned: Set<String>, balance: Int, placed: [Furniture] = []) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.pixel(20, relativeTo: .headline).weight(.bold))   // pixel caps B reads as G
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(items) { item in
                        let button = Button { picked = item } label: {
                            tile(item, Shop.state(item, owned: owned, balance: balance), placed: placed.contains(item))
                        }
                        .buttonStyle(.plain)
                        if owned.contains(item.name) {
                            button.draggable(item.group) { PixelSprite(grid: item.grid).frame(width: 72) }
                        } else {
                            button
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 18)   // items stand on the plank
            }
            .background(alignment: .bottom) { Plank() }
            .pixelBox(Color.wall)
        }
    }

    private func tile(_ item: Furniture, _ state: Shop.State, placed: Bool) -> some View {
        VStack(spacing: 6) {
            Text(item.name).font(.caption.weight(.semibold)).lineLimit(2)
                .multilineTextAlignment(.center).frame(width: 92, height: 32, alignment: .bottom)
            PixelSprite(grid: item.grid).frame(width: 84)
                .opacity(state == .owned || state == .buy ? 1 : 0.55)
            PriceTag(item: item, state: state, placed: placed)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(placed ? "in your house" : PriceTag.text(item, state))")
    }
}

/// The brick icon and a pixel number, as on Home's toolbar.
struct BrickCount: View {
    let value: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image("icon.brick").pixelArt().frame(width: 28)
            PixelNumber(value: value).foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 6)
        .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : value) { $0.scaleEffect($1) } keyframes: { _ in
            SpringKeyframe(1.35, duration: 0.15)
            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) bricks")
    }
}

private struct PriceTag: View {
    let item: Furniture
    let state: Shop.State
    var placed = false

    static func text(_ item: Furniture, _ state: Shop.State) -> String {
        switch state {
        case .owned: "owned"
        case .needs(let base): "needs \(base) first"
        case .buy, .short: "\(item.cost) bricks"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .owned:
                Image(systemName: placed ? "house.fill" : "checkmark").font(.caption2.weight(.heavy))
                Text(placed ? "In house" : "Owned").font(.caption2.weight(.bold))
            case .needs:
                Image(systemName: "lock.fill").font(.caption2)
                Text("Lv 1 first").font(.caption2.weight(.bold))
            case .buy, .short:
                Image("icon.brick").pixelArt().frame(width: 14)
                PixelNumber(value: item.cost, size: 2)
            }
        }
        .foregroundStyle(state == .owned ? Color.white : Color.ink)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(state == .owned ? Color.grass : state == .buy ? Color.gold : Color.track)
        .overlay(Rectangle().strokeBorder(Color.ink, lineWidth: 2))
    }
}

/// A wooden shelf board along the bottom of a shelf.
private struct Plank: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.ink).frame(height: 3)
            Rectangle().fill(Color(red: 0.78, green: 0.56, blue: 0.33)).frame(height: 5)
            Rectangle().fill(Color(red: 0.60, green: 0.40, blue: 0.21)).frame(height: 7)
        }
    }
}

private struct FurnitureDetail: View {
    let item: Furniture
    let state: Shop.State
    let isPlaced: Bool
    let roomFull: Bool
    let buy: () -> Void
    let place: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var enabled: Bool { state == .buy || (state == .owned && (isPlaced || !roomFull)) }

    var body: some View {
        VStack(spacing: 16) {
            PixelSprite(grid: item.grid).frame(width: 168)
                .padding(16).frame(maxWidth: .infinity).pixelBox(Color.wall)
            VStack(spacing: 6) {
                Text(item.name).font(.pixel(26, relativeTo: .title2).weight(.bold))
                Text("\(item.tag) · \(item.hobby ?? item.name) · Lv \(item.level)")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text(item.description).font(.subheadline).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button {
                state == .owned ? place() : buy()
                dismiss()
            } label: {
                Group {
                    switch state {
                    case .owned: Text(isPlaced ? "Take out of house" : roomFull ? "House is full (\(Shop.roomCap)/\(Shop.roomCap))" : "Put in house")
                    case .needs(let base): Text("Buy \(base) first")
                    case .short(let n): Text("\(n) more bricks needed")
                    case .buy: Text("\(item.level > 1 ? "Upgrade" : "Buy") for \(item.cost) bricks")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity).padding()
                .pixelBox(enabled ? Color.gold : Color.track)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
        .padding(20)
        .foregroundStyle(Color.ink)
        .background(Color.paper)
        .presentationDetents([.medium, .large])
    }
}
