import EventKit
import Foundation
import Testing
@testable import CCal

struct EventLayoutTests {
    @Test func nonOverlappingEventsGetFullWidth() {
        let slots = EventLayout.columns(for: [
            TimedSpan(id: "a", start: 540, end: 600),
            TimedSpan(id: "b", start: 600, end: 660),
        ])
        #expect(slots["a"] == ColumnSlot(column: 0, columns: 1))
        #expect(slots["b"] == ColumnSlot(column: 0, columns: 1))
    }

    @Test func overlappingEventsSplitAndReuseColumns() {
        // a overlaps b and c; b ends before c starts, so c reuses b's column.
        let slots = EventLayout.columns(for: [
            TimedSpan(id: "a", start: 540, end: 720),
            TimedSpan(id: "b", start: 560, end: 600),
            TimedSpan(id: "c", start: 630, end: 690),
            TimedSpan(id: "d", start: 800, end: 860),
        ])
        #expect(slots["a"] == ColumnSlot(column: 0, columns: 2))
        #expect(slots["b"] == ColumnSlot(column: 1, columns: 2))
        #expect(slots["c"] == ColumnSlot(column: 1, columns: 2))
        #expect(slots["d"] == ColumnSlot(column: 0, columns: 1))
    }

    @Test func allDayLanesStackOverlappingBars() {
        let lanes = EventLayout.lanes(for: [
            DaySpan(id: "trip", first: 0, last: 4),
            DaySpan(id: "mon", first: 0, last: 0),
            DaySpan(id: "fri", first: 5, last: 5),
        ])
        #expect(lanes["trip"] == 0)
        #expect(lanes["mon"] == 1)
        #expect(lanes["fri"] == 0)
    }
}

struct RepeatRuleTests {
    @Test func roundTripsSimpleRules() {
        for rule in RepeatRule.allCases where rule != .custom {
            #expect(RepeatRule(rules: rule.rules) == rule)
        }
    }

    @Test func richerRulesAreCustom() {
        let ends = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5))
        #expect(RepeatRule(rules: [ends]) == .custom)
        let every3Days = EKRecurrenceRule(recurrenceWith: .daily, interval: 3, end: nil)
        #expect(RepeatRule(rules: [every3Days]) == .custom)
    }
}

struct DateHelperTests {
    @Test func startOfWeekRespectsFirstWeekday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let tuesday = cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 15))!
        cal.firstWeekday = 1
        #expect(cal.component(.day, from: cal.startOfWeek(containing: tuesday)) == 27)
        cal.firstWeekday = 2
        #expect(cal.component(.day, from: cal.startOfWeek(containing: tuesday)) == 28)
    }

    @Test func minutesAreWallClockOnDSTDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Nov 1 2026: clocks fall back at 2 AM, so 9 AM is 10 hours after midnight in absolute time.
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let nine = cal.date(on: day, minutes: 540)
        #expect(cal.minutesIntoDay(nine) == 540)
        #expect(cal.component(.hour, from: nine) == 9)
    }
}
