import EventKit
import Foundation
import Testing
@testable import CCal

/// End-to-end flows through AppModel (the same calls the views make), against an in-memory store.
/// Nothing here touches the Mac's calendars or the app's preferences.
@MainActor
struct ModelFlowTests {
    let store = FakeEventStore()
    let work: EKCalendar
    let home: EKCalendar
    let today = Calendar.current.startOfDay(for: Date())

    init() {
        work = store.addCalendar("Work", color: .systemBlue)
        home = store.addCalendar("Home", color: .systemGreen)
    }

    private func makeModel(_ mode: ViewMode = .week) -> AppModel {
        let model = AppModel(store: store, defaults: Fixture.defaults())
        model.mode = mode
        model.focusDate = today
        return model
    }

    private func visible(_ model: AppModel, _ title: String) -> DisplayEvent? {
        model.displayEvents.first { $0.title == title }
    }

    @Test func showsOnlyTheVisibleWeek() {
        store.addEvent("This week", Fixture.at(today, 10), Fixture.at(today, 11), on: work)
        store.addEvent("Next month", Fixture.at(today.addingTimeInterval(40 * 86400), 10),
                       Fixture.at(today.addingTimeInterval(40 * 86400), 11), on: work)
        let model = makeModel()
        #expect(visible(model, "This week") != nil)
        #expect(visible(model, "Next month") == nil)
        #expect(model.visibleDays.count == 7)
    }

    @Test func createSavesOnceWithTitleTimeAndCalendar() throws {
        let model = makeModel()
        model.newEvent(start: Fixture.at(today, 14), end: Fixture.at(today, 15))
        model.draft.title = "Dentist"
        model.draft.calendarID = home.calendarIdentifier
        model.commit()

        #expect(store.saves.count == 1)
        let saved = try #require(store.saves.first?.event)
        #expect(saved.title == "Dentist")
        #expect(saved.calendar?.calendarIdentifier == home.calendarIdentifier)
        #expect(saved.startDate == Fixture.at(today, 14))
        #expect(model.editing == nil)
        #expect(visible(model, "Dentist") != nil, "cache is refreshed after saving")
    }

    /// Regression: all-day ends are exclusive in EventKit, so a 2-day event must be saved through its last day.
    @Test func multiDayAllDayEventKeepsItsLastDay() throws {
        let model = makeModel()
        let tomorrow = today.addingTimeInterval(86400)
        model.newEvent(start: today, end: tomorrow, isAllDay: true)
        model.draft.title = "Offsite"
        model.commit()
        let saved = try #require(store.saves.first?.event)
        #expect(Calendar.current.isDate(saved.endDate, inSameDayAs: tomorrow))
        let shown = try #require(visible(model, "Offsite"))
        #expect(shown.occurs(on: today, in: Calendar.current) && shown.occurs(on: tomorrow, in: Calendar.current))
        #expect(!shown.occurs(on: tomorrow.addingTimeInterval(86400), in: Calendar.current))
    }

    @Test func untitledDraftIsDiscardedWithoutSaving() {
        let model = makeModel()
        model.newEvent(start: Fixture.at(today, 9), end: Fixture.at(today, 10))
        model.commit()
        #expect(store.saves.isEmpty)
        #expect(model.editing == nil)
    }

    @Test func dragCreateSavesFinalTimesOnly() throws {
        let model = makeModel()
        model.isDragCreating = true
        model.newEvent(start: Fixture.at(today, 9), end: Fixture.at(today, 9, 15))
        for minutes in stride(from: 30, through: 120, by: 15) {
            model.updateDraftTimes(start: Fixture.at(today, 9), end: Fixture.at(today, 9, minutes))
        }
        model.isDragCreating = false
        #expect(store.saves.isEmpty, "nothing is written while dragging")
        model.draft.title = "Deep work"
        model.commit()
        #expect(store.saves.count == 1)
        #expect(try #require(store.saves.first).event.endDate == Fixture.at(today, 11))
    }

    @Test func openingAndClosingWithoutChangesNeverSaves() throws {
        store.addEvent("Standup", Fixture.at(today, 9), Fixture.at(today, 9, 15), on: work)
        let model = makeModel()
        let id = try #require(visible(model, "Standup")).id
        model.open(id)
        model.commit()
        model.open(id)
        model.cancelEditing()
        #expect(store.saves.isEmpty)
    }

