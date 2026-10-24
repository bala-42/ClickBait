import AppKit
import AVFoundation
import ClickBaitCore
import Observation

// Tutorials and walkthroughs.
extension AskCoordinator {
    // MARK: - Tutorials




    /// Asks before a walkthrough takes over the pointer or opens another app. ✕, Esc or 8 s
    /// without a click is a no.
    func offerWalkthrough(opening app: String?) async -> Bool {
        showTutorialPlanning()
        answerOffer(false)  // never two at once
        let label = app.map { "show me in \($0)!" } ?? "show me!"
        Log.ask.notice("Tutorial: offering (\(label, privacy: .public))")
        let yes = await withCheckedContinuation { continuation in
            pendingOffer = continuation
            onTutorialOffer?(label)
        }
        Log.ask.notice("Tutorial: \(yes ? "show me" : "declined", privacy: .public)")
        return yes && !Task.isCancelled
    }

    /// The offer's answer (its pill, Esc, a timeout, anything that replaces it).
    func answerOffer(_ yes: Bool) {
        guard let pending = pendingOffer else { return }
        pendingOffer = nil
        pending.resume(returning: yes)
    }

    /// Declined: the plan's steps in the chat instead of the pointer.
    func writeSteps(_ plan: TutorialPlan, question: String, display: String) {
        let text = (plan.intro.isEmpty ? "" : plan.intro + "\n\n") + plan.checklist(done: 0)
        if conversation == nil || !chatShown {
            conversation = Conversation()
            snipMemory = nil
            chatShown = true
            onChatOpen?(display)
        } else {
            onChatUserMessage?(display)
        }
        conversation?.append(user: question, assistantSpeech: text)
        if state == .thinking { state = .idle }
        onStepsWritten?(text)
    }

    // MARK: Lavender's hold (as Strawberry Red's: `PeelRule.Hold`)

    /// Planning has begun: once the "planning…" pill has been read (`PeelRule.walkthroughDockAfter`),
    /// or at once if the user moves on, it goes to the dock as a lavender card and plans there
    /// (user's rule, 2026-10-24).
    func startWalkthroughHold(question: String) {
        walkthroughPlanning = true
        armMoveOn(after: PeelRule.walkthroughDockAfter) { [weak self] in
            guard let self, walkthroughPlanning, walkthroughJobID == nil else { return }
            let room = backgroundJobs?.hasRoom ?? false
            guard PeelRule.holdPeels(.walkthrough, stillWorking: true, hasRoom: room) else {
                Log.ask.notice("Walkthrough hold: three's a crowd, planning in front")
                return
            }
            peelWalkthrough(question: question)
        }
    }

    /// The planning goes to a Lavender tile: the companion flies there and a fresh one is at
    /// the cursor (the hold ends for the foreground); the plan carries on in the background and
    /// nothing is pointed at or opened until "show me!".
    func peelWalkthrough(question: String) {
        guard let backgroundJobs else { return }
        let job = BackgroundJob(question: question, kind: .walkthrough, homeBundleID: frontmostBundleID, homePID: frontmostPID,
                                conversation: conversation ?? Conversation())
        guard backgroundJobs.add(job, task: askTask) else { return }
        walkthroughJobID = job.id
        backgroundJobs.setStage(.planningSteps, for: job.id)
        // The exact window and tab it was asked in, so "show me!" goes back there (without
        // them it only found the app: "its window wasn't found").
        let asked = currentFlow?.context ?? context
        backgroundJobs.setHomeWindow(title: asked.windowTitle, frame: asked.windowFrame, for: job.id)
        if let reading = currentFlow?.browserTab {
            let id = job.id
            Task { @MainActor [weak self] in self?.backgroundJobs?.setHomeTab(await reading.value, for: id) }
        }
        _ = onPeel?(job)
        // The task belongs to the tile now: Esc or a new question mustn't cancel it.
        askTask = nil
        if tutorialPlanningShown { onTutorialPlanning?(false) }
        tutorialPlanningShown = false
        speaker.stop()
        currentFlow = nil
        if state == .thinking { state = .idle }
        Log.ask.notice("Walkthrough hold: sent to the dock")
    }

    /// The plan is ready (or it needs its app first) in the dock: the card says what it'll do
    /// and offers "show me!".
    func finishWalkthroughInDock(_ jobID: UUID, pending: PendingWalkthrough) {
        guard let backgroundJobs else { return }
        let text: String
        if let plan = pending.plan, !plan.steps.isEmpty {
            let place = pending.app.map { "In \($0):" } ?? ""
            text = [plan.intro, place, plan.checklist(done: 0)].filter { !$0.isEmpty }.joined(separator: "\n")
        } else if let app = pending.app {
            text = "Ready to walk you through it in \(app). \"show me!\" opens \(app) and starts."
        } else {
            backgroundJobs.fail(jobID, reason: "Couldn't work out the steps.")
            return
        }
        backgroundJobs.setChatMessages([ChatModel.Message(role: .user, text: pending.display),
                                        ChatModel.Message(role: .assistant, text: text)], for: jobID)
        backgroundJobs.setWalkthrough(pending, for: jobID)
        backgroundJobs.complete(jobID, answer: text, conversation: conversation ?? Conversation())
        // Its "show me!" is the card's main button (`AgentDoneCard.goLabel`), not a suggestion.
        Log.ask.notice("Walkthrough hold: ready in the dock (\(pending.app == nil ? "steps planned" : "needs its app", privacy: .public))")
    }

