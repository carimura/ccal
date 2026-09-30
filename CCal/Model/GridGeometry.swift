import CoreGraphics
import Foundation

/// A piece of a timed event within one day column (events crossing midnight have several).
struct Segment: Identifiable, Equatable {
    let id: String
    let event: DisplayEvent
    let dayIndex: Int
    let startMinutes: Double
    let endMinutes: Double
    let isLast: Bool
    var slot = ColumnSlot(column: 0, columns: 1)
}

/// Pure geometry for the day/week grid: where each event block goes, and what's under a point.
/// Kept separate from the view so layout and hit-testing can be unit tested.
struct GridGeometry {
    let days: [Date]
    let colWidth: CGFloat
    let gutter: CGFloat
    let hourHeight: CGFloat
    let cal: Calendar

    static let snapMinutes = 15
    /// Height of the grab area at the bottom of a block for resizing.
    static let resizeZone: CGFloat = 6
    /// Short events still get a block this tall (in minutes) so they're clickable.
    static let minimumMinutes: Double = 20

    var totalHeight: CGFloat { hourHeight * 24 }
    var width: CGFloat { gutter + colWidth * CGFloat(days.count) }

    struct Block: Identifiable, Equatable {
        let segment: Segment
        let rect: CGRect
        var id: String { segment.id }
        var event: DisplayEvent { segment.event }
    }

    enum Hit: Equatable {
        case event(id: String, resize: Bool, dayIndex: Int)
        case empty(dayIndex: Int)
        case outside
    }

    // MARK: Coordinates

    func dayIndex(atX x: CGFloat) -> Int? {
        guard x >= gutter else { return nil }
        let index = Int(((x - gutter) / colWidth).rounded(.down))
        return (0..<days.count).contains(index) ? index : nil
    }

    /// Minutes since midnight at `y`, rounded down to `step`.
    func minutes(atY y: CGFloat, step: Int = snapMinutes) -> Int {
        let minutes = Int((y / hourHeight * 60).rounded(.down))
        return min(max(minutes / step * step, 0), 1440 - step)
    }

    /// A vertical drag distance as whole snap steps of minutes.
    func minutesDelta(_ dy: CGFloat) -> Int {
        Int((dy / hourHeight * 60 / Double(Self.snapMinutes)).rounded()) * Self.snapMinutes
    }

    func date(dayIndex: Int, minutes: Int) -> Date {
        cal.date(on: days[dayIndex], minutes: minutes)
    }

    // MARK: Layout

    /// Splits timed events into per-day segments and assigns side-by-side columns.
    /// A segment starting on its event's first day keeps the event's id, so a dragged
    /// block keeps its identity as it moves across days.
    func segments(for events: [DisplayEvent]) -> [Segment] {
        let buckets = DayBuckets.make(events, days: days, cal: cal)
        var result: [Segment] = []
        for (dayIndex, day) in days.enumerated() {
            let dayStart = cal.startOfDay(for: day)
            let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart)!
            var daySegments: [Segment] = []
            for event in buckets[dayIndex] {
                let segStart = max(event.start, dayStart)
                let segEnd = min(event.end, nextDay)
                let startMin = segStart == dayStart ? 0 : cal.minutesIntoDay(segStart)
                let endMin = segEnd == nextDay ? 1440 : cal.minutesIntoDay(segEnd)
                daySegments.append(Segment(
                    id: event.start >= dayStart ? event.id : "\(event.id)#\(dayIndex)",
                    event: event, dayIndex: dayIndex,
                    startMinutes: startMin, endMinutes: max(endMin, startMin),
                    isLast: event.end <= nextDay))
            }
            let slots = EventLayout.columns(for: daySegments.map {
                TimedSpan(id: $0.id, start: $0.startMinutes, end: max($0.endMinutes, $0.startMinutes + Self.minimumMinutes))
            })
            for var segment in daySegments {
                segment.slot = slots[segment.id] ?? segment.slot
                result.append(segment)
            }
        }
        return result
    }

    func blocks(for events: [DisplayEvent]) -> [Block] {
        segments(for: events).map { segment in
            let inset: CGFloat = 2
            let slotWidth = (colWidth - inset * 2) / CGFloat(segment.slot.columns)
            let x = gutter + CGFloat(segment.dayIndex) * colWidth + inset + CGFloat(segment.slot.column) * slotWidth
            let y = segment.startMinutes / 60 * hourHeight
            let minutes = max(segment.endMinutes - segment.startMinutes, Self.minimumMinutes)
            let height = minutes / 60 * hourHeight
            return Block(segment: segment, rect: CGRect(x: x, y: y, width: max(slotWidth - 1, 10), height: max(height - 1, 1)))
        }
    }

    // MARK: Hit testing

    /// What's under `point`. Later blocks are drawn on top, so they win.
    func hit(_ point: CGPoint, blocks: [Block]) -> Hit {
        for block in blocks.reversed() where block.rect.contains(point) {
            let resize = block.segment.isLast && block.event.isEditable && point.y >= block.rect.maxY - Self.resizeZone
            return .event(id: block.event.id, resize: resize, dayIndex: block.segment.dayIndex)
        }
        guard let day = dayIndex(atX: point.x) else { return .outside }
        return .empty(dayIndex: day)
    }
}

