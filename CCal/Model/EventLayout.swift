import Foundation

/// A timed span within one day, in minutes since midnight.
struct TimedSpan<ID: Hashable> {
    let id: ID
    let start: Double
    let end: Double
}

struct ColumnSlot: Equatable {
    let column: Int
    let columns: Int
}

/// A multi-day span across a row of day columns (inclusive indices).
struct DaySpan<ID: Hashable> {
    let id: ID
    let first: Int
    let last: Int
}

enum EventLayout {
    /// Places overlapping events side by side. Each cluster of transitively
    /// overlapping events shares a column count so their widths line up.
    static func columns<ID: Hashable>(for spans: [TimedSpan<ID>]) -> [ID: ColumnSlot] {
        let sorted = spans.sorted { ($0.start, -$0.end) < ($1.start, -$1.end) }
        var result: [ID: ColumnSlot] = [:]
        var cluster: [(id: ID, column: Int)] = []
        var columnEnds: [Double] = []
        var clusterEnd = -Double.infinity

        func flush() {
            for item in cluster {
                result[item.id] = ColumnSlot(column: item.column, columns: columnEnds.count)
            }
            cluster.removeAll()
            columnEnds.removeAll()
        }

        for span in sorted {
            if span.start >= clusterEnd { flush() }
            if let column = columnEnds.firstIndex(where: { $0 <= span.start }) {
                columnEnds[column] = span.end
                cluster.append((span.id, column))
            } else {
                columnEnds.append(span.end)
                cluster.append((span.id, columnEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, span.end)
        }
        flush()
        return result
    }

    /// Stacks all-day bars into lanes so none overlap. Longer bars claim lanes first.
    static func lanes<ID: Hashable>(for spans: [DaySpan<ID>]) -> [ID: Int] {
        let sorted = spans.sorted { ($0.first, $1.last) < ($1.first, $0.last) }
        var laneEnds: [Int] = []
        var result: [ID: Int] = [:]
        for span in sorted {
            if let lane = laneEnds.firstIndex(where: { $0 < span.first }) {
                laneEnds[lane] = span.last
                result[span.id] = lane
            } else {
                laneEnds.append(span.last)
                result[span.id] = laneEnds.count - 1
            }
        }
        return result
    }
}
