import AppKit
import SwiftUI

/// Home's Calendar page: a scrollable ribbon of days, the selected day as an hour-by-hour timeline, and the
/// selected event's detail with Join. The month title opens a month picker. Sizes follow the width it is given
/// (cells 56 / 64 / 72 pt, hourly labels from 900 pt, half-hour lines and notes from 1100 pt).
struct CalendarPage: View {
    static let height: CGFloat = 426

    @Bindable private var store = CalendarStore.shared
    private var settings = AppSettings.shared
    /// First of the month under the ribbon's centre; the ribbon updates it only when the month changes.
    @State private var shownMonth: Date?
    @State private var showsPicker = false
    @State private var pickedEventID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            Group {
                switch store.access {
                case .granted: content(width: proxy.size.width)
                case .needed: CalendarNote(title: "Calendar access", detail: "Allow Perch to read your calendar in the prompt.", action: nil)
                case .denied:
                    CalendarNote(title: "Perch can't read your calendar", detail: "Turn on Calendar access for Perch to see your events here.",
                                 action: ("Open Settings", store.openSettings))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: Self.height)
        .padding(.horizontal, -16) // full bleed: the ribbon and timeline run edge to edge
        .onAppear { store.activate() }
        .onDisappear { store.deactivate() }
    }

    private func content(width: CGFloat) -> some View {
        let agenda = store.agenda(on: store.selectedDay)
        let isToday = store.calendar.isDate(store.selectedDay, inSameDayAs: Date())
        let shownMonth = shownMonth ?? store.selectedDay
        let inset: CGFloat = width >= 1100 ? 28 : width >= 600 ? 20 : 16
        let cell: CGFloat = width >= 1250 ? 72 : width >= 900 ? 64 : width >= 600 ? 56 : 46
        let selection = selected(in: agenda)
        return VStack(alignment: .leading, spacing: 0) {
            header(shownMonth: shownMonth, width: width, inset: inset)
                .frame(height: 52)
            DayRibbon(store: store, shownMonth: $shownMonth, cell: cell, width: width)
                .frame(height: 92)
            daySummary(agenda, isToday: isToday)
                .padding(.horizontal, inset)
                .padding(.top, 2).padding(.bottom, 8)
            DayTimeline(agenda: agenda, day: store.selectedDay, isToday: isToday, calendar: store.calendar, hour24: settings.uses24HourTime,
                        selectedID: selection?.id, width: width) { pickedEventID = $0.id }
            .frame(maxHeight: .infinity)
            .id(store.selectedDay)
            .transition(.opacity)
            EventDetail(event: selection, day: store.selectedDay, calendar: store.calendar, hour24: settings.uses24HourTime, wide: width >= 1100,
                        dayHasEvents: !agenda.isEmpty)
                .frame(height: 56)
                .padding(.horizontal, inset)
        }
        .overlay(alignment: .topLeading) {
            if showsPicker {
                MonthPicker(store: store, shownMonth: shownMonth) { showsPicker = false }
                    .padding(.top, 48).padding(.leading, 12)
                    .transition(.scale(scale: reduceMotion ? 1 : 0.96, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsPicker)
        .animation(.easeOut(duration: 0.15), value: store.selectedDay)
        .onChange(of: store.selectedDay) { pickedEventID = nil }
    }

    private func selected(in agenda: DayAgenda) -> CalendarEvent? {
        let all = agenda.allDay + agenda.placed.map(\.event)
        if let pickedEventID, let match = all.first(where: { $0.id == pickedEventID }) { return match }
        return CalendarLogic.defaultSelection(in: agenda, isToday: store.calendar.isDateInToday(store.selectedDay), now: Date())
    }

    private func header(shownMonth: Date, width: CGFloat, inset: CGFloat) -> some View {
        let big = width >= 900
        return HStack(spacing: 8) {
            Button { showsPicker.toggle() } label: {
                HStack(spacing: 6) {
                    Text(shownMonth, format: .dateTime.month(.wide)).font(.system(size: big ? 20 : 17, weight: .semibold))
                    Text(shownMonth, format: .dateTime.year()).font(.system(size: big ? 20 : 17, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.38))
                        .rotationEffect(.degrees(showsPicker ? 180 : 0))
                }
                .tracking(-0.3)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Choose month")
            .accessibilityValue(shownMonth.formatted(.dateTime.month(.wide).year()))
            Spacer()
            if !store.calendar.isDate(store.selectedDay, inSameDayAs: Date()) {
                Button("Today") { store.select(store.today, scroll: true) }
                    .buttonStyle(TodayPillStyle())
                    .transition(.opacity)
            }
            RoundIconButton(symbol: "chevron.left", label: "Previous week") { store.step(days: -7) }
            RoundIconButton(symbol: "chevron.right", label: "Next week") { store.step(days: 7) }
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.top, 4)
        .animation(.easeOut(duration: 0.15), value: store.selectedDay)
    }

    /// "Today · Wednesday, 4 November" near today, "Friday, 6 November 2026" further out; counts split timed, all-day and past.
    private func daySummary(_ agenda: DayAgenda, isToday: Bool) -> some View {
        let day = store.selectedDay
        let offset = store.calendar.dateComponents([.day], from: store.today, to: day).day ?? 0
        let past = isToday ? agenda.placed.filter { $0.event.end <= Date() }.count : 0
        let timed = agenda.placed.count
        let counts = [
            timed == 0 ? nil : timed == 1 ? "1 event" : "\(timed) events",
            agenda.allDay.isEmpty ? nil : "\(agenda.allDay.count) all day",
            past == 0 ? nil : "\(past) past",
        ].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 12) {
            HStack(spacing: 0) {
                if abs(offset) <= 1 {
                    Text(offset == 0 ? "Today" : offset == 1 ? "Tomorrow" : "Yesterday")
                        .foregroundStyle(offset == 0 ? Color.calendarRed : .white.opacity(0.94))
                    Text(" · \(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))")
                        .fontWeight(.medium).foregroundStyle(.white.opacity(0.62))
                } else {
                    Text(day, format: .dateTime.weekday(.wide).day().month(.wide).year())
                }
            }
            .font(.system(size: 13, weight: .semibold)).tracking(-0.13)
            .lineLimit(1)
            Spacer(minLength: 0)
            Text(counts.isEmpty ? "No events" : counts)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
        .foregroundStyle(.white.opacity(0.94))
        .monospacedDigit()
        .frame(height: 18)
    }
}

// MARK: - Ribbon

private struct DayRibbon: View {
    let store: CalendarStore
    @Binding var shownMonth: Date?
    let cell: CGFloat
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Half the width either side, so the selected day can sit in the centre even at the ends.
        // Spacers inside the stack, not `.contentMargins` (it stops the cells receiving clicks on macOS).
        let margin = max(0, (width - cell) / 2)
        let days = store.days
        let today = store.today
        let selected = store.selectedDay
        let wide = width >= 600
        // No scroll state is written while scrolling: a ScrollViewReader scrolls on request, and the month title
        // follows a geometry reading that only changes when the centred month does. Writing the centred day to state
        // (`scrollPosition(id:)`) re-ran this body for every day passing the centre.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    Color.clear.frame(width: margin, height: 1)
                    ForEach(days) { day in
                        DayCell(day: day, isToday: day.date == today, isSelected: day.date == selected,
                                dots: store.dots(on: day.date), width: cell, wide: wide) { store.select(day.date, scroll: true) }
                            .equatable()
                            .id(day.date)
                    }
                    Color.clear.frame(width: margin, height: 1)
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.viewAligned)
            // The visible cells, not the offset: a lazy stack only estimates its width, so offset / cell drifts by weeks.
            .onScrollTargetVisibilityChange(idType: Date.self, threshold: 0.5) { visible in
                guard !visible.isEmpty,
                      let month = store.calendar.dateInterval(of: .month, for: visible[visible.count / 2])?.start,
                      month != shownMonth else { return }
                shownMonth = month
            }
            .onChange(of: store.scrollRequest) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { proxy.scrollTo(store.selectedDay, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(store.selectedDay, anchor: .center) }
        }
        // Edge fades drawn over the black surface, not `.mask`: a mask re-renders the scrolling strip offscreen every frame.
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 32).allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 32).allowsHitTesting(false)
        }
    }
}

