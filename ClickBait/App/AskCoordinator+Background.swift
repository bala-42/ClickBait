import AppKit
import AVFoundation
import ClickBaitCore
import Observation

// Sending a question to the background, and the intent router in shadow mode.
extension AskCoordinator {
    // MARK: - Sending a question to the background (⌃⌥ while it is orange)

    /// Where the question in progress has got, as `PeelRule` sees it. A flow whose end was
    /// missed (the state moved on without it) counts as idle rather than blocking ⌃⌥.
    var currentPhase: PeelRule.Phase {
        guard let flow = currentFlow else { return .idle }
        if flow.phase == .listening, state != .listening { return .idle }
        if flow.phase.isPreRun, state != .thinking { return .idle }
        return flow.phase
    }

    /// Stops the recording and starts thinking (orange): at the end of the release tail, or
    /// early when ⌃⌥ is pressed during it. The capture and snapshot tasks move to the flow, so
    /// the next question can start its own. The recorder stops before that question's starts.
    func endTail(_ flow: QuestionFlow, releasedAt: ContinuousClock.Instant) {
        flow.samples = recorder.stop()
        answerStartedAt = releasedAt
        state = .thinking
        flow.phase = .transcribing
        pressedAt = nil
        flow.captureTask = captureTask
        flow.snapshotTask = snapshotTask
        captureTask = nil
        snapshotTask = nil
    }

    /// ⌃⌥ pressed: peel the question in progress (now, or as soon as its run exists), or say
    /// why not. True when the press goes on to become the next question.
    func acceptsNewQuestion() -> Bool {
        let flow = currentFlow
        // Let go a moment ago and still in the tail: the companion is orange, so this press
        // ends the tail now and counts as a press during transcribing.
        if let flow, currentPhase == .listening, flow.released, let held = pressedAt.map({ ContinuousClock.now - $0 }),
           held >= Self.minimumHold {
            endTail(flow, releasedAt: .now)
        }
        let situation = PeelRule.Situation(phase: currentPhase, work: flow?.work ?? .answer,
                                           kind: flow?.kind ?? .unknown, hasRoom: backgroundJobs?.hasRoom ?? false)
        switch PeelRule.outcome(of: .chord, in: situation) {
        case .startNew:
            return true
        case .peelNow:
            guard let flow else { return true }
            if let run = flow.run { return peel(flow, run, situation) }
            return queuePeel(flow)
        case .peelWhenReady:
            guard let flow else { return true }
            return queuePeel(flow)
        case .tooQuick:
            // Nothing to send away: the question finishes in the foreground, and this press
            // doesn't become a new one (the answer is moments away, and the companion is busy).
            Log.ask.notice("⌃⌥ ignored: that one is quick, nothing to send away")
            onQuickEnding?(PeelRule.quickPill, flow?.work == .snip ? .capture : .processing, false)
            return false
        case .ignore(let reason):
            if reason == .threesACrowd { onPeelRefused?() }
            Log.ask.notice("⌃⌥ ignored: \(reason.logText, privacy: .public)")
            return false
        }
    }

    /// Makes the job's tile now (with the peel animation) and clears the foreground, so the
    /// next question starts with fresh state and nothing of this one's.
    func startPeel(_ flow: QuestionFlow) -> BackgroundJob? {
        guard let backgroundJobs else { return nil }
        let run = flow.run
        let snipChat = flow.work == .snip || (conversation?.isEmpty == false && snipMemory != nil)
        let job = BackgroundJob(question: run?.question ?? flow.heard ?? (flow.work == .snip ? "" : "your question"),
                                kind: run?.kind ?? (snipChat ? .snip : .answer),
                                homeBundleID: flow.homeBundleID, homePID: flow.homePID,
                                conversation: run?.conversation ?? conversation ?? Conversation())
        let task = run?.task ?? askTask
        guard backgroundJobs.add(job, task: task) else {
            onPeelRefused?()
            return nil
        }
        flow.task = task
        flow.jobID = job.id
        flow.sentAway = true
        backgroundJobs.setStage(flow.stage, for: job.id)
        flow.conversation = conversation
        flow.snipMemory = snipMemory
        flow.chatMessages = onPeel?(job) ?? []
        // The task belongs to the tile now (its ✕ stops it): Esc, dismissing an answer or
        // closing a chat cancels `askTask`, which would silently kill the background answer.
        if askTask == task { askTask = nil }
        if let run {
            if answerFlowID == run.id { answerFlowID = nil }
            finishAnswering(run.id)
            finishRefining(run.id)
            if activeAnswerRun === run { activeAnswerRun = nil }
        }
        speaker.stop()
        onSnipAnswering?(false)
        conversation = nil
        snipMemory = nil
        chatShown = false
        if currentFlow === flow { currentFlow = nil }
        state = .idle
        return job
    }

