import EventKit

/// The slice of EventKit the app uses, so tests can run against an in-memory store
/// instead of the real (synced) calendars.
protocol EventStoring: AnyObject {
    /// Needed to create EKEvent/EKCalendar objects and to observe EKEventStoreChanged.
    var ekStore: EKEventStore { get }
    var authorizationStatus: EKAuthorizationStatus { get }
    func requestAccess() async throws
    func calendars() -> [EKCalendar]
    func calendar(withIdentifier id: String) -> EKCalendar?
    var defaultCalendarForNewEvents: EKCalendar? { get }
    func events(from start: Date, to end: Date) -> [EKEvent]
    func save(_ event: EKEvent, span: EKSpan) throws
    func remove(_ event: EKEvent, span: EKSpan) throws
    func refreshSources()
}

final class SystemEventStore: EventStoring {
    let ekStore = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func requestAccess() async throws {
        _ = try await ekStore.requestFullAccessToEvents()
    }

    func calendars() -> [EKCalendar] { ekStore.calendars(for: .event) }

    func calendar(withIdentifier id: String) -> EKCalendar? { ekStore.calendar(withIdentifier: id) }

    var defaultCalendarForNewEvents: EKCalendar? { ekStore.defaultCalendarForNewEvents }

    func events(from start: Date, to end: Date) -> [EKEvent] {
        ekStore.events(matching: ekStore.predicateForEvents(withStart: start, end: end, calendars: nil))
    }

    func save(_ event: EKEvent, span: EKSpan) throws {
        try ekStore.save(event, span: span, commit: true)
    }

    func remove(_ event: EKEvent, span: EKSpan) throws {
        try ekStore.remove(event, span: span, commit: true)
    }

    func refreshSources() { ekStore.refreshSourcesIfNecessary() }
}
