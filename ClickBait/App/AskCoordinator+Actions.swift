import AppKit
import AVFoundation
import ClickBaitCore
import Observation

// Proposed actions: asking first, reminders.
extension AskCoordinator {
    // MARK: - Proposed actions (phase E, step 4)

    /// The card's buttons, in order.
    static let reminderDayChoices: [ReminderDay] = [.inDays(0), .inDays(1)]

    func askReminderDay(_ request: ActionRequest, speak: Bool) -> ActionOutcome {
        dropPending()
        pendingReminder = (request, speak, chatShown)
        let title = ReminderText.parse(request.detail ?? "").title
        let question = "“\(title)” — when?"
        Log.ask.notice("Reminder: no day said, asking")
        if speak { speaker.speak("When should I remind you?") }
        if state == .thinking { state = .idle }
        onReminderDayRequest?(question, ["Today", "Tomorrow"], "or say a day")
        return .asked(question)
    }

    /// The card's answer: a button's index, or nil when it timed out.
    func answerReminderChoice(_ index: Int?) {
        guard let index, Self.reminderDayChoices.indices.contains(index) else {
            dropPendingReminder(timedOut: true)
            return
        }
        Task { await resolveReminder(Self.reminderDayChoices[index]) }
    }

    /// A day picked on the card's calendar.
    func answerReminderDate(_ date: Date) {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
        Task { await resolveReminder(.inDays(max(days, 0))) }
    }

    func resolveReminder(_ day: ReminderDay) async {
        guard var pending = pendingReminder else { return }
        pendingReminder = nil
        onConfirmEnd?()
        pending.request.detail = (pending.request.detail ?? "") + " " + day.phrase
        let outcome = await perform(pending.request, speak: pending.speak)
        if pending.inChat, chatShown, case .success(let confirmation) = outcome { onChatReply?(confirmation + ".") }
    }

    func dropPendingReminder(timedOut: Bool = false) {
        guard pendingReminder != nil else { return }
        pendingReminder = nil
        onConfirmEnd?()
        Log.ask.notice("Reminder: no day given, not added\(timedOut ? " (timed out)" : "", privacy: .public)")
        if timedOut { show(error: "Reminder not added — no day was picked.") }
    }

    /// A clear order that `ActionPolicy` says asks first (binning files, quitting an app), or nil.
    func asksFirst(_ command: ActionRequest) -> ResolvedAction? {
        guard case .success(let action) = ActionCatalog.resolve(command, allowedShortcuts: settings.allowedShortcuts),
              ActionPolicy.decide(action, from: .clearOrder) == .ask else { return nil }
        return action
    }

    /// An order, said clearly or guessed by the model: `ActionPolicy` decides whether it runs
    /// now or is asked about first. Returns what to show in the chat: the question asked, or
    /// the result.
    @discardableResult
    func handleOrder(_ action: ResolvedAction, request proposal: ActionRequest, speak: Bool,
                             from source: ActionPolicy.Source) async -> String {
        if ActionPolicy.decide(action, from: source) == .ask {
            var count: Int?
            // The files it will use: the shelf's or the document in front, else Finder's.
            if case .file(let file) = action {
                let front = NSWorkspace.shared.frontmostApplication
                count = FileActions.otherSource(for: file, frontmostPID: front?.processIdentifier, frontmostBundleID: front?.bundleIdentifier)?.files.count
                if count == nil { count = try? await FinderSelection.read().count }
            }
            if count == 0 {
                let message = FileActionError.nothingSelected.localizedDescription
                if speak { speaker.speak(message) }
                show(error: message)
                return message
            }
            pendingAction = (proposal, speak, chatShown)
            let question = ActionCatalog.confirmationQuestion(for: action, fileCount: count)
            Log.ask.notice("Order \(proposal.name, privacy: .public) (\(source.rawValue, privacy: .public)): asking first")
            if speak { speaker.speak(question) }
            if state == .thinking { state = .idle }
            onConfirmRequest?(question)
            return question
        }
        Log.ask.notice("Order \(proposal.name, privacy: .public) (\(source.rawValue, privacy: .public)): running")
        switch await perform(proposal, speak: speak) {
        case .success(let confirmation): return confirmation + "."
        case .failure(let message): return message
        case .asked(let question): return question
        }
    }