    /// The run joins its tile: its words, result and errors go to the job from here on.
    func attach(_ run: AnswerRun, to flow: QuestionFlow, appendingQuestion: Bool) {
        guard let jobID = flow.jobID, let backgroundJobs else { return }
        run.destination = .background(jobID)
        run.task = flow.task
        var messages = flow.chatMessages
        if messages.isEmpty || appendingQuestion { messages.append(ChatModel.Message(role: .user, text: run.display)) }
        run.chatMessages = messages
        backgroundJobs.setSnipMemory(run.snipMemory, for: jobID)
        backgroundJobs.setChatMessages(messages, for: jobID)
        // The window it was asked in, for "go there!" (its context is complete by now), and
        // in a browser its exact tab.
        backgroundJobs.setHomeWindow(title: flow.context.windowTitle, frame: flow.context.windowFrame, for: jobID)
        if flow.browserTab == nil { readBrowserTab(for: flow, at: nil) }
        if let reading = flow.browserTab {
            Task { @MainActor [weak self] in self?.backgroundJobs?.setHomeTab(await reading.value, for: jobID) }
        }
        flow.joined = true
    }

    /// The answer is streaming: peel it. A snip whose explanation is already complete keeps
    /// it in the done card and skips its tour, offering "show me the parts" instead.
    func peel(_ flow: QuestionFlow, _ run: AnswerRun, _ situation: PeelRule.Situation) -> Bool {
        guard case .foreground = run.destination else {
            Log.ask.notice("Peel skipped: the answer is already in the background")
            return false
        }
        guard let job = startPeel(flow) else {
            Log.ask.notice("Peel skipped: no free slot or no job list")
            return false
        }
        attach(run, to: flow, appendingQuestion: false)
        Log.ask.notice("Peeled answer \(job.id.uuidString, privacy: .public) into a background capsule")
        if run.explanation != nil {
            let parts = PeelRule.skipsTourAndSuggestsParts(situation) && run.expectsTour != false
            keepExplanation(of: run, jobID: job.id, suggestParts: parts)
        }
        return true
    }

    /// The run doesn't exist yet (transcribing, order check, element pick) or hasn't started
    /// streaming: the tile is made now; the question carries on and its run joins the tile
    /// when the model request starts (`respond`), or it ends as a command or an instant pick
    /// (`settleQuick`).
    func queuePeel(_ flow: QuestionFlow) -> Bool {
        guard startPeel(flow) != nil else { return false }
        Log.ask.notice("Peel queued: waiting for the answer to start")
        return true
    }

