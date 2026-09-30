import SwiftUI

/// Day and week views: a header row, an all-day row, and a scrolling 24-hour grid.
///
/// Performance notes: all event blocks are drawn in one Canvas at precomputed rects, and a single
/// interaction layer on top does all hit-testing. One view to update instead of one per event.
struct TimeGridView: View {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model
    let days: [Date]

    @State private var drag: EventDrag?

    static let hourHeight: CGFloat = 48
    static let gutter: CGFloat = 56

    var body: some View {
        let cal = model.cal
        let allDay = model.displayEvents.filter(\.isAllDayLike)
        GeometryReader { geo in
            let geometry = GridGeometry(
                days: days,
                colWidth: max(40, (geo.size.width - Self.gutter * s) / CGFloat(days.count)),
                gutter: Self.gutter * s, hourHeight: Self.hourHeight * s, cal: cal)
            VStack(spacing: 0) {
                // Day view's title already names the date.
                if days.count > 1 {
                    DayHeaderRow(days: days, colWidth: geometry.colWidth)
                }
                AllDayRow(days: days, events: allDay, colWidth: geometry.colWidth)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid(geometry)
                    }
                    .onAppear { proxy.scrollTo(initialScrollHour, anchor: .top) }
                }
            }
        }
    }

    private var initialScrollHour: Int {
        guard days.contains(where: model.cal.isDateInToday) else { return 7 }
        let hour = model.cal.component(.hour, from: Date())
        return hour < 10 ? 7 : min(hour - 2, 16)
    }

    private func grid(_ geometry: GridGeometry) -> some View {
        // Base layer: saved events only, so selecting, typing and dragging never re-lay it out.
        let allBlocks = geometry.blocks(for: model.visibleDisplay.filter { !$0.isAllDayLike })
        let blocks = allBlocks.filter { !$0.event.isHidden }
        let overlay = overlayBlocks(geometry, base: blocks)
        // Search: only the visible matches, so the base canvas compares a small set.
        let matches = model.searchMatchIDs.map { all in Set(blocks.map(\.event.id).filter(all.contains)) }
        return ZStack(alignment: .topLeading) {
            // Scroll anchors, one per hour.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { hour in
                    Color.clear.frame(height: geometry.hourHeight).id(hour)
                }
            }
            GridBackground(geometry: geometry)
                .equatable()
            EventsCanvas(blocks: blocks, fadedIDs: overlay.fadedIDs, matches: matches, minute: Self.currentMinute)
                .equatable()
                .frame(width: geometry.width, height: geometry.totalHeight)
                .allowsHitTesting(false)
            OverlayCanvas(blocks: overlay.blocks)
                .frame(width: geometry.width, height: geometry.totalHeight)
                .allowsHitTesting(false)
            NowLine(geometry: geometry)
            GridInteractionLayer(geometry: geometry, blocks: blocks + overlay.blocks, drag: $drag)
        }
        .frame(width: geometry.width, height: geometry.totalHeight, alignment: .topLeading)
    }

    /// Minutes since 1970, so the base layer's "past events are dimmed" input changes once a minute, not every frame.
    private static var currentMinute: Int { Int(Date().timeIntervalSince1970 / 60) }

    /// The selected/edited/dragged/new events, drawn on top of the base layer. An event that's been
    /// moved (by dragging or in the inspector) is drawn at its new spot and its original is faded.
    private func overlayBlocks(_ geometry: GridGeometry, base: [GridGeometry.Block]) -> (blocks: [GridGeometry.Block], fadedIDs: Set<String>) {
        var blocks: [GridGeometry.Block] = []
        var faded: Set<String> = []
        func add(_ event: DisplayEvent) {
            guard !event.isAllDayLike else { return }
            let original = model.visibleDisplay.first { $0.id == event.id }
            if let original, original.start == event.start, original.end == event.end {
                // Same place: cover the base block(s) exactly.
                blocks += base.filter { $0.event.id == event.id }.map { block in
                    var segment = block.segment
                    segment = Segment(id: segment.id, event: event, dayIndex: segment.dayIndex, startMinutes: segment.startMinutes,
                                      endMinutes: segment.endMinutes, isLast: segment.isLast, slot: segment.slot)
                    return GridGeometry.Block(segment: segment, rect: block.rect)
                }
            } else {
                blocks += geometry.blocks(for: [event])
                if original != nil { faded.insert(event.id) }
            }
        }
        if var edited = model.editingDisplay {
            if let drag, drag.id == edited.id { edited = drag.applied(to: edited, in: geometry.cal) }
            add(edited)
        }
        if let drag, drag.id != model.editing?.id, let event = model.visibleDisplay.first(where: { $0.id == drag.id }) {
            add(drag.applied(to: event, in: geometry.cal))
        }
        return (blocks, faded)
    }
}

