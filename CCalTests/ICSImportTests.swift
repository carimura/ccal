import EventKit
import Foundation
import Testing
@testable import CCal

@MainActor
struct ICSImportTests {
    let store = FakeEventStore()

    private func document(_ body: String) -> Data {
        Data("BEGIN:VCALENDAR\nVERSION:2.0\n\(body)\nEND:VCALENDAR\n".utf8)
    }

    private func event(_ fields: String) -> String { "BEGIN:VEVENT\n\(fields)\nEND:VEVENT" }

    private func parse(_ fields: String) throws -> EKEvent {
        let calendar = store.addCalendar("Import")
        return try #require(ICSImport.parse(document(event(fields))).first).makeEvent(in: store.ekStore, calendar: calendar)
    }

    private func utc(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func preservesDetailsUnfoldingAndRemindersWithoutGuests() throws {
        let imported = try parse(#"""
        DTSTART:20261013T170000Z
        DTEND:20261013T183000Z
        SUMMARY:Planning\, review
         continued
        DESCRIPTION:First line\nSecond\; line\\end
        LOCATION:Room\, 2
        URL:https://example.com/meeting
        ORGANIZER:mailto:organizer@example.com
        ATTENDEE;CN="Guest: Person; Team":mailto:guest@example.com
        BEGIN:VALARM
        ACTION:DISPLAY
        TRIGGER:-PT15M
        DESCRIPTION:Reminder
        END:VALARM
        """#)
        #expect(imported.title == "Planning, reviewcontinued")
        #expect(imported.notes == "First line\nSecond; line\\end")
        #expect(imported.location == "Room, 2")
        #expect(imported.url?.absoluteString == "https://example.com/meeting")
        #expect(imported.startDate == utc("2026-10-13T17:00:00Z"))
        #expect(imported.endDate == utc("2026-10-13T18:30:00Z"))
        #expect(imported.alarms?.first?.relativeOffset == -900)
        #expect(imported.attendees == nil && imported.organizer == nil)
    }

    @Test func timeZonesAndDurationAcrossDaylightSaving() throws {
        let imported = try parse("DTSTART;TZID=America/Los_Angeles:20260307T120000\nDURATION:P1DT2H")
        #expect(imported.startDate == utc("2026-03-07T20:00:00Z"))
        #expect(imported.endDate == utc("2026-03-08T21:00:00Z"))
        #expect(imported.timeZone?.identifier == "America/Los_Angeles")
        let floating = try parse("DTSTART:20261013T090000")
        #expect(Calendar.current.component(.hour, from: floating.startDate) == 9)
        #expect(floating.timeZone == nil)
        #expect(floating.endDate == floating.startDate)
    }

    @Test func allDayEndsAreExclusiveAndDefaultToOneDay() throws {
        let imported = try parse("DTSTART;VALUE=DATE:20261013\nDTEND;VALUE=DATE:20261016")
        #expect(imported.isAllDay)
        let shown = DisplayEvent(CalEvent(imported))
        #expect(Calendar.current.component(.day, from: shown.lastDay(in: .current)) == 15)
        let single = try parse("DTSTART;VALUE=DATE:20261013")
        #expect(Calendar.current.component(.day, from: DisplayEvent(CalEvent(single)).lastDay(in: .current)) == 13)
    }

    @Test func repeatRulesKeepCountDaysAndUntil() throws {
        let weekly = try parse("DTSTART:20261013T170000Z\nRRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH;COUNT=8;WKST=MO")
        let rule = try #require(weekly.recurrenceRules?.first)
        #expect(rule.frequency == .weekly && rule.interval == 2)
        #expect(rule.recurrenceEnd?.occurrenceCount == 8)
        #expect(rule.daysOfTheWeek?.map(\.dayOfTheWeek) == [.tuesday, .thursday])
        let monthly = try parse("DTSTART:20261013T170000Z\nRRULE:FREQ=MONTHLY;BYDAY=-1FR;UNTIL=20271013T170000Z")
        #expect(monthly.recurrenceRules?.first?.daysOfTheWeek?.first?.weekNumber == -1)
        #expect(monthly.recurrenceRules?.first?.recurrenceEnd?.endDate == utc("2027-10-13T17:00:00Z"))
    }

    @Test func rejectsMalformedAndUnsupportedScheduling() throws {
        for fields in [
            "SUMMARY:No start", "DTSTART:20260230T170000Z", "DTSTART:garbage",
            "DTSTART:20261013T170000Z\nDTEND:20261012T170000Z",
            "DTSTART:20261013T170000Z\nDURATION:-PT1H",
            "DTSTART;TZID=Unrecognized/Zone:20261013T170000",
            "DTSTART:20261013T170000Z\nRRULE:FREQ=HOURLY",
            "DTSTART:20261013T170000Z\nRRULE:FREQ=DAILY;BYDAY=MO",
            "DTSTART:20261013T170000Z\nRRULE:FREQ=WEEKLY;INTERVAL=2;WKST=SU",
            "DTSTART:20261013T170000Z\nRRULE:FREQ=WEEKLY;BYDAY=99TU",
            "DTSTART:20261013T170000Z\nEXDATE:20261020T170000Z",
            "DTSTART:20261013T170000Z\nRECURRENCE-ID:20261013T170000Z"
        ] {
            #expect(throws: ICSImportError.self) { try parse(fields) }
        }
        for text in ["not a calendar", "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20261013T170000Z", "BEGIN:VCALENDAR\nEND:VCALENDAR"] {
            #expect(throws: ICSImportError.self) { try ICSImport.parse(Data(text.utf8)) }
        }
    }

    @Test func ignoresTimeZoneComponentsAndUnfoldsUTF8Bytes() throws {
        var data = Data("BEGIN:VCALENDAR\r\nBEGIN:VTIMEZONE\r\nTZID:America/Los_Angeles\r\nBEGIN:STANDARD\r\nDTSTART:19701101T020000\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\nDTSTART:20261013T170000Z\r\nSUMMARY:Caf".utf8)
        data.append(contentsOf: [0xc3, 13, 10, 32, 0xa9])
        data.append(Data("\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8))
        let parsed = try ICSImport.parse(data)
        #expect(parsed.count == 1)
        let imported = try parsed[0].makeEvent(in: store.ekStore, calendar: store.addCalendar("C"))
        #expect(imported.title == "Café")
    }

    private func write(_ data: Data, in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test(arguments: [ViewMode.day, .week, .month])
    func importsMultipleFilesToCapturedCalendarAndRefreshesVisibleEvents(mode: ViewMode) async throws {
        let work = store.addCalendar("Work"), home = store.addCalendar("Home")
        let model = AppModel(store: store, defaults: Fixture.defaults())
        model.mode = mode
        model.focusDate = utc("2026-01-01T17:00:00Z")
        model.select(home)
        let destinationID = model.selectedCalendar?.calendarIdentifier
        model.select(work)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try write(document(event("DTSTART:20261013T170000Z\nSUMMARY:Imported one")), in: directory, name: "one.ics")
        let second = try write(document(event("DTSTART:20261013T190000Z\nSUMMARY:Imported two")), in: directory, name: "two.ICS")
        await model.importICSFiles([second, first], calendarID: destinationID)
        #expect(model.focusDate == utc("2026-10-13T17:00:00Z"))
        #expect(model.mode == mode)
        #expect(store.saves.count == 2)
        #expect(store.saves.allSatisfy { $0.event.calendar === home })
        #expect(model.visibleDisplay.filter { $0.title.hasPrefix("Imported") }.count == 2)
        #expect(model.errorMessage == nil)
        #expect(model.importMessage == "Imported 2 events into Home.")
        #expect(!model.isImportingICS)
    }

    @Test func badFileSavesNothingButOtherFilesStillImport() async throws {
        let calendar = store.addCalendar("C")
        let model = AppModel(store: store, defaults: Fixture.defaults())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = event("DTSTART:20261013T170000Z\nSUMMARY:Good")
        let bad = try write(document(valid + "\n" + event("SUMMARY:Missing date")), in: directory, name: "bad.ics")
        let good = try write(document(valid), in: directory, name: "good.ics")
        await model.importICSFiles([bad, good], calendarID: calendar.calendarIdentifier)
        #expect(store.saves.count == 1)
        #expect(model.errorMessage?.contains("bad.ics") == true)
        #expect(model.importMessage == "Imported 1 event into C.")
    }

    @Test func missingDestinationDoesNotFallBackToDefault() async {
        _ = store.addCalendar("Default")
        let model = AppModel(store: store, defaults: Fixture.defaults())
        let originalFocus = model.focusDate
        await model.importICSFiles([URL(fileURLWithPath: "/missing.ics")], calendarID: "removed-calendar")
        #expect(model.focusDate == originalFocus)
        #expect(store.saves.isEmpty)
        #expect(model.errorMessage?.contains("writable calendar") == true)
    }

    @Test func saveFailureReportsPartialImportAndRefreshesSavedEvents() async throws {
        let calendar = store.addCalendar("C")
        store.failAfterSaveCount = 1
        let model = AppModel(store: store, defaults: Fixture.defaults())
        model.focusDate = utc("2026-01-01T17:00:00Z")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fields = "DTSTART:20261013T170000Z\nSUMMARY:Saved"
        let failedFields = "DTSTART:20261012T170000Z\nSUMMARY:Not saved"
        let file = try write(document(event(fields) + "\n" + event(failedFields)), in: directory, name: "partial.ics")
        await model.importICSFiles([file], calendarID: calendar.calendarIdentifier)
        #expect(model.focusDate == utc("2026-10-13T17:00:00Z"))
        #expect(store.saves.count == 1)
        #expect(model.visibleDisplay.filter { $0.title == "Saved" }.count == 1)
        #expect(model.errorMessage?.contains("already imported") == true)
        #expect(model.errorMessage?.contains("Save failed") == true)
        #expect(!model.isImportingICS)
    }
}