/// Groups events by the days they touch, in one pass (instead of testing every event against every day).
/// Day lookup is a binary search over precomputed midnights, so there's no Calendar math per event.
enum DayBuckets {
    static func make(_ events: [DisplayEvent], days: [Date], cal: Calendar) -> [[DisplayEvent]] {
        var buckets = Array(repeating: [DisplayEvent](), count: days.count)
        guard let last = days.last else { return buckets }
        // boundaries[i] is the start of day i; the final entry is the end of the last day.
        let boundaries = days.map { cal.startOfDay(for: $0) } + [cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last))!]
        for event in events {
            // The last instant the event covers: an event ending exactly at midnight doesn't touch the next day.
            let lastInstant = max(event.start, event.end.addingTimeInterval(-1))
            let first = max(dayIndex(of: event.start, in: boundaries), 0)
            let lastIndex = min(dayIndex(of: lastInstant, in: boundaries), days.count - 1)
            guard first <= lastIndex else { continue }
            for index in first...lastIndex { buckets[index].append(event) }
        }
        return buckets
    }

    /// Index of the day containing `date`: -1 before the first day, days.count after the last.
    private static func dayIndex(of date: Date, in boundaries: [Date]) -> Int {
        var lo = 0, hi = boundaries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if boundaries[mid] <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }
}

/// A continuous all-day / multi-day bar within one week row of the month grid.
struct MonthBar: Equatable {
    let event: DisplayEvent
    let first: Int
    let last: Int
    let lane: Int
    /// The event started in an earlier week / continues into a later one (drawn with a flat edge).
    let continuesBefore: Bool
    let continuesAfter: Bool
}

/// One week row of the month grid: bars stacked in lanes above each day's timed events.
struct MonthWeekLayout: Equatable {
    let bars: [MonthBar]
    /// Lanes reserved at the top of every day in the row.
    let shownLanes: Int
    /// For each day, the event in each lane down to that day's lowest bar (nil where a lane is empty).
    /// Days whose bars end early reserve fewer rows, so their timed events move up.
    let laneIDs: [[String?]]
    /// For each day, bars that didn't fit (counted in that day's "N more").
    let hiddenBars: [Int]

    /// - Parameters:
    ///   - buckets: the 7 days' events (from `DayBuckets`), in display order.
    ///   - maxRows: rows that fit in a day cell.
    static func make(_ buckets: [[DisplayEvent]], rowStart: Date, maxRows: Int, cal: Calendar) -> MonthWeekLayout {
        var firstColumn: [String: Int] = [:], lastColumn: [String: Int] = [:]
        var events: [String: DisplayEvent] = [:]
        var order: [String] = []
        for (column, bucket) in buckets.enumerated() {
            for event in bucket where event.isAllDayLike {
                if events[event.id] == nil { order.append(event.id); events[event.id] = event }
                firstColumn[event.id] = min(firstColumn[event.id] ?? column, column)
                lastColumn[event.id] = max(lastColumn[event.id] ?? column, column)
            }
        }
        let spans = order.map { DaySpan(id: $0, first: firstColumn[$0]!, last: lastColumn[$0]!) }
        let lanes = EventLayout.lanes(for: spans)
        let laneCount = (lanes.values.max() ?? -1) + 1
        // If they don't all fit, keep the last row for "N more".
        let shownLanes = laneCount <= maxRows ? laneCount : max(maxRows - 1, 0)
        let rowEnd = cal.date(byAdding: .day, value: buckets.count, to: cal.startOfDay(for: rowStart))!

        var bars: [MonthBar] = []
        var laneIDs = Array(repeating: [String?](repeating: nil, count: shownLanes), count: buckets.count)
        var hiddenBars = Array(repeating: 0, count: buckets.count)
        for span in spans {
            let lane = lanes[span.id]!
            if lane >= shownLanes {
                for column in span.first...span.last { hiddenBars[column] += 1 }
                continue
            }
            let event = events[span.id]!
            bars.append(MonthBar(event: event, first: span.first, last: span.last, lane: lane,
                                 continuesBefore: cal.startOfDay(for: event.start) < cal.startOfDay(for: rowStart),
                                 continuesAfter: event.lastDay(in: cal) >= rowEnd))
            for column in span.first...span.last { laneIDs[column][lane] = span.id }
        }
        for column in laneIDs.indices {
            while laneIDs[column].last == .some(nil) { laneIDs[column].removeLast() }
        }
        return MonthWeekLayout(bars: bars, shownLanes: shownLanes, laneIDs: laneIDs, hiddenBars: hiddenBars)
    }
}