/// Places each child at the rect in its `BlockFrame` layout value, proposing exactly that size.
/// Far cheaper than a ZStack of offset views, which measures and aligns every child.
struct BlockLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let rect = subview[BlockFrame.self]
            subview.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

struct BlockFrame: LayoutValueKey {
    static let defaultValue = CGRect.zero
}

/// Converts `rect`, in the coordinates of the view handling the current click at `click`, to window
/// points (top-left origin): where the editor popover attaches.
func windowRect(_ rect: CGRect, click: CGPoint) -> CGRect? {
    guard let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown,
          let height = event.window?.contentView?.bounds.height else { return nil }
    return rect.offsetBy(dx: event.locationInWindow.x - click.x, dy: height - event.locationInWindow.y - click.y)
}

/// All mouse handling for the grid: click to select, double-click to create, drag to create,
/// move or resize. One gesture for the whole grid, so single clicks never wait on a double-click timer.
private struct GridInteractionLayer: View {
    @Environment(AppModel.self) private var model
    let geometry: GridGeometry
    let blocks: [GridGeometry.Block]
    @Binding var drag: EventDrag?

    @State private var press: Press?
    @State private var hoverResize = false
    @State private var hoveredID: String?

    private struct Press {
        let hit: GridGeometry.Hit
        /// The event as it was when pressed (before any drag preview).
        let event: DisplayEvent?
        var moved = false
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .pointerStyle(hoverResize ? .rowResize : nil)
            .onContinuousHover { phase in
                var resize = false
                var hovered: String?
                if case .active(let point) = phase, press == nil,
                   case .event(let id, let onEdge, _) = geometry.hit(point, blocks: blocks) {
                    resize = onEdge
                    hovered = id
                }
                if resize != hoverResize { hoverResize = resize }
                if hovered != hoveredID { hoveredID = hovered }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged(changed).onEnded(ended))
            // Blocks are drawn in a Canvas, so the menu targets whichever event the pointer is over.
            .contextMenu { if let hoveredID { EventContextMenu(eventID: hoveredID) } }
    }

    private func changed(_ value: DragGesture.Value) {
        if press == nil {
            NSApp.keyWindow?.makeFirstResponder(nil)
            let hit = geometry.hit(value.startLocation, blocks: blocks)
            var event: DisplayEvent?
            if case .event(let id, _, _) = hit { event = blocks.first { $0.event.id == id }?.event }
            press = Press(hit: hit, event: event)
        }
        guard var current = press else { return }
        if !current.moved {
            guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
            current.moved = true
            press = current
        }
        switch current.hit {
        case .event(let id, let resize, let dayIndex):
            guard current.event?.isEditable == true else { return }
            let minutes = geometry.minutesDelta(value.translation.height)
            if resize {
                drag = EventDrag(id: id, kind: .resize, minutes: minutes, days: 0)
            } else {
                let dayDelta = Int((value.translation.width / geometry.colWidth).rounded())
                let clamped = min(max(dayDelta, -dayIndex), geometry.days.count - 1 - dayIndex)
                drag = EventDrag(id: id, kind: .move, minutes: minutes, days: clamped)
            }
        case .empty(let dayIndex):
            let a = geometry.minutes(atY: value.startLocation.y)
            let b = geometry.minutes(atY: value.location.y)
            let lo = min(a, b), hi = max(max(a, b), lo + GridGeometry.snapMinutes)
            let start = geometry.date(dayIndex: dayIndex, minutes: lo)
            let end = geometry.date(dayIndex: dayIndex, minutes: min(hi, 1440))
            if model.isDragCreating {
                model.updateDraftTimes(start: start, end: end)
            } else {
                model.isDragCreating = true
                model.newEvent(start: start, end: end)
            }
        case .outside:
            break
        }
    }

