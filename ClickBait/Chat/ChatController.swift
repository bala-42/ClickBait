import AppKit
import SwiftUI

/// A panel that can take typing without activating ClickBait — like Spotlight — so
/// the app the user is asking about stays frontmost (and in the screenshots).
private final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ClickBait is a menu bar app with no Edit menu, which is what normally turns
    /// ⌘C/⌘V/… into actions — so the panel does it, sending them to the focused text
    /// field or selected answer text through the responder chain.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector? = switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "a"): #selector(NSResponder.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns the chat bubble window: pinned where the answer appeared, draggable, sized
/// exactly to its card, open until ✕ or Escape.
@MainActor
final class ChatController {
    let model = ChatModel()
    private var panel: NSPanel?

    var isOpen: Bool { panel != nil }
    /// The centre of the companion's triangle now (AppKit): the card shrinks back into it
    /// on closing.
    var companionPoint: (() -> CGPoint)?
    /// Where the logo opened: the card grows and shrinks around it.
    private var origin: CGPoint?

    /// Opens with the header logo centred on `logoCenter` (global AppKit points): the
    /// centre of the companion's triangle, so the two line up exactly.
    /// `tucked`: set up in place but not shown yet; `untuck()` grows it out of the companion
    /// when the answer starts arriving.
    func open(logoAt logoCenter: CGPoint, tucked: Bool = false) {
        closeNow()
        setHome()
        homePoint = logoCenter
        trace("open\(tucked ? " (tucked)" : "") at \(Int(logoCenter.x)),\(Int(logoCenter.y))")
        model.messages = []
        model.draft = ""
        model.isBusy = false
        model.isClosing = false

        let panel = ChatPanel(
            contentRect: CGRect(x: 0, y: 0, width: ChatView.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // Stays on the desktop it was summoned on: it belongs to that app and window.
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Only take the keyboard when the text field is clicked, never on its own.
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: ChatView(model: model))

        model.onCardSizeChange = { [weak self] in self?.fitToCard() }
        // The measured logo spot arrived (or moved): re-align with where it opened.
        model.onLogoMove = { [weak self] in
            guard let self, let origin, !model.isClosing else { return }
            alignLogo(to: origin)
        }
        self.panel = panel
        origin = logoCenter
        alignLogo(to: logoCenter)
        aim(at: logoCenter, in: panel.frame)
        model.isTucked = tucked
        if !tucked { fadeIn(panel) }
    }

    /// Hides the current chat without treating it as a user close. Its messages are
    /// handed to a background capsule and restored if the user returns to that job.
    func stash() -> [ChatModel.Message] {
        let messages = model.messages
        closeNow()
        model.isClosing = false
        return messages
    }

    /// Restores a stashed conversation at the companion, belonging to its original app.
    func restore(_ messages: [ChatModel.Message], logoAt logoCenter: CGPoint, homeApp: NSRunningApplication?) {
        open(logoAt: logoCenter)
        model.messages = messages
        model.isBusy = false
        if let homeApp {
            homePID = homeApp.processIdentifier
            homeName = homeApp.localizedName
        }
    }

    /// Opens an empty chat (logo on `logoCenter`) with the cursor in the text field,
    /// ready to type. Takes the keyboard without activating ClickBait, like Spotlight.
    func openForTyping(logoAt logoCenter: CGPoint) {
        open(logoAt: logoCenter)
        panel?.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    /// Puts the cursor back in an open chat's text field.
    func focus() {
        guard let panel else { return }
        // Summoned again: it belongs to the app in front now, and comes back there.
        if isAway || homePID != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            setHome()
            isAway = false
        }
        // Summoned by the hotkey: to where it was pressed.
        if let point = homePoint ?? companionPoint?() {
            origin = point
            alignLogo(to: point)
        }
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    var isTucked: Bool { model.isTucked }

    // MARK: Belonging to an app

    /// The app the chat was summoned in. While another app is in front it steps away, and
    /// it's back (where it was) when that app is.
    private var homePID: pid_t?
    private var homeName: String?
    /// Hidden because another app is in front.
    private(set) var isAway = false
    /// An answer came in while away: say so where the user is now.
    var onReadyWhileAway: ((String) -> Void)?
    /// The user is back in the chat's app (it's showing again).
    var onBackHome: (() -> Void)?

    /// Where the chat sits: where the companion was when the hotkey was last pressed. It
    /// appears there and stays there, also when it comes back after tucking away.
    private var homePoint: CGPoint?

    /// A hotkey was pressed with the companion at `point`.
    func invoked(at point: CGPoint) {
        homePoint = point
        // Asked from another app while it's away there: it moves here (a walkthrough's
        // checklist went into a chat hidden in Safari).
        if isAway {
            setHome()
            isAway = false
            trace("re-homed to \(homeName ?? "?") by the hotkey")
        }
        trace("hotkey at \(Int(point.x)),\(Int(point.y))")
    }

    /// The app the chat belongs to.
    var homeApp: NSRunningApplication? {
        homePID.flatMap { NSRunningApplication(processIdentifier: $0) }
    }
    var homeBundleID: String? { homeApp?.bundleIdentifier }
    var homeProcessID: Int32? { homePID }

    private func trace(_ message: String) {
        Log.app.notice("Chat: \(message, privacy: .public)")
    }

    private func setHome() {
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.processIdentifier != getpid() else { return }
        homePID = front?.processIdentifier
        homeName = front?.localizedName
    }

    /// A walkthrough moved on to `app`: the chat (its checklist) goes with it.
    func adopt(_ app: NSRunningApplication) {
        guard let panel, app.processIdentifier != getpid() else { return }
        homePID = app.processIdentifier
        homeName = app.localizedName
        if isAway {
            isAway = false
            if !model.isTucked { fadeIn(panel) }
        }
    }

    /// Called when an app comes to the front.
    func appActivated(_ app: NSRunningApplication) {
        guard let panel, app.processIdentifier != getpid(), homePID != nil else { return }
        if app.processIdentifier == homePID {
            guard isAway else { return }
            trace("back home (\(app.localizedName ?? "?")): \(model.isTucked ? "still tucked" : "shown") at \(Int(panel.frame.minX)),\(Int(panel.frame.maxY))")
            isAway = false
            if !model.isTucked { showWhenSettled(panel) }
            onBackHome?()
        } else if !isAway {
            trace("away: \(app.localizedName ?? "?") in front, home is \(homeName ?? "?")")
            isAway = true
            panel.orderOut(nil)
        }
    }
    /// Tucked on purpose (the reply was said by a pill or the pointer): it stays away, its
    /// conversation kept, until a long answer, a double tap or a new chat brings it back.
    private(set) var isParked = false

    /// Steps aside for a reply the pills can say, keeping the conversation.
    func park() {
        tuck()
        isParked = model.isTucked
    }
    private var tuckTask: Task<Void, Never>?
    /// The text field had the keyboard when the chat tucked away: give it back.
    private var refocusOnReturn = false

    /// Shrinks into the companion while the answer is on its way, keeping its place. Pills
    /// and the companion carry on as usual; only this panel steps aside.
    func tuck() {
        guard let panel, !model.isTucked else { return }
        trace("tuck")
        refocusOnReturn = panel.isKeyWindow
        aim(at: companionPoint?() ?? NSEvent.mouseLocation, in: panel.frame)
        model.isTucked = true
        fadeOut(panel)
        tuckTask?.cancel()
        tuckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))  // the shrink (0.18 s) plays out
            guard !Task.isCancelled, let self, model.isTucked else { return }
            self.panel?.orderOut(nil)
            self.panel?.alphaValue = 1
        }
    }

    /// Grows back out of the companion, its logo on the companion's triangle wherever that
    /// is now (like opening), not where the chat was before it tucked away.
    func untuck() {
        guard let panel, model.isTucked else { return }
        isParked = false
        trace("untuck\(isAway ? " while away" : "") to \(homePoint.map { "\(Int($0.x)),\(Int($0.y))" } ?? "the companion")")
        if isAway {
            // Its app isn't in front: it'll be there when the user goes back.
            model.isTucked = false
            if model.messages.last?.role == .assistant { onReadyWhileAway?(homeName ?? "the other app") }
            return
        }
        tuckTask?.cancel()
        // Pops out of the companion wherever it is now (the user may have moved since the
        // hotkey), then stays there.
        let logoCenter = companionPoint?() ?? homePoint ?? NSEvent.mouseLocation
        homePoint = logoCenter
        origin = logoCenter
        alignLogo(to: logoCenter)
        aim(at: logoCenter, in: panel.frame)
        fadeIn(panel)
        model.isTucked = false
        if refocusOnReturn {
            refocusOnReturn = false
            panel.makeKey()
            model.focusRequest += 1
        }
    }

    /// Coming back to its app: macOS reports the app active before the slide to its desktop
    /// finishes, and a window shown then lands on the desktop being left (the chat turned
    /// up over Chrome after "let's see!" went back to Claude). Wait for the switch, then
    /// show it on the desktop the user is now on.
    ///
    /// A full-screen app's slide can take longer than that wait (the chat landed on Chrome's
    /// desktop and Claude's had nothing), so for a while afterwards each finished desktop
    /// switch, and a couple of later checks, bring it over if it isn't on the one in view.
    private func showWhenSettled(_ shown: NSPanel) {
        settleTask?.cancel()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, isStillHome(shown) else { return }
            bringToCurrentDesktop(shown, fading: true)
            trace("shown at home, on the current desktop (on it: \(shown.isOnActiveSpace))")
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheckDesktop(shown, reason: "desktop switch finished") }
            }
            for delay in [450, 700, 1_500] {  // checks at ~0.8 s, ~1.5 s and ~3 s
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { break }
                recheckDesktop(shown, reason: "check")
            }
            if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
            spaceObserver = nil
        }
    }

    private var settleTask: Task<Void, Never>?
    private var spaceObserver: (any NSObjectProtocol)?

    private func isStillHome(_ shown: NSPanel) -> Bool {
        shown === panel && !isAway && !model.isTucked
    }

    /// Not on the desktop in view (shown while the slide was still going): move it here.
    private func recheckDesktop(_ shown: NSPanel, reason: String) {
        guard isStillHome(shown) else {
            trace("desktop \(reason): not at home any more (away \(isAway), tucked \(model.isTucked))")
            return
        }
        guard !shown.isOnActiveSpace else {
            trace("desktop \(reason): on the current desktop, visible \(shown.isVisible)")
            return
        }
        bringToCurrentDesktop(shown, fading: false)
        trace("moved to the current desktop (\(reason)); on it now: \(shown.isOnActiveSpace)")
    }

    private func bringToCurrentDesktop(_ shown: NSPanel, fading: Bool) {
        shown.collectionBehavior.insert(.moveToActiveSpace)
        if fading {
            fadeIn(shown)
        } else {
            shown.orderOut(nil)
            shown.orderFrontRegardless()
        }
        shown.collectionBehavior.remove(.moveToActiveSpace)
    }

    /// Fades the window in (window server) while SwiftUI grows the card.
    private func fadeIn(_ panel: NSPanel) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
    }

    /// Shrinks back into the companion, then goes.
    func close() {
        guard let closing = panel else { return }
        aim(at: companionPoint?() ?? NSEvent.mouseLocation, in: closing.frame)
        model.isClosing = true
        fadeOut(closing)
        panel = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))  // the shrink (0.18 s) plays out
            closing.orderOut(nil)
            closing.close()
        }
    }

    private func closeNow() {
        isParked = false
        isAway = false
        tuckTask?.cancel()
        model.isTucked = false
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// Keeps the window exactly the card's size, growing downward from a fixed top edge.
    private func fitToCard() {
        guard let panel, model.cardSize.width > 0 else { return }
        let size = CGSize(width: model.cardSize.width.rounded(.up), height: model.cardSize.height.rounded(.up))
        guard size != panel.frame.size else { return }  // a resize forces a redraw: only when it changed
        let top = panel.frame.maxY
        panel.setFrame(CGRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        keepOnScreen()
        if let origin, !model.isClosing { aim(at: origin, in: panel.frame) }
    }

    /// Puts the panel so the logo's measured centre is on `point` (the companion's triangle).
    /// Near the right edge the header flips (logo top-right) so it still fits there.
    private func alignLogo(to point: CGPoint) {
        let width = panel?.frame.width ?? ChatView.width
        let bounds = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
        let flip = bounds.map { point.x - ChatView.logoCenter.x + width > $0.maxX } ?? false
        if model.isFlipped != flip { model.isFlipped = flip }  // the logo moves; onLogoMove re-aligns
        var logo = model.logoOffset ?? ChatView.logoCenter
        // Until the flipped layout has been measured, mirror the unflipped spot.
        if flip != (logo.x > width / 2) { logo.x = width - logo.x }
        place(topLeft: CGPoint(x: point.x - logo.x, y: point.y + logo.y))
        logAlignment()
    }

    /// Logs the companion's and the logo's real positions once the spring has settled.
    private func logAlignment() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, let panel, !model.isTucked, let companion = companionPoint?() else { return }
            let logo = model.logoOffset ?? ChatView.logoCenter
            let shown = CGPoint(x: panel.frame.minX + logo.x, y: panel.frame.maxY - logo.y)
            Log.app.notice("""
                Chat logo at (\(Int(shown.x), privacy: .public), \(Int(shown.y), privacy: .public)), companion at \
                (\(Int(companion.x), privacy: .public), \(Int(companion.y), privacy: .public)): off by \
                (\(Int(shown.x - companion.x), privacy: .public), \(Int(shown.y - companion.y), privacy: .public)); \
                panel \(Int(panel.frame.width), privacy: .public)×\(Int(panel.frame.height), privacy: .public), \
                card \(Int(self.model.cardSize.width), privacy: .public)×\(Int(self.model.cardSize.height), privacy: .public), \
                logo offset \(self.model.logoOffset == nil ? "assumed" : "measured", privacy: .public)
                """)
        }
    }

    private func place(topLeft: CGPoint) {
        guard let panel else { return }
        panel.setFrameTopLeftPoint(topLeft)
        keepOnScreen()
    }

    /// Points the grow/shrink animation at `point` (the companion), wherever the card
    /// ended up (it's pushed back on screen near edges).
    private func aim(at point: CGPoint, in frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let x = min(max((point.x - frame.minX) / frame.width, 0), 1)
        let y = min(max((frame.maxY - point.y) / frame.height, 0), 1)
        model.companionAnchor = UnitPoint(x: x, y: y)
    }

    private func keepOnScreen() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
        guard let bounds = screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}
