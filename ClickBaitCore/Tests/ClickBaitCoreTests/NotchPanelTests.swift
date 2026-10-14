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
        state = NotchPanel.next(state, on: .hoverDwelled);    #expect(state == .expanded)
        state = NotchPanel.next(state, on: .hoverDwelled);    #expect(state == .expanded)  // stays
        state = NotchPanel.next(state, on: .pointerLeft);     #expect(state == .collapsed)
        state = NotchPanel.next(state, on: .clicked);         #expect(state == .expanded)
        state = NotchPanel.next(state, on: .escape);          #expect(state == .collapsed)
        state = NotchPanel.next(state, on: .escape);          #expect(state == .collapsed)  // nothing to close
        state = NotchPanel.next(state, on: .displayAvailable(false)); #expect(state == .hidden)
        state = NotchPanel.next(state, on: .clicked);         #expect(state == .hidden)  // hidden ignores clicks
        state = NotchPanel.next(state, on: .displayAvailable(true));  #expect(state == .collapsed)
        state = NotchPanel.next(state, on: .enabled(false));  #expect(state == .hidden)
    }

    @Test func collapsedCoversOnlyTheNotch() {
        let plain = NotchPanel.frame(.collapsed, screen: screen, visible: visible, notch: notch, showsTab: false)
        #expect(plain == notch)  // menu-bar items either side stay clickable
        let tab = NotchPanel.frame(.collapsed, screen: screen, visible: visible, notch: notch, showsTab: true)
        #expect(tab?.width == notch.width + NotchPanel.tabWidth)
        #expect(tab?.x == notch.x)
    }

    @Test func expandedHangsFromTheTopCentredOnTheNotch() throws {
        let frame = try #require(NotchPanel.frame(.expanded, screen: screen, visible: visible, notch: notch, showsTab: false))
        #expect(frame.maxY == screen.maxY)
        #expect(abs(frame.midX - notch.midX) < 0.01)
        #expect(frame.height == NotchPanel.expandedSize.height)
        #expect(frame.width >= notch.width)
    }

    @Test func withoutANotchItIsAPillUnderTheMenuBar() throws {
        let pill = try #require(NotchPanel.frame(.collapsed, screen: screen, visible: visible, notch: nil, showsTab: true))
        #expect(pill.width == NotchPanel.pillSize.width)
        #expect(pill.maxY <= visible.maxY)
        let open = try #require(NotchPanel.frame(.expanded, screen: screen, visible: visible, notch: nil, showsTab: false))
        #expect(open.maxY <= visible.maxY)
        #expect(open.minX >= screen.minX && open.maxX <= screen.maxX)
    }

    @Test func hiddenHasNoFrame() {
        #expect(NotchPanel.frame(.hidden, screen: screen, visible: visible, notch: notch, showsTab: true) == nil)
    }

    @Test func narrowScreensKeepItOnScreen() throws {
        let small = Rect(x: 0, y: 0, width: 400, height: 600)
        let frame = try #require(NotchPanel.frame(.expanded, screen: small, visible: small, notch: nil, showsTab: false))
        #expect(frame.minX >= 0 && frame.maxX <= 400)
    }
}

struct PullGestureTests {
    @Test func pullingDownOpensPushingUpCloses() {
        #expect(NotchPanel.next(.collapsed, on: .pulledDown) == .expanded)
        #expect(NotchPanel.next(.expanded, on: .pushedUp) == .collapsed)
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

    @Test func hoverWaitsHalfASecond() {
        #expect(NotchPanel.hoverDelay == 0.5)
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
                                                  showsTab: true, showsHUD: true))
        #expect(frame.midX == notch.midX)
        #expect(frame.width == notch.width + 2 * NotchPanel.hudWing)
        #expect(frame.height == notch.height)
    }
}

struct CPUUsageTests {
    @Test func busyShareOfTheTicksBetweenSamples() {
        let a = CPUUsage.Ticks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUUsage.Ticks(user: 130, system: 60, idle: 900, nice: 10)
        #expect(CPUUsage.busy(from: a, to: b) == 0.5)  // 50 busy of 100
        #expect(CPUUsage.busy(from: a, to: a) == nil)  // no time passed
        let wrapped = CPUUsage.Ticks(user: 5, system: 60, idle: 900, nice: 0)
        #expect(CPUUsage.busy(from: a, to: wrapped) ?? -1 >= 0)  // a wrapped counter never goes negative
    }
}
