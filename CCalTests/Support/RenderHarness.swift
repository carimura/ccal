import AppKit
import SwiftUI
@testable import CCal

/// Hosts the real ContentView (sidebar, toolbar, grid, inspector) in an offscreen window
/// so tests can drive the model and force SwiftUI to lay out and draw, as it would on screen.
@MainActor
final class RenderHarness {
    let model: AppModel
    let store: FakeEventStore
    let window: NSWindow
    let hosting: NSView

    init(store: FakeEventStore, mode: ViewMode = .week, focus: Date = Date(), size: CGSize = CGSize(width: 1400, height: 900)) {
        self.store = store
        model = AppModel(store: store, defaults: Fixture.defaults())
        model.mode = mode
        model.focusDate = focus
        let root = ContentView().environment(model).environment(\.fontScale, 1)
        hosting = NSHostingView(rootView: root)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        render()
    }

    /// Flushes pending SwiftUI updates, then lays out and draws.
    func render() {
        RunLoop.main.run(until: Date())
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
    }

    func close() { window.close() }
}
