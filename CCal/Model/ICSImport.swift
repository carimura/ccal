import EventKit
import Foundation

struct ICSImportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Reads the event subset of iCalendar. Unsupported scheduling features fail the file before saving.
/// Invitations become personal copies: organizer/attendees are never assigned to the new EKEvent.
enum ICSImport {
    struct Property {
        let name: String
        var parameters: [String: String] = [:]
        let value: String

        init(_ line: String) throws {
            var quoted = false
            var separator: String.Index?
            for index in line.indices {
                if line[index] == "\"" { quoted.toggle() }
                if line[index] == ":", !quoted { separator = index; break }
            }
            guard let separator else { throw ICSImportError("Invalid iCalendar property.") }
            var header: [String] = [], field = ""
            quoted = false
            for character in line[..<separator] {
                if character == "\"" { quoted.toggle() }
                if character == ";", !quoted { header.append(field); field = "" }
                else { field.append(character) }
            }
            header.append(field)
            name = header[0].uppercased()
            value = String(line[line.index(after: separator)...])
            for part in header.dropFirst() {
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { throw ICSImportError("Invalid iCalendar parameter.") }
                parameters[String(pair[0]).uppercased()] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
    }

    struct Event {
        let properties: [Property]
        let alarms: [[Property]]

        func makeEvent(in store: EKEventStore, calendar: EKCalendar) throws -> EKEvent {
            func one(_ name: String) throws -> Property? {
                let matches = properties.filter { $0.name == name }
                guard matches.count <= 1 else { throw ICSImportError("Repeated \(name) is not supported.") }
                return matches.first
            }
            for name in ["EXDATE", "RDATE", "EXRULE", "RECURRENCE-ID"] where properties.contains(where: { $0.name == name }) {
                throw ICSImportError("Recurring events with exceptions (\(name)) are not supported yet.")
            }
            if try one("STATUS")?.value.uppercased() == "CANCELLED" {
                throw ICSImportError("Cancelled events cannot be imported.")
            }
            guard let startProperty = try one("DTSTART") else { throw ICSImportError("An event is missing its start date.") }
            let start = try date(startProperty)
            let allDay = startProperty.parameters["VALUE"]?.uppercased() == "DATE"
            let zone = try timeZone(startProperty)
            var dateCalendar = Calendar(identifier: .gregorian)
            dateCalendar.timeZone = zone ?? .current
            let endProperty = try one("DTEND")
            let durationProperty = try one("DURATION")
            guard endProperty == nil || durationProperty == nil else { throw ICSImportError("An event has both an end date and a duration.") }
            let end: Date
            if let endProperty {
                guard (endProperty.parameters["VALUE"]?.uppercased() == "DATE") == allDay else {
                    throw ICSImportError("An event's start and end dates use different date types.")
                }
                end = try date(endProperty)
                guard end > start else { throw ICSImportError("An event ends before or at its start.") }
            } else if let durationProperty {
                let duration = try duration(durationProperty.value)
                guard duration.days >= 0, duration.seconds >= 0, duration.days > 0 || duration.seconds > 0,
                      !allDay || duration.seconds == 0 else { throw ICSImportError("Invalid event duration.") }
                guard let dayEnd = dateCalendar.date(byAdding: .day, value: duration.days, to: start) else {
                    throw ICSImportError("Invalid event duration.")
                }
                end = dayEnd.addingTimeInterval(duration.seconds)
            } else {
                end = allDay ? dateCalendar.date(byAdding: .day, value: 1, to: start)! : start
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = text(try one("SUMMARY")?.value ?? "New Event")
            event.location = try one("LOCATION").map { text($0.value) }
            event.notes = try one("DESCRIPTION").map { text($0.value) }
            event.url = try one("URL").flatMap { URL(string: $0.value) }
            event.timeZone = allDay ? nil : zone
            // EventKit's all-day setter takes an inclusive last day, whereas ICS DTEND is exclusive.
            event.isAllDay = allDay
            event.startDate = start
            event.endDate = allDay ? dateCalendar.date(byAdding: .day, value: -1, to: end)! : end
            if let rule = try one("RRULE") {
                event.recurrenceRules = [try recurrence(rule.value, start: startProperty)]
            }
            if try one("TRANSP")?.value.uppercased() == "TRANSPARENT" { event.availability = .free }
            for alarm in alarms {
                // Email/audio alarms are not reproduced as external actions.
                guard alarm.first(where: { $0.name == "ACTION" })?.value.uppercased() == "DISPLAY",
                      let trigger = alarm.first(where: { $0.name == "TRIGGER" }) else { continue }
                if trigger.parameters["VALUE"]?.uppercased() == "DATE-TIME" {
                    event.addAlarm(EKAlarm(absoluteDate: try date(trigger)))
                } else {
                    let offset = try duration(trigger.value)
                    let seconds = Double(offset.days) * 86400 + offset.seconds
                    let fromEnd = trigger.parameters["RELATED"]?.uppercased() == "END"
                    event.addAlarm(EKAlarm(relativeOffset: seconds + (fromEnd ? end.timeIntervalSince(start) : 0)))
                }
            }
            return event
        }
    }

    static func parse(_ data: Data) throws -> [Event] {
        // Unfold bytes before decoding: producers sometimes fold in the middle of a UTF-8 character.
        var bytes = [UInt8]()
        let input = Array(data)
        var index = 0
        while index < input.count {
            let newline = input[index] == 13 && index + 1 < input.count && input[index + 1] == 10 ? 2 : (input[index] == 10 ? 1 : 0)
            if newline > 0, index + newline < input.count, [9, 32].contains(input[index + newline]) {
                index += newline + 1
            } else {
                bytes.append(input[index]); index += 1
            }
        }
        guard let string = String(bytes: bytes, encoding: .utf8) else { throw ICSImportError("The file is not UTF-8 iCalendar text.") }
        var stack: [String] = []
        var properties: [Property] = [], alarms: [[Property]] = [], alarm: [Property] = []
        var events: [Event] = []
        var calendars = 0
        for line in string.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).components(separatedBy: .newlines) where !line.isEmpty {
            let property = try Property(line)
            let component = property.value.uppercased()
            if property.name == "BEGIN" {
                if stack.isEmpty {
                    guard component == "VCALENDAR", calendars == 0 else { throw ICSImportError("Expected one VCALENDAR document.") }
                    calendars += 1
                } else if component == "VEVENT" {
                    guard stack == ["VCALENDAR"] else { throw ICSImportError("Invalid nested event.") }
                    properties = []; alarms = []
                } else if component == "VALARM", stack == ["VCALENDAR", "VEVENT"] { alarm = [] }
                stack.append(component)
            } else if property.name == "END" {
                guard stack.last == component else { throw ICSImportError("The iCalendar file is incomplete or malformed.") }
                if stack == ["VCALENDAR", "VEVENT", "VALARM"] { alarms.append(alarm) }
                if stack == ["VCALENDAR", "VEVENT"] { events.append(Event(properties: properties, alarms: alarms)) }
                stack.removeLast()
            } else if stack == ["VCALENDAR", "VEVENT"] {
                properties.append(property)
            } else if stack == ["VCALENDAR", "VEVENT", "VALARM"] {
                alarm.append(property)
            } else if stack == ["VCALENDAR"], property.name == "METHOD", !["PUBLISH", "REQUEST"].contains(component) {
                throw ICSImportError("This file is a calendar reply or cancellation, not an event import.")
            } else if stack.isEmpty {
                throw ICSImportError("Expected an iCalendar document.")
            }
        }
        guard stack.isEmpty, calendars == 1, !events.isEmpty else { throw ICSImportError("The file contains no complete calendar events.") }
        return events
    }

    private static func text(_ value: String) -> String {
        var result = "", escaped = false
        for character in value {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func timeZone(_ property: Property) throws -> TimeZone? {
        if property.value.hasSuffix("Z") { return TimeZone(secondsFromGMT: 0)! }
        guard let id = property.parameters["TZID"] else { return nil }
        guard let zone = TimeZone(identifier: id) else {
            throw ICSImportError("The time zone “\(id)” is not supported. Export using a standard time zone or UTC.")
        }
        return zone
    }

    private static func date(_ property: Property) throws -> Date {
        let allDay = property.parameters["VALUE"]?.uppercased() == "DATE"
        let format = allDay ? "yyyyMMdd" : (property.value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = try timeZone(property) ?? .current
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: property.value), formatter.string(from: date) == property.value else {
            throw ICSImportError("Invalid \(property.name) date: \(property.value).")
        }
        return date
    }

    private static func duration(_ value: String) throws -> (days: Int, seconds: Double) {
        let pattern = #"^([+-])?P(?:(\d+)W|(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              (2...6).contains(where: { match.range(at: $0).location != NSNotFound }), !value.hasSuffix("T") else {
            throw ICSImportError("Invalid iCalendar duration.")
        }
        func number(_ index: Int) throws -> Int {
            guard let range = Range(match.range(at: index), in: value) else { return 0 }
            guard let number = Int(value[range]), number <= 1_000_000 else { throw ICSImportError("Duration is too large.") }
            return number
        }
        let sign = value.hasPrefix("-") ? -1 : 1
        return try ((number(2) * 7 + number(3)) * sign,
                    Double(number(4) * 3600 + number(5) * 60 + number(6)) * Double(sign))
    }

    private static func recurrence(_ value: String, start: Property) throws -> EKRecurrenceRule {
        var parts: [String: String] = [:]
        let supported: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYYEARDAY", "BYWEEKNO", "BYSETPOS", "WKST"]
        for part in value.uppercased().split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, supported.contains(String(pair[0])), parts[String(pair[0])] == nil else {
                throw ICSImportError("This repeat rule contains unsupported or invalid fields.")
            }
            parts[String(pair[0])] = String(pair[1])
        }
        let frequencies: [String: EKRecurrenceFrequency] = ["DAILY": .daily, "WEEKLY": .weekly, "MONTHLY": .monthly, "YEARLY": .yearly]
        guard let frequency = frequencies[parts["FREQ"] ?? ""],
              let interval = Int(parts["INTERVAL"] ?? "1"), (1...1_000_000).contains(interval),
              parts["COUNT"] == nil || parts["UNTIL"] == nil else { throw ICSImportError("Invalid or unsupported repeat frequency.") }
        // EventKit has no public setter for the week start (defaults to Monday).
        if let weekStart = parts["WKST"], weekStart != "MO", (frequency == .weekly && interval > 1) || parts["BYWEEKNO"] != nil {
            throw ICSImportError("Repeat rules with a custom week start are not supported yet.")
        }
        // These combinations are valid ICS, but EventKit ignores the corresponding filters.
        let unsupportedFilter = (frequency == .daily && parts["BYDAY"] != nil)
            || (frequency != .monthly && parts["BYMONTHDAY"] != nil)
            || (frequency != .yearly && ["BYMONTH", "BYWEEKNO", "BYYEARDAY"].contains { parts[$0] != nil })
            || (parts["BYSETPOS"] != nil && !["BYDAY", "BYMONTHDAY", "BYMONTH", "BYWEEKNO", "BYYEARDAY"].contains { parts[$0] != nil })
        guard !unsupportedFilter else { throw ICSImportError("This combination of repeat filters is not supported yet.") }
        var end: EKRecurrenceEnd?
        if let countString = parts["COUNT"] {
            guard let count = Int(countString), (1...1_000_000).contains(count) else { throw ICSImportError("Invalid repeat count.") }
            end = EKRecurrenceEnd(occurrenceCount: count)
        }
        if let until = parts["UNTIL"] {
            let parameter = start.parameters["VALUE"]?.uppercased() == "DATE" ? ";VALUE=DATE" : ""
            end = EKRecurrenceEnd(end: try date(Property("UNTIL\(parameter):\(until)")))
        }
        func numbers(_ name: String, limit: Int, negatives: Bool = true) throws -> [NSNumber]? {
            guard let raw = parts[name] else { return nil }
            return try raw.split(separator: ",", omittingEmptySubsequences: false).map {
                guard let n = Int($0), n != 0, n >= (negatives ? -limit : 1), n <= limit else { throw ICSImportError("Invalid \(name) in repeat rule.") }
                return NSNumber(value: n)
            }
        }
        let weekdays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let days: [EKRecurrenceDayOfWeek]? = try parts["BYDAY"].map { raw in
            try raw.split(separator: ",", omittingEmptySubsequences: false).map { day in
                guard let index = weekdays.firstIndex(of: String(day.suffix(2))) else { throw ICSImportError("Invalid repeat weekday.") }
                let prefix = day.dropLast(2)
                let weekday = EKWeekday(rawValue: index + 1)!
                if prefix.isEmpty { return EKRecurrenceDayOfWeek(weekday) }
                guard let ordinal = Int(prefix), ordinal != 0, (-53...53).contains(ordinal), frequency == .monthly || frequency == .yearly else {
                    throw ICSImportError("Invalid repeat weekday position.")
                }
                return EKRecurrenceDayOfWeek(weekday, weekNumber: ordinal)
            }
        }
        return try EKRecurrenceRule(recurrenceWith: frequency, interval: interval, daysOfTheWeek: days,
                                   daysOfTheMonth: numbers("BYMONTHDAY", limit: 31), monthsOfTheYear: numbers("BYMONTH", limit: 12, negatives: false),
                                   weeksOfTheYear: numbers("BYWEEKNO", limit: 53), daysOfTheYear: numbers("BYYEARDAY", limit: 366),
                                   setPositions: numbers("BYSETPOS", limit: 366), end: end)
    }
}
