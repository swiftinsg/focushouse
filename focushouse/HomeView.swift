import SwiftUI
import SwiftData

/// The main page: the house, how stressed and rested this week has been, the
/// next task, and the brick counter.
struct HomeView: View {
    @Query private var tasks: [PlanTask]
    @Query private var todos: [TodoItem]
    @AppStorage("restLog", store: RestLog.defaults) private var restData = Data()
    @AppStorage("ratings") private var ratingData = Data()
    @AppStorage(KeptTask.key) private var keptData = Data()
    @State private var events: [(title: String, start: Date, minutes: Int)] = []
    @State private var showSettings = false
    @State private var showInside = false
    @State private var doorStep = 0        // 0 shut, 1 ajar, 2 open
    @AppStorage("owned") private var ownedRaw = ""
    @AppStorage("insight") private var insight = ""
    @AppStorage("homeTourDone") private var tourDone = false
    @AppStorage("weeklySummaryOn") private var summaryOn = true

    var body: some View {
        let now = Date.now
        let log = RestLog.load(restData)
        let status = self.status
        let streak = status.streak
        let restToday = log.seconds(on: now)
        let state = House.state(streak: streak, log: log, now: now)
        let level = House.level(earned: status.earned)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack {
                        HouseScene(state: state, level: level)
                            .background(state.sky)
                            .id(state)
                            .transition(.opacity)   // crossfade when the house changes state
                    }
                    .animation(.easeInOut(duration: 0.8), value: state)
                    .animation(.easeInOut(duration: 0.8), value: level)
                    .overlay {
                        // the door (sprite pixels 32–42 × 42–61) is a button into the house
                        GeometryReader { geo in
                            let px = geo.size.width / HouseScene.width
                            Canvas { ctx, _ in Self.drawDoor(ctx, px: px, step: doorStep) }
                                .allowsHitTesting(false)
                            Button { enter() } label: { Color.clear.contentShape(Rectangle()) }
                                .frame(width: 11 * px, height: 20 * px)
                                .tour(.door)   // before .position, which fills the house
                                .position(x: 37.5 * px, y: 52 * px)
                        }
                    }
                    .sensoryFeedback(trigger: doorStep) { _, step in
                        // latch clicks, then the door swings open
                        switch step {
                        case 1: .impact(flexibility: .soft, intensity: 0.6)
                        case 2: .impact(weight: .medium)
                        default: nil
                        }
                    }
                    .pixelBox()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Your house: \(state.title), \(House.levelNames[level])")
                    .accessibilityHint("Double-tap to go inside")
                    .accessibilityAction { enter() }
                    .tour(.house)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.title)
                            .font(.pixel(30, relativeTo: .title))
                            .foregroundStyle(state == .calm || state == .resting ? Color.grass : Color.brick)
                        Text(state.message).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .tour(.status)

                    BrickMeter(title: "Stress this week",
                               detail: streak == 0 ? "Low" : "\(streak) day\(streak == 1 ? "" : "s") in a row",
                               filled: min(10, Int((Double(streak) / 6 * 10).rounded())),
                               color: streak >= 4 ? .brick : streak >= 2 ? .orange : .grass)
                        .tour(.stress)
                    BrickMeter(title: "Rest today",
                               detail: "\(Self.duration(restToday)) / \(Self.duration(House.restGoal)) away",
                               filled: 0,
                               color: .blue,
                               fraction: restToday / House.restGoal)
                        .tour(.rest)
                    BrickMeter(title: "House: \(House.levelNames[level])",
                               detail: House.toNextLevel(earned: status.earned).map { "\($0) bricks to fix up" } ?? "All fixed up",
                               filled: level * 2,
                               color: .brick)