    /// The whole reply to `request`, or nil if it fails or takes longer than `limit`.
    nonisolated static func reply(from provider: any LLMProvider, to request: AskRequest, within limit: Duration) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                var text = ""
                do { for try await chunk in provider.stream(request) { text += chunk } } catch { return nil }
                return text
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// "suggested next:" for a finished background answer's card: one short text-only
    /// request (`Prompt.nextSystem`, ~1 s). Nil if it's slow (Ollama may be busy with a
    /// question: a foreground answer comes first) or the reply isn't usable.
    func suggestNext(question: String, answer: String) async -> [String]? {
        var ask = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: ScreenContext(appName: nil), selectedText: nil)
        ask.suggestNextAfter = MessageFormat.spokenText(answer)
        let start = ContinuousClock.now
        let reply = await Self.reply(from: settings.makeProvider(), to: ask, within: .seconds(4))
        let suggestions = reply.flatMap { NextSuggestions.parse($0, question: question) }
        Log.ask.notice("Suggested next: \(suggestions?.count ?? -1) in \(String(describing: ContinuousClock.now - start), privacy: .public)")
        return suggestions
    }

    /// A card's [voice]: listening as if ⌃⌥ were held, until the next click (or 20 s),
    /// which counts as letting go.
    func listenUntilClick() {
        guard !isBusy else { return }
        handle(.askPressed)
        guard state == .listening else { return }
        var monitors: [Any] = []
        var done = false
        let finish: @MainActor () -> Void = { [weak self] in
            guard !done else { return }
            done = true
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            guard let self, state == .listening else { return }
            handle(.askReleased)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { _ in
            MainActor.assumeIsolated { finish() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in
            MainActor.assumeIsolated { finish() }
            return event
        }) { monitors.append(local) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            finish()
        }
    }

    /// For orders the rules don't recognise ("stash these in my documents"): a quick,
    /// text-only request asking which known action it is. Nil if none (or no answer in
    /// time); the result still has to pass the catalog and the Finder check.
    enum UnderstoodOrder {
        case ready(ResolvedAction)
        /// Understood, but can't be done (the reason, for the user).
        case failed(String)
    }

    func understandOrder(_ text: String, flow: QuestionFlow? = nil) async -> (UnderstoodOrder, ActionRequest)? {
        guard settings.commandsEnabled, CommandParser.looksLikeOrder(text), let provider = flow?.provider ?? self.provider else { return nil }
        let context = flow?.context ?? self.context
        // "Show me how to…" and "open YouTube" are walkthroughs, not orders: reading
        // "show me how to open youtube on chrome" as "open Chrome" just opened Chrome.
        if TutorialQuestion.asksForTutorial(text) || Websites.visit(in: text, installedApps: Array(AppLocator.installed().keys)) != nil {
            Log.ask.notice("Order check: skipped (a walkthrough)")
            return nil
        }
        // "Where's / show me / point at X" is never an order: don't spend ~1.5 s asking.
        if TutorialQuestion.isLocatingRequest(text) {
            Log.ask.notice("Order check: skipped (finding something)")
            return nil
        }
        let start = ContinuousClock.now
        var request = AskRequest(question: text, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0, context: context)
        request.interpretOrder = true
        let reply = await Self.reply(from: provider, to: request, within: ProviderOperation.interpretOrder.timeout)
        guard let reply, let parsed = ResponseParser.action(inReply: reply),
              var proposal = OrderCheck.sanitized(parsed, order: text) else {
            Log.ask.notice("Order check: no action (\(String(describing: ContinuousClock.now - start), privacy: .public))")
            return nil
        }
        // Not Finder in front, or an app name that isn't installed: maybe it wasn't an
        // order after all ("open the File menu") — answer it normally.
        guard !isUnknownApp(proposal) else {
            Log.ask.notice("Order check: \(proposal.name, privacy: .public) doesn't apply here")
            return nil
        }
        // "Add it to my notes": the note is resolved from the user's words (the model's
        // detail is a guess at "it"), when they refer to the page, selection or answer.
        if proposal.name == "make_note" || proposal.name == "add_reminder", NoteReference.find(in: text) != nil {
            proposal.detail = text
        }
        let action: ResolvedAction
        switch ActionCatalog.resolve(proposal, allowedShortcuts: settings.allowedShortcuts) {
        case .success(let resolved): action = resolved
        case .failure(let error):
            // An order ClickBait understood but can't carry out: say why, don't quietly
            // turn it into a how-to.
            Log.ask.notice("Order check: \(proposal.name, privacy: .public) can't be done (\(String(describing: error), privacy: .private))")
            return (.failed(error.message), proposal)
        }
        Log.ask.notice("Order check: \(proposal.name, privacy: .public) (\(String(describing: ContinuousClock.now - start), privacy: .public))")
        return (.ready(action), proposal)
    }

    /// The user's answer to a pending question (Do it / Cancel, "yes" / "cancel", Esc).
    func answerConfirmation(_ yes: Bool) {
        Task { await resolvePending(yes) }
    }

    func resolvePending(_ yes: Bool) async {
        guard let pending = pendingAction else { return }
        pendingAction = nil
        onConfirmEnd?()
        guard yes else {
            Log.ask.notice("Proposed action cancelled")
            if pending.speak { speaker.speak("Okay, I won't.") }
            if state == .thinking { state = .idle }
            return
        }
        let outcome = await perform(pending.request, speak: pending.speak)
        if pending.inChat, chatShown, case .success(let confirmation) = outcome { onChatReply?(confirmation + ".") }
    }

    func dropPending() {
        guard pendingAction != nil else { return }
        pendingAction = nil
        onConfirmEnd?()
    }
}
