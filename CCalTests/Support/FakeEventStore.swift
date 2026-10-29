import AppKit
import EventKit
@testable import CCal

/// In-memory EventStoring. Calendars and events are real EK objects that are never saved,
/// so nothing ever reaches the Mac's calendar database or any synced account.
final class FakeEventStore: EventStoring {
    let ekStore = EKEventStore()
    var authorizationStatus: EKAuthorizationStatus = .fullAccess
    private(set) var allCalendars: [EKCalendar] = []
    private(set) var stored: [EKEvent] = []
    private(set) var saves: [(event: EKEvent, span: EKSpan)] = []
    private(set) var removals: [(event: EKEvent, span: EKSpan)] = []
    private(set) var fetchCount = 0
    var failAfterSaveCount: Int?
    /// Background prefetches read `stored` while tests mutate it on the main thread.
    private let lock = NSLock()

    func requestAccess() async throws {}
    func calendars() -> [EKCalendar] { allCalendars }
    func calendar(withIdentifier id: String) -> EKCalendar? { allCalendars.first { $0.calendarIdentifier == id } }
    var defaultCalendarForNewEvents: EKCalendar? { allCalendars.first }
    func refreshSources() {}

    func events(from start: Date, to end: Date) -> [EKEvent] {
        lock.withLock {
            fetchCount += 1
            return stored.filter { $0.startDate < end && ($0.endDate > start || $0.startDate >= start) }
        }
    }

    func save(_ event: EKEvent, span: EKSpan) throws {
        if let limit = failAfterSaveCount, saves.count >= limit {
            throw NSError(domain: "FakeEventStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Save failed."])
        }
        lock.withLock {
            saves.append((event, span))
            if !stored.contains(where: { $0 === event }) { stored.append(event) }
        }
    }

    func remove(_ event: EKEvent, span: EKSpan) throws {
        lock.withLock {
            removals.append((event, span))
            stored.removeAll { $0 === event }
        }
    }

    @discardableResult
    func addCalendar(_ title: String, color: NSColor = .systemBlue) -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: ekStore)
        calendar.title = title
        calendar.cgColor = color.cgColor
        allCalendars.append(calendar)
        return calendar
    }

    /// For all-day events `end` is the last day, as in the app's drafts.
    @discardableResult
    func addEvent(_ title: String, _ start: Date, _ end: Date, on calendar: EKCalendar, allDay: Bool = false) -> EKEvent {
        let event = EKEvent(eventStore: ekStore)
        event.title = title
        event.isAllDay = allDay // before the dates, as EventDraft.apply does
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        lock.withLock { stored.append(event) }
        return event
    }
}

enum Fixture {
    static var cal: Calendar { Calendar.current }

    /// A fresh UserDefaults so tests never touch the app's real preferences.
    static func defaults() -> UserDefaults {
        let name = "ccal-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func at(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(on: day, minutes: hour * 60 + minute)
    }

    /// A busy, realistic calendar: `calendarCount` calendars, `perDay` timed events per day
    /// (with overlaps), a few all-day and multi-day events, over ±`spanDays` around `center`.
    static func busyStore(center: Date = Date(), spanDays: Int = 120, perDay: Int = 12, calendarCount: Int = 12) -> FakeEventStore {
        let store = FakeEventStore()
        let colors: [NSColor] = [.systemBlue, .systemGreen, .systemPurple, .systemOrange, .systemPink, .systemTeal, .systemBrown, .systemIndigo]
        let calendars = (0..<calendarCount).map { store.addCalendar("Calendar \($0)", color: colors[$0 % colors.count]) }
        var rng = SeededRandom(seed: 42)
        let first = cal.date(byAdding: .day, value: -spanDays, to: cal.startOfDay(for: center))!
        for dayOffset in 0..<(spanDays * 2) {
            let day = cal.date(byAdding: .day, value: dayOffset, to: first)!
            for i in 0..<perDay {
                let startMinute = 6 * 60 + Int(rng.next() % 56) * 15
                let duration = [15, 30, 45, 60, 60, 90, 120][Int(rng.next() % 7)]
                let start = at(day, 0).addingTimeInterval(Double(startMinute * 60))
                store.addEvent("Event \(dayOffset)-\(i) with a longer title", start, start.addingTimeInterval(Double(duration * 60)),
                               on: calendars[Int(rng.next() % UInt64(calendarCount))])
            }
            if dayOffset % 3 == 0 {
                store.addEvent("All-day \(dayOffset)", day, day, on: calendars[dayOffset % calendarCount], allDay: true)
            }
            if dayOffset % 10 == 0 {
                store.addEvent("Trip \(dayOffset)", day, cal.date(byAdding: .day, value: 3, to: day)!, on: calendars[0], allDay: true)
            }
        }
        return store
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
}