                    if state != .calm && state != .resting { restCard }
                    if let next { nextCard(next, status).tour(.next) }
                    if summaryOn {
                        NavigationLink {
                            WeeklySummaryView(stats: WeekStats(items: status.weekItems(tasks: tasks, todos: todos, events: events),
                                                               rest: { log.seconds(on: $0) }))
                        } label: { insightCard }
                        .buttonStyle(.plain)
                    } else if !insight.isEmpty { insightCard }
                }
                .padding()
            }
            .background(Color.paper)
            .homeTour(isOn: Binding(get: { !tourDone }, set: { tourDone = !$0 }))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .principal) {
                    Text("focushouse").font(.pixel(22, relativeTo: .headline).weight(.bold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    BrickCount(value: max(0, status.earned - Shop.spent(Shop.owned(ownedRaw))))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showInside, onDismiss: { doorStep = 0 }) {   // the door shuts behind you
                InsideView(earned: status.earned) { withoutAnimation { showInside = false } }
                    .presentationBackground(.clear)   // Home shows through while the screen fades
            }
            .task { await refresh() }
        }
    }

    /// Opens the door in two pixel frames, then steps inside: InsideView fades
    /// the screen to black and the room in from the dark.
    private func enter() {
        guard doorStep == 0 else { return }
        Task { @MainActor in
            doorStep = 1
            try? await Task.sleep(for: .milliseconds(120))
            doorStep = 2
            try? await Task.sleep(for: .milliseconds(180))
            withoutAnimation { showInside = true }
        }
    }

    /// The door's open frames, drawn over the sprite's door (columns 32–42, rows 42–61;
    /// the knob is on the left, so it swings open from the left edge).
    static func drawDoor(_ ctx: GraphicsContext, px: CGFloat, step: Int) {
        guard step > 0 else { return }
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: Color) {
            ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: CGFloat(w) * px + 0.5, height: CGFloat(h) * px + 0.5)), with: .color(c))
        }
        let light = Color(red: 0.96, green: 0.79, blue: 0.36)     // warm room light (palette k)
        let leaf = Color(red: 0.06, green: 0.22, blue: 0.31)      // door edge (palette n)
        if step == 1 {                                            // ajar: a sliver of light
            fill(32, 42, 2, 20, light)
        } else {                                                  // open: leaf swung in, light spills out
            fill(32, 42, 8, 20, light)
            fill(40, 42, 3, 20, leaf)
            fill(31, 62, 10, 1, light.opacity(0.5))
        }
    }

    private var restCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.zzz.fill").font(.title2).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rest to repair").font(.pixel(20, relativeTo: .headline).weight(.bold))
                Text("Put your phone down for \(Self.duration(House.restGoal)) today to rebuild it.")
                    .font(.footnote)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .pixelBox(Color(red: 0.18, green: 0.21, blue: 0.35))
        .accessibilityElement(children: .combine)
    }

    /// The AI's weekly insight from the student's check-ins.
    private var insightCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lightbulb.fill").font(.title2).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your week").font(.pixel(20, relativeTo: .headline).weight(.bold))
                Text(insight.isEmpty ? "See your different stresses, rest and what weighed on you most." : insight)
                    .font(.footnote)
            }
            Spacer(minLength: 0)
            if summaryOn { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
        }
        .padding()
        .pixelBox()
        .accessibilityElement(children: .combine)
    }

    private func nextCard(_ task: PlanTask, _ status: HouseStatus) -> some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(.snappy) { CheckIn.shared.tick(task) }
            } label: {
                Rectangle().strokeBorder(Color.ink, lineWidth: 3).frame(width: 26, height: 26)
            }
            .accessibilityLabel("Mark \(task.title) done")
            VStack(alignment: .leading, spacing: 2) {
                Text("Next: \(task.title)").font(.subheadline.weight(.semibold))
                let earns = House.bricks(minutes: task.estimate ?? task.minutes, actual: nil, status.rating(task.title, priority: task.priority, category: task.category).effort, focused: false)
                Text("\(task.start!.formatted(date: .omitted, time: .shortened))–\(task.end!.formatted(date: .omitted, time: .shortened))" + (earns > 0 ? " · +\(earns) bricks" : ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .pixelBox()
    }

    private var status: HouseStatus {
        HouseStatus(tasks: tasks, todos: todos, events: events, ratings: Ratings.load(ratingData), kept: KeptTask.load(keptData))
    }

    /// Loads this fortnight's Calendar events, then has the AI rate anything new.
    private func refresh() async {
        let now = Date.now
        events = CalendarSync.attended(from: now.addingTimeInterval(-14 * 86_400), to: now.addingTimeInterval(86_400),
                                       excluding: Set(tasks.compactMap(\.eventID)))
        let rated = Ratings.load(ratingData)
        let titles = Set(tasks.map(\.title) + todos.map(\.name) + events.map(\.title))
            .filter { !$0.isEmpty && rated[Ratings.key($0)] == nil }
        await Ratings.rate(Array(titles))
        await Reflections.refreshInsight(tasks.filter { $0.checkIn == PlanTask.CheckInState.answered.rawValue })
    }

    private var next: PlanTask? {
        tasks.filter { !$0.done && ($0.end ?? .distantPast) > .now }
            .min { $0.start! < $1.start! }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t, change)
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m") : "\(m)m"
    }
}

