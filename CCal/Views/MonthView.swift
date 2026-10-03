import SwiftUI

struct MonthView: View {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model
    /// An all-day bar being moved or stretched: the event as pressed, and where it would land.
    @State private var barDrag: (event: DisplayEvent, preview: DisplayEvent)?
    /// The edge handle being dragged, if any.
    @State private var grabbedEdge: (event: DisplayEvent, grab: BarGrab)?
    @State private var gridSize = CGSize.zero

    private enum BarGrab { case middle(Date), start, end }

    var body: some View {
        let cal = model.cal
        let days = monthDays
        let buckets = DayBuckets.make(shownEvents, days: days, cal: cal)
            .map { $0.sorted { Self.order($0, $1, cal) } }
        let month = cal.component(.month, from: model.focusDate)
        let symbols = cal.orderedWeekdaySymbols(cal.shortStandaloneWeekdaySymbols)
        let selectedID = model.editing?.id
        let searchMatches = model.searchMatchIDs

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(symbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 11 * s, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }
            }
            .frame(height: 26 * s)
            Divider()
            GeometryReader { geo in
                let width = geo.size.width / 7
                let height = geo.size.height / 6
                let maxRows = max(1, Int((height - MonthCell.headerHeight * s) / (MonthCell.rowHeight * s)))
                let weeks = (0..<6).map { row in
                    MonthWeekLayout.make(Array(buckets[row * 7 ..< row * 7 + 7]), rowStart: days[row * 7], maxRows: maxRows, cal: cal)
                }
                // Grab zones on both ends of editable all-day bars, for stretching them across days.
                let handles = weeks.indices.flatMap { row in
                    weeks[row].bars.filter { $0.event.isAllDay && $0.event.isEditable }.flatMap { bar in
                        let y = CGFloat(row) * height + (MonthCell.headerHeight + CGFloat(bar.lane) * MonthCell.rowHeight) * s
                        let size = CGSize(width: 8, height: (MonthCell.rowHeight - 1) * s)
                        var ends: [(event: DisplayEvent, grab: BarGrab, rect: CGRect)] = []
                        if !bar.continuesBefore {
                            ends.append((bar.event, .start, CGRect(origin: CGPoint(x: CGFloat(bar.first) * width, y: y), size: size)))
                        }
                        if !bar.continuesAfter {
                            ends.append((bar.event, .end, CGRect(origin: CGPoint(x: CGFloat(bar.last + 1) * width - 8, y: y), size: size)))
                        }
                        return ends
                    }
                }
                BlockLayout {
                    ForEach(0..<42, id: \.self) { index in
                        let week = weeks[index / 7]
                        let column = index % 7
                        let timed = buckets[index].filter { !$0.isAllDayLike }
                        MonthCell(
                            day: days[index], timed: timed,
                            laneIDs: week.laneIDs[column], hiddenBars: week.hiddenBars[column],
                            inMonth: cal.component(.month, from: days[index]) == month,
                            isToday: cal.isDateInToday(days[index]),
                            maxRows: maxRows,
                            // Only the cell holding the selection sees it, so selecting redraws one cell.
                            selectedID: timed.contains { $0.id == selectedID } ? selectedID : nil,
                            matches: searchMatches.map { all in Set(timed.map(\.id).filter(all.contains)) },
                            dragBar: dragBar, dropBar: dropBar)
                        .equatable()
                        .layoutValue(key: BlockFrame.self, value: CGRect(
                            x: CGFloat(column) * width, y: CGFloat(index / 7) * height, width: width, height: height))
                    }
                    ForEach(0..<6, id: \.self) { row in
                        let bars = weeks[row].bars
                        MonthBarsRow(
                            bars: bars, columnWidth: width,
                            selectedID: bars.contains { $0.event.id == selectedID } ? selectedID : nil,
                            matches: searchMatches.map { all in Set(bars.map(\.event.id).filter(all.contains)) })
                        .equatable()
                        .allowsHitTesting(false)
                        .layoutValue(key: BlockFrame.self, value: CGRect(
                            x: 0, y: CGFloat(row) * height + MonthCell.headerHeight * s,
                            width: geo.size.width, height: CGFloat(max(weeks[row].shownLanes, 0)) * MonthCell.rowHeight * s))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { gridSize = $0 }
                .overlay { MonthGridLines().allowsHitTesting(false) }
                // One view for every handle, so the drag survives the bar wrapping onto another week.
                .overlay {
                    Color.clear
                        .contentShape(Path { path in handles.forEach { path.addRect($0.rect) } })
                        .pointerStyle(.columnResize)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                guard let edge = grabbedEdge
                                        ?? handles.last(where: { $0.rect.contains(value.startLocation) }).map({ ($0.event, $0.grab) })
                                else { return }
                                grabbedEdge = edge
                                preview(edge.event, edge.grab, at: value.location)
                            }
                            .onEnded { _ in
                                grabbedEdge = nil
                                dropBar()
                            })
                }
            }
        }
    }

    /// Computed here, not from model.visibleDays, which shrinks as soon as the mode changes.
    private var monthDays: [Date] {
        let cal = model.cal
        return cal.days(from: cal.startOfWeek(containing: cal.startOfMonth(containing: model.focusDate)), count: 42)
    }

    /// Visible events, with any bar drag in progress applied.
    private var shownEvents: [DisplayEvent] {
        var shown = model.displayEvents.filter { !$0.isHidden }
        if let barDrag, let i = shown.firstIndex(where: { $0.id == barDrag.event.id }) {
            shown[i] = barDrag.preview
        }
        return shown
    }

    /// Moves the drag preview to the day under `point` (month grid coordinates). Grabbed in the middle
    /// (on the given day), the whole event shifts; grabbed by an edge, that end follows.
    private func preview(_ event: DisplayEvent, _ grab: BarGrab, at point: CGPoint) {
        guard gridSize.width > 0, gridSize.height > 0 else { return }
        let cal = model.cal
        let column = min(max(Int(point.x / (gridSize.width / 7)), 0), 6)
        let row = min(max(Int(point.y / (gridSize.height / 6)), 0), 5)
        let day = monthDays[row * 7 + column]
        var moved = event
        switch grab {
        case .middle(let grabbed):
            let delta = cal.dayOffset(from: grabbed, to: day)
            moved.start = cal.date(byAdding: .day, value: delta, to: event.start)!
            moved.end = cal.date(byAdding: .day, value: delta, to: event.end)!
        case .start:
            moved.start = min(day, event.lastDay(in: cal))
        case .end:
            moved.end = cal.date(byAdding: .day, value: 1, to: max(day, cal.startOfDay(for: event.start)))!
        }
        barDrag = (event, moved)
    }

    /// A drag that started in the cell for `day`, on bar `id` if any; `point` is in that cell's coordinates.
    /// The bar is looked up only once, since it leaves the cell as it moves.
    private func dragBar(_ id: String?, from day: Date, at point: CGPoint) {
        guard let event = barDrag?.event ?? model.displayEvents.first(where: { $0.id == id && $0.isEditable }),
              let index = monthDays.firstIndex(of: day) else { return }
        let origin = CGPoint(x: CGFloat(index % 7) * gridSize.width / 7, y: CGFloat(index / 7) * gridSize.height / 6)
        preview(event, .middle(day), at: CGPoint(x: origin.x + point.x, y: origin.y + point.y))
    }

    private func dropBar() {
        let cal = model.cal
        if let (event, moved) = barDrag, moved.start != event.start || moved.lastDay(in: cal) != event.lastDay(in: cal) {
            // All-day ends are given as the last day, as in drafts (see EventDraft.apply).
            model.move(event.id, start: moved.start, end: moved.isAllDay ? moved.lastDay(in: cal) : moved.end)
        }
        barDrag = nil
    }

    private static func order(_ a: DisplayEvent, _ b: DisplayEvent, _ cal: Calendar) -> Bool {
        if a.isAllDayLike != b.isAllDayLike { return a.isAllDayLike }
        if a.isAllDayLike && a.start != b.start { return a.start < b.start }
        // By last day, not end: a selected event's end comes from its draft (midnight after its last day),
        // not EventKit (23:59:59 on it), and selecting it shouldn't move it.
        if a.isAllDayLike { return a.lastDay(in: cal) > b.lastDay(in: cal) }
        return a.start < b.start
    }
}