    @Test func editingTitleSavesOnceOnCommit() throws {
        store.addEvent("Lunch", Fixture.at(today, 12), Fixture.at(today, 13), on: work)
        let model = makeModel()
        model.open(try #require(visible(model, "Lunch")).id)
        for partial in ["L", "Lu", "Lun", "Lunch w/ Sam"] { model.draft.title = partial }
        #expect(store.saves.isEmpty, "typing doesn't save")
        model.commit()
        #expect(store.saves.count == 1)
        #expect(store.saves.first?.span == .thisEvent)
        #expect(visible(model, "Lunch w/ Sam") != nil)
    }

    @Test func switchingSelectionCommitsThePreviousEdit() throws {
        store.addEvent("A", Fixture.at(today, 9), Fixture.at(today, 10), on: work)
        store.addEvent("B", Fixture.at(today, 11), Fixture.at(today, 12), on: work)
        let model = makeModel()
        model.open(try #require(visible(model, "A")).id)
        model.draft.title = "A2"
        model.open(try #require(visible(model, "B")).id)
        #expect(store.saves.count == 1)
        #expect(model.draft.title == "B")
    }

    @Test func escapeDiscardsEdits() throws {
        store.addEvent("Gym", Fixture.at(today, 7), Fixture.at(today, 8), on: home)
        let model = makeModel()
        model.open(try #require(visible(model, "Gym")).id)
        model.draft.title = "Nope"
        model.cancelEditing()
        #expect(store.saves.isEmpty)
        #expect(visible(model, "Gym") != nil)
    }

    @Test func movingSavesImmediatelyWithNewTimes() throws {
        store.addEvent("Call", Fixture.at(today, 15), Fixture.at(today, 16), on: work)
        let model = makeModel()
        let id = try #require(visible(model, "Call")).id
        model.move(id, start: Fixture.at(today, 16, 30), end: Fixture.at(today, 17, 30))
        #expect(store.saves.count == 1)
        #expect(visible(model, "Call")?.start == Fixture.at(today, 16, 30))
    }

    @Test func movingARepeatingEventAsksFirst() throws {
        let event = store.addEvent("Weekly 1:1", Fixture.at(today, 10), Fixture.at(today, 10, 30), on: work)
        event.recurrenceRules = RepeatRule.weekly.rules
        let model = makeModel()
        let id = try #require(visible(model, "Weekly 1:1")).id
        model.move(id, start: Fixture.at(today, 11), end: Fixture.at(today, 11, 30))
        let prompt = try #require(model.spanPrompt)
        #expect(store.saves.isEmpty, "nothing saved until a span is chosen")
        prompt.perform(.futureEvents)
        #expect(store.saves.count == 1)
        #expect(store.saves.first?.span == .futureEvents)
    }

    @Test func cancellingTheRepeatPromptKeepsTheEditorOpen() throws {
        let event = store.addEvent("Daily", Fixture.at(today, 8), Fixture.at(today, 8, 15), on: work)
        event.recurrenceRules = RepeatRule.daily.rules
        let model = makeModel()
        model.open(try #require(visible(model, "Daily")).id)
        model.draft.title = "Daily sync"
        model.commit()
        try #require(model.spanPrompt).onCancel()
        #expect(store.saves.isEmpty)
        #expect(model.editing?.draft.title == "Daily sync")
    }

    @Test func copyToAnotherCalendarKeepsTheOriginal() throws {
        let event = store.addEvent("Dentist", Fixture.at(today, 9), Fixture.at(today, 10), on: work)
        event.location = "Main St"
        let model = makeModel()
        model.copy(try #require(visible(model, "Dentist")).id, to: home)
        #expect(store.saves.count == 1)
        let copy = try #require(store.saves.first?.event)
        #expect(copy !== event)
        #expect(copy.calendar === home && event.calendar === work)
        #expect(copy.title == "Dentist" && copy.location == "Main St")
        #expect(copy.startDate == event.startDate && copy.endDate == event.endDate)
        #expect(model.visibleDisplay.filter { $0.title == "Dentist" }.count == 2)
    }

    @Test func deleteRemovesTheEvent() throws {
        store.addEvent("Old", Fixture.at(today, 18), Fixture.at(today, 19), on: home)
        let model = makeModel()
        model.open(try #require(visible(model, "Old")).id)
        model.deleteEditing()
        #expect(store.removals.count == 1)
        #expect(visible(model, "Old") == nil)
        #expect(model.editing == nil)
    }

    @Test func selectingAnEventSelectsItsCalendar() throws {
        store.addEvent("Gym", Fixture.at(today, 7), Fixture.at(today, 8), on: home)
        let model = makeModel()
        model.select(work)
        model.open(try #require(visible(model, "Gym")).id)
        #expect(model.newEventCalendar === home)
    }

    @Test func newEventsGoToTheSelectedCalendar() {
        let model = makeModel()
        model.toggle(home)
        model.select(home)
        #expect(model.newEventCalendar === home)
        #expect(model.isVisible(home), "selecting shows the calendar")
        model.newEvent(start: Fixture.at(today, 9), end: Fixture.at(today, 10))
        #expect(model.draft.calendarID == home.calendarIdentifier)
        model.draft.title = "Groceries"
        model.commit()
        #expect(store.saves.first?.event.calendar === home)
    }

    @Test func hidingKeepsSpaceUntilYouNavigate() throws {
        store.addEvent("Work thing", Fixture.at(today, 9), Fixture.at(today, 10), on: work)
        let model = makeModel()
        model.toggle(work)
        #expect(visible(model, "Work thing")?.isHidden == true, "still laid out, just not drawn")
        model.step(1)
        model.step(-1)
        #expect(visible(model, "Work thing") == nil, "hidden for good after navigating")
        model.toggle(work)
        #expect(visible(model, "Work thing")?.isHidden == false)
    }

    @Test func soloShowsOneCalendarThenAllAgain() {
        let model = makeModel()
        model.solo(home)
        #expect(!model.isVisible(work) && model.isVisible(home))
        model.solo(home)
        #expect(model.isVisible(work) && model.isVisible(home))
    }

    @Test func hiddenFromSidebarHidesEventsAndPicker() throws {
        store.addEvent("Home thing", Fixture.at(today, 9), Fixture.at(today, 10), on: home)
        let model = makeModel()
        model.setInSidebar(home, false)
        #expect(!model.sidebarCalendars.contains(home))
        #expect(!model.writableCalendars.contains(home))
        model.step(1)
        model.step(-1)
        #expect(visible(model, "Home thing") == nil)
    }

    @Test func navigationFarOutsideTheCacheFetches() {
        let far = today.addingTimeInterval(400 * 86400)
        store.addEvent("Far away", Fixture.at(far, 10), Fixture.at(far, 11), on: work)
        let model = makeModel()
        #expect(visible(model, "Far away") == nil)
        model.focusDate = far
        #expect(visible(model, "Far away") != nil)
    }

    @Test func outsideChangesShowUpAfterStoreNotification() {
        let model = makeModel()
        store.addEvent("Added on phone", Fixture.at(today, 13), Fixture.at(today, 14), on: work)
        #expect(visible(model, "Added on phone") == nil, "served from cache until told otherwise")
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: store.ekStore)
        #expect(visible(model, "Added on phone") != nil)
    }

    @Test func textSizeIsClampedAndPersisted() {
        let defaults = Fixture.defaults()
        let model = AppModel(store: store, defaults: defaults)
        for _ in 0..<30 { model.adjustFontScale(by: 0.1) }
        #expect(model.fontScale == 2)
        for _ in 0..<30 { model.adjustFontScale(by: -0.1) }
        #expect(model.fontScale == 0.7)
        #expect(AppModel(store: store, defaults: defaults).fontScale == 0.7)
    }
}

/// Geometry and hit-testing used by the grid's single interaction layer.
@MainActor
struct GridGeometryTests {
    let cal = Calendar.current
    let monday: Date

    init() {
        monday = cal.startOfWeek(containing: Date())
    }

    private func geometry() -> GridGeometry {
        GridGeometry(days: cal.days(from: monday, count: 7), colWidth: 100, gutter: 50, hourHeight: 60, cal: cal)
    }

    private func event(_ id: String, day: Int, _ startHour: Int, _ endHour: Int) -> DisplayEvent {
        let store = FakeEventStore()
        let ek = store.addEvent(id, Fixture.at(cal.date(byAdding: .day, value: day, to: monday)!, startHour),
                                Fixture.at(cal.date(byAdding: .day, value: day, to: monday)!, endHour),
                                on: store.addCalendar("C"))
        var display = DisplayEvent(CalEvent(ek))
        display = DisplayEvent(draftID: id, draft: EventDraft(start: display.start, end: display.end, isAllDay: false,
                                                             calendarID: display.calendarID), color: .blue)
        return display
    }

    @Test func blocksAreSizedFromTimes() throws {
        let g = geometry()
        let block = try #require(g.blocks(for: [event("a", day: 2, 9, 11)]).first)
        #expect(abs(block.rect.minX - 252) < 0.001)
        #expect(abs(block.rect.minY - 540) < 0.001)
        #expect(abs(block.rect.height - 119) < 0.001)
    }

    @Test func hitTestingFindsEventsResizeHandlesAndEmptySlots() {
        let g = geometry()
        let blocks = g.blocks(for: [event("a", day: 1, 9, 10)])
        let rect = blocks[0].rect
        #expect(g.hit(CGPoint(x: rect.midX, y: rect.midY), blocks: blocks) == .event(id: "a", resize: false, dayIndex: 1))
        #expect(g.hit(CGPoint(x: rect.midX, y: rect.maxY - 2), blocks: blocks) == .event(id: "a", resize: true, dayIndex: 1))
        #expect(g.hit(CGPoint(x: 50 + 350, y: 300), blocks: blocks) == .empty(dayIndex: 3))
        #expect(g.hit(CGPoint(x: 10, y: 300), blocks: blocks) == .outside)
    }

    @Test func overlappingEventsSplitTheColumn() {
        let g = geometry()
        let blocks = g.blocks(for: [event("a", day: 0, 9, 11), event("b", day: 0, 10, 12)])
        #expect(blocks.count == 2)
        #expect(blocks[0].rect.width == blocks[1].rect.width)
        #expect(blocks[0].rect.maxX <= blocks[1].rect.minX + 1)
    }

    @Test func snappingAndDates() {
        let g = geometry()
        #expect(g.minutes(atY: 9 * 60 + 20) == 9 * 60 + 15)
        #expect(g.minutes(atY: 9 * 60 + 20, step: 30) == 9 * 60)
        #expect(g.minutesDelta(22) == 15)
        #expect(g.minutesDelta(-40) == -45)
        #expect(g.date(dayIndex: 0, minutes: 90) == Fixture.at(monday, 1, 30))
    }

    /// The binary-search bucketing must agree with the straightforward per-day check.
    @Test func dayBucketsMatchPerDayOccurrence() {
        let days = cal.days(from: cal.startOfWeek(containing: cal.startOfMonth(containing: Date())), count: 42)
        let store = Fixture.busyStore(center: days[20], spanDays: 30, perDay: 4, calendarCount: 3)
        let events = store.events(from: days[0].addingTimeInterval(-86400 * 5), to: days[41].addingTimeInterval(86400 * 5))
            .map { DisplayEvent(CalEvent($0)) }
        let buckets = DayBuckets.make(events, days: days, cal: cal)
        for (index, day) in days.enumerated() {
            let expected = Set(events.filter { $0.occurs(on: day, in: cal) }.map(\.id))
            #expect(Set(buckets[index].map(\.id)) == expected, "day \(index)")
        }
    }
}

/// Full UI rendered offscreen: regressions that only show up when SwiftUI actually lays out.
@MainActor
struct RenderingTests {
    /// The crash from switching month → day (the month grid indexed a 7-day list).
    @Test func switchingModesRendersWithoutCrashing() {
        let harness = RenderHarness(store: Fixture.busyStore(spanDays: 60, perDay: 6))
        defer { harness.close() }
        for mode in [ViewMode.month, .day, .month, .week, .month, .week, .day] {
            harness.model.mode = mode
            harness.render()
            harness.model.step(1)
            harness.render()
        }
    }

    @Test func selectingDraggingAndHidingRender() throws {
        let harness = RenderHarness(store: Fixture.busyStore(spanDays: 30, perDay: 6))
        defer { harness.close() }
        let model = harness.model
        let id = try #require(model.displayEvents.first { !$0.isAllDayLike }).id
        model.open(id)
        harness.render()
        model.isDragCreating = true
        model.newEvent(start: Fixture.at(model.visibleDays[3], 9), end: Fixture.at(model.visibleDays[3], 10))
        harness.render()
        model.isDragCreating = false
        model.cancelEditing()
        model.toggle(model.calendars[0])
        harness.render()
        model.fontScale = 1.5
        harness.render()
        #expect(model.editing == nil)
    }
}

/// Search (⌘K): the pool loads in the background, then filtering happens on every keystroke.
@MainActor
struct SearchTests {
    let store = FakeEventStore()
    let work: EKCalendar
    let home: EKCalendar
    let today = Calendar.current.startOfDay(for: Date())

    init() {
        work = store.addCalendar("Work")
        home = store.addCalendar("Home")
    }

    private func searchingModel() async throws -> AppModel {
        let model = AppModel(store: store, defaults: Fixture.defaults())
        model.focusDate = today
        model.openSearch()
        for _ in 0..<200 where model.isLoadingSearch { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoadingSearch)
        return model
    }

    @Test func matchesTitleLocationAndNotesIgnoringCaseAndAccents() async throws {
        let tomorrow = today.addingTimeInterval(86400)
        store.addEvent("Coffee with Sam", Fixture.at(tomorrow, 9), Fixture.at(tomorrow, 10), on: work)
        let lunch = store.addEvent("Lunch", Fixture.at(tomorrow, 12), Fixture.at(tomorrow, 13), on: work)
        lunch.location = "Café Rouge"
        let call = store.addEvent("Call", Fixture.at(tomorrow, 15), Fixture.at(tomorrow, 16), on: home)
        call.notes = "Discuss the roadmap"
        let model = try await searchingModel()

        model.searchQuery = "COFFEE"
        #expect(model.searchUpcoming.map(\.event.title) == ["Coffee with Sam"])
        model.searchQuery = "cafe"
        #expect(model.searchUpcoming.map(\.event.title) == ["Lunch"])
        model.searchQuery = "road"
        #expect(model.searchUpcoming.map(\.event.title) == ["Call"])
        model.searchQuery = "coffee sam"
        #expect(model.searchUpcoming.count == 1, "every word must match")
        model.searchQuery = "coffee bob"
        #expect(model.searchUpcoming.isEmpty)
    }

    @Test func pastAndUpcomingAreSeparatedAndNewestPastFirst() async throws {
        let lastWeek = today.addingTimeInterval(-7 * 86400), lastMonth = today.addingTimeInterval(-30 * 86400)
        store.addEvent("Review", Fixture.at(lastMonth, 9), Fixture.at(lastMonth, 10), on: work)
        store.addEvent("Review", Fixture.at(lastWeek, 9), Fixture.at(lastWeek, 10), on: work)
        store.addEvent("Review", Fixture.at(today.addingTimeInterval(86400), 9), Fixture.at(today.addingTimeInterval(86400), 10), on: work)
        let model = try await searchingModel()
        model.searchQuery = "review"
        #expect(model.searchUpcoming.count == 1)
        #expect(model.searchPast.map(\.event.start) == [Fixture.at(lastWeek, 9), Fixture.at(lastMonth, 9)])
    }

    @Test func matchesAreHighlightedAndClearedWithTheQuery() async throws {
        store.addEvent("Dentist", Fixture.at(today, 9), Fixture.at(today, 10), on: home)
        store.addEvent("Standup", Fixture.at(today, 11), Fixture.at(today, 11, 15), on: work)
        // (Highlighting covers past events on screen too, not just upcoming results.)
        let model = try await searchingModel()
        #expect(model.searchMatchIDs == nil)
        model.searchQuery = "dent"
        let dentist = try #require(model.displayEvents.first { $0.title == "Dentist" })
        #expect(model.searchMatchIDs == [dentist.id])
        model.closeSearch()
        #expect(model.searchMatchIDs == nil && !model.isSearching && model.searchQuery.isEmpty)
    }

    @Test func hiddenCalendarsAreLeftOut() async throws {
        store.addEvent("Private thing", Fixture.at(today.addingTimeInterval(86400), 9), Fixture.at(today.addingTimeInterval(86400), 10), on: home)
        let model = try await searchingModel()
        model.toggle(home)
        model.searchQuery = "private"
        #expect(model.searchUpcoming.isEmpty)
    }

    @Test func revealJumpsToTheDateAndOpensTheEvent() async throws {
        let later = today.addingTimeInterval(60 * 86400)
        store.addEvent("Conference", Fixture.at(later, 9), Fixture.at(later, 17), on: work)
        let model = try await searchingModel()
        model.searchQuery = "conf"
        let result = try #require(model.searchUpcoming.first)
        model.reveal(result.event)
        #expect(model.visibleDays.contains { Calendar.current.isDate($0, inSameDayAs: later) })
        #expect(model.editing?.id == result.id)
        #expect(model.isSearching, "search stays open behind the editor")
    }

    @Test func savingRefreshesSearchResults() async throws {
        let model = try await searchingModel()
        model.searchQuery = "piano"
        #expect(model.searchUpcoming.isEmpty)
        let tomorrow = today.addingTimeInterval(86400)
        model.newEvent(start: Fixture.at(tomorrow, 16), end: Fixture.at(tomorrow, 17))
        model.draft.title = "Piano lesson"
        model.commit()
        for _ in 0..<200 where model.searchUpcoming.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.searchUpcoming.map(\.event.title) == ["Piano lesson"])
    }
}

/// Month view: multi-day events as continuous bars per week row.
@MainActor
struct MonthBarTests {
    let cal = Calendar.current
    let store = FakeEventStore()
    let calendar: EKCalendar
    let rowStart: Date

    init() {
        calendar = store.addCalendar("C")
        rowStart = Calendar.current.startOfWeek(containing: Date())
    }

    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: rowStart)! }

    private func allDay(_ title: String, from first: Int, through last: Int) -> DisplayEvent {
        DisplayEvent(CalEvent(store.addEvent(title, day(first), day(last), on: calendar, allDay: true)))
    }

    private func layout(_ events: [DisplayEvent], maxRows: Int = 5) -> MonthWeekLayout {
        let days = (0..<7).map(day)
        return MonthWeekLayout.make(DayBuckets.make(events, days: days, cal: cal), rowStart: rowStart, maxRows: maxRows, cal: cal)
    }

    @Test func multiDayEventIsOneBarAcrossItsDays() throws {
        let trip = allDay("Trip", from: 1, through: 3)
        let week = layout([trip])
        let bar = try #require(week.bars.first)
        #expect(week.bars.count == 1)
        #expect(bar.first == 1 && bar.last == 3 && bar.lane == 0)
        #expect(!bar.continuesBefore && !bar.continuesAfter)
        #expect(week.laneIDs.map { $0.first ?? nil } == [nil, trip.id, trip.id, trip.id, nil, nil, nil])
    }

    @Test func daysOnlyReserveRowsForTheirOwnBars() {
        let week = allDay("Week-long", from: 0, through: 6)
        let short = allDay("Two days", from: 0, through: 1)
        let layout = layout([week, short])
        #expect(layout.shownLanes == 2)
        #expect(layout.laneIDs.map(\.count) == [2, 2, 1, 1, 1, 1, 1], "later days reclaim the second row")
    }

    @Test func barsThatCrossWeeksContinue() throws {
        let long = allDay("Vacation", from: -2, through: 9)
        let bar = try #require(layout([long]).bars.first)
        #expect(bar.first == 0 && bar.last == 6)
        #expect(bar.continuesBefore && bar.continuesAfter)
    }

    @Test func overlappingBarsStackAndOverflowIntoMore() {
        let events = (0..<4).map { allDay("E\($0)", from: 0, through: 2) }
        let week = layout(events, maxRows: 3)
        #expect(week.shownLanes == 2, "last row is kept for \"N more\"")
        #expect(week.bars.count == 2)
        #expect(week.hiddenBars == [2, 2, 2, 0, 0, 0, 0])
    }
}

@MainActor
struct TitleTests {
    @Test func weekTitleShowsTheDayRange() {
        let model = AppModel(store: FakeEventStore(), defaults: Fixture.defaults())
        model.mode = .week
        var components = DateComponents(year: 2026, month: 9, day: 30)
        model.focusDate = Calendar.current.date(from: components)!
        let first = model.visibleDays[0], last = model.visibleDays[6]
        #expect(model.title == (first..<last).formatted(.interval.month(.abbreviated).day().year()))
        #expect(model.title.contains(last.formatted(.dateTime.day())))
        components.month = 12
        components.day = 31
        model.focusDate = Calendar.current.date(from: components)!
        #expect(model.title.contains("2026") && model.title.contains("2027"), "a week spanning New Year shows both years")
    }
}
