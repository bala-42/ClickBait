import Foundation
import Testing
@testable import ClickBaitCore

struct NotchPanelTests {
    // A 14" MacBook Pro: 1512 × 982 pt, the menu bar 37 pt (notch height), notch ~185 pt wide.
    private let screen = Rect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = Rect(x: 0, y: 0, width: 1512, height: 945)
    private var notch: Rect {
        NotchPanel.notch(screen: screen, topInset: 37, leftArea: Rect(x: 0, y: 945, width: 663.5, height: 37),
                         rightArea: Rect(x: 848.5, y: 945, width: 663.5, height: 37))!
    }

    @Test func findsTheNotchBetweenTheMenuBarHalves() {
        #expect(notch == Rect(x: 663.5, y: 945, width: 185, height: 37))
        #expect(NotchPanel.notch(screen: screen, topInset: 0, leftArea: nil, rightArea: nil) == nil)  // no notch
    }

    @Test func statesMoveAsExpected() {
        var state = NotchPanel.State.hidden
        state = NotchPanel.next(state, on: .enabled(true));   #expect(state == .collapsed)
        state = NotchPanel.next(state, on: .pointerEntered);  #expect(state == .peek)
        state = NotchPanel.next(state, on: .pointerEntered);  #expect(state == .peek)  // stays
        state = NotchPanel.next(state, on: .clicked);         #expect(state == .expanded)
        state = NotchPanel.next(state, on: .clicked);         #expect(state == .expanded)  // a click inside keeps it open
        state = NotchPanel.next(state, on: .openTimedOut);    #expect(state == .peek)
        state = NotchPanel.next(state, on: .peekTimedOut);    #expect(state == .collapsed)
        state = NotchPanel.next(state, on: .clicked);         #expect(state == .expanded)  // straight from the notch
        state = NotchPanel.next(state, on: .escape);          #expect(state == .peek)
        state = NotchPanel.next(state, on: .escape);          #expect(state == .collapsed)
        state = NotchPanel.next(state, on: .escape);          #expect(state == .collapsed)  // nothing to close
        state = NotchPanel.next(state, on: .displayAvailable(false)); #expect(state == .hidden)
        state = NotchPanel.next(state, on: .clicked);         #expect(state == .hidden)  // hidden ignores clicks
        state = NotchPanel.next(state, on: .displayAvailable(true));  #expect(state == .collapsed)
        state = NotchPanel.next(state, on: .enabled(false));  #expect(state == .hidden)
    }

    /// Sizes from the GIF (1 px = 0.746 pt).
    @Test func shapesMatchTheGIF() {
        let plain = NotchPanel.shape(.collapsed, notch: notch, activity: false, hud: false)
        #expect(plain.width == notch.width && plain.height == notch.height)
        let playing = NotchPanel.shape(.collapsed, notch: notch, activity: true, hud: false)
        #expect(playing.width == notch.width + 80)  // 248 → 356 px
        let peek = NotchPanel.shape(.peek, notch: notch, activity: true, hud: false)
        #expect(peek.width == notch.width + NotchPanel.peekWidth && peek.height == notch.height)
        #expect(peek.radius == NotchPanel.compactCorner)
        let open = NotchPanel.shape(.expanded, notch: notch, activity: true, hud: false)
        #expect(open.width == NotchPanel.expandedSize.width && open.height == NotchPanel.expandedSize.height)  // the Nook
        let tray = NotchPanel.shape(.expanded, notch: notch, activity: false, hud: false, shelf: true)
        #expect(tray.width == NotchPanel.shelfSize.width && tray.height == NotchPanel.shelfSize.height)
        let hud = NotchPanel.shape(.collapsed, notch: notch, activity: true, hud: true)
        #expect(hud.width == notch.width + 2 * NotchPanel.hudWing)  // the HUD wins over the music wings
    }

    @Test func collapsedCoversOnlyTheBlack() throws {
        let frame = try #require(NotchPanel.frame(.collapsed, screen: screen, visible: visible, notch: notch))
        #expect(frame.width == notch.width + 2 * NotchPanel.ear)
        #expect(abs(frame.midX - notch.midX) < 0.01)
        #expect(frame.maxY == screen.maxY)
    }

    @Test func expandedHangsFromTheTopCentredOnTheNotch() throws {
        let frame = try #require(NotchPanel.frame(.expanded, screen: screen, visible: visible, notch: notch))
        #expect(frame.maxY == screen.maxY)
        #expect(abs(frame.midX - notch.midX) < 0.01)
        #expect(frame.height == NotchPanel.expandedSize.height)
    }

    @Test func withoutANotchItIsAPillUnderTheMenuBar() throws {
        let pill = try #require(NotchPanel.frame(.collapsed, screen: screen, visible: visible, notch: nil))
        #expect(pill.width == NotchPanel.pillSize.width + 2 * NotchPanel.ear)
        #expect(pill.maxY <= visible.maxY)
        let open = try #require(NotchPanel.frame(.expanded, screen: screen, visible: visible, notch: nil))
        #expect(open.maxY <= visible.maxY)
        #expect(open.minX >= screen.minX && open.maxX <= screen.maxX)
    }

