import SwiftUI
import AlmanacKit

/// The main window: toolbar, sidebar, month grid and day inspector (or search results).
///
/// Keyboard: ←/→ day, ↑/↓ week, T today, E edit, Return open, Delete delete (on the grid),
/// ⌘N new event, ⌘F search, ⌘R sync now. Esc in the search field clears it.
public struct MainWindowView: View {
    @Bindable private var store: CalendarStore
    @FocusState private var focus: FocusTarget?
    @Environment(\.openURL) private var openURL

    private enum FocusTarget: Hashable { case grid, search }

    public init(store: CalendarStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(spacing: 0) {
                SidebarView(store: store)
                Hairline(vertical: true)
                MonthView(store: store, onInteract: { focus = .grid }, onOpenItem: open)
                    .focusable()
                    .focused($focus, equals: .grid)
                    .focusEffectDisabled()
                    .modifier(GridKeys(store: store, open: openSelected))
                    .overlay(alignment: .top) { banner }
                    .frame(minWidth: 560)
                Hairline(vertical: true)
                if store.isSearchActive {
                    SearchResultsView(store: store)
                } else {
                    DayInspector(store: store)
                }
            }
        }
        .background(Theme.ground)
        .foregroundStyle(Theme.ink)
        .frame(minWidth: 1100, minHeight: 640)
        .sheet(item: $store.form) { mode in
            EventFormView(store: store, mode: mode)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: store.pendingDeletion
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await store.delete(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the event from Google Calendar.")
        }
        .onAppear {
            store.start()
            focus = .grid
        }
        .onChange(of: store.searchFocusRequest) { focus = .search }
        .onChange(of: store.form == nil) { _, closed in
            if closed { focus = .grid }
        }
    }

    private var deleteTitle: String {
        "Delete ‘\(store.pendingDeletion?.title ?? "")’?"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(Text(Formats.monthName(store.displayedMonth))) \(Text(Formats.year(store.displayedMonth)).foregroundColor(Theme.secondary).fontWeight(.medium))")
                .font(Fonts.heading(22))
                .kerning(-0.2)
                .frame(minWidth: 200, alignment: .leading)
            HStack(spacing: 6) {
                Button(action: store.previousMonth) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                }
                .accessibilityLabel("Previous month")
                .help("Previous month")
                Button("Today", action: store.goToToday)
                    .help("Today (T)")
                Button(action: store.nextMonth) {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                }
                .accessibilityLabel("Next month")
                .help("Next month")
            }
            .buttonStyle(PlainButtonStyle())
            Spacer(minLength: 0)
            searchField
            Button {
                store.newEvent()
            } label: {
                Label("New event", systemImage: "plus")
            }
            .buttonStyle(PlainButtonStyle(prominent: true))
            .keyboardShortcut("n", modifiers: .command)
            .help("New event (⌘N)")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Theme.sidebar)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Button {
                focus = .search
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .help("Search (⌘F)")
            .accessibilityLabel("Search events")
            TextField("", text: $store.searchText, prompt: Text("Search"))
                .textFieldStyle(.plain)
                .font(Fonts.text(13))
                .focused($focus, equals: .search)
                .onSubmit {
                    if let first = store.searchResults.first { store.reveal(first) }
                }
                .onExitCommand {
                    store.clearSearch()
                    focus = .grid
                }
            if !store.searchText.isEmpty {
                Button {
                    store.clearSearch()
                    focus = .grid
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 220, height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ground))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(focus == .search ? Theme.accent : Theme.border, lineWidth: 1))
    }

    // MARK: Error banner

    @ViewBuilder private var banner: some View {
        if let message = store.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.destructive)
                Text(message)
                    .font(Fonts.text(13))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    store.lastError = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.destructive.opacity(0.5), lineWidth: 1))
            .frame(maxWidth: 520)
            .padding(.top, 44)
            .padding(.horizontal, 16)
            .task(id: message) {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled, store.lastError == message { store.lastError = nil }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Opening items

    /// Return / double-click: edit if editable, otherwise open in Google Calendar.
    private func open(_ item: CalendarItem) {
        store.select(item: item)
        if store.canEdit(item) {
            store.edit(item)
        } else if let web = item.webURL {
            openURL(web)
        }
    }

    private func openSelected() {
        if let item = store.selectedItem {
            open(item)
        } else {
            store.selectFirstItemOfDay()
        }
    }
}

/// Grid keyboard handling. Only active while the grid has focus, so typing in fields is unaffected.
private struct GridKeys: ViewModifier {
    let store: CalendarStore
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.leftArrow) { store.moveSelection(byDays: -1); return .handled }
            .onKeyPress(.rightArrow) { store.moveSelection(byDays: 1); return .handled }
            .onKeyPress(.upArrow) { store.moveSelection(byDays: -7); return .handled }
            .onKeyPress(.downArrow) { store.moveSelection(byDays: 7); return .handled }
            .onKeyPress(.return) { open(); return .handled }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard let item = store.selectedItem, store.canDelete(item) else { return .ignored }
                store.requestDelete(item)
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "tTeE")) { press in
                guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
                switch press.characters.lowercased() {
                case "t":
                    store.goToToday()
                    return .handled
                case "e":
                    guard let item = store.selectedItem, store.canEdit(item) else { return .ignored }
                    store.edit(item)
                    return .handled
                default:
                    return .ignored
                }
            }
    }
}
