import AppKit
import AVFoundation
import ClickBaitCore
import Observation

// Answering: the model request, streaming, pointing and speaking.
extension AskCoordinator {
    // MARK: - Answering


    struct SnipMemory {
        var kind: SnipKind
        var closeUp: EncodedScreenshot
        var context: Data?
        var view: SnipView?
        var text: Task<[TextBox], Never>?
        /// The separate things in the close-up, found on this Mac, for the tour to point at.
        var objects: Task<[FoundObject], Never>?
        /// What the snip shows, looked up on Wikipedia once the reply names its subject
        /// (`startLookup`), for naming the marks. Nil with lookups off.
        var reference: Task<WikiReference?, Never>?
        /// Brought back from the dock ("go there!"): the screen may have changed since, so a
        /// tour first checks the snipped area still looks the same.
        var returnedFromBackground = false
        /// A tour placed while the snip was in the dock: "show me the parts" plays it without
        /// asking the model again (`playReadyTour`).
        var readyTour: [ScreenPointer]?
    }


    /// Shared by ask, explain and chat follow-ups: send to the model (with the open
    /// bubble's memory), stream into the bubble, parse, map, snap, show. A first
    /// message opens a new bubble; anything sent while one is open continues it.
    func respond(
        question: String,
        selectedText: String?,
        capture: ScreenCapture,
        encoding: Task<EncodedScreenshot, Error>,
        startedAt: ContinuousClock.Instant,
        speak: Bool,
        display: String,
        snip: SnipKind? = nil,
        snipContext: Data? = nil,
        elements: [ScreenElement] = [],
        flow givenFlow: QuestionFlow? = nil,
        autoPeels: Bool = false,
        highlightIsContext: Bool = false
    ) async {
        // An ⌥⌘ explanation of highlighted text or a snip (shortened, peeled when slow). Code
        // highlighted under a spoken or typed question is only its context: a normal answer.
        let explaining = (selectedText != nil && !highlightIsContext) || snip != nil
        // A walkthrough was just declined: words only — no app opened, nothing pointed at.
        let wordsOnly = answerInWordsOnly
        answerInWordsOnly = false
        if wordsOnly { Log.ask.debug("Answering in words only: the walkthrough was declined") }
        // ⌥⌘ explanations and typed follow-ups have no flow yet: this one's, so they can be peeled too.
        let flow = givenFlow ?? adHocFlow(snip: snip != nil)
        if flow.documentText == nil { flow.documentText = selectedText }
        defer { if givenFlow == nil { end(flow) } }
        // Sent to the background before this run existed: the chat, memory and conversation
        // belong to the next question (or nothing), so this one keeps its own.
        let queued = flow.jobID != nil
        let releasedAt = startedAt
        if !queued { answerStartedAt = startedAt }
        var spokeAnything = false
        guard let provider = flow.provider else {
            report("No model is set up for this question.", for: flow)
            return
        }
        var context = flow.context
        // In a browser: the page's address, read when it was asked (waits at most 0.4 s for it).
        if context.pageAddress == nil, let reading = flow.browserTab {
            let tab = await withTaskGroup(of: BrowserTab?.self) { group in
                group.addTask { await reading.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(400)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            context.pageAddress = tab.flatMap { ScreenContext.cleanAddress($0.url) }
        }
        flow.phase = .buildingRequest
        if !queued, conversation != nil, !chatShown { conversation = nil }  // an earlier pointing answer: start fresh
        let history = (queued ? flow.conversation : conversation)?.history ?? []
        // Follow-ups in a snip's chat keep looking at what was marked, not a new screenshot.
        let snipFollowUp = history.isEmpty ? nil : (queued ? flow.snipMemory : snipMemory)
        let snip = snip ?? snipFollowUp?.kind
        if queued {
            // nothing of the foreground to set up
        } else if conversation == nil {
            conversation = Conversation()
            snipMemory = nil
            if !speak {  // explain: show the bubble right away, the answer streams into it
                chatShown = true
                // Still undoable by a second tap: the chat opens once that can't happen; a
                // double tap drops it (it used to open the explanation instead of a new chat).
                if isExplainProvisional {
                    explainChat = display
                } else {
                    onChatOpen?(display)
                }
            }
        } else {
            onChatUserMessage?(display)
        }
        let answerID = queued ? UUID() : beginAnswerFlow()
        let run = AnswerRun(id: answerID, question: question, kind: snip == nil ? .answer : .snip,
                            homeBundleID: flow.homeBundleID, homePID: flow.homePID,
                            display: display, conversation: (queued ? flow.conversation : conversation) ?? Conversation())
        run.task = queued ? flow.task : askTask
        run.snipMemory = queued ? flow.snipMemory : snipMemory
        flow.run = run
        if !queued { activeAnswerRun = run }
        defer {
            finishAnswering(answerID)
            if activeAnswerRun?.id == answerID { activeAnswerRun = nil }
        }
        // "… in Safari" while another app is in front: look at Safari's buttons, not the
        // front app's (the first "show me the share button in Safari" looked in the wrong app).
        var elements = elements
        var capture = capture
        var encoding = encoding
        // "Show me the Share button in Safari" with Safari closed or behind: open or switch
        // to it first (green), take a fresh look, then point (blue).
        // Only when the request says so ("in Safari", "open Messages"): an app's name in a
        // sentence is just a word (`TutorialQuestion.locatingApp`).
        var switchedApp = false
        if !wordsOnly, snip == nil, selectedText == nil, history.isEmpty, flow.jobID == nil, TutorialQuestion.isLocatingRequest(question) {
            let apps = AppLocator.installed()
            // A menu bar item that's also an app's name (Control Center): point at the item, never
            // open the app (it opened macOS's Control Center app: test drive, 2026-10-24).
            let barNames = await Task.detached(priority: .userInitiated) {
                Set(AXInspector.menuExtras().map { LabelMatcher.sameSpelling(ImpliedPointer.normalized($0.label)) })
            }.value
            if let named = TutorialQuestion.locatingApp(in: question, apps: Array(apps.keys)),
               named.caseInsensitiveCompare(context.appName ?? "") != .orderedSame,
               !barNames.contains(LabelMatcher.sameSpelling(ImpliedPointer.normalized(named))),
               let ready = await openForTutorial(named, url: apps[named]) {
                let screenshot = ready.1
                capture = ready.0
                encoding = Task { screenshot }
                elements = ready.2
                switchedApp = true
                Log.ask.notice("Opened the app the question names, then looking (\(elements.count, privacy: .public) elements)")
            }
            if !switchedApp, TutorialQuestion.mentionedApp(in: question, apps: Array(apps.keys)) != nil,
               TutorialQuestion.locatingApp(in: question, apps: Array(apps.keys)) == nil {
                Log.ask.debug("An app's name in the question, not asked to go there: staying in the app in front")
            }
        }
        // "Where's the Share button?" with exactly one element named Share on screen: point
        // now (~0.1 s), not after the model (~8 s). The model still answers in words; its own
        // pointers are only used when there was no exact, single match.
        var instant: [ScreenPointer]?
        // "Point to October 27th", "today's date": content, not a control. The element list
        // only holds controls, so a pick from it lands on the nearest button ("Today",
        // "View"); the screenshot can see the day.
        let namesContent = InstantAnswer.namesContent(question)
        let targets = !wordsOnly && snip == nil && selectedText == nil && !namesContent ? InstantAnswer.locateTargets(in: question) : []
        if namesContent { Log.ask.notice("Finding content (a date, day or event), not a control: reading the screen") }
        // The menu bar's right side too (Control Center, Wi-Fi, the clock): the app's own list never
        // has them, and the model pointed at the middle of the menu bar (test drive, 2026-10-24).
        let barItems = targets.isEmpty ? [] : await Task.detached(priority: .userInitiated) { AXInspector.menuExtras() }.value
        let found = targets.compactMap {
            InstantAnswer.uniqueElement(named: $0, in: elements) ?? InstantAnswer.closeElement(named: $0, in: elements)
                ?? InstantAnswer.uniqueElement(named: $0, in: barItems) ?? InstantAnswer.closeElement(named: $0, in: barItems)
        }
        // "Where do I type?": the focused field's caret, exact and instant, before any model —
        // in the app that was in front when asked, never one switched to on the way.
        let pidForCaret = flow.homePID
        let caret = !wordsOnly && snip == nil && selectedText == nil && !switchedApp && InstantAnswer.asksWhereToType(question)
            ? await Task.detached(priority: .userInitiated) { pidForCaret.flatMap { AXInspector.caretRect(pid: $0) } }.value
            : nil
        if let caret {
            let spot = Point(x: caret.minX + 6, y: caret.midY)
            instant = [ScreenPointer(label: "type here", appKit: Point(x: spot.x, y: Double(capture.primaryDisplayHeight) - spot.y),
                                     quartz: spot)]
            Log.ask.notice("Instant pointer: the text caret (where typing goes)")
            flow.kind = .instantPick
            guard await settleQuick(flow) else { return }
            if let instant { onInstantPointer?(instant) }
        } else if !targets.isEmpty, found.count == targets.count {  // every one named exactly once, or none at all
            instant = found.map { element in
                let center = Point(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
                return ScreenPointer(label: element.label, appKit: Point(x: center.x, y: Double(capture.primaryDisplayHeight) - center.y),
                                     quartz: center)
            }
            Log.ask.notice("Instant pointer: \(found.count, privacy: .public) element(s) named exactly that")
            flow.kind = .instantPick
            guard await settleQuick(flow) else { return }
            if let instant { onInstantPointer?(instant) }
        } else if !wordsOnly, !elements.isEmpty, snip == nil, selectedText == nil, !namesContent,
                  !targets.isEmpty || InstantAnswer.allowsUnnamedPick(question) {
            // Any "where / which / what do I click" question, not only "where's the X": the
            // answer is usually something in the list ("where do I type my message?").
            // Not named exactly: let the model pick from the element list as text (~1.5 s)
            // rather than read the screenshot (~9 s). Nothing fits → the screenshot as before.
            let listed = PromptElement.list(elements, geometry: capture.geometry(imageWidth: Int(capture.displayFrame.width),
                                                                                   imageHeight: Int(capture.displayFrame.height)),
                                            question: question, limit: 80)  // text only: a longer list is cheap
            var pick = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                                  context: context, elements: listed)
            pick.pickElement = true
            let pickStart = ContinuousClock.now
            flow.phase = .elementPick
            let reply = await Self.reply(from: provider, to: pick, within: ProviderOperation.selectElement.timeout)
            flow.phase = .buildingRequest
            let chosen = InstantAnswer.pickedIDs(in: reply ?? "").compactMap { id -> ScreenElement? in
                guard let listing = listed.first(where: { $0.id == id }) else { return nil }
                return elements.first(where: { $0.label == listing.label })
            }
            // "Back and forward": one element for each thing named, or the screenshot. And
            // each must plausibly be the thing named, or the model settled for a neighbour.
            let fits = targets.isEmpty
                ? chosen.allSatisfy { InstantAnswer.unnamedPick($0.label, fits: question) }
                : chosen.count == targets.count && zip(chosen, targets).allSatisfy { InstantAnswer.pick($0.label, fits: $1) }
            if !chosen.isEmpty {
                Log.ask.notice("Pick for \(targets.isEmpty ? "(no named target)" : targets.joined(separator: " + "), privacy: .public): \(chosen.map { "\"\($0.label)\"" }.joined(separator: ", "), privacy: .public)\(fits ? "" : " — doesn't fit, reading the screen instead", privacy: .public)")
            }
            if !chosen.isEmpty, fits {
                instant = chosen.map { element in
                    let center = Point(x: element.frame.x + element.frame.width / 2, y: element.frame.y + element.frame.height / 2)
                    return ScreenPointer(label: element.label, appKit: Point(x: center.x, y: Double(capture.primaryDisplayHeight) - center.y),
                                         quartz: center)
                }
                Log.ask.notice("Picked \(chosen.count, privacy: .public) from the element list in \(String(describing: ContinuousClock.now - pickStart), privacy: .public)")
                flow.kind = .instantPick
                guard await settleQuick(flow) else { return }
                if let instant { onInstantPointer?(instant) }
            } else {
                Log.ask.notice("Nothing among \(listed.count, privacy: .public) listed elements fits (\(String(describing: ContinuousClock.now - pickStart), privacy: .public)); looking at the screen")
            }
        } else if !targets.isEmpty {
            Log.ask.notice("Instant pointer: no single exact match among \(elements.count, privacy: .public) elements; asking the model")
        }
        if flow.jobID == nil { pointedInstantly = instant != nil }
        // Pointed already: the model would only add a sentence (~8 s of the GPU, and the
        // next question waited behind it). Say so ourselves and stop here.
        if let instant {
            encoding.cancel()
            let names = instant.map(\.label).joined(separator: " and ")
            let response = AssistantResponse(speech: "Here's \(names).")
            if speak { speaker.speak(response.speech) }
            if !flow.sentAway { conversation?.append(user: question, assistantSpeech: response.speech) }
            if state == .thinking { state = .idle }
            Log.ask.notice("Answered instantly, without the model")
            onAnswer?(response, instant)
            return
        }
        // "Find that note about the dentist", "find the march invoice": smart search on this
        // Mac (`SearchIndex`), not the model; the reply links each thing found.
        // Any time in a chat, spoken or typed: a search question stands on its own.
        if snip == nil, let search = SmartSearch.request(in: question) {
            encoding.cancel()
            let found = await SearchIndex.shared.search(search, notchNote: settings.notchNote, photos: settings.searchPhotos,
                                                            brain: settings.ollamaModel)
            let headline = SmartSearch.headline(found, for: search)
            if speak { speaker.speak(headline) }
            // The chat keeps the full list, so "open the second one" can follow.
            if !flow.sentAway { conversation?.append(user: question, assistantSpeech: SmartSearch.reply(found, for: search)) }
            if state == .thinking { state = .idle }
            // Spoken: the results need the chat to show in (a spoken answer doesn't open it).
            if !chatShown, !found.isEmpty, flow.jobID == nil {
                chatShown = true
                onChatOpen?(display)
            }
            onAnswer?(AssistantResponse(speech: headline), [])
            onSearchResults?(found)
            return
        }
        // "How many days until Christmas?", "what's the date?": worked out here, exactly, in
        // under 0.1 s. The model has no clock and counted 30 days instead of 66 (2026-10-20).
        if snip == nil, selectedText == nil, history.isEmpty, let answer = DateFacts.instantAnswer(question, now: Date()) {
            encoding.cancel()
            let response = AssistantResponse(speech: answer)
            if speak { speaker.speak(response.speech) }
            if !flow.sentAway { conversation?.append(user: question, assistantSpeech: response.speech) }
            if state == .thinking { state = .idle }
            Log.ask.notice("Answered a date question instantly, without the model")
            onAnswer?(response, [])
            return
        }
        // Internet Mode (🌐): online only when the user's words ask (spec decision 3), never
        // for snips (their subject lookup is separate) or pointing. Starts now, alongside the
        // screenshot's encoding.
        let lookupReason = snip == nil && !question.isEmpty && !ImpliedPointer.isLocating(question)
            ? WebLookup.reason(for: question, selectedText: selectedText) : nil
        var webNote: String?
        var webCredit: String?
        var lookup: Task<WebLookupResult, Never>?
        if let lookupReason {
            if settings.internet.isOn {
                let capturedImage = capture
                setStage(.lookingUp, of: flow)
                lookup = Task {
                    await lookUp(question: question, reason: lookupReason, selectedText: selectedText,
                                 capture: capturedImage, history: history, provider: provider)
                }
            } else if lookupReason == .asked {
                webNote = "Internet's off. Switch to 🌐 in the menu bar to look things up."
                Log.ask.notice("Lookup asked for with Internet Mode off: answering locally")
            }
        }
        defer { lookup?.cancel() }
        let reply: String
        let screenshot: EncodedScreenshot
        var request: AskRequest
        var listed: [PromptElement] = []
        do {
            if let snipFollowUp {
                encoding.cancel()
                screenshot = snipFollowUp.closeUp
            } else {
                screenshot = try await encoding.value
            }
            if let snip, history.isEmpty {
                let pending = flow.pendingSnipView
                let memory = SnipMemory(kind: snip, closeUp: screenshot, context: snipContext,
                                        view: pending?.view, text: pending?.text, objects: pending?.objects)
                flow.pendingSnipView = nil
                if flow.jobID == nil {
                    snipMemory?.objects?.cancel()
                    snipMemory = memory
                } else {  // sent away: the foreground's memory is the next question's
                    flow.snipMemory?.objects?.cancel()
                    flow.snipMemory = memory
                }
            }
            // Only "where/how/click…" questions need something to point at; for the rest
            // the list would just slow the local model down. Never for snips.
            if snip == nil, ImpliedPointer.isLocating(question) || !history.isEmpty {
                listed = PromptElement.list(elements, geometry: capture.geometry(imageWidth: screenshot.width, imageHeight: screenshot.height),
                                            question: question, limit: Self.maxListedElements)
            }
            if !elements.isEmpty {
                Log.ask.notice("Element list: offering \(listed.count, privacy: .public) of \(elements.count, privacy: .public)")
            }
            request = AskRequest(
                question: question,
                screenshotJPEG: screenshot.jpeg,
                screenshotWidth: screenshot.width,
                screenshotHeight: screenshot.height,
                context: context,
                selectedText: selectedText,
                history: history,
                snip: snip,
                elements: listed
            )
            request.contextJPEG = snipFollowUp?.context ?? snipContext
            request.codeAnswer = snip == nil && !ImpliedPointer.isLocating(question)
                && CodeAnswer.wanted(question: question, selectedText: selectedText)
            if flow.jobID != nil { flow.modelTurn.sendToBackground() }
            request.turn = flow.modelTurn
            request.detailed = nextTypedIsDetailed
            nextTypedIsDetailed = false
            if snip != nil {
                request.snipWords = flow.snipWords
                request.snipMarked = flow.snipMarked
            }
            if request.codeAnswer { Log.ask.notice("Code question: answering in Markdown") }
            request.remembered = await MemoryStore.shared.block(for: question)
            request.askSubject = snip != nil && history.isEmpty && settings.internet.isOn
            if let lookup {
                // What the lookup found within its ~4 s; a question not about the screen is
                // then answered text-only (faster).
                let result = await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
                request.web = result.passages
                request.webQuery = result.query
                if result.passages.isEmpty {
                    webNote = "Couldn't reach the web, so this is from what I know."
                } else {
                    webCredit = result.credit
                    if !result.needsScreen { request.screenshotJPEG = Data(); request.elements = [] }
                }
            }
            // A plain question about the world: the model answers it the same from text, ~6 s
            // sooner (reading the screenshot is most of its time).
            if !request.screenshotJPEG.isEmpty,
               ScreenNeed.isAboutTheWorld(question, selectedText: selectedText, snipped: snip != nil, followUp: !history.isEmpty) {
                request.screenshotJPEG = Data()
                request.elements = []
                Log.ask.notice("About the world, not the screen: asking without the screenshot")
            }
            // The conversation so far wasn't about the screen ("who is Steve Jobs?"), and the
            // follow-up doesn't name it ("elaborate"): no screenshot, or it described the screen.
            // "tell me more" is about the last answer whatever it was about.
            if snip == nil, !history.isEmpty, !request.screenshotJPEG.isEmpty, !ScreenNeed.followUpNeedsScreen(question),
               (queued ? flow.conversation : conversation)?.lastOffScreen == true || request.detailed || ScreenNeed.asksForMore(question) {
                request.screenshotJPEG = Data()
                request.elements = []
                Log.ask.notice("Follow-up about the last answer, not the screen: asking without the screenshot")
            }
            // A follow-up on an unchanged screen: the first question's screenshot, which Ollama
            // has already read, instead of a new one (~1.3 s sooner). Any change: a new one.
            if !queued, snip == nil, !history.isEmpty, !request.screenshotJPEG.isEmpty {
                let fresh = ScreenChange.thumbnail(of: capture.image)
                let differing = conversation?.screen.map { first in zip(first.thumbnail, fresh).filter { abs(Int($0) - Int($1)) > ScreenChange.tolerance }.count }
                Log.ask.notice("Follow-up screen: first kept \(self.conversation?.screen != nil, privacy: .public), \(differing ?? -1, privacy: .public) thumbnail pixels differ")
            }
            if !queued, snip == nil, !history.isEmpty, !request.screenshotJPEG.isEmpty,
               let first = conversation?.screen, first.width == screenshot.width, first.height == screenshot.height,
               ScreenChange.same(first.thumbnail, ScreenChange.thumbnail(of: capture.image)) {
                request.screenshotJPEG = Data()
                request.sameScreen = true
                request.history = conversation?.historyReusingScreen ?? history
                Log.ask.notice("Follow-up on an unchanged screen: reusing the first screenshot")
            }
            setStage(request.screenshotJPEG.isEmpty && !request.sameScreen ? .thinking : .readingScreen, of: flow)
            let answerProvider: any LLMProvider
            if settings.internet.isOn, settings.geminiInternetAnswers,
               let key = GeminiKeyStore.read(),
               request.screenshotJPEG.isEmpty, request.contextJPEG == nil, request.selectedText == nil,
               request.history.isEmpty, request.snip == nil,
               request.webQuery != nil, !request.web.isEmpty {
                answerProvider = GeminiInternetFallbackProvider(apiKey: key, fallback: provider)
                Log.ask.notice("Internet answer: trying Gemini with the cleaned query and retrieved excerpts only")
            } else {
                answerProvider = provider
            }
            Log.ask.notice("""
                Asking \(answerProvider.displayName, privacy: .public) with a \(screenshot.width, privacy: .public)x\(screenshot.height, privacy: .public) \
                JPEG (\(screenshot.jpeg.count / 1024, privacy: .public) KB, downscale \(screenshot.downscale, format: .fixed(precision: 3), privacy: .public))
                """)
            var text = ""
            var firstChunkAt: ContinuousClock.Instant?
            var extractor = StreamingSpeechExtractor()
            var sentences = SentenceSplitter()
            var codeFilter = CodeFenceFilter()  // code is shown, never read aloud
            var spokenSoFar = ""
            var isFirstSentence = true
            // Explanations shouldn't open with "The highlighted text refers to…".
            let tidy: (String) -> String = { explaining ? ExplanationCleaner.clean($0) : $0 }
            // The chat shows the words as they come, but at most ~12 times a second: redrawing
            // and resizing it for every fragment made the companion stutter while answering.
            var lastPartial = ContinuousClock.now - .seconds(1)
            run.snipMemory = flow.jobID == nil ? snipMemory : flow.snipMemory
            flow.phase = .streaming
            if let jobID = flow.jobID, !flow.joined {
                attach(run, to: flow, appendingQuestion: queued)
                Log.ask.notice("Peel joined: \(jobID.uuidString, privacy: .public)")
            }
            // A first highlight or snip explanation, or a clicked suggestion, goes to the dock by itself when slow.
            // Explanations, snips, clicked suggestions and code answers (the slowest) go to the
            // dock after 1 s or when the user moves on, whichever comes first.
            if !queued, autoPeels || (history.isEmpty && explaining) || request.codeAnswer { scheduleAutoPeel(flow, run) }
            if backgroundJobs?.entries.contains(where: { $0.job.isWorking && $0.id != flow.jobID }) == true {
                Log.ask.notice("Foreground answer submitted while Ollama is serving a background capsule; Ollama will queue it")
            }
            // A first snip explanation opens with its subject: with lookups on, it's looked up
            // while the rest streams, ready for naming the marks after the answer.
            var lookingUp = !request.askSubject
            for try await chunk in answerProvider.stream(request) {
                if firstChunkAt == nil { firstChunkAt = .now }
                text += chunk
                if !lookingUp, case .foreground = run.destination, let subject = StreamingSubject.subject(in: text) {
                    lookingUp = true
                    startLookup(subject)
                } else if !lookingUp, text.contains("\"speech\"") {
                    lookingUp = true  // no subject before the explanation: nothing to look up
                }
                let newSpeech = extractor.feed(chunk)
                if case .background(let jobID) = run.destination {
                    backgroundJobs?.append(chunk, speech: newSpeech, to: jobID)
                } else if !newSpeech.isEmpty, !Task.isCancelled {
                    spokenSoFar += newSpeech
                    if chatShown, ContinuousClock.now - lastPartial >= .milliseconds(80) {
                        lastPartial = .now
                        onPartialAnswer?(CoordinateScrubber.partial(tidy(spokenSoFar)))
                    }
                    for sentence in sentences.feed(codeFilter.feed(newSpeech)) where speak {
                        speaker.speak(isFirstSentence ? tidy(sentence) : sentence)
                        isFirstSentence = false
                        spokeAnything = true
                    }
                }
            }
            if case .foreground = run.destination, speak, !Task.isCancelled {
                for sentence in sentences.feed(codeFilter.flush()) {
                    speaker.speak(isFirstSentence ? tidy(sentence) : sentence)
                    isFirstSentence = false
                    spokeAnything = true
                }
            }
            if case .foreground = run.destination, speak, !Task.isCancelled, let rest = sentences.flush() {
                speaker.speak(isFirstSentence ? tidy(rest) : rest)
                spokeAnything = true
            }
            // A cancelled stream just ends; don't treat it as an (empty) answer.
            guard !Task.isCancelled else { return }
            reply = text
            let firstChunk = firstChunkAt.map { String(describing: $0 - releasedAt) } ?? "none"
            Log.ask.notice("""
                Reply: first chunk \(firstChunk, privacy: .public) after release, complete after \
                \(String(describing: ContinuousClock.now - releasedAt), privacy: .public), \(reply.count, privacy: .public) characters
                """)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Log.ask.error("Provider failed: \(error.localizedDescription, privacy: .public)")
            if case .background(let jobID) = run.destination {
                backgroundJobs?.fail(jobID, reason: error.localizedDescription)
                return
            }
            // Sent away but not joined yet: the tile shows it, not the next question's companion.
            if flow.jobID != nil {
                report(error.localizedDescription, for: flow)
                return
            }
            if state == .thinking { state = .idle }
            if chatShown {
                onChatError?(error.localizedDescription)
            } else {
                conversation = nil
                show(error: error.localizedDescription)
            }
            return
        }

        if settings.keepDebugCaptures {
            DebugCaptureStore.saveReply(reply)
        }

        if case .background(let jobID) = run.destination {
            var parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height, elements: listed,
                                             scale: provider.coordinateScale)
            if explaining { parsed.response.speech = ExplanationCleaner.limited(ExplanationCleaner.clean(parsed.response.speech)) }
            run.conversation.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech,
                                    code: parsed.response.code, language: parsed.response.language)
            var finalText = parsed.response.displayText + (webCredit.map { "\n\n" + $0 } ?? "")
            // A snip in the dock places its tour there too: it waits for "show me the parts".
            var tourReady = false
            var hasSnipParts = false
            if snip != nil, let memory = run.snipMemory, let view = memory.view {
                var named = parsed.response.parts + parsed.response.pointers
                // Foreground snips already get a focused parts-only second look when the
                // explanation omits names. Do the same after auto-peeling; otherwise the
                // dock answer has no tour to offer even when the close-up has clear parts.
                if named.isEmpty, history.isEmpty {
                    var partsRequest = AskRequest(question: parsed.response.speech, screenshotJPEG: memory.closeUp.jpeg,
                                                  screenshotWidth: memory.closeUp.width, screenshotHeight: memory.closeUp.height,
                                                  context: request.context)
                    partsRequest.listParts = true
                    partsRequest.snipMarked = view.marked
                    partsRequest.snipWords = request.snipWords
                    let start = ContinuousClock.now
                    if let reply = await Self.reply(from: provider, to: partsRequest,
                                                    within: ProviderOperation.labelTourParts.timeout), !Task.isCancelled {
                        named = ResponseParser.parse(reply, imageWidth: memory.closeUp.width, imageHeight: memory.closeUp.height,
                                                     scale: provider.coordinateScale).response.parts
                        Log.ask.notice("Parts: background second look found \(named.count, privacy: .public) names in \(String(describing: ContinuousClock.now - start), privacy: .public)")
                    } else {
                        Log.ask.notice("Parts: background second look unavailable")
                    }
                }
                hasSnipParts = !named.isEmpty
                if hasSnipParts, await !isLabelled(named, memory: memory, view: view), !Task.isCancelled {
                    let placed = await placeTour(named, explanation: parsed.response.speech, memory: memory, view: view,
                                                 provider: provider)
                    if !placed.tour.isEmpty, !Task.isCancelled {
                        var ready = memory
                        ready.readyTour = placed.tour
                        backgroundJobs?.setSnipMemory(ready, for: jobID)
                        if let credit = placed.credit { finalText += "\n\n" + credit }
                        tourReady = true
                    }
                }
            }
            guard !Task.isCancelled else { return }
            settleChat(of: run, finalText: finalText)
            backgroundJobs?.setChatMessages(run.chatMessages, for: jobID)
            if tourReady || (snip != nil && history.isEmpty && hasSnipParts) {
                backgroundJobs?.setLeadingSuggestion(PeelRule.suggestedPartsPrompt, for: jobID)
            }
            backgroundJobs?.complete(jobID, answer: finalText, conversation: run.conversation)
            return
        }