/// Inside the house, through the front door: the room with the student's
/// furniture, and a way to the shop to decorate.
/// Going in or out fades through black, like walking through a doorway in a
/// pixel game: fade out, a beat in the dark, fade in on the other side.
struct InsideView: View {
    let earned: Int
    /// Takes the cover away without its own slide; the fades are the transition.
    var leave: () -> Void
    @State private var showUpgrades = false
    @State private var showRoom = false
    @State private var dark = 0.0   // the black screen between Home and the room

    var body: some View {
        ZStack {
            if showRoom { room }
            Color.black.opacity(dark).ignoresSafeArea()
                .allowsHitTesting(dark > 0)
        }
        .task {
            await fade(to: 1, .easeIn(duration: 0.3))
            showRoom = true
            try? await Task.sleep(for: .milliseconds(150))
            await fade(to: 0, .easeOut(duration: 0.35))
        }
    }

    private func exit() {
        Task {
            await fade(to: 1, .easeIn(duration: 0.3))
            showRoom = false
            try? await Task.sleep(for: .milliseconds(150))
            await fade(to: 0, .easeOut(duration: 0.35))
            leave()
        }
    }

    private func fade(to value: Double, _ curve: Animation) async {
        await withCheckedContinuation { done in
            withAnimation(curve) { dark = value } completion: { done.resume() }
        }
    }

    private var room: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                RoomView()
                    .frame(maxWidth: .infinity)
                Text("Hold and drag your furniture to move it around. Up to \(Shop.roomCap) things fit inside.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { showUpgrades = true } label: {
                    Label("Decorate with bricks", systemImage: "paintbrush.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding()
                        .pixelBox(Color.gold)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding()
            .foregroundStyle(Color.ink)
            .background(Color.paper)
            .pixelTitle("Inside")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Leave", systemImage: "door.left.hand.open") { exit() }
                }
            }
            .sheet(isPresented: $showUpgrades) { UpgradesView(earned: earned) }
        }
    }
}

/// The house sprite (96×64, `house.<state>.<level>`, tools/house_art.py) with a
/// little life on top, in the sprite's own pixels: chimney smoke when calm, grey
/// smoke when stressed, rain when overloaded, rain and falling bricks when
/// crumbling, twinkling stars and Z's when resting. Off with Reduce Motion.
struct HouseScene: View {
    let state: House.State
    var level = 4
    static let width: CGFloat = 96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image("house.\(state.rawValue).\(level)").pixelArt()
            .overlay {
                if !reduceMotion {
                    // 12 fps on purpose: smooth motion looks wrong on pixel art.
                    TimelineView(.animation(minimumInterval: 1 / 12)) { timeline in
                        Canvas { ctx, size in
                            Self.draw(state, t: timeline.date.timeIntervalSinceReferenceDate, ctx: ctx, px: size.width / Self.width)
                        }
                    }
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
    }

    static func draw(_ state: House.State, t: Double, ctx: GraphicsContext, px: CGFloat) {
        /// One sprite pixel (or a w×h block), snapped to the grid.
        func dot(_ x: Double, _ y: Double, _ color: Color, w: Double = 1, h: Double = 1) {
            ctx.fill(Path(CGRect(x: x.rounded() * px, y: y.rounded() * px, width: w * px, height: h * px)), with: .color(color))
        }
        /// 0→1 every `period` seconds, offset per particle.
        func phase(_ period: Double, _ offset: Double) -> Double {
            (t / period + offset).truncatingRemainder(dividingBy: 1)
        }
        func smoke(_ color: Color, period: Double) {   // from the chimney top (x 24–32, y 15)
            for i in 0..<3 {
                let p = phase(period, Double(i) / 3)
                let size: Double = p < 0.5 ? 4 : 3
                dot(27 + p * 10 + sin(p * 6) * 2, 12 - p * 12, color.opacity(1 - p), w: size, h: size)
            }
        }
        func rain(_ drops: Int) {
            for i in 0..<drops {
                // 37 is coprime with 96, so every drop gets its own column
                dot(Double((i * 37 + 5) % 96), 2 + phase(0.6, Double(i) * 0.137) * 58,
                    Color(red: 0.62, green: 0.71, blue: 0.85).opacity(0.85), h: 4)
            }
        }

        switch state {
        case .calm:
            smoke(.white, period: 3)
        case .stressed:
            smoke(Color(white: 0.55), period: 1.8)
        case .overloaded:
            rain(24)
        case .crumbling:
            rain(48)
            for (i, x) in [17.0, 73].enumerated() {   // bricks slipping off the eaves
                let p = phase(2.4, Double(i) / 2)
                if p < 0.5 { dot(x, 40 + 21 * (p * 2) * (p * 2), Color(red: 0.70, green: 0.29, blue: 0.20), w: 4, h: 2) }
            }
        case .resting:
            for (i, (x, y)) in [(6.0, 4.0), (16, 9), (30, 3), (64, 6), (72, 14), (90, 22), (10, 24)].enumerated() {
                dot(x, y, Color(red: 1, green: 0.95, blue: 0.7).opacity(0.3 + 0.7 * max(0, sin(t * 2 + Double(i) * 1.7))))
            }
            for i in 0..<2 {   // a 5×5 Z drifting up from the chimney
                let p = phase(4, Double(i) / 2)
                let (x, y, c) = (30 + p * 8, 12 - p * 11, Color.white.opacity(1 - p))
                dot(x, y, c, w: 5)
                for k in 1...3 { dot(x + 4 - Double(k), y + Double(k), c) }
                dot(x, y + 4, c, w: 5)
            }
        }
    }
}

/// The weekly summary page: the last 7 days of stress, work and rest, what
/// weighed on the student most, and the AI's few kind words about it. The words
/// are cached with the facts they came from and rewritten only when those change.
struct WeeklySummaryView: View {
    let stats: WeekStats
    /// [facts, summary, encouragement] as JSON.
    @AppStorage("weeklySummary") private var saved = Data()
    @State private var writing = false

