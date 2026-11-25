import SwiftUI
import SwiftData

/// A day-by-day timeline of a plan. Press and hold a task, then drag it to a new
/// time (snaps to 5 minutes). It starts from there, and the student is asked
/// whether to pin it; nothing is pinned without asking. Swipe a task left to delete it.
struct PlanTimeline: View {
    @Bindable var plan: Plan
    @Binding var day: Date   // PlanView's + adds to this day
    @State private var swiped: PersistentIdentifier?   // swiped left: Delete showing
    @State private var dragging = false   // a block is being moved: the timeline holds still
    @State private var askPin: PlanTask?   // just dragged: offer to lock it there
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pinch to zoom; remembered between visits.
    @AppStorage("timelineHourHeight") private var savedHourHeight = 120.0
    @GestureState private var pinch: CGFloat = 1

    private var hourHeight: CGFloat { min(max(savedHourHeight * pinch, 70), 320) }
    private var perMinute: CGFloat { hourHeight / 60 }
    private let cal = Calendar.current
    private let gutter: CGFloat = 52       // hour labels column
    private let minBlock: CGFloat = 34     // shortest block that fits a line of text
    private let top: CGFloat = 12

    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            dayPicker
            Divider()
            ScrollView {
                let (from, to) = hourRange
                let frames = layout(from: from)
                ZStack(alignment: .topLeading) {
                    hourGrid(from: from, to: to)
                    ForEach(from..<max(from, to), id: \.self) { h in   // scroll targets, one per hour
                        Color.clear.frame(width: 1, height: 1).offset(y: top + CGFloat(h - from) * hourHeight).id(h)
                    }
                    ForEach(Array(busyToday.enumerated()), id: \.offset) { _, range in
                        busyBlock(range, from: from)
                    }
                    ForEach(tasksToday) { task in
                        if let frame = frames[task.persistentModelID] {
                            // Its own view, so a drag redraws just this block, not the whole timeline.
                            TimelineBlock(task: task, frame: frame, top: top, gutter: gutter, perMinute: perMinute,
                                          swiped: $swiped, dragging: $dragging,
                                          onMove: { minutes in
                                              guard let start = task.start else { return }
                                              plan.move(task, to: start.addingTimeInterval(TimeInterval(minutes * 60)))
                                              askPin = task
                                          },
                                          onDelete: { delete(task) }) { menu(for: task) }
                        }
                    }
                    nowLine(from: from)
                }
                // Pin content to the top: blocks are placed by offset from here.
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: max(CGFloat(to - from) * hourHeight, frames.values.map { $0.y + $0.height }.max() ?? 0) + top * 2,
                       alignment: .topLeading)
                .padding(.horizontal)
            }
            .scrollDisabled(dragging)
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { savedHourHeight = min(max(savedHourHeight * $0.magnification, 70), 320) }
            )
        }
        .onAppear {
            day = days.contains(day) ? day : (days.first ?? day)
            jumpToFirstTask(proxy)
        }
        .onChange(of: day) { swiped = nil; jumpToFirstTask(proxy) }
        .confirmationDialog(askPin.map { "Pin “\($0.title)” to \($0.start?.formatted(date: .omitted, time: .shortened) ?? "")?" } ?? "",
                            isPresented: Binding(get: { askPin != nil }, set: { if !$0 { askPin = nil } }),
                            titleVisibility: .visible, presenting: askPin) { task in
            Button("Pin here", systemImage: "pin") {
                task.pinned = task.start
                plan.reflow()
            }
            Button("Don't pin", role: .cancel) {}
        } message: { _ in
            Text("A pinned task never moves, even if earlier tasks run late. If you don't pin it, it starts here but can still be pushed later.")
        }
        .animation(.smooth, value: plan.ordered.map(\.start))
        }
    }

    /// Open the day at its first unfinished task (or now, if that's later).
    private func jumpToFirstTask(_ proxy: ScrollViewProxy) {
        let first = tasksToday.first { !$0.done }?.start ?? tasksToday.first?.start
        guard var target = first else { proxy.scrollTo(hourRange.0, anchor: .top); return }
        if cal.isDateInToday(day), Date.now > target { target = .now }
        // the hour before, so a little of what came earlier shows above it
        proxy.scrollTo(max(hourRange.0, cal.component(.hour, from: target) - 1), anchor: .top)
    }

    // MARK: Days

    /// The plan's days, plus any day a task overflowed onto.
    private var days: [Date] {
        let first = cal.startOfDay(for: plan.start)
        let planDays = (0..<max(plan.days, 1)).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
        let taskDays = plan.tasks.compactMap { $0.start.map(cal.startOfDay(for:)) }
        return Array(Set(planDays + taskDays)).sorted()
    }

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { d in
                    let selected = d == day
                    let count = plan.tasks.filter { $0.start.map { cal.isDate($0, inSameDayAs: d) } ?? false }.count
                    Button { withAnimation(.snappy) { day = d } } label: {
                        VStack(spacing: 2) {
                            Text(cal.isDateInToday(d) ? "Today" : d.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption.weight(.semibold))
                            Text(d.formatted(.dateTime.day())).font(.title3.weight(.bold)).monospacedDigit()
                            Text("\(count) task\(count == 1 ? "" : "s")").font(.caption2)
                                .opacity(0.8)
                        }
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.vertical, 6)
                        .frame(width: 64)
                        .frame(minHeight: 68)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
                                    in: Rectangle())
                        .overlay(Rectangle().strokeBorder(Color.ink, lineWidth: selected ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    // MARK: Layout

    private var tasksToday: [PlanTask] {
        plan.ordered.filter { $0.start.map { cal.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { $0.start! < $1.start! }
    }

    private var busyToday: [Range<Date>] {
        let own = Set(plan.tasks.compactMap(\.eventID))
        return CalendarSync.busy(from: day, days: 1, excluding: own).filter { cal.isDate($0.lowerBound, inSameDayAs: day) }
    }

    /// Hours shown: the routine's waking hours, stretched to fit any task.
    private var hourRange: (Int, Int) {
        let r = plan.routine
        let minute = { (d: Date) in Int(d.timeIntervalSince(day) / 60) }
        let starts = tasksToday.compactMap(\.start).map(minute)
        let ends = tasksToday.compactMap(\.end).map(minute)
        let lo = min(([r.wake] + starts).min()!, 24 * 60 - 60)
        let hi = max(([r.bed <= r.wake ? 24 * 60 : r.bed] + ends).max()!, lo + 60)
        return (lo / 60, min((hi + 59) / 60, 26))
    }

    private func y(_ date: Date, from hour: Int) -> CGFloat {
        CGFloat(date.timeIntervalSince(day) / 60 - Double(hour * 60)) * perMinute
    }

    /// Where each task block goes. Blocks sit at their start time, but a short
    /// block is drawn tall enough to read, and the next one moves down just
    /// enough not to cover it. Labels always show the real times.
    private func layout(from: Int) -> [PersistentIdentifier: (y: CGFloat, height: CGFloat)] {
        var out: [PersistentIdentifier: (y: CGFloat, height: CGFloat)] = [:]
        var bottom = -CGFloat.infinity
        for task in tasksToday {
            let top = max(y(task.start!, from: from), bottom + 3)
            let height = max(CGFloat(task.minutes) * perMinute - 3, minBlock)
            out[task.persistentModelID] = (top, height)
            bottom = top + height
        }
        return out
    }

    private func hourGrid(from: Int, to: Int) -> some View {
        ForEach(from...to, id: \.self) { h in
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 8) {
                    Text(cal.date(byAdding: .hour, value: h, to: day)!.formatted(.dateTime.hour()))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: gutter - 8, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(.separator).frame(height: 0.5)
                }
                // Half-hour line, only when there's room for it to help.
                if h < to, hourHeight >= 100 {
                    Rectangle().fill(.separator.opacity(0.5)).frame(height: 0.5)
                        .padding(.leading, gutter)
                        .offset(y: hourHeight / 2)
                }
            }
            .offset(y: CGFloat(h - from) * hourHeight + top)
        }
    }

    @ViewBuilder private func nowLine(from: Int) -> some View {
        if cal.isDateInToday(day) {
            HStack(spacing: 0) {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .overlay {
                        // A soft ring breathes out from the dot every 1.6 s. It's an
                        // overlay, so the line and dot never shift in the layout.
                        if !reduceMotion {
                            TimelineView(.animation(minimumInterval: 1 / 12)) { timeline in
                                let phase = timeline.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                                Circle()
                                    .stroke(.red.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                                    .frame(width: 8 + 12 * phase, height: 8 + 12 * phase)
                            }
                        }
                    }
                Rectangle().fill(.red).frame(height: 1.5)
            }
            .padding(.leading, gutter - 4)
            .offset(y: y(.now, from: from) + top - 4)
            .allowsHitTesting(false)   // decoration over the blocks must not eat drags
            .accessibilityHidden(true)
        }
    }

    private func busyBlock(_ range: Range<Date>, from: Int) -> some View {
        let height = max(CGFloat(range.upperBound.timeIntervalSince(range.lowerBound) / 60) * perMinute - 3, 22)
        return Text("Busy")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .background(.fill.quaternary)
            .overlay(Rectangle().strokeBorder(.separator, style: StrokeStyle(lineWidth: 2, dash: [4, 4])))
            .padding(.leading, gutter)
            .offset(y: y(range.lowerBound, from: from) + top)
    }

    // MARK: Tasks

    private func delete(_ task: PlanTask) {
        withAnimation(.snappy) {
            swiped = nil
            plan.delete([task])
        }
    }


    @ViewBuilder private func menu(for task: PlanTask) -> some View {
        if !task.done, let start = task.start {
            Menu("Move to day", systemImage: "calendar") {
                ForEach(days.filter { !cal.isDate($0, inSameDayAs: start) }, id: \.self) { d in
                    Button(d.formatted(.dateTime.weekday(.wide).day().month())) {
                        let time = start.timeIntervalSince(cal.startOfDay(for: start))
                        plan.move(task, to: d.addingTimeInterval(time))
                        day = d
                    }
                }
            }
        }
        if task.pinned == nil, !task.done, let start = task.start {
            Button("Pin to \(start.formatted(date: .omitted, time: .shortened))", systemImage: "pin") {
                task.pinned = start
                plan.reflow()
            }
        }
        if task.pinned != nil {
            Button("Unpin time", systemImage: "pin.slash") {
                task.pinned = nil
                plan.reflow()
            }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { delete(task) }
    }
}

/// One task on the timeline: a calendar-style block with a solid bar on the left.
/// Press and hold, then drag to move it (5-minute snaps); swipe left for Delete.
/// Drag and swipe offsets live here, so moving redraws only this block.
private struct TimelineBlock<MenuItems: View>: View {
    let task: PlanTask
    let frame: (y: CGFloat, height: CGFloat)
    let top, gutter, perMinute: CGFloat
    @Binding var swiped: PersistentIdentifier?   // the one block with Delete showing
    @Binding var dragging: Bool
    var onMove: (Int) -> Void
    var onDelete: () -> Void
    @ViewBuilder var menu: MenuItems

    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0
    @State private var swipeX: CGFloat = 0

    private let swipeOpen: CGFloat = 80
    private let swipeDelete: CGFloat = 220

    private var minutes: Int { Int((dragOffset / perMinute / 5).rounded()) * 5 }
    private var isSwiped: Bool { swiped == task.persistentModelID }

    var body: some View {
        let color: Color = task.done ? .gray : task.priority == 0 ? .red : .accentColor
        let roomy = frame.height >= 56
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                if roomy, !task.parent.isEmpty {
                    Text(task.parent).font(.caption2.weight(.semibold)).foregroundStyle(color).lineLimit(1)
                }
                // Short blocks put the time beside the title so nothing is cut off.
                let line = roomy ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
                line {
                    HStack(spacing: 4) {
                        if task.pinned != nil { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                        if task.done { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                        Text(task.title)
                            .font(.subheadline.weight(.semibold))
                            .strikethrough(task.done)
                            .foregroundStyle(task.done ? .secondary : .primary)
                    }
                    Text(timeLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, roomy ? 6 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: roomy ? .topLeading : .leading)
        }
        .frame(height: frame.height)
        .background(color.opacity(isDragging ? 0.3 : 0.15))
        .background(.background)   // solid underneath, so hour lines don't show through
        .overlay(Rectangle().strokeBorder(color, lineWidth: 2))
        .shadow(color: .black.opacity(isDragging ? 0.2 : 0), radius: 8, y: 4)
        .scaleEffect(isDragging ? 1.02 : 1)
        .animation(.snappy(duration: 0.2), value: isDragging)
        .contentShape(.contextMenuPreview, Rectangle())
        .contextMenu { menu }
        .offset(x: isSwiped ? swipeX : 0)
        .background(alignment: .trailing) {
            if isSwiped {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: max(-swipeX, 0), height: frame.height)
                    .background(.red)
            }
        }
        .gesture(task.done ? nil : move)
        .simultaneousGesture(swipe)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Press and hold, then drag to change the time")
        .accessibilityAction(named: "Delete", onDelete)
        .padding(.leading, gutter)
        .offset(y: frame.y + top + dragOffset)
        .zIndex(isDragging ? 1 : 0)
        .sensoryFeedback(.impact(weight: .light), trigger: isDragging) { _, on in on }
        .sensoryFeedback(.selection, trigger: minutes) { _, _ in isDragging }
        .onChange(of: swiped) { if !isSwiped { swipeX = 0 } }
    }

    private var timeLabel: String {
        guard let start = task.start?.addingTimeInterval(TimeInterval((isDragging ? minutes : 0) * 60)) else { return "" }
        let end = start.addingTimeInterval(TimeInterval(task.minutes * 60))
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    /// Long-press then drag, so normal scrolling still works.
    private var move: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture())
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !isDragging { isDragging = true; dragging = true; swiped = nil }
                dragOffset = drag?.translation.height ?? 0
            }
            .onEnded { _ in
                let moved = minutes
                // One animation for the drop and the reflow: the block settles from
                // where it was let go instead of jumping back first.
                withAnimation(.snappy) {
                    if moved != 0 { onMove(moved) }
                    dragOffset = 0
                    isDragging = false
                }
                dragging = false
            }
    }

    /// Swipe left to show Delete (stays open at `swipeOpen`); swipe far to delete
    /// straight away; swipe right or swipe another task to close.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isDragging, abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = isSwiped && swipeX < 0 ? -swipeOpen : 0
                if !isSwiped { swiped = task.persistentModelID }
                swipeX = min(0, base + value.translation.width)
            }
            .onEnded { _ in
                guard isSwiped else { return }
                withAnimation(.snappy) {
                    if swipeX < -swipeDelete { onDelete() }
                    else if swipeX < -swipeOpen / 2 { swipeX = -swipeOpen }
                    else { swiped = nil }
                }
            }
    }
}
