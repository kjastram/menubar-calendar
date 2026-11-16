import SwiftUI
import AlmanacKit

/// New / edit event sheet. Create mode has a quick-add field at the top.
struct EventFormView: View {
    let store: CalendarStore
    let mode: EventFormMode
    @Environment(\.dismiss) private var dismiss

    @State private var quickText = ""
    @State private var quickError: String?
    @State private var quickBusy = false
    @State private var title: String
    @State private var isAllDay: Bool
    @State private var start: Date
    /// For all-day events this is the last day (inclusive); converted to the exclusive end on save.
    @State private var end: Date
    @State private var calendarID: String
    @State private var location: String
    @State private var notes: String
    @State private var addMeet = false
    @FocusState private var focus: Field?

    private enum Field { case quick, title }

    init(store: CalendarStore, mode: EventFormMode) {
        self.store = store
        self.mode = mode
        let cal = store.calendar
        switch mode {
        case .create(let start):
            _title = State(initialValue: "")
            _isAllDay = State(initialValue: false)
            _start = State(initialValue: start)
            _end = State(initialValue: start.addingTimeInterval(3600))
            _calendarID = State(initialValue: store.preferredCalendarID ?? "")
            _location = State(initialValue: "")
            _notes = State(initialValue: "")
        case .edit(let item):
            _title = State(initialValue: item.title)
            _isAllDay = State(initialValue: item.isAllDay)
            _start = State(initialValue: item.start)
            _end = State(initialValue: item.isAllDay ? CalendarMath.lastDay(of: item, calendar: cal) : item.end)
            _calendarID = State(initialValue: item.calendarID)
            _location = State(initialValue: item.location ?? "")
            _notes = State(initialValue: item.notes ?? "")
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(isCreate ? "New event" : "Edit event")
                    .font(Fonts.heading(20))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .accessibilityLabel("Close")
            }

            if isCreate {
                quickAddSection
                HStack(spacing: 10) {
                    Hairline()
                    SectionLabel(text: "or fill in details")
                        .fixedSize()
                    Hairline()
                }
            }

            field("Title") {
                TextField("", text: $title, prompt: Text("Event title"))
                    .focused($focus, equals: .title)
                    .modifier(InputStyle())
            }

            HStack(alignment: .top, spacing: 12) {
                field("Calendar") { calendarPicker }
                field("All day") {
                    Toggle("All-day event", isOn: $isAllDay)
                        .toggleStyle(.checkbox)
                        .font(Fonts.text(13.5))
                        .frame(height: 36)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                field("Starts") {
                    DatePicker("Starts", selection: startBinding, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .frame(height: 36)
                }
                field("Ends") {
                    DatePicker("Ends", selection: $end, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .frame(height: 36)
                }
            }
            if !isValidRange {
                Text("The event has to end after it starts.")
                    .font(Fonts.text(12))
                    .foregroundStyle(Theme.destructive)
            }

            field("Location") {
                TextField("", text: $location, prompt: Text("Add a place"))
                    .modifier(InputStyle())
            }

            if isCreate {
                Toggle(isOn: $addMeet) {
                    Label("Add Google Meet link", systemImage: "video")
                        .font(Fonts.text(13.5))
                }
                .toggleStyle(.checkbox)
            }

            field("Notes") {
                TextEditor(text: $notes)
                    .font(Fonts.text(13.5))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ground))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
            }

            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PlainButtonStyle(height: 36))
                    .keyboardShortcut(.cancelAction)
                Button(isCreate ? "Create event" : "Save") { save() }
                    .buttonStyle(PlainButtonStyle(prominent: true, height: 36))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                    .help(isCreate ? "Create (⌘↩)" : "Save (⌘↩)")
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.ground)
        .onAppear { focus = isCreate ? .quick : .title }
        .onChange(of: isAllDay) { _, allDay in
            let cal = store.calendar
            if allDay {
                let firstDay = cal.startOfDay(for: start)
                let lastDay = max(cal.startOfDay(for: end.addingTimeInterval(-1)), firstDay)
                end = lastDay
                start = firstDay
            } else {
                let newStart = CalendarMath.nineAM(on: start, calendar: cal)
                end = newStart.addingTimeInterval(3600)
                start = newStart
            }
        }
    }

    /// Moving the start keeps the event's length.
    private var startBinding: Binding<Date> {
        Binding(
            get: { start },
            set: { new in
                let cal = store.calendar
                if isAllDay {
                    let days = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: new)).day ?? 0
                    end = CalendarMath.addingDays(days, to: end, calendar: cal)
                } else {
                    end = end.addingTimeInterval(new.timeIntervalSince(start))
                }
                start = new
            })
    }

    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Quick add")
            HStack(spacing: 10) {
                Image(systemName: "bolt")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                TextField("", text: $quickText, prompt: Text("Lunch with Sam Friday 1pm"))
                    .textFieldStyle(.plain)
                    .font(Fonts.text(14.5))
                    .focused($focus, equals: .quick)
                    .onSubmit(submitQuickAdd)
                    .disabled(quickBusy)
                if quickBusy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 2))
            Text(quickError ?? "Type it like you'd say it. Google parses the date and time. Press Return to create.")
                .font(Fonts.text(12))
                .foregroundStyle(quickError == nil ? Theme.secondary : Theme.destructive)
        }
    }

    private var calendarPicker: some View {
        let writable = store.writableCalendars
        let groups = Dictionary(grouping: writable, by: \.accountEmail)
        let emails = store.accounts.map(\.email).filter { groups[$0] != nil }
        return HStack(spacing: 8) {
            ItemDot(color: HexColor.color(store.calendarInfo(id: calendarID)?.color ?? "#888888"))
            Picker("Calendar", selection: $calendarID) {
                if writable.isEmpty {
                    Text("No writable calendars").tag("")
                }
                ForEach(emails, id: \.self) { email in
                    Section(email) {
                        ForEach(groups[email] ?? []) { info in
                            Text(info.name).tag(info.id)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(height: 36)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isValidRange: Bool {
        if isAllDay { return store.calendar.startOfDay(for: end) >= store.calendar.startOfDay(for: start) }
        return end >= start
    }

    private var canSave: Bool {
        isValidRange && store.calendarInfo(id: calendarID)?.canWrite == true
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func makeDraft() -> EventDraft {
        let cal = store.calendar
        let draftStart = isAllDay ? cal.startOfDay(for: start) : start
        let draftEnd = isAllDay ? CalendarMath.exclusiveEnd(forLastDay: end, calendar: cal) : end
        return EventDraft(calendarID: calendarID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          start: draftStart, end: draftEnd, isAllDay: isAllDay,
                          location: location, notes: notes, addMeet: isCreate && addMeet)
    }

    private func save() {
        guard canSave else { return }
        let draft = makeDraft()
        let store = self.store
        switch mode {
        case .create:
            Task { await store.create(draft) }
        case .edit(let item):
            Task { await store.update(item, with: draft) }
        }
        dismiss()
    }

    private func submitQuickAdd() {
        let text = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !quickBusy else { return }
        guard store.calendarInfo(id: calendarID)?.canWrite == true else {
            quickError = "Pick a calendar below first."
            return
        }
        quickBusy = true
        quickError = nil
        let store = self.store
        let calendarID = self.calendarID
        Task {
            let result = await store.quickAdd(text, calendarID: calendarID)
            quickBusy = false
            switch result {
            case .success: dismiss()
            case .failure(let error): quickError = error.message
            }
        }
    }
}

/// The bordered text field from the mockup.
private struct InputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Fonts.text(13.5))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ground))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }
}