    private func ended(_ value: DragGesture.Value) {
        defer {
            press = nil
            drag = nil
        }
        guard let current = press else { return }
        if current.moved {
            switch current.hit {
            case .event(let id, _, _):
                if let drag, drag.minutes != 0 || drag.days != 0, let event = current.event {
                    let moved = drag.applied(to: event, in: geometry.cal)
                    model.move(id, start: moved.start, end: moved.end)
                }
            case .empty:
                showNewEventEditor(click: value.location)
                model.isDragCreating = false
                model.requestTitleFocus()
            case .outside:
                break
            }
            return
        }
        let isDoubleClick = (NSApp.currentEvent?.clickCount ?? 1) >= 2
        switch current.hit {
        case .event(let id, _, _):
            let anchor = blocks.last { $0.rect.contains(value.location) }.flatMap { windowRect($0.rect, click: value.location) }
            model.open(id, anchor: anchor)
            if isDoubleClick { model.showEditor(anchor: anchor) }
        case .empty(let dayIndex) where isDoubleClick:
            let start = geometry.minutes(atY: value.location.y, step: 30)
            model.newEvent(start: geometry.date(dayIndex: dayIndex, minutes: start),
                           end: geometry.date(dayIndex: dayIndex, minutes: min(start + 60, 1440)))
            showNewEventEditor(click: value.location)
        case .empty, .outside:
            model.commit()
        }
    }
}

extension GridInteractionLayer {
    /// Attaches a just-created event's editor to its block.
    fileprivate func showNewEventEditor(click: CGPoint) {
        guard model.editing?.isNew == true, let event = model.editingDisplay,
              let block = geometry.blocks(for: [event]).first else { return }
        model.showEditor(anchor: windowRect(block.rect, click: click))
    }
}

/// An in-progress drag, applied to the event as a live preview.
struct EventDrag: Equatable {
    enum Kind { case move, resize }
    let id: String
    let kind: Kind
    var minutes: Int
    var days: Int

    func applied(to event: DisplayEvent, in cal: Calendar) -> DisplayEvent {
        guard event.id == id else { return event }
        var result = event
        switch kind {
        case .move:
            let shift = { (date: Date) in
                cal.date(byAdding: .day, value: days, to: date)!.addingTimeInterval(TimeInterval(minutes * 60))
            }
            result.start = shift(event.start)
            result.end = shift(event.end)
        case .resize:
            result.end = max(event.start.addingTimeInterval(15 * 60), event.end.addingTimeInterval(TimeInterval(minutes * 60)))
        }
        return result
    }
}

// MARK: - Pieces

/// The base layer: every saved timed event. Equatable, so SwiftUI skips redrawing it unless
/// the events themselves change.
private struct EventsCanvas: View, Equatable {
    @Environment(\.fontScale) private var s
    let blocks: [GridGeometry.Block]
    /// Drawn faintly: the original spots of events being dragged or re-timed.
    let fadedIDs: Set<String>
    /// While searching: matching events get an outline and everything else fades.
    let matches: Set<String>?
    let minute: Int