/// One day in the month grid, drawn in a Canvas: day number, then (below any multi-day bar lanes,
/// which `MonthBarsRow` draws across the week) timed event chips and "N more". A single tap
/// handler works out which row was clicked. Equatable, so selecting redraws only its cell.
private struct MonthCell: View, Equatable {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model
    let day: Date
    let timed: [DisplayEvent]
    /// The bar in each reserved lane on this day (nil where empty).
    let laneIDs: [String?]
    let hiddenBars: Int
    let inMonth: Bool
    let isToday: Bool
    let maxRows: Int
    let selectedID: String?
    /// While searching: IDs in this cell that match (others fade); nil when not searching.
    let matches: Set<String>?
    /// A drag that started in this cell: the bar under where it started (if any), this day, and the pointer.
    let dragBar: (String?, Date, CGPoint) -> Void
    let dropBar: () -> Void
    @State private var hoveredID: String?
    @State private var size = CGSize.zero

    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 17

    static func == (a: MonthCell, b: MonthCell) -> Bool {
        a.day == b.day && a.timed == b.timed && a.laneIDs == b.laneIDs && a.hiddenBars == b.hiddenBars
            && a.inMonth == b.inMonth && a.isToday == b.isToday && a.maxRows == b.maxRows
            && a.selectedID == b.selectedID && a.matches == b.matches
    }

