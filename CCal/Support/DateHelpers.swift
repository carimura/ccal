import Foundation

extension Calendar {
    func startOfWeek(containing date: Date) -> Date {
        let day = startOfDay(for: date)
        let offset = (component(.weekday, from: day) - firstWeekday + 7) % 7
        return self.date(byAdding: .day, value: -offset, to: day)!
    }

    func startOfMonth(containing date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }

    func days(from start: Date, count: Int) -> [Date] {
        (0..<count).map { self.date(byAdding: .day, value: $0, to: start)! }
    }

    /// Wall-clock minutes since midnight (DST-safe, unlike subtracting startOfDay).
    func minutesIntoDay(_ date: Date) -> Double {
        let c = dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour! * 60 + c.minute!) + Double(c.second!) / 60
    }

    /// The wall-clock time `minutes` after midnight on `day`. 1440 means the next midnight.
    func date(on day: Date, minutes: Int) -> Date {
        let midnight = startOfDay(for: day)
        if minutes >= 24 * 60 {
            return self.date(byAdding: .day, value: 1, to: midnight)!
        }
        return self.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: midnight)!
    }

    func dayOffset(from start: Date, to date: Date) -> Int {
        dateComponents([.day], from: startOfDay(for: start), to: startOfDay(for: date)).day!
    }

    /// Weekday symbols rotated so they begin on `firstWeekday`.
    func orderedWeekdaySymbols(_ symbols: [String]) -> [String] {
        let start = firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }
}

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
}