/// Plain values only, compared with `.equatable()`, so a selection change redraws two cells, not every visible one.
private struct DayCell: View, Equatable {
    let day: RibbonDay
    let isToday: Bool
    let isSelected: Bool
    let dots: [CalendarEvent.RGB]
    let width: CGFloat
    let wide: Bool
    let select: () -> Void

    private static let weekend = Color(red: 1, green: 0.41, blue: 0.38)

    static func == (lhs: DayCell, rhs: DayCell) -> Bool {
        lhs.day == rhs.day && lhs.isToday == rhs.isToday && lhs.isSelected == rhs.isSelected
            && lhs.dots == rhs.dots && lhs.width == rhs.width && lhs.wide == rhs.wide
    }

    var body: some View {
        let circle: CGFloat = width >= 72 ? 38 : width >= 64 ? 36 : width >= 56 ? 34 : 32
        Button(action: select) {
            VStack(spacing: 0) {
                Text(wide ? day.weekdayShort : day.weekdayNarrow)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isToday ? Color.calendarRed : day.isWeekend ? Self.weekend.opacity(0.62) : .white.opacity(0.38))
                    .frame(height: 13)
                Text(day.number)
                    .font(.system(size: width >= 64 ? 17 : 16, weight: isToday ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? .white : day.isWeekend ? Self.weekend.opacity(0.9) : .white.opacity(0.94))
                    .frame(width: circle, height: circle)
                    .background { Circle().fill(isToday ? Color.calendarRed : isSelected ? .white.opacity(0.11) : .clear) }
                    .overlay {
                        if isToday && isSelected { Circle().strokeBorder(.white.opacity(0.94), lineWidth: 2).padding(-4) }
                    }
                    .padding(.top, 4)
                HStack(spacing: 3) {
                    ForEach(dots.indices, id: \.self) { i in
                        Circle().fill(dots[i].color).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
                .padding(.top, 6)
            }
            .padding(.top, 24)
            .frame(width: width, height: 92, alignment: .top)
            .overlay(alignment: .topLeading) {
                if day.monthChip != nil { Rectangle().fill(.white.opacity(0.1)).frame(width: 1).padding(.top, 8).padding(.bottom, 10) }
            }
            .overlay(alignment: .top) {
                if let chip = day.monthChip {
                    Text(chip)
                        .font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.horizontal, 6).frame(height: 15)
                        .background(Capsule().fill(.white.opacity(0.11)))
                        .fixedSize()
                        .padding(.top, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .accessibilityLabel(day.spoken + (isToday ? ", today" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Timeline

private struct DayTimeline: View {
    let agenda: DayAgenda
    let day: Date
    let isToday: Bool
    let calendar: Calendar
    let hour24: Bool
    let selectedID: String?
    let width: CGFloat
    let select: (CalendarEvent) -> Void

    /// Prototype gutter: midnight sits 24 pt in, so the first and last labels are not clipped.
    private let lead: CGFloat = 24
    /// Recreated per day (the page keys this view by date), so each day opens at its own `openingMinute`.
    @State private var scroll = ScrollPosition(edge: .leading)

    var body: some View {
        // 18 hours fit the width; the rest of the day (midnight to 6 AM by default) is a scroll away.
        let hw = (width - 2 * lead) / CGFloat(CalendarLogic.visibleHours)
        let content = 2 * lead + 24 * hw
        let lanes = max(agenda.placed.map(\.laneCount).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 0) {
            if !agenda.allDay.isEmpty { allDayBars.padding(.horizontal, width >= 1100 ? 28 : 20).padding(.bottom, 6) }
            GeometryReader { proxy in
                // Lanes grow into the free height (34 pt minimum, 46 / 60 maximum); tall lanes add a second title line and the location.
                let lh = min(max(((proxy.size.height - 34) / CGFloat(lanes)).rounded(.down) - 4, 34), width >= 900 ? 60 : 46)
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        grid(hw: hw)
                        blocks(hw: hw, lh: lh, tall: lh >= 54, content: content)
                        if isToday { nowMarker(hw: hw) }
                    }
                    .frame(width: content, height: proxy.size.height, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                .scrollPosition($scroll)
                .overlay {
                    if agenda.placed.isEmpty {
                        VStack(spacing: 3) {
                            Text(agenda.isEmpty ? "Nothing scheduled" : "No timed events")
                                .font(.system(size: 14, weight: .semibold)).tracking(-0.14)
                            Text(agenda.isEmpty ? "This day is clear." : "Everything on this day is all-day.")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.38))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 22)
                        .allowsHitTesting(false)
                    }
                }
                .onAppear {
                    let minute = CalendarLogic.openingMinute(for: agenda, nowMinute: isToday ? nowMinute() : nil)
                    scroll.scrollTo(x: CGFloat(minute) / 60 * hw)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func x(_ minute: Int, _ hw: CGFloat) -> CGFloat {
        lead + CGFloat(minute) / 60 * hw
    }

    private func grid(hw: CGFloat) -> some View {
        let nowX = isToday ? x(nowMinute(), hw) : nil
        return ZStack(alignment: .topLeading) {
            ForEach(0...24, id: \.self) { hour in
                let px = x(hour * 60, hw)
                Rectangle().fill(.white.opacity(0.1)).frame(width: 0.5).padding(.top, 22).offset(x: px)
                if width >= 1100, hour < 24 {
                    Rectangle().fill(.white.opacity(0.04)).frame(width: 0.5).padding(.top, 22).offset(x: px + hw / 2)
                }
                if width >= 900 || hour % 2 == 0, nowX.map({ abs($0 - px) > 30 }) ?? true {
                    Text(CalendarLogic.hourLabel(hour, hour24: hour24))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.38))
                        .fixedSize()
                        .position(x: px, y: 11)
                }
            }
            Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5).offset(y: 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func blocks(hw: CGFloat, lh: CGFloat, tall: Bool, content: CGFloat) -> some View {
        let rows = max(agenda.placed.map(\.laneCount).max() ?? 1, 1)
        let now = Date()
        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                ForEach(agenda.placed) { placed in
                    let left = x(placed.startMinute, hw)
                    let w = max(CGFloat(placed.endMinute - placed.startMinute) / 60 * hw - 2, 6)
                    EventBlock(placed: placed, width: w, isSelected: placed.id == selectedID, isPast: isToday && placed.event.end <= now,
                               large: width >= 900, tall: tall, day: day, calendar: calendar, hour24: hour24) { select(placed.event) }
                        .frame(width: w, height: lh)
                        .offset(x: left, y: CGFloat(placed.lane) * (lh + 4))
                }
            }
            .frame(width: content, height: CGFloat(rows) * (lh + 4) + 8, alignment: .topLeading)
            .padding(.top, 30)
        }
        .scrollIndicators(.never)
    }

    private func nowMinute() -> Int {
        CalendarLogic.minuteOfDay(Date(), calendar: calendar)
    }

    private func nowMarker(hw: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let px = x(nowMinute(), hw)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.calendarRed).frame(width: 1.5).offset(x: px - 0.75)
                Text(CalendarLogic.time(Date(), hour24: hour24))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(Color.calendarRed))
                    .fixedSize()
                    .position(x: px, y: 11)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private var allDayBars: some View {
        VStack(spacing: 4) {
            ForEach(agenda.allDay.prefix(2)) { event in
                let color = event.color.color
                Button { select(event) } label: {
                    HStack(spacing: 10) {
                        Text(event.title).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(CalendarLogic.durationLabel(event, calendar: calendar))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 13).padding(.trailing, 10)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(event.id == selectedID ? 0.34 : 0.22)))
                    .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.99))
            }
            if agenda.allDay.count > 2 {
                Text("+\(agenda.allDay.count - 2) more all-day")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

}

private struct EventBlock: View {
    let placed: PlacedEvent
    let width: CGFloat
    let isSelected: Bool
    let isPast: Bool
    let large: Bool
    let tall: Bool
    let day: Date
    let calendar: Calendar
    let hour24: Bool
    let action: () -> Void

    var body: some View {
        let color = placed.event.color.color
        let event = placed.event
        Button(action: action) {
            // Prototype: text from 47 pt of content width, kind chip from 140, a second title line and location when lanes are tall.
            let showsText = width - 17 >= 47
            VStack(alignment: .leading, spacing: 1) {
                if showsText {
                    HStack(spacing: 6) {
                        Text(event.title).font(.system(size: large ? 13 : 12, weight: .semibold)).lineLimit(tall ? 2 : 1)
                        if width - 17 >= 140, let link = event.meetingLink {
                            HStack(spacing: 3) {
                                Image(systemName: "video").font(.system(size: 9, weight: .semibold))
                                Text(link.service == .meet ? "Meet" : link.service.title)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.leading, 5).padding(.trailing, 6).frame(height: 16)
                            .background(Capsule().fill(.white.opacity(0.11)))
                            .fixedSize()
                        }
                    }
                    Text(CalendarLogic.rangeLabel(event, on: day, calendar: calendar, hour24: hour24))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    if tall, let location = event.location {
                        Text(location).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.38)).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, showsText ? 11 : 0).padding(.trailing, 6).padding(.vertical, 3)
            .background(color.opacity(isSelected ? 0.34 : 0.22))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { if isSelected { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color, lineWidth: 1.5) } }
            .opacity(isPast ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .help(event.title)
        .accessibilityLabel("\(event.title)")
    }
}

// MARK: - Detail

private struct EventDetail: View {
    let event: CalendarEvent?
    let day: Date
    let calendar: Calendar
    let hour24: Bool
    let wide: Bool
    /// The day has events, all of them over: "No more events today" instead of "Nothing scheduled".
    let dayHasEvents: Bool

    private var emptyTitle: String { dayHasEvents ? "No more events today" : "Nothing scheduled" }
    private var emptyDetail: String { dayHasEvents ? "Everything on today's list has finished." : "Pick another day on the ribbon." }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 12) {
            if let event {
                Capsule().fill(event.color.color).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).tracking(-0.1)
                    HStack(spacing: 5) {
                        Text(CalendarLogic.rangeLabel(event, on: day, calendar: calendar, hour24: hour24))
                        Text("·").foregroundStyle(.white.opacity(0.38))
                        Text(CalendarLogic.durationLabel(event, calendar: calendar))
                        if let location = event.location {
                            Text("·").foregroundStyle(.white.opacity(0.38))
                            Image(systemName: "mappin").font(.system(size: 10))
                            Text(location).lineLimit(1)
                        }
                    }
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                }
                if wide, let notes = event.notes {
                    Text(notes).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.38)).lineLimit(2)
                        .frame(maxWidth: 320, alignment: .leading)
                }
                Spacer(minLength: 8)
                if let rel = CalendarLogic.relativeLabel(event, now: Date()) {
                    Text(rel).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(.white.opacity(0.11)))
                }
                if let link = event.meetingLink {
                    Button { NSWorkspace.shared.open(MeetingSource.preferredURL(link.url)) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "video").font(.system(size: 12, weight: .semibold))
                            Text("Join \(link.service == .meet ? "Meet" : link.service.title)")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.leading, 12).padding(.trailing, 14).frame(height: 32)
                        .background(Capsule().fill(.white))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle())
                }
            } else {
                Capsule().fill(.white.opacity(0.38)).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(emptyTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.62))
                    Text(emptyDetail).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
            }
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(.white.opacity(0.06)))
    }
}