    @Test func hiddenHasNoFrame() {
        #expect(NotchPanel.frame(.hidden, screen: screen, visible: visible, notch: notch) == nil)
    }

    @Test func narrowScreensKeepItOnScreen() throws {
        let small = Rect(x: 0, y: 0, width: 400, height: 600)
        let frame = try #require(NotchPanel.frame(.expanded, screen: small, visible: small, notch: nil))
        #expect(frame.minX >= 0 && frame.maxX <= 400)
    }

    /// The notch motion (2026-10-20): a lively spring open, a quick ease-out closed.
    @Test func islandMotion() {
        #expect(NotchPanel.openSpring == (response: 0.5, damping: 0.72))
        #expect(NotchPanel.closeCurve.duration == 0.34)
    }

    /// The open island: 640 × 160, corners 22, flush with the top.
    @Test func openIsland() throws {
        let notch = Rect(x: 600, y: 950, width: 185, height: 32)
        let open = NotchPanel.shape(.expanded, notch: notch, activity: false, hud: false)
        #expect(open.width == 640 && open.height == 160 && open.radius == NotchPanel.openCorner)
        let wings = NotchPanel.shape(.collapsed, notch: notch, activity: true, hud: false)
        #expect(wings.radius == NotchPanel.compactCorner)
        #expect(NotchPanel.ear == 0)
    }
}

struct CalendarStripTests {
    @Test func sixDaysTodayThirdLikeTheGIF() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let wednesday = try #require(calendar.date(from: DateComponents(year: 2025, month: 8, day: 13)))
        let days = CalendarStrip.days(around: wednesday, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(days.map(\.number) == [11, 12, 13, 14, 15, 16])
        #expect(days.map(\.weekday) == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])
        #expect(days.map(\.isToday) == [false, false, true, false, false, false])
    }

    @Test func monthAndYearChangesClampInvalidDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let leapDay = try #require(CalendarNavigation.date(year: 2024, month: 2, preservingDay: 29, calendar: calendar))
        let nextYear = try #require(CalendarNavigation.date(year: 2025, month: 2, preservingDay: 29, calendar: calendar))
        #expect(calendar.component(.day, from: leapDay) == 29)
        #expect(calendar.component(.day, from: nextYear) == 28)
        #expect(CalendarNavigation.monthDays(containing: leapDay, calendar: calendar).count == 29)
        #expect(CalendarNavigation.monthDays(containing: nextYear, calendar: calendar).count == 28)
    }

    @Test func monthStepsCrossYearBoundariesAndClamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let january31 = try #require(CalendarNavigation.date(year: 2025, month: 1, preservingDay: 31, calendar: calendar))
        let february = try #require(CalendarNavigation.addingMonths(1, to: january31, calendar: calendar))
        #expect(calendar.dateComponents([.year, .month, .day], from: february) == DateComponents(year: 2025, month: 2, day: 28))
        let december = try #require(CalendarNavigation.addingMonths(-1, to: january31, calendar: calendar))
        #expect(calendar.dateComponents([.year, .month, .day], from: december) == DateComponents(year: 2024, month: 12, day: 31))
        let january = try #require(CalendarNavigation.addingMonths(1, to: december, calendar: calendar))
        #expect(calendar.dateComponents([.year, .month, .day], from: january) == DateComponents(year: 2025, month: 1, day: 31))
    }

    @Test func rapidDateRequestsMakeOlderAgendaResultsStale() {
        var sequence = CalendarRequestSequence()
        let first = sequence.next()
        let second = sequence.next()
        let third = sequence.next()
        #expect(!sequence.isCurrent(first))
        #expect(!sequence.isCurrent(second))
        #expect(sequence.isCurrent(third))
    }

    @Test func todayReturnsTheCurrentLocalDayStart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 23, minute: 45)))
        let today = CalendarNavigation.today(now: now, calendar: calendar)
        #expect(calendar.isDate(today, inSameDayAs: now))
        #expect(calendar.component(.hour, from: today) == 0)
        #expect(calendar.component(.day, from: today) == 1)
    }
}

struct TrackTimeTests {
    @Test func timesReadLikeTheGIF() {
        #expect(TrackTime.text(177.9) == "2:57")
        #expect(TrackTime.text(234) == "3:54")
        #expect(TrackTime.text(3725) == "1:02:05")
        #expect(TrackTime.text(-3) == "0:00")
    }

    @Test func draggingAlongTheBarSeeks() {
        #expect(TrackTime.position(x: 50, width: 200, duration: 240) == 60)
        #expect(TrackTime.position(x: -10, width: 200, duration: 240) == 0)
        #expect(TrackTime.position(x: 500, width: 200, duration: 240) == 240)
    }

    @Test func playbackMovesOnOnlyWhilePlaying() {
        let reading = Date(timeIntervalSince1970: 0)
        #expect(TrackTime.now(reported: 10, at: reading, playing: true, duration: 100, now: reading.addingTimeInterval(5)) == 15)
        #expect(TrackTime.now(reported: 10, at: reading, playing: false, duration: 100, now: reading.addingTimeInterval(5)) == 10)
        #expect(TrackTime.now(reported: 98, at: reading, playing: true, duration: 100, now: reading.addingTimeInterval(5)) == 100)
    }
}