    /// Timed chips that fit below the bar lanes; the last row becomes "N more" when needed.
    private var shownCount: Int {
        let available = max(maxRows - laneIDs.count, 0)
        return timed.count + hiddenBars > available ? max(available - 1, 0) : timed.count
    }

    private var moreCount: Int { hiddenBars + timed.count - shownCount }

    var body: some View {
        Canvas { context, size in draw(in: context, size: size) }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in tapped(at: location) }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let row = row(at: value.startLocation)
                    dragBar(row >= 0 && row < laneIDs.count ? laneIDs[row] : nil, day, value.location)
                }
                .onEnded { _ in dropBar() })
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onContinuousHover { phase in
                var hovered: String?
                if case .active(let point) = phase { hovered = eventID(at: point) }
                if hovered != hoveredID { hoveredID = hovered }
            }
            .contextMenu { if let hoveredID { EventContextMenu(eventID: hoveredID) } }
    }

    private func row(at location: CGPoint) -> Int {
        Int(((location.y - Self.headerHeight * s) / (Self.rowHeight * s)).rounded(.down))
    }

    /// The bar or chip at `location`, if any.
    private func eventID(at location: CGPoint) -> String? {
        let row = row(at: location)
        let chipRow = row - laneIDs.count
        if row >= 0, row < laneIDs.count, let id = laneIDs[row] { return id }
        if chipRow >= 0 && chipRow < shownCount { return timed[chipRow].id }
        return nil
    }

    private func tapped(at location: CGPoint) {
        let row = row(at: location)
        let chipRow = row - laneIDs.count
        // Click count instead of a count: 2 gesture, so single clicks don't wait for a double.
        let isDoubleClick = (NSApp.currentEvent?.clickCount ?? 1) >= 2
        if let id = eventID(at: location) {
            let rowRect = CGRect(x: 2, y: Self.headerHeight * s + CGFloat(row) * Self.rowHeight * s,
                                 width: size.width - 4, height: (Self.rowHeight - 1) * s)
            let anchor = windowRect(rowRect, click: location)
            model.open(id, anchor: anchor)
            if isDoubleClick { model.showEditor(anchor: anchor) }
        } else if chipRow == shownCount && moreCount > 0 {
            model.show(day, in: .day)
        } else if isDoubleClick {
            let start = model.cal.date(on: day, minutes: 9 * 60)
            model.newEvent(start: start, end: start.addingTimeInterval(3600))
            if model.editing?.isNew == true {
                model.showEditor(anchor: windowRect(CGRect(origin: .zero, size: size), click: location))
            }
        } else {
            model.commit()
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        if isToday {
            context.fill(Path(bounds), with: .color(Color.yellow.opacity(0.3)))
        } else if !inMonth {
            context.fill(Path(bounds), with: .color(Color.primary.opacity(0.09)))
        }

        // Day number, top right; today gets a red circle.
        let number = Text(verbatim: day.formatted(.dateTime.day()))
            .font(.system(size: 12 * s, weight: isToday ? .bold : .regular))
            .foregroundColor(isToday ? .white : inMonth ? .primary : .secondary)
        let center = CGPoint(x: size.width - 4 - 11 * s, y: 3 + 10 * s)
        if isToday {
            context.fill(Circle().path(in: CGRect(x: center.x - 10 * s, y: center.y - 10 * s, width: 20 * s, height: 20 * s)),
                         with: .color(.red))
        }
        context.draw(number, at: center)

        let font = Font.system(size: 11 * s)
        let firstRow = CGFloat(laneIDs.count)
        for (index, event) in timed.prefix(shownCount).enumerated() {
            let rect = CGRect(x: 2, y: Self.headerHeight * s + (firstRow + CGFloat(index)) * Self.rowHeight * s,
                              width: size.width - 4, height: (Self.rowHeight - 1) * s)
            drawChip(event, in: rect, font: font, context: context)
        }
        if moreCount > 0 {
            let y = Self.headerHeight * s + (firstRow + CGFloat(shownCount)) * Self.rowHeight * s + Self.rowHeight * s / 2
            context.draw(Text(verbatim: "\(moreCount) more").font(.system(size: 11 * s, weight: .medium))
                            .foregroundColor(.secondary),
                         at: CGPoint(x: 8, y: y), anchor: .leading)
        }
    }

    private func drawChip(_ event: DisplayEvent, in rect: CGRect, font: Font, context: GraphicsContext) {
        let selected = event.id == selectedID
        var ctx = context
        let matched = matches?.contains(event.id)
        if matched == false { ctx.opacity = 0.25 }
        if matched == true {
            ctx.stroke(RoundedRectangle(cornerRadius: 3).path(in: rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.orange), lineWidth: 1.5)
        }
        if selected {
            ctx.fill(RoundedRectangle(cornerRadius: 3).path(in: rect), with: .color(event.color))
        }
        if event.isDraft {
            ctx.stroke(RoundedRectangle(cornerRadius: 3).path(in: rect.insetBy(dx: 0.5, dy: 0.5)),
                       with: .color(event.color), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
        ctx.fill(Circle().path(in: CGRect(x: rect.minX + 4, y: rect.midY - 3, width: 6, height: 6)),
                 with: .color(selected ? .white : event.color))
        let titleX = rect.minX + 14
        let time = ctx.resolve(Text(verbatim: event.start.shortTime).font(font)
            .foregroundColor(selected ? .white.opacity(0.85) : .secondary))
        ctx.draw(time, at: CGPoint(x: rect.maxX - 4, y: rect.midY), anchor: .trailing)
        let titleMaxX = rect.maxX - 4 - time.measure(in: rect.size).width - 6
        // Drawn into a one-line rect so long titles end in "…" before the time.
        let title = ctx.resolve(Text(verbatim: event.title).font(font).foregroundColor(selected ? .white : .primary))
        let lineHeight = title.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).height
        ctx.draw(title, in: CGRect(x: titleX, y: rect.midY - lineHeight / 2, width: max(titleMaxX - titleX, 0), height: lineHeight))
    }
}

/// All-day and multi-day events across one week row: one continuous bar per event, name at its start.
/// Bars that continue from the previous week or into the next get a flat edge on that side.
private struct MonthBarsRow: View, Equatable {
    @Environment(\.fontScale) private var s
    let bars: [MonthBar]
    let columnWidth: CGFloat
    let selectedID: String?
    let matches: Set<String>?

    static func == (a: MonthBarsRow, b: MonthBarsRow) -> Bool {
        a.bars == b.bars && a.columnWidth == b.columnWidth && a.selectedID == b.selectedID && a.matches == b.matches
    }

    var body: some View {
        Canvas { context, _ in
            let font = Font.system(size: 11 * s, weight: .medium)
            for bar in bars {
                let event = bar.event
                let selected = event.id == selectedID
                let rect = CGRect(
                    x: CGFloat(bar.first) * columnWidth + (bar.continuesBefore ? 0 : 2),
                    y: CGFloat(bar.lane) * MonthCell.rowHeight * s,
                    width: CGFloat(bar.last - bar.first + 1) * columnWidth - (bar.continuesBefore ? 0 : 2) - (bar.continuesAfter ? 0 : 2),
                    height: (MonthCell.rowHeight - 1) * s)
                let left: CGFloat = bar.continuesBefore ? 0 : 3, right: CGFloat = bar.continuesAfter ? 0 : 3
                let shape = UnevenRoundedRectangle(topLeadingRadius: left, bottomLeadingRadius: left,
                                                   bottomTrailingRadius: right, topTrailingRadius: right)
                var ctx = context
                let matched = matches?.contains(event.id)
                if matched == false { ctx.opacity = 0.25 }
                ctx.fill(shape.path(in: rect), with: .color(selected ? event.color : event.color.opacity(0.25)))
                if matched == true {
                    ctx.stroke(shape.path(in: rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(.orange), lineWidth: 1.5)
                }
                if event.isDraft {
                    ctx.stroke(shape.path(in: rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(event.color),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                let title = ctx.resolve(Text(verbatim: event.title).font(font).foregroundColor(selected ? .white : .primary))
                let lineHeight = title.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).height
                ctx.draw(title, in: CGRect(x: rect.minX + 5, y: rect.midY - lineHeight / 2,
                                           width: max(rect.width - 10, 0), height: lineHeight))
            }
        }
    }
}

private struct MonthGridLines: View {
    var body: some View {
        Canvas { context, size in
            let line = Color.primary.opacity(0.16)
            for row in 1..<6 {
                let y = size.height * CGFloat(row) / 6
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(line), lineWidth: 0.5)
            }
            for column in 1..<7 {
                let x = size.width * CGFloat(column) / 7
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(line), lineWidth: 0.5)
            }
        }
    }
}