    /// `PeelRule.autoPeelDelay` after the explanation's model request starts: if it is still
    /// working in front, peel it as ⌃⌥ would. Not before a second ⌥⌘ tap is ruled out (a
    /// double tap drops the explanation instead).
    func scheduleAutoPeel(_ flow: QuestionFlow, _ run: AnswerRun) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: PeelRule.autoPeelDelay)
            await self?.explainCommit?.value
            self?.autoPeel(flow, run)
        }
    }

    func autoPeel(_ flow: QuestionFlow, _ run: AnswerRun) {
        guard flow.run === run, activeAnswerRun === run, case .foreground = run.destination,
              run.task?.isCancelled != true else { return }
        let situation = PeelRule.Situation(phase: flow.phase, work: flow.work, kind: flow.kind,
                                           hasRoom: backgroundJobs?.hasRoom ?? false)
        // Complete when the delay came: a fast answer keeps the companion it has.
        guard PeelRule.autoPeels(situation, answeredAlready: run.explanation != nil) else {
            if run.explanation != nil { Log.ask.notice("Auto-peel skipped: answered within \(String(describing: PeelRule.autoPeelDelay), privacy: .public)") }
            if !situation.hasRoom, flow.phase.hasRun { Log.ask.notice("Auto-peel skipped: three's a crowd, finishing in front") }
            return
        }
        if peel(flow, run, situation) {
            Log.ask.notice("Auto-peeled after \(String(describing: PeelRule.autoPeelDelay), privacy: .public) (\(flow.work == .snip ? "snip" : "explanation", privacy: .public))")
        }
    }

    /// Whether the snipped area still looks as it did: captured again and compared with
    /// the close-up (`SnipMatch`, on this Mac, no model).
    func stillShows(_ view: SnipView) async -> Bool {
        let center = NSPoint(x: view.crop.midX, y: view.primaryDisplayHeight - view.crop.midY)
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: settings.blocklist, at: center,
                                                                          ignoreClickBait: settings.ignoreNotchInCaptures),
              let fresh = try? SnipRenderer.view(capture, region: view.markedOnScreen),
              fresh.crop == view.crop else { return false }
        let difference = SnipMatch.difference(view.thumbnail, fresh.thumbnail)
        Log.ask.notice("Parts: snipped area differs by \(difference.map { String(format: "%.1f", $0) } ?? "?", privacy: .public) grey levels")
        return SnipMatch.matches(view.thumbnail, fresh.thumbnail)
    }

    /// A flow for work that doesn't start from a spoken question or a snip (⌥⌘ explain, typed
    /// follow-ups), made when its answer starts so a streaming answer can still be peeled.
    func adHocFlow(snip: Bool) -> QuestionFlow {
        let flow = QuestionFlow(work: snip ? .snip : .answer, phase: .buildingRequest)
        flow.provider = provider
        flow.context = context
        flow.homeBundleID = frontmostBundleID
        flow.homePID = frontmostPID
        flow.task = askTask
        if currentFlow == nil { currentFlow = flow }
        return flow
    }

    func keepExplanation(of run: AnswerRun, jobID: UUID, suggestParts: Bool) {
        guard let text = run.explanation, let backgroundJobs else { return }
        run.recordTurn?(&run.conversation)
        run.recordTurn = nil
        settleChat(of: run, finalText: text)
        backgroundJobs.setChatMessages(run.chatMessages, for: jobID)
        backgroundJobs.complete(jobID, answer: text, conversation: run.conversation)
        if suggestParts { backgroundJobs.setLeadingSuggestion(PeelRule.suggestedPartsPrompt, for: jobID) }
        run.task?.cancel()  // the tour: marks, placement and pointing never run
        Log.ask.notice("Peel kept the explanation and skipped the tour: \(jobID.uuidString, privacy: .public)")
    }

    /// The answer's text goes into the run's chat messages: the last assistant message after
    /// the last question, or a new one.
    func settleChat(of run: AnswerRun, finalText: String) {
        let lastUser = run.chatMessages.lastIndex(where: { $0.role == ChatModel.Message.Role.user })
        let lastAssistant = run.chatMessages.lastIndex(where: { $0.role == ChatModel.Message.Role.assistant })
        if let lastUser, let lastAssistant, lastAssistant > lastUser {
            run.chatMessages[lastAssistant].text = finalText
        } else {
            run.chatMessages.append(ChatModel.Message(role: .assistant, text: finalText))
        }
    }

    /// A queued question turned out to need no model answer (`flow.kind` says which): per
    /// `PeelRule.resolution` its tile goes. A command or walkthrough then runs as usual and an
    /// instant pick points, as soon as the foreground is free (the next question may be
    /// listening): at once if it is, else after waiting at most 10 s. Past that, or for a pick
    /// whose capture is over 15 s old, it is dropped with a visible pill. The "quick" pill
    /// shows only once the work actually starts. `resolvesPending`: this is the "yes" or the
    /// day that answers a waiting question, which must not count as the foreground being busy.
    func settleQuick(_ flow: QuestionFlow, resolvesPending: Bool = false) async -> Bool {
        guard let id = flow.jobID, !flow.joined else { return true }
        let isPick = flow.kind == .instantPick
        let tone: CompanionTone = flow.work == .snip ? .capture : .processing
        let busy = isBusy || currentFlow != nil
        let resolution = PeelRule.resolution(of: isPick ? .instantPick(foregroundBusy: busy) : .command)
        backgroundJobs?.remove(id)
        flow.jobID = nil
        Log.ask.notice("""
            Peel ended quick (\(isPick ? "instant pick" : "command", privacy: .public)): \
            \(id.uuidString, privacy: .public) \(String(describing: resolution), privacy: .public)
            """)
        let stale = isPick && ContinuousClock.now - flow.startedAt > .seconds(15)
        var free = !stale
        if free { free = await waitForForeground(upTo: .seconds(10), resolvingPending: resolvesPending) }
        guard free else {
            Log.ask.notice("Queued \(isPick ? "pick" : "command", privacy: .public) dropped: \(stale ? "its screen is too old" : "the foreground stayed busy", privacy: .public)")
            onQuickEnding?(Self.droppedPill, tone, false)
            return false
        }
        currentFlow = flow
        askTask = flow.task
        provider = flow.provider
        context = flow.context
        frontmostPID = flow.homePID
        frontmostBundleID = flow.homeBundleID
        state = .thinking
        if let pill = resolution.pill { onQuickEnding?(pill, tone, false) }
        return true
    }

    static let droppedPill = "couldn't do that while you were busy — ask again"

    func foregroundIsFree(resolvingPending: Bool) -> Bool {
        guard currentFlow == nil, state == .idle, !isAnswering, !isRefining, !speaker.isSpeaking,
              !snipper.isActive else { return false }
        return resolvingPending || (pendingAction == nil && pendingReminder == nil && !(tutorial?.isActive ?? false))
    }

    func waitForForeground(upTo limit: Duration, resolvingPending: Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !foregroundIsFree(resolvingPending: resolvingPending) {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !Task.isCancelled
    }

    /// A queued question that ended without an answer starting (cancelled, nothing heard):
    /// its tile goes rather than working forever. Also the flow's end.
    func end(_ flow: QuestionFlow) {
        if currentFlow === flow { currentFlow = nil }
        shadowRoute(flow)
        flow.pendingSnipView?.text.cancel()  // left over if the run never took it
        flow.pendingSnipView?.objects.cancel()
        flow.pendingSnipView = nil
        guard let id = flow.jobID, !flow.joined, backgroundJobs?.job(id)?.isWorking == true else { return }
        backgroundJobs?.remove(id)
        Log.ask.notice("Peel dropped: the question ended before an answer started (\(id.uuidString, privacy: .public))")
    }

    /// What the question is doing now, for its tile if it is (or later gets) sent away (C6).
    func setStage(_ stage: JobStage, of flow: QuestionFlow) {
        flow.stage = stage
        if let id = flow.jobID { backgroundJobs?.setStage(stage, for: id) }
    }

    // MARK: IntentRouter, shadow mode (C3)

    /// Off with `defaults write org.clickbait.ClickBait router.shadow -bool false`.
    static var routerShadowOn: Bool { UserDefaults.standard.object(forKey: "router.shadow") as? Bool ?? true }

    /// After a question ends: what the router would have done, logged next to what ClickBait
    /// did. Changes nothing. Waits until ClickBait is idle (it never shares the GPU with an
    /// answer) and gives up if another question starts.
    func shadowRoute(_ flow: QuestionFlow) {
        guard Self.routerShadowOn, let question = flow.heard, !question.isEmpty, let provider = flow.provider else { return }
        let actual: IntentRouter.Intent
        if tutorial?.isActive == true { actual = .tutorial }
        else if flow.kind == .command { actual = .order }
        else if flow.kind == .instantPick || flow.pointed { actual = .point }
        else { actual = .answer }
        let context = flow.context
        shadowTask?.cancel()
        shadowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, self.state == .idle, self.currentFlow == nil else { return }
            let start = ContinuousClock.now
            var route = self.routeCache.route(for: question)
            let cached = route != nil
            if route == nil {
                var ask = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0, context: context)
                ask.routeIntent = true
                let apps = Array(AppLocator.installed().keys)
                // Checked, then one retry on a bad reply (LTK's pattern); no bigger local model to escalate to yet.
                for _ in 0..<2 where route == nil {
                    guard self.state == .idle, !Task.isCancelled else { return }
                    let reply = await Self.reply(from: provider, to: ask, within: ProviderOperation.classifyRequest.timeout)
                    route = reply.flatMap { IntentRouter.parse($0, apps: apps) }
                }
                if let route { self.routeCache.store(route, for: question) }
            }
            let comparison = IntentRouter.Comparison(route: route, actual: actual)
            Log.ask.notice("""
                Router (shadow): \(comparison.summary, privacy: .public) in \(String(describing: ContinuousClock.now - start), privacy: .public)\
                \(cached ? " (cached)" : "", privacy: .public)
                """)
        }
    }

    /// A problem with the question: shown by the companion, or on the tile if it was sent away.
    func report(_ message: String, for flow: QuestionFlow) {
        guard let id = flow.jobID, !flow.joined else {
            show(error: message)
            return
        }
        backgroundJobs?.fail(id, reason: message)
        Log.ask.notice("Peel failed before an answer started: \(message, privacy: .private)")
    }

    /// Checks shared by ask and explain. Shows the reason and returns false if blocked.
    func checkCanAsk(frontmost: NSRunningApplication?) -> Bool {
        if settings.blocklist.isBlocked(bundleID: frontmost?.bundleIdentifier) {
            let name = frontmost?.localizedName ?? "this app"
            Log.ask.notice("Refused: frontmost app is on the blocklist")
            show(error: "ClickBait doesn't look at \(name) — it's on your blocklist.")
            return false
        }
        guard CGPreflightScreenCaptureAccess() else {
            show(error: "Screen Recording is off. Open Permissions… from the menu bar icon.")
            return false
        }
        return true
    }

    func finish() async {
        guard state == .listening, let pressedAt, let flow = currentFlow else { return }
        defer { end(flow) }
        let held = ContinuousClock.now - pressedAt
        guard held >= Self.minimumHold else {
            cancel(reason: "hold was too short")
            return
        }

        let releasedAt = ContinuousClock.now
        try? await Task.sleep(for: Self.releaseTail)
        // A ⌃⌥ press during the tail already ended it (`endTail`).
        if flow.samples == nil {
            guard state == .listening else { return }  // cancelled meanwhile
            endTail(flow, releasedAt: releasedAt)
        }
        guard let samples = flow.samples else { return }
        let captureTask = flow.captureTask
        let snapshotTask = flow.snapshotTask

        let capture: ScreenCapture
        do {
            guard let captureTask else { throw CancellationError() }
            capture = try await captureTask.value
        } catch {
            Log.capture.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            report("Couldn't capture the screen: \(error.localizedDescription)", for: flow)
            return
        }

        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let audio = AudioConditioner.condition(samples, sampleRate: AudioRecorder.sampleRate)
        Log.ask.notice("""
            Audio level: peak \(audio.peak, format: .fixed(precision: 3), privacy: .public), \
            rms \(audio.rms, format: .fixed(precision: 4), privacy: .public), gain \(audio.gain, format: .fixed(precision: 1), privacy: .public)x\
            \(audio.isSilent ? " — silent" : "", privacy: .public)
            """)
        Log.ask.notice("""
            Captured \(samples.count, privacy: .public) samples (\(seconds, format: .fixed(precision: 2), privacy: .public)s), \
            screenshot \(capture.image.width, privacy: .public)x\(capture.image.height, privacy: .public)px \
            of display \(capture.displayID, privacy: .public) at \(capture.backingScale, privacy: .public)x
            """)

        // Highlighted code counts for a spoken question too ("why does this crash?"); other
        // selections don't, since a selection turns pointing off.
        var highlighted: String?
        if let snapshot = await snapshotTask?.value {
            highlighted = snapshot.selectedText.flatMap { CodeAnswer.looksLikeCode($0) ? $0 : nil }
            flow.context.windowTitle = snapshot.windowTitle
            flow.context.windowFrame = snapshot.windowFrame
            flow.context.focusedElement = snapshot.focusedElement
            if currentFlow === flow { context = flow.context }
        }

        // Downscale and list what's clickable while Whisper runs.
        let encoding = Task.detached(priority: .userInitiated) { try ScreenshotEncoder.encode(capture.image) }
        let pid = flow.homePID
        let elementsTask = Task { await Self.elements(in: capture, frontmostPID: pid) }

        guard !audio.isSilent else {
            report("I didn't hear anything. Check the microphone, hold ⌃⌥ and try again.", for: flow)
            return
        }
        let transcript: String
        do {
            let start = ContinuousClock.now
            transcript = try await speech.transcribe(audio.samples)
            Log.ask.notice("""
                Transcribed \(seconds, format: .fixed(precision: 2), privacy: .public)s of audio in \
                \(String(describing: ContinuousClock.now - start), privacy: .public): \(transcript.count, privacy: .public) characters
                """)
        } catch {
            Log.ask.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            report("Couldn't understand the recording: \(error.localizedDescription)", for: flow)
            return
        }

        if settings.keepDebugCaptures {
            await Task.detached(priority: .utility) {
                do {
                    try DebugCaptureStore.save(capture, samples: samples, transcript: transcript)
                } catch {
                    Log.capture.error("Debug save failed: \(error.localizedDescription, privacy: .public)")
                }
            }.value
        }

        guard !Task.isCancelled else { return }
        guard !transcript.isEmpty else {
            report("I didn't catch that. Hold Control+Option and try again.", for: flow)
            return
        }
        flow.heard = transcript
        if let id = flow.jobID { backgroundJobs?.rename(id, to: transcript) }
        // A day answers a reminder's "when?"; "cancel" drops it; anything else replaces it.
        if pendingReminder != nil {
            if let day = ReminderDay.parse(transcript) {
                encoding.cancel()
                flow.kind = .command
                guard await settleQuick(flow, resolvesPending: true) else { return }
                await resolveReminder(day)
                return
            }
            let cancelled = CommandParser.confirmation(transcript) == false
            dropPendingReminder()
            if cancelled {
                encoding.cancel()
                return
            }
        }
        // "yes" / "cancel" answers a pending question; anything else replaces it.
        if pendingAction != nil {
            if let answer = CommandParser.confirmation(transcript) {
                encoding.cancel()
                flow.kind = .command
                guard await settleQuick(flow, resolvesPending: true) else { return }
                await resolvePending(answer)
                return
            }
            dropPending()
        }
        if flow.jobID == nil { onTranscript?(transcript) }

        if NoteReference.asksToSeeNote(transcript), ActionExecutor.lastNoteID.withLock({ $0 }) != nil {
            encoding.cancel()
            flow.kind = .command
            guard await settleQuick(flow) else { return }
            let reply = await showLastNote(speak: true)
            if chatShown, let reply {
                onChatUserMessage?(transcript)
                onChatReply?(reply)
            }
            return
        }

        // "remember …" / "forget …": the user's own facts (`Memory`), no model.
        if let command = Memory.command(in: transcript) {
            encoding.cancel()
            flow.kind = .command
            guard await settleQuick(flow) else { return }
            let reply = MemoryStore.shared.reply(to: command)
            Log.ask.notice("Memory (spoken): \(reply.ok ? "done" : "not done", privacy: .public)")
            speaker.speak(reply.message)
            if reply.ok { state = .speaking; onActionDone?(reply.message) } else { show(error: reply.message) }
            return
        }

        // Direct orders run right away, without the model.
        if settings.commandsEnabled,
           let command = CommandParser.parse(transcript, allowedShortcuts: settings.allowedShortcuts),
           !isUnknownApp(command) {
            Log.ask.notice("Command recognised: \(command.name, privacy: .public)")
            encoding.cancel()
            flow.kind = .command
            guard await settleQuick(flow) else { return }
            if let action = asksFirst(command) {
                await handleOrder(action, request: command, speak: true, from: .clearOrder)
                return
            }
            _ = await perform(command)  // the outcome is already shown and spoken
            return
        }

        // An order in other words: ask the model which action it is (text only, ~1 s).
        flow.phase = .orderCheck
        let understood = await understandOrder(transcript, flow: flow)
        guard !Task.isCancelled else { return }  // Esc while checking
        if let (order, proposal) = understood {
            encoding.cancel()
            flow.kind = .command
            guard await settleQuick(flow) else { return }
            let message: String
            switch order {
            case .ready(let action): message = await handleOrder(action, request: proposal, speak: true, from: .modelGuess)
            case .failed(let reason):
                message = reason
                speaker.speak(reason)
                show(error: reason)
            }
            if chatShown {
                onChatUserMessage?(transcript)
                onChatReply?(message)
            }
            return
        }

        // "How do I…" with several clicks: walk them through it on screen.
        let elements = await elementsTask.value
        if await startTutorial(question: transcript, capture: capture, encoding: encoding, elements: elements,
                               speak: true, display: transcript, flow: flow) { return }
        flow.kind = .unknown  // not a walkthrough after all

        // With a chat open, a spoken question is a follow-up in it.
        await respond(question: transcript, selectedText: ImpliedPointer.isLocating(transcript) ? nil : highlighted, capture: capture, encoding: encoding, startedAt: releasedAt,
                      speak: true, display: transcript, elements: elements, flow: flow, highlightIsContext: true)
    }
}
