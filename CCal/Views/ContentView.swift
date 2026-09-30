import EventKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some View {
        Group {
            if model.hasAccess {
                MainView()
            } else {
                AccessView()
            }
        }
        .task {
            if model.authorization == .notDetermined && !isRunningTests {
                await model.requestAccess()
            }
        }
    }
}

private struct MainView: View {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model
    @State private var eventMonitors: [Any] = []

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            Group {
                switch model.mode {
                case .day, .week:
                    TimeGridView(days: model.visibleDays)
                case .month:
                    MonthView()
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .navigationTitle(model.title)
            // The system title can't be restyled, so it's replaced by a larger label in the toolbar.
            .toolbar(removing: .title)
            .inspector(isPresented: inspectorPresented) {
                EventInspector()
                    // Wide enough for the date + time pickers beside their labels; grows with text size.
                    .inspectorColumnWidth(min: 340 * s, ideal: 370 * s, max: 520 * s)
            }
            .toolbar { toolbar }
        }
        .confirmationDialog(
            model.spanPrompt?.title ?? "",
            isPresented: spanPromptPresented,
            presenting: model.spanPrompt
        ) { prompt in
            Button("\(prompt.verb) This Event Only") { prompt.perform(.thisEvent) }
            Button("\(prompt.verb) All Future Events") { prompt.perform(.futureEvents) }
            Button("Cancel", role: .cancel) { prompt.onCancel() }
        }
        .sheet(isPresented: $model.showingShortcuts) { ShortcutsView() }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { eventMonitors = KeyboardShortcuts.install(model: model) }
        .onDisappear { KeyboardShortcuts.remove(eventMonitors) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.saveBeforeQuit()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                Text(model.title)
                    .font(.system(size: 20, weight: .bold))
                    .fixedSize()
                // Only visible after ⌘R: spinner while syncing, then a checkmark.
                switch model.syncState {
                case .idle: EmptyView()
                case .syncing: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 6)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .principal) {
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous (⌘←)")
            Button("Today") { model.goToToday() }
                .help("Today (T)")
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .help("Next (⌘→)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $model.mode) {
                ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Day (D) · Week (W) · Month (M)")
            Button { model.newEventAtNextSlot() } label: { Label("New Event", systemImage: "plus") }
                .help("New Event (N)")
            Button { model.toggleSearchFromButton() } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search Events (⌘K)")
        }
    }

    private var inspectorPresented: Binding<Bool> {
        // Held back while drag-creating so the grid doesn't narrow under the cursor.
        Binding(get: { (model.editing != nil || model.isSearching) && !model.isDragCreating },
                set: { if !$0 { model.commit(); model.closeSearch() } })
    }

    private var spanPromptPresented: Binding<Bool> {
        Binding(get: { model.spanPrompt != nil }, set: { if !$0 { model.spanPrompt = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct AccessView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            switch model.authorization {
            case .notDetermined:
                Text("CCal needs access to your calendars.").font(.title3)
                Button("Allow Calendar Access") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            default:
                Text("Calendar access is turned off.").font(.title3)
                Text("Turn on CCal under Privacy & Security → Calendars, with Full Access.")
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                .buttonStyle(.borderedProminent)
            }
            Text("CCal uses the accounts in System Settings → Internet Accounts.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