private struct RoundIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

private struct TodayPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold)).tracking(0.1)
            .foregroundStyle(Color.calendarRed)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.16 : 0.11)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

private struct CalendarNote: View {
    let title: String
    let detail: String
    let action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.5))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            if let action { Button(action.title, action: action.run).buttonStyle(CalendarChipStyle(fill: .white, text: .black)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Twelve months of one year with how busy each is; the way to jump across months.
private struct MonthPicker: View {
    let store: CalendarStore
    let shownMonth: Date
    let close: () -> Void
    @State private var year: Int?

    var body: some View {
        let calendar = store.calendar
        let year = year ?? calendar.component(.year, from: shownMonth)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        VStack(spacing: 10) {
            HStack {
                Text(String(year)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                Spacer()
                Button { self.year = year - 1 } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(BarButtonStyle()).accessibilityLabel("Previous year")
                Button { self.year = year + 1 } label: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(BarButtonStyle()).accessibilityLabel("Next year")
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(1...12, id: \.self) { month in
                    monthButton(year: year, month: month)
                }
            }
        }
        .padding(12)
        .frame(width: 330)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(white: 0.1))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        }
    }

    @ViewBuilder
    private func monthButton(year: Int, month: Int) -> some View {
        let calendar = store.calendar
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let interval = calendar.dateInterval(of: .month, for: first)
        let inRange = interval.map { $0.end > store.firstDay && $0.start <= store.lastDay } ?? false
        let isCurrent = calendar.isDate(first, equalTo: Date(), toGranularity: .month)
        let isShown = calendar.isDate(first, equalTo: shownMonth, toGranularity: .month)
        let count = inRange ? store.eventCount(inMonthOf: first) : 0
        Button {
            store.select(isCurrent ? store.today : first, scroll: true)
            close()
        } label: {
            VStack(spacing: 3) {
                Text(first.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 13, weight: isShown ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? Color.calendarRed : .white)
                Capsule().fill(.white.opacity(0.4)).frame(width: max(3, CGFloat(min(count, 60)) / 60 * 28), height: 3).opacity(count > 0 ? 1 : 0.15)
                Text(count > 0 ? "\(count)" : " ").font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(isShown ? 0.14 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .disabled(!inRange)
        .opacity(inRange ? 1 : 0.35)
        .accessibilityLabel(first.formatted(.dateTime.month(.wide).year()))
    }
}

// MARK: - Styles

private extension Color {
    /// Today and the Today button: Calendar's red (#FF453A), not the system accent, so today always reads as today.
    static let calendarRed = Color(.sRGB, red: 1, green: 0.271, blue: 0.227)
}

private extension CalendarEvent.RGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// Press feedback on pointer-down, instant, no hover chrome.
private struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Capsule chip; `fill`/`text` make the white primary Join pill.
private struct CalendarChipStyle: ButtonStyle {
    var fill: Color?
    var text: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(fill ?? .white.opacity(configuration.isPressed ? 0.2 : 0.1)).opacity(fill != nil && configuration.isPressed ? 0.8 : 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