    /// "show me!" on a walkthrough's card, once "go there!" has brought its window back: the
    /// walkthrough starts now (and only now may it open an app, as a step needs it).
    func resumeWalkthrough(_ pending: PendingWalkthrough) {
        guard let tutorial else { return }
        let apps = AppLocator.installed()
        let installedName = { (name: String) in apps.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } }
        let provider = self.provider ?? settings.makeProvider()
        self.provider = provider
        let frontmost = NSWorkspace.shared.frontmostApplication
        frontmostPID = frontmost?.processIdentifier
        frontmostBundleID = frontmost?.bundleIdentifier
        context = ScreenContext(appName: frontmost?.localizedName)
        Log.ask.notice("Walkthrough hold: resumed from the dock")
        askTask = Task {
            // Lavender from "show me!" to the first point: never green, never blue in between.
            tutorialPlanningShown = false
            showTutorialPlanning()
            defer { if tutorialPlanningShown, !(tutorial.isActive) { onTutorialPlanning?(false) }; tutorialPlanningShown = false }
            var plan = pending.plan
            // It happens in another app: open it now (the user said "show me!"). Its plan was made
            // in the dock from that app's menus; it starts at once if its first step is there,
            // else it's planned again from what's really on screen.
            if let app = pending.app.flatMap(installedName), app.caseInsensitiveCompare(frontmost?.localizedName ?? "") != .orderedSame {
                guard let ready = await openForTutorial(app, url: apps[app]) else { return }
                context = ScreenContext(appName: app)
                if let first = plan?.steps.first, await !Self.canFind(first, in: ready.2, pid: frontmostPID) {
                    Log.ask.notice("Walkthrough hold: the dock's plan doesn't fit \(app, privacy: .public); planning again there")
                    plan = nil
                }
                if plan == nil {
                    plan = await planTutorial(pending.question, capture: ready.0, screenshot: ready.1, elements: ready.2, provider: provider)?
                        .separatingSetup(frontmostApp: app, isInstalledApp: { installedName($0) != nil })
                }
                guard let plan, !plan.steps.isEmpty else {
                    show(error: "Couldn't work out the steps in \(app).")
                    return
                }
                _ = await beginTutorial(plan, question: pending.question, startedIn: frontmost, speak: false,
                                        display: pending.display, installedName: installedName, apps: apps,
                                        provider: provider, tutorial: tutorial, continues: pending.continues)
                return
            }
            guard let plan, !plan.steps.isEmpty else { return }
            _ = await beginTutorial(plan, question: pending.question, startedIn: frontmost, speak: false,
                                    display: pending.display, installedName: installedName, apps: apps,
                                    provider: provider, tutorial: tutorial, continues: pending.continues)
        }
    }

    /// A step is there to point at: on screen, or in the app's menus (or a shortcut).
    nonisolated static func canFind(_ step: TutorialStep, in elements: [ScreenElement], pid: pid_t?) async -> Bool {
        if step.isShortcut || step.typing != nil || StepMatcher.find(step.target, in: elements) != nil { return true }
        let target = step.target
        return await Task.detached(priority: .userInitiated) { AXInspector.menuPath(to: target, frontmostPID: pid) != nil }.value
    }

    /// The plan for a walkthrough in another app, made in the dock without bringing that app
    /// forward: from its menus (read in the background when it's running) and the question.
    /// "show me!" checks it against the real screen (`resumeWalkthrough`).
    func planElsewhere(_ app: String, question: String, provider: any LLMProvider,
                       isInstalledApp: @escaping (String) -> Bool) async -> TutorialPlan? {
        let pid = NSWorkspace.shared.runningApplications
            .first { $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame }?.processIdentifier
        let menus = await Task.detached(priority: .userInitiated) { pid.map { AXInspector.menuOutline(frontmostPID: $0) } ?? [] }.value
        var request = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                                 context: ScreenContext(appName: app))
        request.planTutorial = true
        request.browser = AppLocator.defaultBrowserName()
        request.menuOutline = MenuOutline.relevant(menus, to: question, limit: 25)
        let start = ContinuousClock.now
        let reply = await Self.reply(from: provider, to: request, within: ProviderOperation.planTutorialWithScreenshot.timeout)
        let plan = reply.flatMap { TutorialPlan.parse($0)?.expandingMenus(using: menus) }?
            .separatingSetup(frontmostApp: app, isInstalledApp: isInstalledApp)
        Log.ask.notice("Walkthrough hold: planned \(plan?.steps.count ?? 0, privacy: .public) step(s) for another app in the dock in \(String(describing: ContinuousClock.now - start), privacy: .public) (\(menus.count, privacy: .public) menu items)")
        return plan?.steps.isEmpty == false ? plan : nil
    }

    /// A walkthrough planned in front (instantly, or with no time to dock): it goes to the dock
    /// ready, its "show me!" waiting there. False when there's no room (asked in front instead).
    func dockReadyWalkthrough(_ pending: PendingWalkthrough, owns: Bool) async -> Bool {
        guard owns, walkthroughJobID == nil,
              PeelRule.holdPeels(.walkthrough, stillWorking: true, hasRoom: backgroundJobs?.hasRoom ?? false) else { return false }
        showTutorialPlanning()
        try? await Task.sleep(for: PeelRule.walkthroughDockAfter)  // the "planning…" pill is read
        guard !Task.isCancelled else { return true }  // Esc: dropped, not docked or asked
        peelWalkthrough(question: pending.question)
        guard let jobID = walkthroughJobID else { return false }
        walkthroughJobID = nil
        finishWalkthroughInDock(jobID, pending: pending)
        return true
    }

    /// Lavender and spinning from the moment it's known to be a walkthrough, not only once
    /// the steps are ready.
    func showTutorialPlanning() {
        guard !tutorialPlanningShown else { return }
        tutorialPlanningShown = true
        onTutorialPlanning?(true)
    }

    /// "How do I…" or an order that takes clicks ("Clear search history."): plan the
    /// clicks and walk the user through them in lavender. If the task lives in another
    /// app, open it first (green). Returns false to answer normally instead.
    func startTutorial(question: String, capture: ScreenCapture, encoding: Task<EncodedScreenshot, Error>,
                               elements: [ScreenElement], speak: Bool, display: String, flow: QuestionFlow? = nil) async -> Bool {
        // Lavender while planning, once an app was opened for the walkthrough (green →
        // lavender, not green → idle blue → lavender). Dropped again if no tutorial starts.
        // A queued question until it is settled: not the foreground's, so it neither shows nor
        // clears the planning colour, and reads its own context, provider and app.
        var ownsPlanningUI = flow?.jobID == nil
        let context = flow?.context ?? self.context
        let homePID = flow?.homePID ?? frontmostPID
        let provider = flow?.provider ?? self.provider
        if ownsPlanningUI { tutorialPlanningShown = false }
        defer {
            if ownsPlanningUI {
                if tutorialPlanningShown, !(tutorial?.isActive ?? false) { onTutorialPlanning?(false) }
                tutorialPlanningShown = false
            }
        }
        // "Where" is showing where: always a blue point, never a walkthrough.
        if TutorialQuestion.asksWhere(question) { return false }
        let asking = TutorialQuestion.asksForTutorial(question)
        let ordering = !asking && CommandParser.looksLikeOrder(question) && !TutorialQuestion.isContentRequest(question)
            && !TutorialQuestion.isLocatingRequest(question)  // "show me the refresh button": blue pointing
        // A well-known website is typed into the browser (lavender) however it's asked,
        // even "show me how to open YouTube"; other "show me…" requests point (blue).
        let visiting = Websites.visit(in: question, installedApps: Array(AppLocator.installed().keys)) != nil
        // "System Setting" on its own: getting there is the task (Apple menu → System Settings…).
        let toSystemSettings = TutorialQuestion.onlyOpens(question, app: "System Settings")
            && TutorialQuestion.taskApp(in: question, apps: Array(AppLocator.installed().keys)) == "System Settings"
        // "Where's / show me X" is showing where (blue), not how (lavender) — unless getting to
        // X takes more than one click: X is an item inside this app's menus, or a thing
        // (not a control) in another app the request names ("show me my Safari history").
        // Decided before any colour changes, so a "where" never flashes lavender.
        var findingHidden = false
        // "Where's the calendar?" with Calendar not in front: it just opens (green), no
        // walkthrough — that planned 18 s inside Calendar for one step (try-list c06).
        var opensApp: String?
        if TutorialQuestion.isLocatingRequest(question), !Self.isOnScreen(question, in: elements),
           !TutorialQuestion.namesControl(question) {
            let named = TutorialQuestion.mentionedApp(in: question, apps: Array(AppLocator.installed().keys))
            if let named, named.caseInsensitiveCompare(context.appName ?? "") != .orderedSame,
               TutorialQuestion.onlyOpens(question, app: named) {
                opensApp = named
            } else if let named, named.caseInsensitiveCompare(context.appName ?? "") != .orderedSame {
                findingHidden = true
            } else if let target = InstantAnswer.locateTargets(in: question).first {
                let pid = homePID
                let path = await Task.detached(priority: .userInitiated) { AXInspector.menuPath(to: target, frontmostPID: pid) }.value
                findingHidden = (path?.count ?? 0) >= 2
            }
        }
        guard asking || ordering || visiting || toSystemSettings || findingHidden || opensApp != nil,
              let provider, let tutorial else { return false }
        // A walkthrough isn't sent away: a queued peel's tile goes and it runs once the foreground is free.
        if let flow {
            flow.kind = .command
            guard await settleQuick(flow) else { return true }
            ownsPlanningUI = true
            tutorialPlanningShown = false
        }
        if let opensApp {
            Log.ask.notice("Locate: the app itself isn't in front; opening it")
            _ = await perform(ActionRequest(name: "open_app", argument: opensApp), speak: speak)
            return true
        }
        if findingHidden { Log.ask.notice("Tutorial: what they're looking for isn't on screen; walking them there") }
        let startedIn = NSWorkspace.shared.frontmostApplication
        let apps = AppLocator.installed()
        // The installed app's own name ("Safari"), whatever case the plan wrote.
        let installedName = { (name: String) in apps.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } }
        var capture = capture
        var elements = elements
        var screenshot: EncodedScreenshot
        do { screenshot = try await encoding.value } catch { return false }
        tutorialReturnApp = nil

        // "Go to YouTube": an order, not a how-to — ClickBait just does it (green), switching
        // to a tab already showing the site or opening it. "Show me how to open YouTube" (and
        // "…and play lofi", with more to do) stays a walkthrough.
        if !asking, let site = Websites.visit(in: question, installedApps: Array(apps.keys)),
           Websites.isJustAVisit(question, site: site.name),
           let browser = Websites.namedBrowser(in: question, installed: Array(apps.keys)) ?? AppLocator.defaultBrowserName() {
            await visitWebsite(site, in: browser, appURL: apps[browser])
            return true
        }

        // The task's app isn't in front. Either the request names it ("my Safari history")
        // or it's a Mac setting. Planning those from the app in front walked Finder's own
        // "Settings…", so the app is opened first and the plan made there.
        let taskApp = TutorialQuestion.taskApp(in: question, apps: Array(apps.keys))
        // System Settings is shown, not opened for the user: the Apple menu, then "System
        // Settings…" (works from any app, no model needed); once it's open, the rest of the
        // task is planned in there — unless getting there was the whole request.
        if taskApp == "System Settings", context.appName?.caseInsensitiveCompare("System Settings") != .orderedSame {
            // Known settings go on to their page and control (`SystemSettingsMap`): facts,
            // where the model sent Night Shift to General.
            let route = SystemSettingsMap.route(for: question) ?? []
            Log.ask.notice("Tutorial: System Settings by the Apple menu\(route.isEmpty ? "" : " → " + route.joined(separator: " → "), privacy: .public)")
            let settingsPlan = TutorialPlan.systemSettingsByAppleMenu(from: context.appName, route: route)
            let settingsContinue = !TutorialQuestion.onlyOpens(question, app: "System Settings")
            if await dockReadyWalkthrough(PendingWalkthrough(plan: settingsPlan, app: nil, question: question, display: display,
                                                             continues: settingsContinue), owns: ownsPlanningUI) {
                return true
            }
            guard await offerWalkthrough(opening: nil) else {
                writeSteps(settingsPlan, question: question, display: display)
                return true
            }
            return await beginTutorial(settingsPlan, question: question, startedIn: startedIn,
                                       speak: speak, display: display, installedName: installedName, apps: apps,
                                       provider: provider, tutorial: tutorial,
                                       continues: !TutorialQuestion.onlyOpens(question, app: "System Settings"))
        }
        // Said yes already ("show me in Safari!"): never asked a second time.
        var offered = false
        if let named = taskApp, named.lowercased() != context.appName?.lowercased() {
            // It happens in another app: nothing to plan here, so it goes straight to the dock
            // as a lavender card whose "show me!" opens that app and walks through it there —
            // waiting for the user, never declining by itself (user's ask, 2026-10-24).
            if ownsPlanningUI, PeelRule.holdPeels(.walkthrough, stillWorking: true, hasRoom: backgroundJobs?.hasRoom ?? false) {
                showTutorialPlanning()
                try? await Task.sleep(for: PeelRule.walkthroughDockAfter)  // the "planning…" pill is read
                guard !Task.isCancelled else { return true }  // Esc: dropped
                peelWalkthrough(question: question)
                if let jobID = walkthroughJobID {
                    walkthroughJobID = nil
                    let plan = await planElsewhere(named, question: question, provider: provider,
                                                   isInstalledApp: { installedName($0) != nil })
                    finishWalkthroughInDock(jobID, pending: PendingWalkthrough(plan: plan, app: named, question: question, display: display))
                }
                return true
            }
            // A full dock: asked in front before switching apps (no plan yet: it's made in that
            // app), so a no gets a written answer instead.
            guard await offerWalkthrough(opening: named) else {
                answerInWordsOnly = true
                return false
            }
            offered = true
            showTutorialPlanning()  // lavender while the app opens too: a walkthrough is never green
            guard let ready = await openForTutorial(named, url: apps[named]) else { return false }
            (capture, screenshot, elements) = ready
        }

        // A well-known website ("open YouTube", "I want to watch YouTube"): one typing step
        // in the browser's address bar, with the address from ClickBait's own list — no
        // model, so it's instant and never a guessed domain. Whatever's left once the page
        // is open ("…and play lofi") is planned from there.
        if let site = Websites.visit(in: question, installedApps: Array(apps.keys)),
           let browser = Websites.namedBrowser(in: question, installed: Array(apps.keys)) ?? AppLocator.defaultBrowserName() {
            let step = TutorialStep(target: "address bar", instruction: "Type \(site.address), then press Return",
                                    app: browser, typing: site.address)
            let plan = TutorialPlan(intro: "Type \(site.name)'s address in \(browser).", steps: [step])
            Log.ask.notice("Tutorial: website \(site.address, privacy: .public) in the browser")
            let switching = browser.caseInsensitiveCompare(context.appName ?? "") != .orderedSame
            if await dockReadyWalkthrough(PendingWalkthrough(plan: plan, app: nil, question: question, display: display,
                                                             continues: !Websites.isJustAVisit(question, site: site.name)),
                                          owns: ownsPlanningUI) {
                return true
            }
            guard await offerWalkthrough(opening: switching ? browser : nil) else {
                writeSteps(plan, question: question, display: display)
                return true
            }
            return await beginTutorial(plan, question: question, startedIn: startedIn, speak: speak, display: display,
                                       installedName: installedName, apps: apps, provider: provider, tutorial: tutorial,
                                       continues: !Websites.isJustAVisit(question, site: site.name))
        }

        var plan: TutorialPlan?
        for _ in 0..<2 {
            guard !Task.isCancelled else { return false }
            plan = await planTutorial(question, capture: capture, screenshot: screenshot, elements: elements, provider: provider,
                                      holdable: ownsPlanningUI && walkthroughJobID == nil)?
                .separatingSetup(frontmostApp: context.appName, isInstalledApp: { installedName($0) != nil })
            // The plan says it happens in another app: ask, then open it and plan again there —
            // not while held in the dock (no app opens during a hold; "show me!" opens it later).
            guard walkthroughJobID == nil, let other = plan?.app.flatMap(installedName), let url = apps[other] else { break }
            if !offered {
                offered = true
                guard await offerWalkthrough(opening: other) else {
                    answerInWordsOnly = true
                    return false
                }
            }
            showTutorialPlanning()  // lavender while the app opens too: a walkthrough is never green
            guard let ready = await openForTutorial(other, url: url) else { return false }
            (capture, screenshot, elements) = ready
        }
        if let jobID = walkthroughJobID {
            walkthroughJobID = nil
            let elsewhere = plan?.app.flatMap(installedName)
            if let elsewhere {
                plan = await planElsewhere(elsewhere, question: question, provider: provider,
                                           isInstalledApp: { installedName($0) != nil })
            }
            finishWalkthroughInDock(jobID, pending: PendingWalkthrough(plan: plan, app: elsewhere, question: question, display: display))
            return true
        }
        guard !Task.isCancelled, let plan, let first = plan.steps.first else {
            onSetupFinished?()
            Log.ask.notice("Tutorial: no steps; answering normally")
            return false
        }
        Log.ask.notice("Tutorial steps: \(plan.steps.map { "\($0.target) [\($0.app ?? "-")]\($0.typing.map { " type " + $0 } ?? "")" }.joined(separator: " → "), privacy: .public)")
        // Its first click must be findable (on screen or in the app's menus).
        if StepMatcher.find(first.target, in: elements) == nil, !first.isShortcut {
            let pid = frontmostPID
            let inMenus = await Task.detached(priority: .userInitiated) {
                AXInspector.menuPath(to: first.target, frontmostPID: pid) != nil
            }.value
            guard inMenus else {
                onSetupFinished?()
                Log.ask.notice("Tutorial: first step (\(first.target, privacy: .public)) isn't on screen; answering normally")
                return false
            }
        }
        if !offered, await dockReadyWalkthrough(PendingWalkthrough(plan: plan, app: nil, question: question, display: display),
                                                owns: ownsPlanningUI) {
            return true
        }
        if !offered, !(await offerWalkthrough(opening: nil)) {
            writeSteps(plan, question: question, display: display)
            return true
        }
        return await beginTutorial(plan, question: question, startedIn: startedIn, speak: speak, display: display,
                                   installedName: installedName, apps: apps, provider: provider, tutorial: tutorial)
    }

    /// Goes to a well-known site (green): its tab if one's open, else a new page.
    func visitWebsite(_ site: (name: String, address: String), in browser: String, appURL: URL?) async {
        onActionStarted?("opening \(site.name)…")
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == browser }
        if let running {
            let pid = running.processIdentifier
            let switched = await Task.detached(priority: .userInitiated) {
                AXInspector.selectTab(showing: site.name, browserPID: pid)
            }.value
            if switched {
                running.activate()
                Log.ask.notice("Website: switched to an open \(site.name, privacy: .public) tab in \(browser, privacy: .public)")
                onActionDone?("switched to \(site.name)")
                if state == .thinking { state = .idle }
                return
            }
        }
        guard let url = URL(string: site.address.hasPrefix("http") ? site.address : "https://" + site.address),
              let appURL else {
            show(error: "Couldn't open \(site.name).")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            Log.ask.notice("Website: opened \(site.address, privacy: .public) in \(browser, privacy: .public)")
            onActionDone?("opened \(site.name)")
        } catch {
            show(error: "Couldn't open \(site.name): \(error.localizedDescription)")
        }
        if state == .thinking { state = .idle }
    }

    /// A tour's stops on screen, labelled as guesses ("~ name"), each with the outline of the
    /// thing at its point where one stands out (found off the main thread).
    /// `known`: outlines the marks already have (close-up pixels, nil where they don't).
    nonisolated static func tourPointers(_ stops: [Pointer], outlines known: [PartOutline?] = [], in view: SnipView) async -> [ScreenPointer] {
        let start = ContinuousClock.now
        let pointsPerPixel = view.crop.width / Double(view.image.width)
        let outlines = await Task.detached(priority: .userInitiated) {
            stops.enumerated().map { index, stop -> PartOutline? in
                if index < known.count, let outline = known[index] { return outline.scaled(by: pointsPerPixel) }
                return view.outlines(at: [stop]).first.flatMap { $0 }
            }
        }.value
        Log.ask.notice("Parts: outlines for \(outlines.compactMap { $0 }.count, privacy: .public) of \(stops.count, privacy: .public) in \(String(describing: ContinuousClock.now - start), privacy: .public) (the tip stops at their edges)")
        // Where each part is and how far its edges are, so a tip that's off can be read off:
        // the model's spot (close-up pixels) or the outline (points: nearest–farthest edge).
        for (stop, outline) in zip(stops, outlines) {
            let edges = outline.map { "edges \(Int($0.radii.min() ?? 0))–\(Int($0.radii.max() ?? 0)) pt" } ?? "no outline"
            Log.ask.notice("Parts: \(stop.label, privacy: .public) at \(Int(stop.x), privacy: .public),\(Int(stop.y), privacy: .public) of \(view.image.width, privacy: .public)×\(view.image.height, privacy: .public): \(edges, privacy: .public)")
        }
        return zip(stops, outlines).map { stop, outline in
            var pointer = view.screenPointer(Pointer(x: stop.x, y: stop.y, label: "~ " + stop.label.lowercased()))
            pointer.outline = outline
            return pointer
        }
    }

    /// Faces in a snip's close-up, found off the main thread.
    /// Starts finding the separate things in a snip's close-up, off the main thread.
    nonisolated static func findObjects(in view: SnipView) -> Task<[FoundObject], Never> {
        let cancellation = ObjectFinder.CancellationFlag()
        return Task.detached(priority: .userInitiated) {
            await withTaskCancellationHandler {
                let start = ContinuousClock.now
                let objects = ObjectFinder.objects(in: view.image, marked: view.marked, cancellation: cancellation)
                Log.ask.notice("Objects: \(objects.count, privacy: .public) found in \(String(describing: ContinuousClock.now - start), privacy: .public)")
                return objects
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    struct WebLookupResult: Sendable {
        var passages: [WebPassage] = []
        var needsScreen = false
        /// "Sources: [Wikipedia — Swift](…) · …", for under the answer.
        var credit: String?
    }

    /// Internet Mode's fixed steps: the search words (local model, text only), then the
    /// sources at once (~4 s at most), then the passages closest to the question. Only the
    /// cleaned search words and page addresses leave the Mac (spec decisions 4–5).
    func lookUp(question: String, reason: WebLookup.Reason, selectedText: String?, capture: ScreenCapture,
                        history: [ChatTurn], provider: any LLMProvider) async -> WebLookupResult {
        let start = ContinuousClock.now
        var result = WebLookupResult(needsScreen: WebLookup.refersToScreen(question))
        // What's on screen near the pointer, read on this Mac, for the query step only.
        var screenWords = ""
        if result.needsScreen {
            let boxes = await TextReader.read(capture.image)
            let mouse = NSEvent.mouseLocation
            let pointer = Point(x: (mouse.x - capture.displayFrame.minX) * capture.backingScale,
                                y: (capture.displayFrame.maxY - mouse.y) * capture.backingScale)
            func distance(_ point: Point) -> Double { hypot(point.x - pointer.x, point.y - pointer.y) }
            for box in boxes.sorted(by: { distance($0.center) < distance($1.center) }) {
                guard screenWords.count + box.text.count < 1_500 else { break }
                screenWords += (screenWords.isEmpty ? "" : " | ") + box.text
            }
        }
        let onScreen = [screenWords, context.windowTitle ?? "", selectedText ?? ""].joined(separator: "\n")
        let screenNames = OnDeviceLanguage.personalNames(in: onScreen)
        let earlier = history.last(where: { $0.role == .user }).map { Self.spokenQuestion(in: $0.content) }

        var ask = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0,
                             context: context, selectedText: selectedText)
        ask.lookupQuery = true
        ask.screenWords = screenWords.isEmpty ? nil : screenWords
        ask.earlierQuestion = earlier
        let reply = await Self.reply(from: provider, to: ask, within: .seconds(3))
        guard !Task.isCancelled else { return result }
        let fallback = WebLookup.directQuery(question).isEmpty ? WebLookup.directQuery(earlier ?? "") : WebLookup.directQuery(question)
        let written = reply.flatMap(WebLookup.query(inReply:))
        let query = QueryScrubber.clean(written ?? fallback, screenNames: screenNames, userWords: question)
        let queryTook = ContinuousClock.now - start

        // A page the user means ("summarise this page") or named, if it's https.
        var pages = Array(URLGuard.addresses(in: question))
        if question.range(of: #"\bthis\s+(?:page|article|site|website|post|doc|documentation)\b"#,
                          options: [.regularExpression, .caseInsensitive]) != nil {
            let pid = frontmostPID
            let found = await Task.detached(priority: .userInitiated) { () -> String? in
                var trace = ""
                return AXInspector.pageAddress(frontmostPID: pid, trace: &trace)?.address
            }.value
            if let address = found,
               let url = URL(string: address), URLGuard.allows(url, seenIn: [url]) {
                pages.append(url)
            }
        }
        guard !query.isEmpty || !pages.isEmpty else {
            Log.ask.notice("Lookup: no search words left after cleaning; answering locally")
            return result
        }
        if !query.isEmpty { settings.internet.record(query) }
        pages.prefix(2).forEach { settings.internet.record($0.absoluteString) }

        let searxng = await settings.web.searxngReady()
        let sources = query.isEmpty ? [] : WebSourcePicker.sources(question: question, query: query, reason: reason,
                                                                  searxngAvailable: searxng)
        let outcome = await settings.web.lookUp(query: query, sources: sources, pages: Array(pages.prefix(2)))
        guard !Task.isCancelled else { return result }
        let documents = outcome.documents
        result.passages = await Task.detached(priority: .userInitiated) {
            OnDeviceLanguage.pickPassages(documents, question: question + " " + query)
        }.value
        // Off-topic hits (a weak search's best guesses) are neither used nor credited.
        let kept = result.passages.filter { WebRelevance.isRelevant(title: $0.title, text: $0.text, query: query.isEmpty ? question : query) }
        if kept.count < result.passages.count {
            Log.ask.notice("Lookup: dropped \(result.passages.count - kept.count, privacy: .public) off-topic passage(s)")
        }
        result.passages = kept
        var seen = Set<URL>()
        let cited = result.passages.filter { seen.insert($0.url).inserted }.prefix(3)
        if !cited.isEmpty {
            result.credit = "Sources: " + cited.map { "[\($0.source.displayName) — \(Self.markdownSafe($0.title))](\($0.url.absoluteString))" }
                .joined(separator: " · ")
        }
        Log.ask.notice("""
            Lookup (\(reason.rawValue, privacy: .public), \(result.needsScreen ? "about the screen" : "text only", privacy: .public)): \
            query \(written == nil ? "fallback" : "written", privacy: .public) in \(String(describing: queryTook), privacy: .public), \
            "\(query, privacy: .private)"; sources \(sources.map(\.rawValue).joined(separator: ","), privacy: .public) \
            (failed: \(outcome.failed.map(\.rawValue).joined(separator: ","), privacy: .public)); \
            \(documents.count, privacy: .public) docs → \(result.passages.count, privacy: .public) passages, \
            \(result.passages.reduce(0) { $0 + $1.text.count }, privacy: .public) chars; \
            \(String(describing: ContinuousClock.now - start), privacy: .public) in all
            """)
        return result
    }

    /// The words a stored user turn asked ("The user said: …" in the prompt text it keeps).
    static func spokenQuestion(in content: String) -> String {
        guard let range = content.range(of: "The user said: ", options: .backwards) else { return String(content.suffix(200)) }
        return String(content[range.upperBound...].prefix(300))
    }

    static func markdownSafe(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// Looks up the subject a snip's reply opened with (Wikipedia lookups on). Only those
    /// words are sent, and not at all when the close-up shows a face (a person's name is
    /// never sent) or is mostly text (no tour follows). Stored in the snip's memory.
    func startLookup(_ subject: String) {
        guard let memory = snipMemory, let view = memory.view else { return }
        let reading = memory.text
        snipMemory?.reference = Task { [weak self] in
            if !(await Self.faces(in: view)).isEmpty {
                Log.ask.notice("Lookup: skipped, the snip shows a face")
                return nil
            }
            let share = await PartPlacer.colourfulShare(of: view)
            if let reading, PartsTour.isMostlyText(await TextReader.read(reading, within: .milliseconds(1500)), marked: view.marked,
                                                   colourfulShare: share) {
                Log.ask.notice("Lookup: skipped, the snip is mostly text")
                return nil
            }
            guard !Task.isCancelled, let self, settings.internet.isOn else { return nil }
            settings.internet.record("Wikipedia: \(subject)")
            let start = ContinuousClock.now
            let reference = await WikipediaClient().reference(for: subject)
            Log.ask.notice("""
                Lookup: Wikipedia for \(subject, privacy: .private) → \(reference?.title ?? "nothing", privacy: .private) \
                (\(String(describing: ContinuousClock.now - start), privacy: .public))
                """)
            return reference
        }
    }

    nonisolated static func faces(in view: SnipView) async -> [(center: Point, width: Double)] {
        await Task.detached(priority: .userInitiated) { FaceFinder.faces(in: view.image) }.value
    }

    /// What "where's / show me …" asks for is clickable on screen now, by (nearly) its name.
    static func isOnScreen(_ question: String, in elements: [ScreenElement]) -> Bool {
        let targets = InstantAnswer.locateTargets(in: question)
        return !targets.isEmpty && targets.allSatisfy { StepMatcher.find($0, in: elements, minimum: 0.9) != nil }
    }

    /// Shows the plan in the chat and starts walking it.
    func beginTutorial(_ plan: TutorialPlan, question: String, startedIn: NSRunningApplication?, speak: Bool,
                               display: String, installedName: @escaping (String) -> String?, apps: [String: URL],
                               provider: any LLMProvider, tutorial: TutorialController, continues: Bool = true) async -> Bool {
        if let startedIn, startedIn.processIdentifier != frontmostPID { tutorialReturnApp = startedIn }
        onSetupFinished?()

        if conversation == nil || !chatShown {
            conversation = Conversation()
            snipMemory = nil
            chatShown = true
            onChatOpen?(display)
        } else {
            onChatUserMessage?(display)
        }
        conversation?.append(user: question, assistantSpeech: plan.intro + "\n" + plan.checklist(done: 0))
        if state == .thinking { state = .idle }
        if speak, !plan.intro.isEmpty { speaker.speak(plan.intro) }
        tutorial.isInstalledApp = { installedName($0) != nil }
        tutorial.openApp = { [weak self] name in
            guard let self, let installed = installedName(name) else { return false }
            let ready = await openForTutorial(installed, url: apps[installed]) != nil
            onSetupFinished?()
            return ready
        }
        tutorial.start(plan, goal: question, provider: provider, context: context, blocklist: settings.blocklist,
                       ignoreClickBait: settings.ignoreNotchInCaptures, speak: speak, continues: continues)
        return true
    }

    /// Plans from the app's menus and elements alone when Accessibility describes it
    /// (~1–2 s); otherwise (or if that finds nothing) from the screenshot (~10 s).
    func planTutorial(_ question: String, capture: ScreenCapture, screenshot: EncodedScreenshot,
                              elements: [ScreenElement], provider: any LLMProvider, holdable: Bool = false) async -> TutorialPlan? {
        let geometry = capture.geometry(imageWidth: screenshot.width, imageHeight: screenshot.height)
        var request = AskRequest(question: question, screenshotJPEG: screenshot.jpeg, screenshotWidth: screenshot.width,
                                 screenshotHeight: screenshot.height, context: context,
                                 elements: PromptElement.list(elements, geometry: geometry, question: question, limit: 25))
        request.planTutorial = true
        request.browser = AppLocator.defaultBrowserName()
        let pid = frontmostPID
        let menus = await Task.detached(priority: .userInitiated) { AXInspector.menuOutline(frontmostPID: pid) }.value
        request.menuOutline = MenuOutline.relevant(menus, to: question, limit: 25)
        // The request names exactly one menu item ("clear history" → History ▸ Clear
        // History…): start at once from the app's own menus; whatever follows (a dialog's
        // button) is planned by the model after the item is chosen.
        if let instant = InstantAnswer.menuPlan(for: question, app: context.appName, outline: menus) {
            Log.ask.notice("Tutorial plan: instant, from the menus (\(instant.steps.count, privacy: .public) steps)")
            return instant
        }
        // A how-to about content ("how do I make this code faster?") is a question: a quick
        // sort (~1 s) spots it. It runs alongside the plan instead of before it, so a real
        // walkthrough doesn't wait for it; a "question" verdict drops the plan. Skipped when
        // asked outright ("show me how…") or when a how-to names an app ("how do I open
        // Safari history"): that is clearly about doing something in it.
        let namesApp = TutorialQuestion.asksForTutorial(question)
            && TutorialQuestion.mentionedApp(in: question, apps: Array(AppLocator.installed().keys)) != nil
        // "Where's / show me X" is about getting to X, never a content question.
        let sorting = !TutorialQuestion.insistsOnWalkthrough(question) && !namesApp
            && !TutorialQuestion.isLocatingRequest(question)
        var sort = AskRequest(question: question, screenshotJPEG: Data(), screenshotWidth: 0, screenshotHeight: 0, context: context)
        sort.sortRequest = true
        let start = ContinuousClock.now
        let planRequest = request
        // Both are child tasks: cancelled with the ask (Esc), and the plan is dropped when
        // this returns early on a "question" verdict.
        async let verdict: String? = sorting
            ? Self.reply(from: provider, to: sort, within: ProviderOperation.classifyRequest.timeout)
            : nil
        async let planned = Self.planSteps(planRequest, menus: menus, provider: provider)
        if sorting {
            let answer = await verdict
            let took = String(describing: ContinuousClock.now - start)
            if let answer, TutorialQuestion.sortedAsAnswer(answer) {
                Log.ask.notice("Sorted as a question in \(took, privacy: .public): answering, no plan")
                return nil
            }
            Log.ask.notice("Sorted as a walkthrough in \(took, privacy: .public)\(answer == nil ? " (no verdict)" : "", privacy: .public)")
            showTutorialPlanning()  // it is a walkthrough: lavender while the steps are planned
        } else {
            Log.ask.notice("Tutorial: no sort needed (\(namesApp ? "a how-to naming an app" : "asked outright", privacy: .public))")
            showTutorialPlanning()
        }
        if holdable { startWalkthroughHold(question: question) }
        let plan = await planned
        walkthroughPlanning = false
        Log.ask.notice("""
            Tutorial plan: \(plan?.steps.count ?? 0, privacy: .public) step(s)\(plan?.app != nil ? " in another app" : "", privacy: .public) \
            in \(String(describing: ContinuousClock.now - start), privacy: .public) (\(menus.count, privacy: .public) menu items)
            """)
        return plan
    }

    /// The model's plan: text-only first when Accessibility describes the app (~1–2 s),
    /// else with the screenshot.
    nonisolated static func planSteps(_ request: AskRequest, menus: [String], provider: any LLMProvider) async -> TutorialPlan? {
        var plan: TutorialPlan?
        if TutorialPlanning.canUseTextOnly(elements: request.elements.count, menuItems: menus.count) {
            var textOnly = request
            textOnly.screenshotJPEG = Data()
            if let reply = await reply(from: provider, to: textOnly, within: ProviderOperation.planTutorialTextOnly.timeout),
               let parsed = TutorialPlan.parse(reply)?.expandingMenus(using: menus), !parsed.steps.isEmpty || parsed.app != nil {
                plan = parsed
            }
        }
        if plan == nil, !Task.isCancelled,
           let reply = await reply(from: provider, to: request, within: ProviderOperation.planTutorialWithScreenshot.timeout) {
            plan = TutorialPlan.parse(reply)?.expandingMenus(using: menus)
        }
        return plan
    }


    func openForTutorial(_ name: String, url: URL?) async -> (ScreenCapture, EncodedScreenshot, [ScreenElement])? {
        isOpeningAppForTutorial = true
        defer { isOpeningAppForTutorial = false }
        guard let url else {
            show(error: "That needs \(name), which isn't installed.")
            return nil
        }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL == url }
        onActionStarted?(running ? "switching to \(name)…" : "opening \(name)…")
        Log.ask.notice("Tutorial setup: opening another app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else {
            show(error: "Couldn't open \(name).")
            return nil
        }
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return nil }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                let pid = app.processIdentifier
                let ready = await Task.detached(priority: .userInitiated) { !AXInspector.menuOutline(frontmostPID: pid, limit: 5).isEmpty }.value
                if ready { break }
            } else {
                app.activate()
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .milliseconds(300))  // the window settles
        onActionDone?("\(running ? "switched to" : "opened") \(app.localizedName ?? name)")
        frontmostPID = app.processIdentifier
        frontmostBundleID = app.bundleIdentifier
        let pid = app.processIdentifier
        let snapshot = await Task.detached(priority: .userInitiated) { AXInspector.snapshot(frontmostPID: pid) }.value
        context = ScreenContext(appName: app.localizedName ?? name, windowTitle: snapshot.windowTitle)
        context.windowFrame = snapshot.windowFrame
        guard let capture = try? await capturer.captureDisplayUnderCursor(excluding: settings.blocklist,
                                                                          ignoreClickBait: settings.ignoreNotchInCaptures),
              let screenshot = try? await ScreenshotEncoder.encodeInBackground(capture.image) else { return nil }
        let elements = await Self.elements(in: capture, frontmostPID: pid)
        return (capture, screenshot, elements)
    }
}
