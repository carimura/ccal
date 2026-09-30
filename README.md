# CCal

A personal macOS calendar built on EventKit, so it shows whatever accounts are set up in
System Settings → Internet Accounts (Google, iCloud, Exchange) with no logins of its own.

## Build & run

Requires Xcode 26+ and XcodeGen (`brew install xcodegen`). The Xcode project is generated from
`project.yml` and not checked in.

```sh
make run       # optimized build, install to /Applications, launch (the only copy you use)
make test      # unit + integration tests
```

On first launch, grant **Full Access** to calendars. If access was denied, re-enable it under
Privacy & Security → Calendars.

## Using it

| Action | How |
|---|---|
| Create event | Drag on the grid, double-click an empty slot, or `N` / ⌘N |
| Create all-day event | Double-click the all-day row |
| Move / resize | Drag an event / drag its bottom edge |
| Edit | Click an event; edits save when you press Return or click away |
| Discard edits | Esc |
| Delete | Delete key (or Edit → Delete Event) |
| Copy to another calendar | Right-click an event → Copy to |
| Day / Week / Month | `D` `W` `M` or ⌘1 ⌘2 ⌘3 |
| Previous / Next | ⌘← ⌘→ or `K` `J` |
| Today | `T` or ⌘T |

Single-key shortcuts are ignored while you're typing in a text field.

## Tests

```sh
make test        # model flows, grid geometry, offscreen rendering (~2s)
make perf        # timing of key interactions against a Release build
make snapshots   # renders screens with fake data to build.noindex/snapshots/*.png
```

Tests run against `FakeEventStore`, an in-memory `EventStoring`, with a throwaway `UserDefaults`, so
they never write to your calendars or preferences. The two tests that use real calendar data
(`testNavigateRealCalendars`, `testRealStoreFetch`) only read.

## Performance notes

Timings from `make perf` on an M2 Max. The test calendar has 12 events a day across 12 calendars,
roughly double a busy real week.

| Interaction | Before | After |
|---|---|---|
| Next/previous week | 62 ms | 18 ms |
| Next/previous month | 196 ms | 37 ms |
| Switch day/week/month | 112 ms | 31 ms |
| Click another event (inspector open) | 65 ms | 15 ms |
| Drag-create, per mouse move | 25 ms | 9 ms |
| Navigate real calendars (read-only) | 48 ms | 25 ms |

What made the difference:

- **One interaction layer for the grid.** A single gesture plus hit-testing (`GridGeometry.hit`), instead
  of tap, drag and resize gestures on every event. Double-clicks are detected from the click count, so
  single clicks no longer wait out the system double-click interval before responding.
- **Canvas drawing.** Week and day event blocks are drawn in one `Canvas`, and each month cell in one
  `Canvas`. The base layer holds saved events and is `Equatable`, so selecting, typing or dragging
  redraws only a small overlay canvas.
- **Fetch cache.** Events are fetched for a window of one page on either side of the visible range and
  recentered in the background, so arrow navigation rarely touches EventKit. Display values are built
  once per fetch, not on every redraw.
- **Cheap date math.** A fixed `Calendar` snapshot (not `autoupdatingCurrent`), and events are bucketed
  into days with a binary search over precomputed midnights.
- **Inspector.** It isn't rebuilt per event, it uses a plain `Grid` instead of `Form(.grouped)`, and it
  stays closed during drag-create so the grid doesn't reflow under the cursor.

`make run` always builds the optimized (Release) configuration; tests build their own copy separately.

## Scope

- **Step 1 (this):** view and edit your own events across all calendars.
- **Events with guests are read-only.** Saving those through EventKit could send update emails
  to attendees, so guest events (and invites/RSVPs) wait for step 2, which will go through the
  Google Calendar API with explicit control over `sendUpdates`.