struct PullGestureTests {
    @Test func pullingDownOpensPushingUpCloses() {
        #expect(NotchPanel.next(.collapsed, on: .pulledDown) == .expanded)
        #expect(NotchPanel.next(.expanded, on: .pushedUp) == .peek)
        #expect(NotchPanel.next(.peek, on: .pulledDown) == .expanded)
        #expect(NotchPanel.next(.expanded, on: .pulledDown) == .expanded)
        #expect(NotchPanel.next(.hidden, on: .pulledDown) == .hidden)
    }

    @Test func fingersDownIsAPullWhicheverWayScrollingRuns() {
        var natural = PullGesture()
        #expect(natural.add(deltaY: 10, inverted: true) == nil)
        #expect(natural.add(deltaY: 15, inverted: true) == .pulledDown)
        var classic = PullGesture()
        #expect(classic.add(deltaY: -30, inverted: false) == .pulledDown)
        var up = PullGesture()
        #expect(up.add(deltaY: -30, inverted: true) == .pushedUp)
    }

    @Test func oncePerGestureAndSmallWigglesDoNothing() {
        var gesture = PullGesture()
        #expect(gesture.add(deltaY: 30, inverted: true) == .pulledDown)
        #expect(gesture.add(deltaY: 30, inverted: true) == nil)  // same gesture
        #expect(gesture.add(deltaY: 0, inverted: true, ended: true) == nil)
        #expect(gesture.add(deltaY: 10, inverted: true) == nil)  // a new, small one
        #expect(gesture.add(deltaY: -10, inverted: true) == nil)
    }

    @Test func foldsLikeTheIsland() {
        #expect(NotchPanel.openHold == 15)
        #expect(NotchPanel.peekHold == 60)
    }
}

struct VolumeHUDTests {
    @Test func sixteenStepsQuarterStepsWithOptionShift() {
        #expect(VolumeStep.apply(.up, volume: 0.5, muted: false).volume == 0.563)
        #expect(VolumeStep.apply(.down, volume: 0.5, muted: false).volume == 0.438)
        #expect(VolumeStep.apply(.up, volume: 0.5, muted: false, fine: true).volume == 0.516)
        #expect(VolumeStep.apply(.up, volume: 0.99, muted: false).volume == 1)
    }

    @Test func muteTogglesUpUnmutesBottomMutes() {
        #expect(VolumeStep.apply(.mute, volume: 0.4, muted: false) == (0.4, true))
        #expect(VolumeStep.apply(.up, volume: 0.4, muted: true).muted == false)
        let bottom = VolumeStep.apply(.down, volume: 0.03, muted: false)
        #expect(bottom.volume == 0 && bottom.muted)
    }

    @Test func onlyTheVolumeKeysAreTaken() {
        #expect(VolumeStep.key(forSystemCode: 0) == .up)
        #expect(VolumeStep.key(forSystemCode: 1) == .down)
        #expect(VolumeStep.key(forSystemCode: 7) == .mute)
        #expect(VolumeStep.key(forSystemCode: 2) == nil)  // brightness: left to macOS
        #expect(VolumeStep.key(forSystemCode: 16) == nil)  // play/pause
    }

    @Test func theHUDsWingsSpreadEvenlyFromTheNotch() throws {
        let screen = Rect(x: 0, y: 0, width: 1512, height: 982), visible = Rect(x: 0, y: 0, width: 1512, height: 945)
        let notch = Rect(x: 663.5, y: 945, width: 185, height: 37)
        let frame = try #require(NotchPanel.frame(.collapsed, screen: screen, visible: visible, notch: notch,
                                                  activity: true, hud: true))
        #expect(frame.midX == notch.midX)
        #expect(frame.width == notch.width + 2 * NotchPanel.hudWing + 2 * NotchPanel.ear)
        #expect(frame.height == notch.height)
    }
}

struct AirDropItemsTests {
    let a = URL(fileURLWithPath: "/tmp/a.pdf")
    let b = URL(fileURLWithPath: "/tmp/b.png")
    let c = URL(fileURLWithPath: "/tmp/c.txt")

    @Test func droppedFilesWin() {
        #expect(NotchPanel.airDropItems(dropped: [c, c], shelf: [a, b], selected: [a]) == [c])
    }

    @Test func selectionInShelfOrder() {
        #expect(NotchPanel.airDropItems(shelf: [a, b, c], selected: [c, a]) == [a, c])
    }

    @Test func nothingSelectedSendsAll() {
        #expect(NotchPanel.airDropItems(shelf: [a, b], selected: []) == [a, b])
        #expect(NotchPanel.airDropItems(shelf: [], selected: []) == [])
    }

    @Test func onlyFiles() {
        #expect(NotchPanel.airDropItems(dropped: [URL(string: "https://example.com")!], shelf: [], selected: []) == [])
    }
}