        var parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height, elements: listed,
                                         scale: provider.coordinateScale)
        if explaining { parsed.response.speech = ExplanationCleaner.limited(ExplanationCleaner.clean(parsed.response.speech)) }
        // From here a peeled snip keeps its explanation and skips the tour.
        run.explanation = parsed.response.displayText
        let userText = Prompt.userText(for: request), speech = parsed.response.speech
        let code = parsed.response.code, language = parsed.response.language
        run.recordTurn = { $0.append(user: userText, assistantSpeech: speech, code: code, language: language) }
        if snip != nil { flow.phase = .explained }
        // An ⌥⌘ explanation is about the text or area, never about where to click (and a
        // snip's close-up has no screen coordinates anyway).
        // A snip's "where is X?" may come back as pointers: treat them as parts (they're in
        // the close-up's pixels, not the screen's).
        let snipPointers = snip != nil ? parsed.response.pointers : []
        if explaining, !parsed.response.pointers.isEmpty {
            Log.ask.notice("Explain: ignoring \(parsed.response.pointers.count, privacy: .public) pointer(s) the model added")
            parsed.response.pointers = []
        }
        // Only "where / how / show me / click / open" questions get pointed at; the model
        // sometimes adds a pointer to anything (a corner of the screen for a general question).
        if snip == nil, selectedText == nil, !parsed.response.pointers.isEmpty, wordsOnly || !InstantAnswer.allowsPointing(question) {
            Log.ask.notice("Dropped \(parsed.response.pointers.count, privacy: .public) pointer(s): not a where/how question")
            parsed.response.pointers = []
        }
        // Asked where something is, the answer names a listed element but doesn't point.
        // Only for an explicit where-question, and only a control the user's own words name:
        // otherwise any control the reply mentions got pointed at (the menu bar, 2026-10-14).
        if !wordsOnly, snip == nil, selectedText == nil, parsed.response.pointers.isEmpty, InstantAnswer.allowsPointing(question),
           let implied = ImpliedPointer.find(question: question, speech: parsed.response.speech, elements: listed) {
            if InstantAnswer.unnamedPick(implied.label, fits: question) {
                Log.ask.notice("Pointer taken from the element list: the answer named it without pointing")
                parsed.response.pointers = [implied]
            } else {
                Log.ask.debug("Not pointing at a control only the answer names")
            }
        }
        let geometry = capture.geometry(imageWidth: screenshot.width, imageHeight: screenshot.height)
        let modelPointers = parsed.response.pointers.map { pointer in
            let pixel = Point(x: pointer.x, y: pointer.y)
            return ScreenPointer(
                label: pointer.label,
                appKit: geometry.appKitPoint(fromImagePixel: pixel),
                quartz: geometry.quartzPoint(fromImagePixel: pixel)
            )
        }
        // Pointers on a listed element's exact center came from the app's own data:
        // nothing to snap or double-check.
        let fromList = parsed.response.pointers.map { pointer in listed.contains { $0.isCenter(of: pointer) } }
        let checked = await snap(zip(modelPointers, fromList).filter { !$0.1 }.map(\.0), geometry: geometry)
        var remaining = checked[...]
        let snapped = zip(modelPointers, fromList).map { pointer, listedCenter in
            listedCenter ? (pointer: pointer, confirmed: true) : remaining.popFirst() ?? (pointer: pointer, confirmed: false)
        }
        if fromList.contains(true) {
            Log.ask.notice("\(fromList.filter { $0 }.count, privacy: .public) pointer(s) on a listed element: exact")
        }
        let pointers = instant ?? snapped.map(\.pointer)
        flow.pointed = !pointers.isEmpty
        Log.ask.notice("""
            Parsed reply: fallback=\(parsed.usedFallback, privacy: .public), \
            \(pointers.count, privacy: .public) pointer(s), \(parsed.droppedPointers, privacy: .public) dropped
            """)
        for (pointer, mapped) in zip(parsed.response.pointers, modelPointers) {
            Log.ask.notice("""
                Pointer image px (\(pointer.x, format: .fixed(precision: 0), privacy: .public), \
                \(pointer.y, format: .fixed(precision: 0), privacy: .public)) → screen \(mapped.quartz.description, privacy: .public) \
                (Quartz), \(mapped.appKit.description, privacy: .public) (AppKit)
                """)
        }
        guard !Task.isCancelled else { return }
        // No streamed "speech" field (e.g. plain-text fallback): speak the parsed answer.
        if speak, !spokeAnything {
            var sentences = SentenceSplitter()
            sentences.feed(MessageFormat.spokenText(parsed.response.speech)).forEach(speaker.speak)
            sentences.flush().map(speaker.speak)
        }
        run.conversation.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech,
                                code: parsed.response.code, language: parsed.response.language)
        run.conversation.lastOffScreen = snip == nil && request.screenshotJPEG.isEmpty && !request.sameScreen
        if snip == nil, !request.screenshotJPEG.isEmpty {
            run.conversation.remember(.init(jpeg: request.screenshotJPEG, width: screenshot.width, height: screenshot.height,
                                            thumbnail: ScreenChange.thumbnail(of: capture.image)))
        }
        run.recordTurn = nil  // recorded: a peel from here on must not add it again
        if answerFlowID == answerID { conversation = run.conversation }
        // The answer lives in the chat bubble now; the companion goes back to its arrowhead.
        if state == .thinking || state == .speaking { state = .idle }
        if snip == nil { flow.phase = .explained }  // an answer stays peelable until here
        // Snips: tour the named parts of what was marked — but only when the names aren't
        // already printed in the image (then a tour adds nothing). Where they are is worked
        // out after the answer is shown (`PartPlacer`): on things found on this Mac where it
        // can, else the model's own guesses, so every pill is marked approximate: "~ jupiter".
        var named: [Pointer] = []
        var needsPartsLook = false
        if snip != nil, let memory = snipMemory, let view = memory.view {
            let candidates = parsed.response.parts + snipPointers
            let labelled = await isLabelled(candidates, memory: memory, view: view)
            guard !Task.isCancelled, answerFlowID == answerID else { return }
            // Nothing named at all in a first explanation: a focused second look follows.
            needsPartsLook = !labelled && candidates.isEmpty && history.isEmpty
            if !labelled { named = candidates }
            run.expectsTour = !named.isEmpty || needsPartsLook
        }
        // A reply a pill can say ("Yep, it's on!") opens no chat: the companion says it.
        // Web answers always go to the chat, where their sources can show (spec decision 11).
        if !chatShown, pointers.isEmpty,
           !PillText.fits(parsed.response.speech, code: parsed.response.code) || webCredit != nil || webNote != nil {
            chatShown = true
            onChatOpen?(display)
        }
        onAnswer?(parsed.response, pointers)
        if let webNote { onChatSource?(webNote) }
        if let webCredit { onChatSource?(webCredit) }
        // A snip stays red and spinning until its parts are pointed at; with nothing more to
        // look for, it ends here.
        if snip != nil, named.isEmpty, !needsPartsLook { onSnipAnswering?(false) }

        // Place the named parts and tour them, while the user reads. An explanation that came
        // back without parts (a 7B model often forgets them while writing) is asked once
        // more, just for the parts, first.
        if !named.isEmpty || needsPartsLook, let memory = snipMemory, let view = memory.view, let provider = self.provider {
            defer { if answerFlowID == answerID { onSnipAnswering?(false) } }
            finishAnswering(answerID)
            beginRefining(answerID)
            defer { finishRefining(answerID) }
            if needsPartsLook {
                flow.phase = .partsLook
                var partsRequest = AskRequest(question: parsed.response.speech, screenshotJPEG: memory.closeUp.jpeg,
                                              screenshotWidth: memory.closeUp.width, screenshotHeight: memory.closeUp.height,
                                              context: context)
                partsRequest.listParts = true
                let start = ContinuousClock.now
                guard let reply = await Self.reply(from: provider, to: partsRequest,
                                                   within: ProviderOperation.labelTourParts.timeout), !Task.isCancelled else { return }
                named = ResponseParser.parse(reply, imageWidth: memory.closeUp.width, imageHeight: memory.closeUp.height,
                                             scale: provider.coordinateScale).response.parts
                Log.ask.notice("""
                    Parts look: \(named.count, privacy: .public) named (\(String(describing: ContinuousClock.now - start), privacy: .public)) \
                    in a \(memory.closeUp.width, privacy: .public)×\(memory.closeUp.height, privacy: .public) close-up, marked \
                    \(Int(view.marked.minX), privacy: .public),\(Int(view.marked.minY), privacy: .public)–\
                    \(Int(view.marked.maxX), privacy: .public),\(Int(view.marked.maxY), privacy: .public), scale \
                    \(String(describing: provider.coordinateScale), privacy: .public)
                    """)
            }
            flow.phase = .tourPrep
            let placed = await placeTour(named, explanation: parsed.response.speech, memory: memory, view: view,
                                         provider: provider)
            if let credit = placed.credit { onChatSource?(credit) }
            let tour = placed.tour
            guard !tour.isEmpty, !Task.isCancelled, answerFlowID == answerID else { return }
            if memory.returnedFromBackground, await !stillShows(view) {
                guard !Task.isCancelled, answerFlowID == answerID else { return }
                Log.ask.notice("Parts: the snipped area has changed since it was sent away; no tour")
                onQuickEnding?(PeelRule.movedPill, .capture, true)
                return
            }
            guard !Task.isCancelled, answerFlowID == answerID else { return }
            flow.phase = .tour
            onTour?(tour)
        }

        // Pointers no accessibility element backs up: the triangle is already on its
        // way to the rough spot; take a sharp, zoomed-in look and nudge it if needed.
        guard snapped.contains(where: { !$0.confirmed }), let provider = self.provider else { return }
        // The answer is done: the next question mustn't wait for this.
        finishAnswering(answerID)
        beginRefining(answerID)
        defer { finishRefining(answerID) }
        var refined: [ScreenPointer?] = pointers
        for (index, item) in snapped.enumerated() where !item.confirmed {
            guard !Task.isCancelled else { return }
            switch await refine(item.pointer, question: question, capture: capture, geometry: geometry, provider: provider) {
            case .keep: break
            case .moved(let better): refined[index] = better
            case .rejected: refined[index] = nil
            }
        }
        let kept = refined.compactMap { $0 }
        guard !Task.isCancelled, answerFlowID == answerID, kept != pointers else { return }
        if kept.count < pointers.count {
            Log.ask.notice("Close-up: withdrew \(pointers.count - kept.count, privacy: .public) pointer(s) that matched nothing on screen")
        }
        onPointersRefined?(kept)
    }

    /// Whether a tour of these parts adds nothing: the snip is mostly text (a paragraph,
    /// code), or the names are already printed in it. Only unlabelled figures, diagrams,
    /// drawings and charts get a tour.
    func isLabelled(_ candidates: [Pointer], memory: SnipMemory, view: SnipView) async -> Bool {
        var text: [TextBox] = []
        if let reading = memory.text { text = await TextReader.read(reading, within: .milliseconds(1500)) }
        let printed = PartsMatcher.match(parts: candidates, speech: "", text: text).verified
        let share = await PartPlacer.colourfulShare(of: view)
        let mostlyText = PartsTour.isMostlyText(text, marked: view.marked, colourfulShare: share)
        let labelled = mostlyText || (!printed.isEmpty && printed.count * 2 >= max(candidates.count, 1))
        Log.ask.notice("""
            Parts: \(candidates.count, privacy: .public) named, \(printed.count, privacy: .public) printed in the image \
            (\(mostlyText ? "text, no tour" : labelled ? "labelled, no tour" : "unlabelled", privacy: .public))
            """)
        return labelled
    }

    /// Where the named parts are (`PartPlacer`) and the tour through them on screen. The
    /// credit line when Wikipedia helped name them. Empty when nothing could be placed.
    func placeTour(_ named: [Pointer], explanation: String, memory: SnipMemory, view: SnipView,
                           provider: any LLMProvider) async -> (tour: [ScreenPointer], credit: String?) {
        let placing = ContinuousClock.now
        let objects = await memory.objects?.value ?? []
        let reference = await memory.reference?.value
        let placement = await PartPlacer.place(named, explanation: explanation, view: view, objects: objects,
                                               reference: reference, provider: provider)
        let credit = placement.usedReference ? reference?.credit : nil
        guard !placement.stops.isEmpty, !Task.isCancelled else { return ([], credit) }
        let tour = await Self.tourPointers(placement.stops, outlines: placement.outlines, in: view)
        Log.ask.notice("Parts: tour of \(tour.count, privacy: .public) stop(s) by \(placement.method, privacy: .public) starts \(String(describing: ContinuousClock.now - placing), privacy: .public) after the explanation")
        return (tour, credit)
    }

    enum RefineResult {
        /// Leave the rough pointer (nothing to check it against).
        case keep
        case moved(ScreenPointer)
        /// It points at something that isn't what was asked for: take it away.
        case rejected
    }

    /// Checks a point with Accessibility: snaps onto an element whose name matches the
    /// label. `rejected` when Accessibility can see what's there and it's something
    /// else; nil when Accessibility can't see the area (no way to check).
    func verify(_ point: Point, label: String, geometry: ScreenGeometry) async -> RefineResult? {
        guard AXInspector.isTrusted, !label.isEmpty else { return nil }
        let pid = frontmostPID
        let (candidates, probe) = await Task.detached(priority: .userInitiated) {
            AXInspector.candidates(around: point, frontmostPID: pid)
        }.value
        let decision = Snapper.decide(target: point, label: label, candidates: candidates)
        if decision.reason == .labelMatch {
            return .moved(ScreenPointer(label: label, appKit: geometry.appKitPoint(fromQuartz: decision.point), quartz: decision.point))
        }
        return probe.seesContent ? .rejected : nil
    }

    #if DEBUG
    /// Creates a real, cancellable local Ollama job to inspect capsule runtime behaviour.
    /// The capture goes only to Ollama on this Mac.
    func runDebugCapsuleTest() {
        guard !isBusy, !chatShown else {
            show(error: "Finish or close the current answer before starting a capsule test.")
            return
        }
        guard let jobs = backgroundJobs, jobs.hasRoom else {
            show(error: "There is no free capsule slot for the local test.")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if settings.blocklist.isBlocked(bundleID: frontmost?.bundleIdentifier) {
            show(error: "ClickBait doesn't look at this app — it's on your blocklist.")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            show(error: "Screen Recording is off. Open Permissions… from the menu bar icon.")
            return
        }

        let question = "For a local capsule runtime check, briefly describe the visible screen content."
        let provider = settings.makeProvider()
        let pid = frontmost.map { Int32($0.processIdentifier) }
        let bundleID = frontmost?.bundleIdentifier
        Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await capturer.captureDisplayUnderCursor(excluding: settings.blocklist,
                                                                           ignoreClickBait: settings.ignoreNotchInCaptures)
                let screenshot = try await ScreenshotEncoder.encodeInBackground(capture.image)
                guard !Task.isCancelled, let jobs = backgroundJobs, jobs.hasRoom else { return }
                let request = AskRequest(question: question, screenshotJPEG: screenshot.jpeg,
                                         screenshotWidth: screenshot.width, screenshotHeight: screenshot.height,
                                         context: ScreenContext(appName: frontmost?.localizedName))
                let job = BackgroundJob(question: question, kind: .answer, homeBundleID: bundleID,
                                       homePID: pid, conversation: Conversation())
                let task = Task { [weak self] in
                    guard let self else { return }
                    await completeDebugCapsuleTest(jobID: job.id, request: request, screenshot: screenshot, provider: provider)
                }
                guard jobs.add(job, task: task) else {
                    task.cancel()
                    return
                }
                var messages = onPeel?(job) ?? []
                if messages.isEmpty { messages = [ChatModel.Message(role: .user, text: question)] }
                jobs.setChatMessages(messages, for: job.id)
                Log.ask.notice("Started DEBUG local capsule runtime check using Ollama")
            } catch {
                guard !Task.isCancelled else { return }
                Log.capture.error("Debug capsule capture failed: \(error.localizedDescription, privacy: .public)")
                show(error: "Couldn't capture the screen for the local capsule test: \(error.localizedDescription)")
            }
        }
    }

    func completeDebugCapsuleTest(jobID: UUID, request: AskRequest, screenshot: EncodedScreenshot,
                                          provider: OllamaProvider) async {
        guard let jobs = backgroundJobs else { return }
        do {
            var reply = ""
            for try await chunk in provider.stream(request) {
                guard !Task.isCancelled else { return }
                reply += chunk
                jobs.append(chunk, to: jobID)
            }
            guard !Task.isCancelled else { return }
            let parsed = ResponseParser.parse(reply, imageWidth: screenshot.width, imageHeight: screenshot.height,
                                              scale: provider.coordinateScale)
            let answer = parsed.response.displayText
            var conversation = Conversation()
            conversation.append(user: Prompt.userText(for: request), assistantSpeech: parsed.response.speech,
                                code: parsed.response.code, language: parsed.response.language)
            jobs.setChatMessages([
                ChatModel.Message(role: .user, text: request.question),
                ChatModel.Message(role: .assistant, text: answer),
            ], for: jobID)
            jobs.complete(jobID, answer: answer, conversation: conversation)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            jobs.fail(jobID, reason: error.localizedDescription)
        }
    }
    #endif


    func beginAnswerFlow() -> UUID {
        let id = UUID()
        answerFlowID = id
        answeringOwnerID = id
        isAnswering = true
        return id
    }

    func finishAnswering(_ id: UUID) {
        guard answeringOwnerID == id else { return }
        answeringOwnerID = nil
        isAnswering = false
    }

    func invalidateAnswerFlow() {
        answerFlowID = nil
        answeringOwnerID = nil
        isAnswering = false
        refiningOwnerID = nil
        isRefining = false
        onSnipAnswering?(false)
    }

    func beginRefining(_ id: UUID) {
        refiningOwnerID = id
        isRefining = true
    }

    func finishRefining(_ id: UUID) {
        guard refiningOwnerID == id else { return }
        refiningOwnerID = nil
        isRefining = false
    }

    /// A new question or explanation takes over: drop a close-up still running so the
    /// local model is free at once.
    func stopRefining() {
        guard isRefining else { return }
        askTask?.cancel()
        invalidateAnswerFlow()
        Log.ask.notice("Close-up dropped: a new question started")
    }

    /// A second look at a pointer on a 2× close-up around it. Nil when the model can't
    /// find the thing there (the rough pointer stays).
    func refine(_ pointer: ScreenPointer, question: String, capture: ScreenCapture, geometry: ScreenGeometry,
                        provider: any LLMProvider) async -> RefineResult {
        let start = ContinuousClock.now
        let target = pointer.label.isEmpty ? question : pointer.label
        do {
            let closeUp = try CloseUp(capture, around: pointer.quartz)
            let encoded = try await ScreenshotEncoder.encodeInBackground(closeUp.image)
            let request = AskRequest(question: question, screenshotJPEG: encoded.jpeg, screenshotWidth: encoded.width,
                                     screenshotHeight: encoded.height, context: context, locate: target)
            var reply = ""
            for try await chunk in provider.stream(request) { reply += chunk }
            let found = ResponseParser.parse(reply, imageWidth: encoded.width, imageHeight: encoded.height,
                                             scale: provider.coordinateScale).response.pointers.first
            guard let found else {
                // Not in the close-up. Where Accessibility can see the rough spot (and it
                // didn't match before), the guess was wrong; elsewhere keep it.
                let check = await verify(pointer.quartz, label: pointer.label, geometry: geometry)
                Log.ask.notice("Close-up: not found (\(String(describing: ContinuousClock.now - start), privacy: .public)); \(check == nil ? "keeping the rough pointer" : "checked on screen", privacy: .public)")
                return check ?? .keep
            }
            let quartz = closeUp.quartzPoint(fromPixel: found.x * encoded.downscale, found.y * encoded.downscale)
            let shift = ((quartz.x - pointer.quartz.x) * (quartz.x - pointer.quartz.x) + (quartz.y - pointer.quartz.y) * (quartz.y - pointer.quartz.y)).squareRoot()
            // The close-up can "find" something wrong next to a wrong guess: check what's
            // really there before moving the triangle onto it.
            let check = await verify(quartz, label: pointer.label, geometry: geometry)
            let verdict = switch check {
            case .moved: "matches"
            case .rejected: "something else is there, withdrawn"
            default: "unchecked"
            }
            Log.ask.notice("""
                Close-up: \(shift, format: .fixed(precision: 0), privacy: .public) pt away, \(verdict, privacy: .public) \
                (\(String(describing: ContinuousClock.now - start), privacy: .public))
                """)
            return check ?? .moved(ScreenPointer(label: pointer.label, appKit: geometry.appKitPoint(fromQuartz: quartz), quartz: quartz))
        } catch {
            Log.ask.error("Close-up failed: \(error.localizedDescription, privacy: .public)")
            return .keep
        }
    }

    /// Orders that should go to the model as a normal question instead:
    /// "open the File menu" (not an app), or a file order while Finder isn't in front
    /// ("delete this" in a text editor must never touch files).
    func isUnknownApp(_ command: ActionRequest) -> Bool {
        if command.name == "open_app" { return AppLocator.url(forAppNamed: command.argument ?? "") == nil }
        if case .success(.file) = ActionCatalog.resolve(command, allowedShortcuts: []) {
            return frontmostBundleID != FileAction.requiredFrontmostApp
        }
        return false
    }

    /// A direct order: validate it, run it, confirm out loud. Nothing runs unless it
    /// resolves against the catalog and the user's allowed shortcuts.
    enum ActionOutcome {
        case success(String)
        case failure(String)
        /// Nothing done yet: a question was asked (a reminder's day).
        case asked(String)
    }

    @discardableResult
    /// "Show me that note": Notes in front with the note ClickBait just made (green).
    func showLastNote(speak: Bool) async -> String? {
        Log.ask.notice("Showing the last note")
        onActionStarted?("opening the note…")
        do {
            guard try await ActionExecutor.showLastNote() else { return nil }
            onActionDone?("opened the note")
            if state == .thinking { state = .idle }
            return "Here it is, in Notes."
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't open the note."
            if speak { speaker.speak(message) }
            show(error: message)
            return message
        }
    }

    func perform(_ request: ActionRequest, speak: Bool = true) async -> ActionOutcome {
        guard settings.commandsEnabled else { return .failure("Commands are turned off in Settings.") }
        var request = request
        // A day said with a reminder ("…by Friday"), read before a page or selection
        // replaces the words.
        let saidDay = request.name == "add_reminder" ? ReminderText.parse(request.detail ?? "").day : nil
        // "Add this page's URL to my notes": the note is the page (or the selection), not
        // the order's words — which is what the note said before.
        if request.name == "make_note" || request.name == "add_reminder", let reference = NoteReference.find(in: request.detail ?? "") {
            let pid = frontmostPID
            let content: String?
            switch reference {
            case .pageAddress:
                let (page, trace) = await Task.detached(priority: .userInitiated) {
                    var trace = ""
                    return (AXInspector.pageAddress(frontmostPID: pid, trace: &trace), trace)
                }.value
                Log.ask.notice("Page address: \(trace, privacy: .public)")
                content = page.map { NoteReference.noteText(address: $0.address, title: $0.title) }
            case .selection:
                content = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid).selectedText }.value
            case .previous:
                // "Add it to my notes": the answer above in the chat, else the selection.
                if let answer = conversation?.lastAnswer, chatShown {
                    content = NoteReference.content(ofAnswer: answer)
                } else {
                    content = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid).selectedText }.value
                }
            }
            Log.ask.notice("Note is \(String(describing: reference), privacy: .public): \(content == nil ? "not readable" : "read", privacy: .public)")
            guard let content, !content.isEmpty else {
                let message = switch reference {
                case .pageAddress: "I can't see a web page in front."
                case .selection: "Nothing's selected."
                case .previous: "What should the note say?"
                }
                speaker.stop()
                if speak { speaker.speak(message) }
                show(error: message)
                return .failure(message)
            }
            request.detail = content + (saidDay.map { " " + $0.phrase } ?? "")
        }
        // No day said: ask ("when?"), so it lands on a day the Today list shows.
        if request.name == "add_reminder", ReminderText.parse(request.detail ?? "").day == nil {
            return askReminderDay(request, speak: speak)
        }
        switch ActionCatalog.resolve(request, allowedShortcuts: settings.allowedShortcuts) {
        case .failure(let error):
            Log.ask.notice("Action refused: \(request.name, privacy: .public) (\(String(describing: error), privacy: .private))")
            speaker.stop()
            if speak { speaker.speak(error.message) }
            show(error: error.message)
            return .failure(error.message)
        case .success(let action):
            onActionStarted?(Self.workingMessage(for: action))
            do {
                let confirmation = try await ActionExecutor.run(action, blocklist: settings.blocklist,
                                                                ignoreClickBait: settings.ignoreNotchInCaptures)
                Log.ask.notice("Action done: \(request.name, privacy: .public)")
                if let started = answerStartedAt {
                    Log.ask.notice("Command finished \(String(describing: ContinuousClock.now - started), privacy: .public) after release")
                }
                if speak {
                    speaker.speak(confirmation + ".")
                    state = .speaking
                }
                onActionDone?(confirmation)
                return .success(confirmation)
            } catch {
                Log.ask.error("Action failed: \(request.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                speaker.stop()
                if speak { speaker.speak(error.localizedDescription) }
                show(error: error.localizedDescription)
                return .failure(error.localizedDescription)
            }
        }
    }

    static func workingMessage(for action: ResolvedAction) -> String {
        switch action {
        case .openApp(let name): "Opening \(name)…"
        case .quitApp(let name): "Quitting \(name)…"
        case .setVolume, .setMuted: "Changing the sound…"
        case .setDarkMode: "Switching appearance…"
        case .runShortcut(let name): "Running “\(name)”…"
        case .setWiFi: "Changing Wi-Fi…"
        case .lockScreen: "Locking…"
        case .sleepDisplay: "Turning off the display…"
        case .newFolder: "Making a folder…"
        case .openPlace(let place): "Opening \(place.displayName)…"
        case .makeNote: "Adding a note…"
        case .addReminder: "Adding a reminder…"
        case .media: "…"
        case .screenshot: "Taking a screenshot…"
        case .newFinderWindow: "Opening Finder…"
        case .showDesktop: "Showing the desktop…"
        case .file(let file):
            switch file {
            case .compress: "Compressing…"
            case .merge: "Merging…"
            case .convertImages: "Converting…"
            case .moveIntoNewFolder: "Making a new folder…"
            case .moveTo(let place): "Moving to \(place.displayName)…"
            case .copyTo(let place): "Copying to \(place.displayName)…"
            case .moveToFolder(let name): "Moving into “\(name)”…"
            case .copyToFolder(let name): "Copying into “\(name)”…"
            case .rename: "Renaming…"
            case .moveToTrash: "Moving to the Trash…"
            case .shrink: "Making smaller copies…"
            }
        }
    }

    /// Moves each pointer onto a matching real element nearby, and drops pointers that
    /// don't land on or near anything clickable — the model sometimes points at empty
    /// space for questions that need no clicking. Without Accessibility permission
    /// there's no way to check, so pointers are returned unchanged.
    /// Settles each pointer on the accessibility element it's on or near. `confirmed`
    /// means an element backs it up; the others get a second, zoomed-in look.
    func snap(_ pointers: [ScreenPointer], geometry: ScreenGeometry) async -> [(pointer: ScreenPointer, confirmed: Bool)] {
        guard AXInspector.isTrusted else {
            Log.ask.notice("Snapping skipped: Accessibility not granted")
            return pointers.map { ($0, false) }
        }
        let pid = frontmostPID
        var snapped: [(pointer: ScreenPointer, confirmed: Bool)] = []
        for pointer in pointers {
            let target = pointer.quartz
            let start = ContinuousClock.now
            let (candidates, probe) = await Task.detached(priority: .userInitiated) {
                AXInspector.candidates(around: target, frontmostPID: pid)
            }.value
            Log.ask.notice("Snap probe: \(probe.description, privacy: .public)")
            let decision = Snapper.decide(target: target, label: pointer.label, candidates: candidates)
            let moved = decision.point != target
            let dx = decision.point.x - target.x, dy = decision.point.y - target.y
            Log.ask.notice("""
                Snap "\(pointer.label, privacy: .private)": \(target.description, privacy: .public) → \
                \(decision.point.description, privacy: .public) (moved \((dx * dx + dy * dy).squareRoot(), format: .fixed(precision: 1), privacy: .public) pt, \
                \(decision.reason.rawValue, privacy: .public), \(candidates.count, privacy: .public) candidates, \
                matched \(decision.candidate?.role ?? "-", privacy: .public) "\(decision.candidate?.label ?? "", privacy: .private)", \
                \(String(describing: ContinuousClock.now - start), privacy: .public))
                """)
            // Nothing to snap to (sidebar rows, canvases, web content…): trust the model's
            // point. Useless pointers are kept away by the prompt and the parser instead.
            guard decision.candidate != nil else {
                Log.ask.notice("Pointer kept as is: \(probe.seesContent ? "no matching element" : "accessibility can't see this area", privacy: .public)")
                snapped.append((pointer, false))
                continue
            }
            let confirmed = Snapper.confirms(decision)
            if !confirmed { Log.ask.notice("Snap inside a whole-window element: not confirmed, the close-up checks it") }
            snapped.append((moved ? ScreenPointer(
                label: pointer.label,
                appKit: geometry.appKitPoint(fromQuartz: decision.point),
                quartz: decision.point
            ) : pointer, confirmed))
        }
        return snapped
    }

    func cancel(reason: String) {
        guard state == .listening else { return }
        _ = recorder.stop()
        captureTask?.cancel()
        captureTask = nil
        pressedAt = nil
        if currentFlow?.phase == .listening { currentFlow = nil }
        state = .idle
        Log.ask.notice("Cancelled: \(reason, privacy: .public)")
    }

    func show(error message: String) {
        state = .error(message)
        errorResetTask?.cancel()
        errorResetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.errorDisplayTime)
            guard !Task.isCancelled, let self, case .error = self.state else { return }
            self.state = .idle
        }
    }
}

extension ScreenChange {
    /// A small grey copy of the screen to compare (`same`).
    static func thumbnail(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