    static func == (a: EventsCanvas, b: EventsCanvas) -> Bool {
        a.fadedIDs == b.fadedIDs && a.matches == b.matches && a.minute == b.minute && a.blocks == b.blocks
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            let now = Date(timeIntervalSince1970: TimeInterval(minute * 60))
            for block in blocks {
                let matched = matches?.contains(block.event.id)
                let opacity = matched == false ? 0.2 : fadedIDs.contains(block.event.id) ? 0.3 : block.event.end < now ? 0.6 : 1
                drawBlock(block, selected: false, opacity: opacity, highlighted: matched == true, scale: s, in: context)
            }
        }
    }
}

/// The top layer: just the selected / edited / dragged / new event.
private struct OverlayCanvas: View {
    @Environment(\.fontScale) private var s
    let blocks: [GridGeometry.Block]

    var body: some View {
        Canvas { context, _ in
            for block in blocks {
                drawBlock(block, selected: !block.event.isDraft, opacity: 1, highlighted: false, scale: s, in: context)
            }
        }
    }
}

/// One event block: tinted rounded rect, color stripe, and text clipped to the block.
private func drawBlock(_ block: GridGeometry.Block, selected: Bool, opacity: Double, highlighted: Bool,
                       scale s: CGFloat, in context: GraphicsContext) {
    let event = block.event
    let rect = block.rect
    var ctx = context
    ctx.opacity = opacity
    // Selected blocks are opaque so they fully cover the base-layer block underneath.
    ctx.fill(RoundedRectangle(cornerRadius: 4).path(in: rect),
             with: .color(selected ? event.color : event.color.opacity(event.isDraft ? 0.35 : 0.2)))
    ctx.fill(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                .path(in: CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height)),
             with: .color(event.color))
    if event.isDraft {
        ctx.stroke(RoundedRectangle(cornerRadius: 4).path(in: rect.insetBy(dx: 0.5, dy: 0.5)),
                   with: .color(event.color), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }
    if highlighted {
        ctx.stroke(RoundedRectangle(cornerRadius: 4).path(in: rect.insetBy(dx: 1, dy: 1)), with: .color(.orange), lineWidth: 2)
    }
    let compact = rect.height < 30 * s
    let primary = selected ? Color.white : Color.primary
    let secondary = selected ? Color.white.opacity(0.85) : Color.secondary
    // Text(verbatim:) skips the localization lookup that interpolated string literals trigger.
    let title = Text(verbatim: event.title).fontWeight(.semibold).foregroundColor(primary)
    let text = compact
        ? title + Text(verbatim: "  " + event.start.shortTime).foregroundColor(secondary)
        : title + Text(verbatim: "\n" + event.timeRangeText).foregroundColor(secondary)
            + Text(verbatim: event.location.map { "\n" + $0 } ?? "").foregroundColor(secondary)
    let top: CGFloat = compact ? 1 : 3
    ctx.clip(to: Path(rect))
    let resolved = ctx.resolve(text.font(.system(size: 11 * s)))
    let textWidth = max(rect.width - 10, 0)
    // If the longest word doesn't fit, wrapping would stack single letters: draw one truncated line instead.
    var height = max(rect.height - top, 0)
    if textWidth < 90 * s {
        let unbounded = CGSize(width: CGFloat.infinity, height: .infinity)
        let words: [Substring] = event.title.split(separator: " ")
        let longest = String(words.max(by: { $0.count < $1.count }) ?? Substring(event.title))
        let wordWidth = ctx.resolve(Text(verbatim: longest).font(.system(size: 11 * s, weight: .semibold))).measure(in: unbounded).width
        if wordWidth > textWidth {
            height = ctx.resolve(Text(verbatim: "Ag").font(.system(size: 11 * s))).measure(in: unbounded).height
        }
    }
    ctx.draw(resolved, in: CGRect(x: rect.minX + 7, y: rect.minY + top, width: textWidth, height: min(height, max(rect.height - top, 0))))
}

