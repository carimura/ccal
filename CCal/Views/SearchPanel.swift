import SwiftUI

/// The right panel while searching: a search field and matching events, upcoming then past.
struct SearchPanel: View {
    @Environment(\.fontScale) private var s
    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search events", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15 * s))
                    .focused($fieldFocused)
                    .onSubmit {
                        if let first = model.searchUpcoming.first ?? model.searchPast.first { model.reveal(first.event) }
                        // Hand the keyboard back so ⌘←/⌘→ and the other shortcuts work; ⌘K returns here.
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                    .onExitCommand { model.closeSearch() }
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
            Divider()
            results
        }
        .onAppear { fieldFocused = true }
        // Clicking away from an empty search closes it.
        .onChange(of: fieldFocused) {
            if !fieldFocused && model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty && model.editing == nil {
                model.closeSearch()
            }
        }
        .onChange(of: model.searchFocusRequest) { fieldFocused = true }
    }

    @ViewBuilder
    private var results: some View {
        if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView("Search Events", systemImage: "magnifyingglass",
                                   description: Text("Titles, locations and notes, from a year ago to a year ahead."))
        } else if model.isLoadingSearch && model.searchMatchIDs?.isEmpty != false {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.searchUpcoming.isEmpty && model.searchPast.isEmpty {
            ContentUnavailableView.search(text: model.searchQuery)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section("Upcoming", model.searchUpcoming)
                    section("Past", model.searchPast)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [SearchItem]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.system(size: 11 * s, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(items) { item in
                SearchRow(item: item, isSelected: model.editing?.id == item.id)
                    .onTapGesture { model.reveal(item.event) }
            }
        }
    }
}

private struct SearchRow: View {
    @Environment(\.fontScale) private var s
    let item: SearchItem
    let isSelected: Bool

    var body: some View {
        let event = item.event
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(event.color).frame(width: 8 * s, height: 8 * s)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13 * s, weight: .semibold))
                    .lineLimit(2)
                Text(dateText)
                    .font(.system(size: 11 * s))
                    .foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 11 * s))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private var dateText: String {
        let event = item.event
        let sameYear = Calendar.current.isDate(event.start, equalTo: Date(), toGranularity: .year)
        let day = sameYear
            ? event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        let time = event.isAllDay ? "All-day" : event.timeRangeText
        return "\(day) · \(time)" + (item.isRecurring ? " · Repeats" : "")
    }
}
