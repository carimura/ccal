import AppKit
import EventKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let store: EventStoring
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var authorization: EKAuthorizationStatus
    private(set) var calendars: [EKCalendar] = []
    /// Events overlapping the visible range (including ones on hidden calendars).
    private(set) var events: [CalEvent] = []
    /// What the views draw: `events` as display values, hidden-calendar rules applied. See `displayEvents`.
    private(set) var visibleDisplay: [DisplayEvent] = []

    /// Fetched events for a window around the visible range, so navigating doesn't hit EventKit.
    @ObservationIgnored private var cache: (range: DateInterval, events: [CalEvent], display: [DisplayEvent])?
    @ObservationIgnored private var cacheGeneration = 0
    @ObservationIgnored private var isPrefetching = false

    /// A fixed snapshot (much faster than `autoupdatingCurrent`); replaced when the locale or time zone changes.
    private(set) var cal = Calendar.current

    var mode: ViewMode {
        didSet {
            defaults.set(mode.rawValue, forKey: "viewMode")
            rangeChanged()
        }
    }

    var focusDate = Date() {
        didSet { rangeChanged() }
    }

    private(set) var visibleDays: [Date] = []

    var hiddenCalendarIDs: Set<String> {
        didSet {
            defaults.set(Array(hiddenCalendarIDs), forKey: "hiddenCalendarIDs")
            rebuildVisible()
        }
    }

    /// Calendars removed from the sidebar (right-click → Hide, or Settings). Their events are hidden too.
    var sidebarHiddenIDs: Set<String> {
        didSet {
            defaults.set(Array(sidebarHiddenIDs), forKey: "sidebarHiddenIDs")
            rebuildVisible()
        }
    }

    /// The calendar selected in the sidebar: where new events go.
    var selectedCalendarID: String? {
        didSet { defaults.set(selectedCalendarID, forKey: "selectedCalendarID") }
    }

    // Search (⌘K): results come from a year back to a year ahead, loaded once in the background.
    var isSearching = false
    var searchQuery = "" {
        didSet { updateSearchResults() }
    }
    /// IDs of every matching event; nil when there's no query. Views highlight these and fade the rest.
    private(set) var searchMatchIDs: Set<String>?
    private(set) var searchUpcoming: [SearchItem] = []
    private(set) var searchPast: [SearchItem] = []
    private(set) var isLoadingSearch = false
    var searchFocusRequest = 0
    @ObservationIgnored private var searchPool: [SearchItem] = []
    @ObservationIgnored private var searchClosedAt = Date.distantPast
    @ObservationIgnored private var searchPoolGeneration = -1

    /// True while drag-creating, so the inspector waits until the mouse is released.
    var isDragCreating = false

    /// Everything whose events aren't drawn: unchecked calendars plus ones hidden from the sidebar.
    var concealedCalendarIDs: Set<String> { hiddenCalendarIDs.union(sidebarHiddenIDs) }

    var showingShortcuts = false

    /// Calendars that were already hidden when this day/week/month was shown. They take no space;
    /// calendars hidden since then keep their space so the layout doesn't move while toggling.
    private var settledHiddenIDs: Set<String>

    var fontScale: Double {
        didSet { defaults.set(fontScale, forKey: "fontScale") }
    }

    var editing: EditSession?
    var spanPrompt: SpanPrompt?
    var errorMessage: String?
    private(set) var isImportingICS = false
    var importMessage: String?
    /// Bumped to ask the inspector to focus its title field.
    var titleFocusRequest = 0

    init(store: EventStoring = SystemEventStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        authorization = store.authorizationStatus
        mode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .week
        selectedCalendarID = defaults.string(forKey: "selectedCalendarID")
        let savedScale = defaults.double(forKey: "fontScale")
        fontScale = savedScale == 0 ? 1 : savedScale
        let hidden = Set(defaults.stringArray(forKey: "hiddenCalendarIDs") ?? [])
        let removed = Set(defaults.stringArray(forKey: "sidebarHiddenIDs") ?? [])
        hiddenCalendarIDs = hidden
        sidebarHiddenIDs = removed
        settledHiddenIDs = hidden.union(removed)
        visibleDays = computeVisibleDays()
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store.ekStore, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cal = Calendar.current
                    self?.rangeChanged()
                }
            }
        }
        if hasAccess {
            loadCalendars()
            reload()
        }
    }

    // MARK: - Access

    var hasAccess: Bool { authorization == .fullAccess }

    func requestAccess() async {
        do {
            try await store.requestAccess()
        } catch {
            errorMessage = error.localizedDescription
        }
        authorization = store.authorizationStatus
        if hasAccess {
            loadCalendars()
            reload()
        }
    }

    // MARK: - Fetching

    private func loadCalendars() {
        calendars = store.calendars().sorted {
            ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title)
        }
    }

    private func rangeChanged() {
        settledHiddenIDs = concealedCalendarIDs
        visibleDays = computeVisibleDays()
        reload()
    }

    /// Shows the visible range from the cache, fetching only if it isn't covered.
    /// Fetches hidden calendars too: the grid lays out every event so hiding one never moves the rest.
    func reload() {
        guard hasAccess else { return }
        let range = visibleRange
        if let cache, cache.range.start <= range.start, cache.range.end >= range.end {
            rebuildVisible()
            prefetchIfNearEdge()
            return
        }
        let window = fetchWindow(around: range)
        installCache(window, store.events(from: window.start, to: window.end).map(CalEvent.init))
        rebuildVisible()
    }

    /// After a save or an outside change: drop the cache and fetch fresh.
    private func invalidateAndReload() {
        cache = nil
        cacheGeneration += 1
        reload()
        if isSearching { loadSearchPool() }
    }

    /// The visible range plus one page on either side, so ← and → are served from memory.
    private func fetchWindow(around range: DateInterval) -> DateInterval {
        let page = range.duration
        return DateInterval(start: range.start.addingTimeInterval(-page), end: range.end.addingTimeInterval(page))
    }

    private func installCache(_ window: DateInterval, _ fetched: [CalEvent]) {
        cache = (window, fetched, fetched.map(DisplayEvent.init))
    }

    // MARK: - Search

    func openSearch() {
        isSearching = true
        searchFocusRequest += 1
        if searchPoolGeneration != cacheGeneration { loadSearchPool() }
    }

    func closeSearch() {
        isSearching = false
        searchQuery = ""
        searchClosedAt = Date()
    }

    /// The 🔍 button toggles search. If the click that pressed it also closed an empty search (by
    /// leaving the field), don't immediately reopen it.
    func toggleSearchFromButton() {
        if isSearching {
            closeSearch()
        } else if Date().timeIntervalSince(searchClosedAt) > 0.5 {
            openSearch()
        }
    }

    /// Jumps to a result's date (keeping the current view mode) and selects it.
    func reveal(_ event: DisplayEvent) {
        focusDate = event.start
        open(event.id)
    }

    private func loadSearchPool() {
        let now = Date()
        let start = now.addingTimeInterval(-365 * 86400), end = now.addingTimeInterval(365 * 86400)
        let generation = cacheGeneration
        let store = store
        isLoadingSearch = true
        Task.detached(priority: .userInitiated) {
            let items = store.events(from: start, to: end)
                .sorted { $0.startDate < $1.startDate }
                .map { SearchItem(CalEvent($0)) }
            await MainActor.run { [weak self] in
                guard let self, generation == cacheGeneration else { return }
                searchPool = items
                searchPoolGeneration = generation
                isLoadingSearch = false
                updateSearchResults()
            }
        }
    }

    /// Filters the pool on every keystroke (in memory, so it keeps up with typing).
    /// Every occurrence of a repeating event is listed.
    private func updateSearchResults() {
        let tokens = SearchItem.tokens(searchQuery)
        guard isSearching, !tokens.isEmpty else {
            searchMatchIDs = nil
            searchUpcoming = []
            searchPast = []
            return
        }
        let concealed = concealedCalendarIDs
        let matches = searchPool.filter { item in
            !concealed.contains(item.event.calendarID) && tokens.allSatisfy { item.text.contains($0) }
        }
        let now = Date()
        searchMatchIDs = Set(matches.map(\.id))
        searchUpcoming = Array(matches.lazy.filter { $0.event.end >= now }.prefix(150))
        searchPast = Array(matches.reversed().lazy.filter { $0.event.end < now }.prefix(150))
    }

    /// Recenters the cache in the background once the visible range gets within half a page of its edge.
    private func prefetchIfNearEdge() {
        guard let cached = cache?.range, !isPrefetching else { return }
        let range = visibleRange
        let margin = range.duration / 2
        guard range.start.timeIntervalSince(cached.start) < margin
                || cached.end.timeIntervalSince(range.end) < margin else { return }
        let window = fetchWindow(around: range)
        let generation = cacheGeneration
        let store = store
        isPrefetching = true
        // EventKit documents events(matching:) as safe to run off the main thread.
        Task.detached(priority: .userInitiated) {
            let fetched = store.events(from: window.start, to: window.end).map(CalEvent.init)
            let display = fetched.map(DisplayEvent.init)
            await MainActor.run { [weak self] in
                guard let self else { return }
                isPrefetching = false
                // Same data as on screen, so the visible arrays are left alone (no redraw).
                if generation == cacheGeneration { cache = (window, fetched, display) }
            }
        }
    }

    /// Picks the visible slice of the cache and applies hidden-calendar rules.
    private func rebuildVisible() {
        guard let cache else {
            events = []
            visibleDisplay = []
            return
        }
        let range = visibleRange
        let concealed = concealedCalendarIDs
        var visibleEvents: [CalEvent] = []
        var display: [DisplayEvent] = []
        for (event, item) in zip(cache.events, cache.display)
        where item.start < range.end && (item.end > range.start || item.start >= range.start) {
            visibleEvents.append(event)
            guard concealed.contains(item.calendarID) else {
                display.append(item)
                continue
            }
            if !settledHiddenIDs.contains(item.calendarID) {
                var hidden = item
                hidden.isHidden = true
                display.append(hidden)
            }
        }
        events = visibleEvents
        visibleDisplay = display
    }

    enum SyncState { case idle, syncing, done }
    private(set) var syncState = SyncState.idle

    /// ⌘R. EventKit's refresh is fire-and-forget, so the spinner runs for a moment, then shows a checkmark.
    func refresh() {
        guard syncState != .syncing else { return }
        syncState = .syncing
        store.refreshSources()
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            loadCalendars()
            invalidateAndReload()
            syncState = .done
            try? await Task.sleep(for: .seconds(1.5))
            if syncState == .done { syncState = .idle }
        }
    }

    private func storeChanged() {
        loadCalendars()
        invalidateAndReload()
        // Someone else deleted the event we're looking at.
        if let session = editing, !session.isNew, !session.event.refresh() {
            editing = nil
        }
    }

    // MARK: - Visible range & navigation

    private func computeVisibleDays() -> [Date] {
        switch mode {
        case .day:
            [cal.startOfDay(for: focusDate)]
        case .week:
            cal.days(from: cal.startOfWeek(containing: focusDate), count: 7)
        case .month:
            cal.days(from: cal.startOfWeek(containing: cal.startOfMonth(containing: focusDate)), count: 42)
        }
    }

    var visibleRange: DateInterval {
        let days = visibleDays
        return DateInterval(start: days[0], end: cal.date(byAdding: .day, value: 1, to: days[days.count - 1])!)
    }

    var title: String {
        switch mode {
        case .day:
            return focusDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .month:
            return focusDate.formatted(.dateTime.month(.wide).year())
        case .week:
            // e.g. "Sep 21 – 27, 2026", "Sep 27 – Oct 3, 2026", "Dec 27, 2026 – Jan 2, 2027"
            let days = visibleDays
            return (days[0]..<days[6]).formatted(.interval.month(.abbreviated).day().year())
        }
    }

    func step(_ direction: Int) {
        focusDate = cal.date(byAdding: mode.step, value: direction, to: focusDate)!
    }

    func goToToday() { focusDate = Date() }

    func adjustFontScale(by delta: Double) {
        fontScale = min(max((fontScale + delta) * 10, 7).rounded() / 10, 2)
    }

    func show(_ day: Date, in mode: ViewMode) {
        focusDate = day
        self.mode = mode
    }

    func toggle(_ calendar: EKCalendar) {
        if hiddenCalendarIDs.contains(calendar.calendarIdentifier) {
            hiddenCalendarIDs.remove(calendar.calendarIdentifier)
        } else {
            hiddenCalendarIDs.insert(calendar.calendarIdentifier)
        }
    }

    /// ⌘-click: show only this calendar, or everything again if it's already the only one.
    func solo(_ calendar: EKCalendar) {
        let others = Set(sidebarCalendars.map(\.calendarIdentifier)).subtracting([calendar.calendarIdentifier])
        hiddenCalendarIDs = others.isSubset(of: hiddenCalendarIDs) && isVisible(calendar) ? [] : others
    }

    func isVisible(_ calendar: EKCalendar) -> Bool {
        !concealedCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func isInSidebar(_ calendar: EKCalendar) -> Bool {
        !sidebarHiddenIDs.contains(calendar.calendarIdentifier)
    }

    func setInSidebar(_ calendar: EKCalendar, _ shown: Bool) {
        if shown {
            sidebarHiddenIDs.remove(calendar.calendarIdentifier)
        } else {
            sidebarHiddenIDs.insert(calendar.calendarIdentifier)
        }
    }

    var sidebarCalendars: [EKCalendar] {
        calendars.filter(isInSidebar)
    }

    var writableCalendars: [EKCalendar] {
        calendars.filter { $0.allowsContentModifications && isInSidebar($0) }
    }

    func color(forCalendarID id: String) -> Color {
        Color(cgColor: store.calendar(withIdentifier: id)?.cgColor ?? CGColor(gray: 0.5, alpha: 1))
    }

    // MARK: - What the views draw

    var displayEvents: [DisplayEvent] {
        var result = visibleDisplay
        if let session = editing {
            let color = color(forCalendarID: session.draft.calendarID)
            if session.isNew {
                result.append(DisplayEvent(draftID: session.id, draft: session.draft, color: color))
            } else if let i = result.firstIndex(where: { $0.id == session.id }) {
                result[i].apply(session.draft, color: color)
            }
        }
        return result
    }

    /// The event being edited or created, with unsaved changes applied (nil when nothing is selected).
    var editingDisplay: DisplayEvent? {
        guard let session = editing else { return nil }
        let color = color(forCalendarID: session.draft.calendarID)
        if session.isNew { return DisplayEvent(draftID: session.id, draft: session.draft, color: color) }
        guard var event = visibleDisplay.first(where: { $0.id == session.id }) else { return nil }
        event.apply(session.draft, color: color)
        return event
    }

    /// Two-way binding target for the inspector form.
    var draft: EventDraft {
        get { editing?.draft ?? EventDraft(start: Date(), end: Date(), isAllDay: false, calendarID: "") }
        set { editing?.draft = newValue }
    }

    // MARK: - Editing

    /// Selects an event, and its calendar in the sidebar.
    /// `anchor` is where the editor popover attaches if it's opened (see `showEditor`).
    func open(_ id: String, anchor: CGRect? = nil) {
        guard editing?.id != id, let event = events.first(where: { $0.id == id }) else { return }
        finishEditing { [weak self] in
            let draft = EventDraft(event.ek)
            self?.editing = EditSession(
                id: event.id, event: event.ek, isNew: false, isEditable: event.isEditable,
                draft: draft, original: draft, anchor: anchor)
            if let calendar = event.ek.calendar { self?.select(calendar) }
        }
    }

    func newEvent(start: Date, end: Date, isAllDay: Bool = false) {
        finishEditing { [weak self] in
            guard let self else { return }
            // A read-only calendar selected in the sidebar means no new events (quietly, since it's on purpose).
            guard let calendar = newEventCalendar else {
                if selectedCalendar == nil {
                    errorMessage = "There's no calendar you can add events to. Add an account in System Settings → Internet Accounts."
                }
                return
            }
            // A new event on an unchecked calendar would vanish on save, so show that calendar.
            hiddenCalendarIDs.remove(calendar.calendarIdentifier)
            let draft = EventDraft(start: start, end: end, isAllDay: isAllDay, calendarID: calendar.calendarIdentifier)
            editing = EditSession(
                id: "draft-\(UUID().uuidString)", event: EKEvent(eventStore: store.ekStore), isNew: true,
                isEditable: true, draft: draft, original: draft, showsEditor: true)
            titleFocusRequest += 1
        }
    }

    /// ⌘N: the next half hour today if today is on screen, otherwise 9 AM on the focused day.
    func newEventAtNextSlot() {
        let now = Date()
        let start: Date
        if visibleDays.contains(where: cal.isDateInToday) {
            let minutes = Int(cal.minutesIntoDay(now))
            start = cal.date(on: now, minutes: min((minutes / 30 + 1) * 30, 23 * 60))
        } else {
            start = cal.date(on: focusDate, minutes: 9 * 60)
        }
        newEvent(start: start, end: start.addingTimeInterval(3600))
    }

    /// Live update while drag-creating a new event.
    func updateDraftTimes(start: Date, end: Date) {
        guard editing?.isNew == true else { return }
        editing?.draft.start = start
        editing?.draft.end = end
    }

    func setDraftStart(_ newStart: Date) {
        guard var s = editing else { return }
        let duration = s.draft.end.timeIntervalSince(s.draft.start)
        s.draft.start = newStart
        s.draft.end = newStart.addingTimeInterval(max(0, duration))
        editing = s
    }

    func setDraftEnd(_ newEnd: Date) {
        guard var s = editing else { return }
        s.draft.end = max(newEnd, s.draft.start)
        editing = s
    }

    func setDraftAllDay(_ allDay: Bool) {
        guard var s = editing, s.draft.isAllDay != allDay else { return }
        if allDay {
            s.draft.end = cal.startOfDay(for: max(s.draft.start, s.draft.end.addingTimeInterval(-1)))
            s.draft.start = cal.startOfDay(for: s.draft.start)
        } else {
            s.draft.start = cal.date(on: s.draft.start, minutes: 9 * 60)
            s.draft.end = s.draft.start.addingTimeInterval(3600)
        }
        s.draft.isAllDay = allDay
        editing = s
    }

    /// Save (or discard an untitled draft) and close the inspector.
    func commit() { finishEditing {} }

    /// Drop unsaved changes and close the inspector.
    func cancelEditing() { editing = nil }

    func requestTitleFocus() { titleFocusRequest += 1 }

    /// Opens the editor popover for the selected event, attached to `anchor` if given.
    func showEditor(anchor: CGRect? = nil) {
        guard editing != nil else { return }
        if let anchor { editing?.anchor = anchor }
        editing?.showsEditor = true
    }

    /// Saves whatever is being edited, then runs `next`. If the event repeats, asks which
    /// occurrences to change first; cancelling that prompt keeps the editor open and skips `next`.
    private func finishEditing(then next: @escaping () -> Void) {
        guard let s = editing else { return next() }
        guard s.isEditable, s.hasChanges || s.isNew else {
            editing = nil
            return next()
        }
        if s.isNew {
            if !s.draft.title.trimmingCharacters(in: .whitespaces).isEmpty {
                save(s, span: .thisEvent)
            }
            editing = nil
            return next()
        }
        // Changing the repeat rule itself only makes sense for the series going forward.
        if s.event.hasRecurrenceRules && s.draft.recurrence == s.original.recurrence {
            spanPrompt = SpanPrompt(title: "This is a repeating event.", verb: "Save") { [weak self] span in
                self?.save(s, span: span)
                self?.editing = nil
                next()
            }
            return
        }
        save(s, span: s.event.hasRecurrenceRules ? .futureEvents : .thisEvent)
        editing = nil
        next()
    }

    private func save(_ s: EditSession, span: EKSpan) {
        s.draft.apply(to: s.event, store: store, original: s.isNew ? nil : s.original)
        do {
            try store.save(s.event, span: span)
        } catch {
            errorMessage = error.localizedDescription
        }
        invalidateAndReload()
    }

    /// Drag-move or drag-resize from the grid. Existing events save right away (one save per drag).
    func move(_ id: String, start: Date, end: Date) {
        if var s = editing, s.id == id {
            s.draft.start = start
            s.draft.end = end
            if s.isNew {
                editing = s
                return
            }
        }
        guard let event = events.first(where: { $0.id == id }), event.isEditable else { return }
        let perform: (EKSpan) -> Void = { [weak self] span in
            guard let self else { return }
            event.ek.startDate = start
            event.ek.endDate = end
            do {
                try store.save(event.ek, span: span)
            } catch {
                errorMessage = error.localizedDescription
            }
            if var s = editing, s.id == id {
                s.draft.start = start
                s.draft.end = end
                s.original.start = start
                s.original.end = end
                editing = s
            }
            invalidateAndReload()
        }
        if event.ek.hasRecurrenceRules {
            spanPrompt = SpanPrompt(title: "This is a repeating event.", verb: "Move", perform: perform)
        } else {
            perform(.thisEvent)
        }
    }

    /// Right-click → Copy to: a new event with the same details on another calendar. Guests aren't
    /// copied, so this never sends invites. Saves any open edits first so the copy includes them.
    func copy(_ id: String, to calendar: EKCalendar) {
        finishEditing { [weak self] in
            guard let self, let source = events.first(where: { $0.id == id })?.ek else { return }
            let copy = EKEvent(eventStore: store.ekStore)
            var draft = EventDraft(source)
            draft.calendarID = calendar.calendarIdentifier
            draft.apply(to: copy, store: store, original: nil)
            copy.timeZone = source.timeZone
            copy.recurrenceRules = source.recurrenceRules?.map { $0.copy() as! EKRecurrenceRule }
            do {
                try store.save(copy, span: .thisEvent)
            } catch {
                errorMessage = error.localizedDescription
            }
            invalidateAndReload()
        }
    }

    var canDeleteEditing: Bool {
        guard let s = editing else { return false }
        return s.isNew || s.isEditable
    }

    func deleteEditing() {
        guard let s = editing, canDeleteEditing else { return }
        if s.isNew {
            editing = nil
            return
        }
        let perform: (EKSpan) -> Void = { [weak self] span in
            guard let self else { return }
            do {
                try store.remove(s.event, span: span)
                editing = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            invalidateAndReload()
        }
        if s.event.hasRecurrenceRules {
            spanPrompt = SpanPrompt(title: "This is a repeating event.", verb: "Delete", perform: perform)
        } else {
            perform(.thisEvent)
        }
    }

    /// On quit, keep edits that can be saved without asking anything.
    func saveBeforeQuit() {
        guard let s = editing, s.isEditable, s.hasChanges || s.isNew else { return }
        if s.isNew && s.draft.title.trimmingCharacters(in: .whitespaces).isEmpty { return }
        if s.event.hasRecurrenceRules && !s.isNew { return }
        save(s, span: .thisEvent)
    }

    /// Selects a calendar in the sidebar and makes sure it's shown.
    func select(_ calendar: EKCalendar) {
        selectedCalendarID = calendar.calendarIdentifier
        hiddenCalendarIDs.remove(calendar.calendarIdentifier)
    }

    /// The sidebar selection, else the system default, else any writable calendar.
    var selectedCalendar: EKCalendar? {
        if let id = selectedCalendarID, let match = sidebarCalendars.first(where: { $0.calendarIdentifier == id }) {
            return match
        }
        if let fallback = store.defaultCalendarForNewEvents, fallback.allowsContentModifications {
            return fallback
        }
        return writableCalendars.first
    }

    /// Where new events go: the selected calendar, or nil (no new events) when that one is read-only.
    var newEventCalendar: EKCalendar? {
        selectedCalendar.flatMap { $0.allowsContentModifications ? $0 : nil }
    }

    /// The drop captures the selection before loading files, so later clicks cannot redirect it.
    func importICSFiles(_ urls: [URL], calendarID: String?) async {
        guard !isImportingICS else { return }
        importMessage = nil
        guard hasAccess, let calendarID, let destination = store.calendar(withIdentifier: calendarID),
              destination.allowsContentModifications else {
            errorMessage = "Select a writable calendar before importing .ics files."
            return
        }
        let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "ics" }
        guard !files.isEmpty else { return }
        isImportingICS = true
        defer { isImportingICS = false }
        var imported = 0
        var earliestImportedDate: Date?
        var failures: [String] = []
        for url in files {
            var savedInFile = 0
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 10_000_000 else { throw ICSImportError("The file exceeds the 10 MB import limit.") }
                    return try ICSImport.parse(Data(contentsOf: url))
                }.value
                let events = try parsed.map { try $0.makeEvent(in: store.ekStore, calendar: destination) }
                for event in events {
                    try store.save(event, span: .thisEvent)
                    let start = CalEvent.dates(of: event, in: cal).start
                    earliestImportedDate = min(earliestImportedDate ?? start, start)
                    imported += 1
                    savedInFile += 1
                }
            } catch {
                let partial = savedInFile == 0 ? "" : " \(savedInFile) events from this file were already imported; importing it again will duplicate them."
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)\(partial)")
            }
        }
        if imported > 0 {
            hiddenCalendarIDs.remove(calendarID)
            invalidateAndReload()
            if let earliestImportedDate { focusDate = earliestImportedDate }
        }
        let summary = "Imported \(imported) \(imported == 1 ? "event" : "events") into \(destination.title)."
        importMessage = summary
        if !failures.isEmpty { errorMessage = ([summary] + failures).joined(separator: "\n\n") }
    }
}
