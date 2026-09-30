import AppKit
import XCTest
@testable import CCal

/// Renders key screens (with fake data) to PNGs for eyeballing layout changes.
/// Runs only when SNAPSHOT_DIR is set (via TEST_RUNNER_SNAPSHOT_DIR).
@MainActor
final class SnapshotTests: XCTestCase {
    private func snapshot(_ harness: RenderHarness, _ name: String) throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["SNAPSHOT_DIR"])
        harness.render()
        let view = harness.hosting
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    func testScreens() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] == nil)
        let harness = RenderHarness(store: Fixture.busyStore(perDay: 6))
        defer { harness.close() }
        try snapshot(harness, "week")

        let event = harness.model.displayEvents.first { !$0.isAllDayLike && $0.start > Date() }!
        harness.model.open(event.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8)) // let the inspector finish sliding in
        try snapshot(harness, "week-selected")

        harness.model.cancelEditing()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // A narrow window: the inspector must keep its labels on one line.
        let narrow = RenderHarness(store: Fixture.busyStore(perDay: 6), size: CGSize(width: 1000, height: 800))
        defer { narrow.close() }
        narrow.model.open(narrow.model.displayEvents.first { !$0.isAllDayLike }!.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        try snapshot(narrow, "narrow-inspector")

        harness.model.openSearch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        harness.model.searchQuery = "event 12"
        try snapshot(harness, "week-search")
        harness.model.closeSearch()
        harness.model.mode = .month
        try snapshot(harness, "month")
        harness.model.open(harness.model.displayEvents.first { !$0.isAllDayLike }!.id)
        try snapshot(harness, "month-selected")
    }
}