    private var words: (summary: String, encouragement: String)? {
        guard let s = try? JSONDecoder().decode([String].self, from: saved), s.count == 3,
              s[0] == stats.facts.joined(separator: "\n") else { return nil }
        return (s[1], s[2])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let words {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("How your week went", systemImage: "sparkles")
                            .font(.pixel(20, relativeTo: .headline).weight(.bold))
                        Text(words.summary)
                        Text(words.encouragement).foregroundStyle(Color.grass).fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().pixelBox()
                } else if writing {
                    HStack { ProgressView(); Text("Writing your summary…").foregroundStyle(.secondary) }
                }

                HStack(spacing: 10) {
                    tile("\(stats.stressfulDays)/7", "stressful days")
                    tile("\(stats.restedDays)/7", "rested days")
                    tile(stats.planned == 0 ? "–" : "\(stats.done)/\(stats.planned)", "tasks done")
                }

                section("Stress by day")
                ForEach(stats.days, id: \.date) { d in
                    BrickMeter(title: d.date.formatted(.dateTime.weekday(.abbreviated)),
                               detail: "\(HomeView.duration(TimeInterval(d.work * 60))) work · \(HomeView.duration(d.rest)) rest",
                               filled: min(10, d.stress * 5 / House.stressfulMinutes),
                               color: d.stressful ? .brick : d.stress * 2 >= House.stressfulMinutes ? .orange : .grass)
                }

                if !stats.top.isEmpty {
                    section("Weighed on you most")
                    ForEach(stats.top, id: \.title) { t in
                        LabeledContent(t.title, value: "\(t.share)% of your stress")
                    }
                }
                if let feeling = stats.feeling {
                    section("How tasks felt")
                    LabeledContent("Average", value: "\(feeling.formatted(.number.precision(.fractionLength(1))))/5 · \(stats.checkIns) check-ins")
                    if !stats.drained.isEmpty { LabeledContent("Drained you", value: stats.drained.joined(separator: ", ")) }
                    if !stats.energised.isEmpty { LabeledContent("Felt good", value: stats.energised.joined(separator: ", ")) }
                }
                // A nudge, not a block: bulk ticking is sometimes honest.
                if stats.quickTicks >= 5 {
                    Text("\(stats.quickTicks) ticks came within a minute of each other. Ticking each task as you finish it keeps your pace and bricks accurate.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let overrun = stats.overrun, abs(overrun) >= 10 {
                    Text("Tasks took \(abs(overrun))% \(overrun > 0 ? "longer" : "less time") than planned. New plans adjust for your pace.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color.paper)
        .pixelTitle("Your week")
        .task(id: stats.facts) {
            guard words == nil else { return }
            writing = true
            defer { writing = false }
            if let s = await Reflections.summary(stats) {
                saved = (try? JSONEncoder().encode([stats.facts.joined(separator: "\n"), s.summary, s.encouragement])) ?? Data()
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.pixel(24, relativeTo: .title2).weight(.bold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).pixelBox()
        .accessibilityElement(children: .combine)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.pixel(18, relativeTo: .headline).weight(.bold)).padding(.top, 4)
    }
}
