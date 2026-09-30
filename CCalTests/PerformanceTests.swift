import EventKit
import SwiftUI
import XCTest
@testable import CCal

/// Timings for the interactions that should feel instant. Uses a deliberately busy calendar
/// (12 timed events a day across 12 calendars, plus all-day and multi-day events).
@MainActor
final class PerformanceTests: XCTestCase {
    private var harness: RenderHarness!

    override func setUp() async throws {
        harness = RenderHarness(store: Fixture.busyStore())
    }

    override func tearDown() async throws {
        harness.close()
        harness = nil
    }

    private var options: XCTMeasureOptions {
        let o = XCTMeasureOptions()
        // PERF_ITER (set via TEST_RUNNER_PERF_ITER) runs longer for profiling with `sample`.
        o.iterationCount = Int(ProcessInfo.processInfo.environment["PERF_ITER"] ?? "") ?? 10
        return o
    }

    func testNavigateWeeks() {
        measure(metrics: [XCTClockMetric()], options: options) {
            for _ in 0..<5 { harness.model.step(1); harness.render() }
            for _ in 0..<5 { harness.model.step(-1); harness.render() }
        }
    }

    func testSwitchModes() {
        measure(metrics: [XCTClockMetric()], options: options) {
            for mode in [ViewMode.month, .day, .week] { harness.model.mode = mode; harness.render() }
        }
    }

    func testNavigateMonths() {
        harness.model.mode = .month
        harness.render()
        measure(metrics: [XCTClockMetric()], options: options) {
            for _ in 0..<3 { harness.model.step(1); harness.render() }
            for _ in 0..<3 { harness.model.step(-1); harness.render() }
        }
    }

    /// Clicking between events while the inspector is already open.
    func testSwitchSelection() {
        let ids = harness.model.displayEvents.filter { !$0.isAllDayLike }.prefix(6).map(\.id)
        harness.model.open(ids[0])
        harness.render()
        measure(metrics: [XCTClockMetric()], options: options) {
            for id in ids.dropFirst() + [ids[0]] { harness.model.open(id); harness.render() }
        }
    }

    /// First click on an event (inspector opens), then Esc (inspector closes).
    func testOpenAndCloseInspector() {
        let id = harness.model.displayEvents.first { !$0.isAllDayLike }!.id
        measure(metrics: [XCTClockMetric()], options: options) {
            harness.model.open(id); harness.render()
            harness.model.cancelEditing(); harness.render()
        }
    }

    func testDragCreate() {
        let day = harness.model.visibleDays[2]
        // Mirrors GridInteractionLayer: the inspector stays closed until the mouse is released.
        measure(metrics: [XCTClockMetric()], options: options) {
            harness.model.isDragCreating = true
            harness.model.newEvent(start: Fixture.at(day, 9), end: Fixture.at(day, 9, 15))
            harness.render()
            for step in 1...20 {
                harness.model.updateDraftTimes(start: Fixture.at(day, 9), end: Fixture.at(day, 9, 15 + step * 5))
                harness.render()
            }
            harness.model.isDragCreating = false
            harness.model.cancelEditing()
            harness.render()
        }
    }

    func testToggleCalendar() {
        let calendar = harness.model.calendars[0]
        measure(metrics: [XCTClockMetric()], options: options) {
            for _ in 0..<3 {
                harness.model.toggle(calendar); harness.render()
                harness.model.toggle(calendar); harness.render()
            }
        }
    }

    func testDisplayEventsComputation() {
        harness.model.mode = .month
        measure(metrics: [XCTClockMetric()], options: options) {
            for _ in 0..<20 { _ = harness.model.displayEvents }
        }
    }

    /// Week and month navigation over the Mac's real calendars. Read-only: nothing is saved.
    func testNavigateRealCalendars() throws {
        let real = SystemEventStore()
        try XCTSkipUnless(real.authorizationStatus == .fullAccess, "No calendar access")
        let model = AppModel(store: real, defaults: Fixture.defaults())
        let root = ContentView().environment(model).environment(\.fontScale, 1)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        defer { window.close() }
        func render() {
            RunLoop.main.run(until: Date())
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            hosting.display()
        }
        render()
        measure(metrics: [XCTClockMetric()], options: options) {
            for mode in [ViewMode.week, .month] {
                model.mode = mode
                render()
                for _ in 0..<3 { model.step(1); render() }
                for _ in 0..<3 { model.step(-1); render() }
            }
        }
    }

    /// Read-only fetches from the Mac's real calendars (skipped without calendar access).
    func testRealStoreFetch() throws {
        let store = SystemEventStore()
        try XCTSkipUnless(store.authorizationStatus == .fullAccess, "No calendar access")
        let cal = Calendar.current
        let weekStart = cal.startOfWeek(containing: Date())
        let monthStart = cal.startOfWeek(containing: cal.startOfMonth(containing: Date()))
        var counts: [Int] = []
        measure(metrics: [XCTClockMetric()], options: options) {
            counts = [
                store.events(from: weekStart, to: cal.date(byAdding: .day, value: 7, to: weekStart)!).count,
                store.events(from: monthStart, to: cal.date(byAdding: .day, value: 42, to: monthStart)!).count,
            ]
        }
        print("REAL-FETCH week=\(counts[0]) events, month=\(counts[1]) events")
    }
}