private struct DayHeaderRow: View {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model
    let days: [Date]
    let colWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: (TimeGridView.gutter * s), height: 34 * s)
            // Positional identity: navigating updates these views instead of rebuilding them.
            ForEach(days.indices, id: \.self) { index in
                let day = days[index]
                let isToday = model.cal.isDateInToday(day)
                Button { model.show(day, in: .day) } label: {
                    // Narrow columns fall back to "S 27", then just "27", instead of wrapping.
                    ViewThatFits(in: .horizontal) {
                        header(day, weekday: .abbreviated, isToday: isToday)
                        header(day, weekday: .narrow, isToday: isToday)
                        dayNumber(day, isToday: isToday)
                    }
                    .font(.system(size: 13 * s))
                    .frame(width: colWidth, height: 34 * s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(day.formatted(date: .complete, time: .omitted))")
            }
        }
    }

    private func header(_ day: Date, weekday: Date.FormatStyle.Symbol.Weekday, isToday: Bool) -> some View {
        HStack(spacing: 5) {
            Text(day.formatted(.dateTime.weekday(weekday)))
                .foregroundStyle(isToday ? Color.red : Color.secondary)
            dayNumber(day, isToday: isToday)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func dayNumber(_ day: Date, isToday: Bool) -> some View {
        Text(day.formatted(.dateTime.day()))
            .fontWeight(.semibold)
            .foregroundStyle(isToday ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background { if isToday { Capsule().fill(Color.red) } }
            .lineLimit(1)
            .fixedSize()
    }
}

private struct AllDayRow: View {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model
    let days: [Date]
    let events: [DisplayEvent]
    let colWidth: CGFloat

    private static let laneHeight: CGFloat = 20
    private static let maxVisibleLanes = 5

    var body: some View {
        let cal = model.cal
        let lastIndex = days.count - 1
        let spans = events.compactMap { event -> DaySpan<String>? in
            let first = cal.dayOffset(from: days[0], to: event.start)
            let last = cal.dayOffset(from: days[0], to: event.lastDay(in: cal))
            guard last >= 0, first <= lastIndex else { return nil }
            return DaySpan(id: event.id, first: max(first, 0), last: min(last, lastIndex))
        }
        let hiddenIDs = Set(events.filter(\.isHidden).map(\.id))
        // Height comes from every event (so the grid below never jumps); bars pack from visible ones.
        let laneCount = (EventLayout.lanes(for: spans).values.max() ?? -1) + 1
        let lanes = EventLayout.lanes(for: spans.filter { !hiddenIDs.contains($0.id) })
        let height = max(24 * s, CGFloat(min(laneCount, Self.maxVisibleLanes)) * (Self.laneHeight * s) + 4)
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })

        ZStack(alignment: .topLeading) {
            Text("all-day")
                .font(.system(size: 10 * s))
                .foregroundStyle(.secondary)
                .frame(width: (TimeGridView.gutter * s) - 8, alignment: .trailing)
                .padding(.top, 5)

            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: colWidth, height: height)
                    .onTapGesture { location in
                        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                            let start = cal.startOfDay(for: day)
                            model.newEvent(start: start, end: start, isAllDay: true)
                            if model.editing?.isNew == true {
                                model.showEditor(anchor: windowRect(CGRect(x: 0, y: 0, width: colWidth, height: height), click: location))
                            }
                        } else {
                            model.commit()
                        }
                    }
                    .offset(x: (TimeGridView.gutter * s) + CGFloat(index) * colWidth)
            }

            let shownSpans = spans.filter { !hiddenIDs.contains($0.id) }
            ForEach(shownSpans.indices, id: \.self) { index in
                let span = shownSpans[index]
                if let event = byID[span.id], let lane = lanes[span.id], lane < Self.maxVisibleLanes {
                    let selected = model.editing?.id == event.id
                    let matched = model.searchMatchIDs?.contains(event.id)
                    let size = CGSize(width: CGFloat(span.last - span.first + 1) * colWidth - 4, height: (Self.laneHeight * s) - 2)
                    Text(event.title)
                        .font(.system(size: 11 * s, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(width: size.width, height: size.height, alignment: .leading)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? event.color : event.color.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            if event.isDraft {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(event.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            } else if matched == true {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange, lineWidth: 2)
                            }
                        }
                        .opacity(matched == false ? 0.25 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let anchor = windowRect(CGRect(origin: .zero, size: size), click: location)
                            model.open(event.id, anchor: anchor)
                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.showEditor(anchor: anchor) }
                        }
                        .offset(x: (TimeGridView.gutter * s) + CGFloat(span.first) * colWidth + 2, y: 2 + CGFloat(lane) * (Self.laneHeight * s))
                        .contextMenu { EventContextMenu(eventID: event.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .clipped()
    }
}

/// Column tints, hour lines and hour labels in a single Canvas (one view instead of dozens).
private struct GridBackground: View, Equatable {
    @Environment(\.fontScale) private var s
    let geometry: GridGeometry

    /// Redraw only when what's drawn changes (not merely which week it is).
    static func == (a: GridBackground, b: GridBackground) -> Bool {
        a.geometry.colWidth == b.geometry.colWidth && a.geometry.gutter == b.geometry.gutter
            && a.geometry.hourHeight == b.geometry.hourHeight && a.tints == b.tints
    }

    /// Day view has a single column, so there's nothing to set apart.
    private var tints: [Color?] {
        guard geometry.days.count > 1 else { return [] }
        return geometry.days.map { day in
            geometry.cal.isDateInToday(day) ? Color.accentColor.opacity(0.11)
                : geometry.cal.isDateInWeekend(day) ? Color.primary.opacity(0.025) : nil
        }
    }

    private static let labels: [String] = (0..<24).map { hour in
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        let g = geometry
        let tints = tints
        Canvas { context, size in
            for (index, tint) in tints.enumerated() {
                guard let tint else { continue }
                context.fill(Path(CGRect(x: g.gutter + CGFloat(index) * g.colWidth, y: 0, width: g.colWidth, height: size.height)),
                             with: .color(tint))
            }
            let line = Color.primary.opacity(0.16)
            for hour in 0...24 {
                let y = CGFloat(hour) * g.hourHeight
                context.stroke(Path { $0.move(to: CGPoint(x: g.gutter - 6, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(line), lineWidth: 0.5)
                guard hour < 24 else { continue }
                let half = y + g.hourHeight / 2
                context.stroke(Path { $0.move(to: CGPoint(x: g.gutter, y: half)); $0.addLine(to: CGPoint(x: size.width, y: half)) },
                               with: .color(line.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                if hour > 0 {
                    context.draw(Text(Self.labels[hour]).font(.system(size: 10 * s).monospacedDigit()).foregroundColor(.secondary),
                                 at: CGPoint(x: g.gutter - 10, y: y), anchor: .trailing)
                }
            }
            for index in 0...g.days.count {
                let x = g.gutter + CGFloat(index) * g.colWidth
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(line), lineWidth: 0.5)
            }
        }
        .frame(width: g.width, height: g.totalHeight)
        .allowsHitTesting(false)
    }
}

private struct NowLine: View {
    let geometry: GridGeometry

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let index = geometry.days.firstIndex(where: geometry.cal.isDateInToday) {
                let y = geometry.cal.minutesIntoDay(context.date) / 60 * geometry.hourHeight
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.red).frame(width: geometry.colWidth, height: 1.5)
                    Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: -4)
                }
                .offset(x: geometry.gutter + CGFloat(index) * geometry.colWidth, y: y - 4)
            }
        }
        .allowsHitTesting(false)
    }
}
