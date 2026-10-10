# Background ClickBaits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Holding ⌃⌥ while a plain answer is being written sends that answer to a docked background capsule and starts listening for the next question at once.

**Architecture:** Each answer run in `AskCoordinator.respond()` gets an `AnswerRun` whose output (speech, streamed text) can be switched mid-stream from the foreground to a `BackgroundJob`; after the stream, a background run records its result in the job and returns before any pointing, chat or state code. Pure logic (job states, summary, capsule geometry, the peel gate) lives in ClickBaitCore with tests; capsules are small always-on-every-desktop panels managed by `CapsuleController`, wired in `AppDelegate`.

**Tech Stack:** Swift 5.10+, SwiftUI + AppKit, macOS 14+, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-07-background-clickbaits-design.md`

## Global Constraints

- Prerequisite: the parts-tour work currently uncommitted in the working tree (`AskCoordinator.swift`, `ObjectFinder.swift`, `OutlineFinder.swift`, Core parts files) is committed or explicitly accepted by the user as the base before Task 4 touches `AskCoordinator.swift`. Never stage or commit files this plan doesn't own.
- Commit only when the user has asked for commits; stage only the task's own files (never `git add -A`). Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Core stays free of AppKit/SwiftUI imports.
- No force-unwraps outside tests. UI on `@MainActor`. Prefer async/await.
- After each task: `swift test --package-path ClickBaitCore` (Core tasks) and `xcodebuild -scheme ClickBait -configuration Debug -destination 'platform=macOS' build` with zero errors and warnings. Run `xcodegen generate` first whenever files are added to the app target.
- Max 3 capsules (`CapsuleLayout.maxCapsules = 3`). Capsule 44×28 pt; 8 pt below the menu bar, 8 pt from the right edge; 6 pt gaps; oldest on top; card 280 pt wide, 6 pt below its capsule.
- Exact copy: refusal pill `three's a crowd`; working card `working on it…`; failure `Couldn't answer: <reason>`; swapped chat summary `your chat about <first question>`; buttons (lowercase, no brackets, like "let's see!"): `stop`, `go there!`, `later, pls`, `ok`. Empty answer summary `Done.`
- Background answers never speak, point, open/untuck a chat, run close-ups or parts tours, or change `AskCoordinator.state`.
- Capsules are memory-only; nothing written to disk. Esc never stops a capsule.
- Colours: answer capsule Pumpkin (`CompanionTone.processing`), snip capsule Strawberry Red (`CompanionTone.capture`); glow per `Glow`.

## Review Focus

1. A background answer finishing while a new foreground question is listening or thinking → the foreground state, chat, speech and companion are untouched. (Pinned by Task 4's `PeelGate` tests and Task 9's manual check 3.)
2. ⌃⌥ pressed in the instant the stream ends → either the answer peels completely or stays completely in front; never half (no speech after peel, no chat opening for a peeled run). (Task 4: `peelAfterCloseIsRefused`, `closeAfterPeelReportsBackground`.)
3. [stop] or [go there!] on a job whose task already ended, or whose home app has quit → no crash; stop just removes the capsule; go there opens the chat where the user is. (Task 1: `stopAfterDoneIsIgnored`; Task 9 manual.)
4. Displays change while capsules are up (main display unplugged, resolution change, Dock/menu bar size) → capsules re-dock on the new main display's visible frame. (Task 3: `slotsFollowAnyVisibleFrame`; Task 6 observes `NSApplication.didChangeScreenParametersNotification`.)
5. The model fails or Ollama quits mid background answer → the capsule shows `Couldn't answer: <reason>` with `ok`, never a stuck pulse. (Task 1: `failMovesWorkingToFailed`; Task 5 routes errors.)

---

### Task 1: `BackgroundJob` model (Core)

**Files:**
- Create: `ClickBaitCore/Sources/ClickBaitCore/Models/BackgroundJob.swift`
- Test: `ClickBaitCore/Tests/ClickBaitCoreTests/BackgroundJobTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct BackgroundJob: Identifiable, Equatable, Sendable {
      public enum Kind: Equatable, Sendable { case answer, snip }
      public enum Status: Equatable, Sendable { case working, done(summary: String), failed(reason: String), stopped }
      public let id: UUID
      public let question: String
      public let kind: Kind
      public let homeBundleID: String?
      public let homePID: Int32?
      public internal(set) var conversation: Conversation
      public private(set) var status: Status
      public private(set) var answer: String        // streamed text so far, then the final speech
      public init(question: String, kind: Kind, homeBundleID: String?, homePID: Int32?, conversation: Conversation)
      public var isWorking: Bool
      public mutating func stream(_ text: String)    // replaces `answer` while working; ignored otherwise
      /// Returns true only the first time (done is reported once).
      public mutating func finish(userText: String, speech: String, code: String?, language: String?) -> Bool
      public mutating func fail(_ reason: String) -> Bool
      public mutating func stop() -> Bool
  }
  ```
  `finish` appends the exchange to `conversation` and sets `.done(summary: JobSummary.make(from: speech))`. `JobSummary` is Task 2: do Task 2 before this task's Step 3.

- [ ] **Step 1: Write the failing tests** (`struct BackgroundJobTests`, Swift Testing)
  - `startsWorking`: new job → `status == .working`, `isWorking`.
  - `finishMovesWorkingToDoneOnce`: first `finish(userText: "q", speech: "It's on. More words.", code: nil, language: nil)` returns `true`, status `.done(summary: "It's on. More words.")`, `conversation.turns.count == 2`; second call returns `false`, turns still 2.
  - `failMovesWorkingToFailed`: `fail("Ollama isn't running")` → `true`, `.failed(reason: "Ollama isn't running")`.
  - `stopAfterDoneIsIgnored`: finish then `stop()` → `false`, still `.done`.
  - `nothingChangesAfterStop`: `stop()` then `finish(...)` → `false`, `stream("x")` leaves `answer` unchanged, status `.stopped`.
  - `streamOnlyWhileWorking`: `stream("Hel")`, `stream("Hello")` → `answer == "Hello"`.
- [ ] **Step 2: Run** `swift test --package-path ClickBaitCore --filter BackgroundJobTests` — expect FAIL (type not found).
- [ ] **Step 3: Implement `BackgroundJob`** in `Models/BackgroundJob.swift` as specified; transitions only from `.working`.
- [ ] **Step 4: Run** the same command — expect PASS.
- [ ] **Step 5: Commit** (if commits were asked for): `git add` the two files; message `Add BackgroundJob: one answer finishing in the background`.

### Task 2: `JobSummary` (Core)

**Files:**
- Create: `ClickBaitCore/Sources/ClickBaitCore/Prompting/JobSummary.swift`
- Test: `ClickBaitCore/Tests/ClickBaitCoreTests/JobSummaryTests.swift`

**Interfaces:**
- Produces: `public enum JobSummary { public static let maxLength = 140; public static func make(from speech: String) -> String }`
- Consumes: `MessageFormat.spokenText(_:)` (drops code), `SentenceSplitter` (`feed`/`flush`), `PillText.fits(_:code:)`, `CoordinateScrubber.scrub(_:).text` (removes stray coordinates).

- [ ] **Step 1: Write the failing tests**
  - `emptyIsDone`: `make(from: "")` and `make(from: "   ")` → `"Done."`.
  - `pillSizedKeptWhole`: `"Yep, it's on!"` → `"Yep, it's on!"`.
  - `firstTwoSentences`: `"VLOOKUP finds a value. It returns the row's value. Use FALSE for exact."` → `"VLOOKUP finds a value. It returns the row's value."`.
  - `cappedAtAWord`: one 300-character sentence of words → result `count <= 140`, ends with `"…"`, and the character before `"…"` is not a space and the cut falls at a word boundary (result minus `"…"` is a prefix of the input ending where the input has a space).
  - `noCodeBlocks`: ``"Run this:\n```bash\nls -la\n```\nThat lists files."`` → result contains no `` ``` `` and no `ls -la`.
- [ ] **Step 2: Run** `swift test --package-path ClickBaitCore --filter JobSummaryTests` — expect FAIL.
- [ ] **Step 3: Implement `make(from:)`**: trim; empty → `"Done."`; `PillText.fits` → as is; else `MessageFormat.spokenText`, take the first two sentences from `SentenceSplitter` (feed + flush), join with a space, then cap at 140 at the last space with `"…"`.
- [ ] **Step 4: Run** — expect PASS; then Task 1's tests too.
- [ ] **Step 5: Commit** (if asked): message `Add JobSummary: the first sentence or two of a background answer`.

### Task 3: `CapsuleLayout` geometry (Core)

**Files:**
- Create: `ClickBaitCore/Sources/ClickBaitCore/Geometry/CapsuleLayout.swift`
- Test: `ClickBaitCore/Tests/ClickBaitCoreTests/CapsuleLayoutTests.swift`

**Interfaces:**
- Produces (Core's `Rect`/`Point`, AppKit orientation: y up, `visible` = the main screen's `visibleFrame`):
  ```swift
  public enum CapsuleLayout {
      public static let maxCapsules = 3
      public static let capsuleSize = (width: 44.0, height: 28.0)
      public static let margin = 8.0, gap = 6.0, cardWidth = 280.0, cardGap = 6.0
      /// Slot frames, index 0 on top; nil beyond maxCapsules.
      public static func slot(_ index: Int, in visible: Rect) -> Rect?
      /// The expanded card under `slot`, right edges aligned, moved up if it would leave `visible`.
      public static func card(under slot: Rect, height: Double, in visible: Rect) -> Rect
  }
  ```

- [ ] **Step 1: Write the failing tests** (visible = `Rect(x: 0, y: 0, width: 1440, height: 875)`)
  - `firstSlotTopRight`: slot 0 == `Rect(x: 1440-8-44, y: 875-8-28, width: 44, height: 28)`.
  - `slotsStackDown`: slot 1 `y == slot0.y - 28 - 6`; slot 2 `y == slot1.y - 34`.
  - `fourthIsRefused`: `slot(3, in:) == nil`, `slot(-1, in:) == nil`.
  - `slotsFollowAnyVisibleFrame`: visible `Rect(x: -1920, y: 200, width: 1920, height: 1050)` → slot 0 `maxX == -8`, `maxY == 1242`.
  - `cardHangsUnderItsSlot`: `card(under: slot0, height: 120, in: visible)` → `width 280`, `maxX == slot0.maxX`, `maxY == slot0.minY - 6`.
  - `cardStaysOnScreen`: visible height 200, `card(under: slot(2)!, height: 180, …)` → `minY >= visible.minY`.
- [ ] **Step 2: Run** `swift test --package-path ClickBaitCore --filter CapsuleLayoutTests` — expect FAIL.
- [ ] **Step 3: Implement** the two functions with the pinned constants.
- [ ] **Step 4: Run** — expect PASS.
- [ ] **Step 5: Commit** (if asked): message `Add CapsuleLayout: where background capsules dock`.

### Task 4: `PeelGate` and `AnswerRun` — answers can change hands mid-stream (no visible change yet)

**Files:**
- Create: `ClickBaitCore/Sources/ClickBaitCore/Models/PeelGate.swift`
- Test: `ClickBaitCore/Tests/ClickBaitCoreTests/PeelGateTests.swift`
- Create: `ClickBait/App/AnswerRun.swift`
- Modify: `ClickBait/App/AskCoordinator.swift` — `respond()` streaming section (currently ~lines 1740–1805) and its post-stream start (~1810)

**Interfaces:**
- Produces (Core):
  ```swift
  /// One answer run's hand-over state: closed → open (model is writing a plain answer) → peeled | closed.
  public struct PeelGate: Equatable, Sendable {
      public init()
      public private(set) var isOpen: Bool
      public private(set) var isPeeled: Bool
      public mutating func open()                 // only from the initial state
      public mutating func peel() -> Bool         // true only while open; then isPeeled, closed
      public mutating func close() -> Bool        // closes; returns isPeeled (true = finish in the background)
  }
  ```
- Produces (app, `@MainActor final class AnswerRun`):
  - `init(question: String, kind: BackgroundJob.Kind, homeBundleID: String?, homePID: Int32?)` — what a peel needs to build its job
  - `var gate = PeelGate()`
  - `private(set) var job: BackgroundJob?` and `var onJobChange: ((BackgroundJob) -> Void)?` (set by the coordinator's `peel()` in Task 5)
  - `func speak(_ sentence: String, using speaker: Speaker)` — speaks only while not peeled.
  - `func stream(_ text: String, foreground: (String) -> Void)` — calls `foreground` while not peeled; after peel updates `job` via `BackgroundJob.stream` and calls `onJobChange`.
  - `func handOver(to job: BackgroundJob)` — used by Task 5.
- `AskCoordinator` gains `@ObservationIgnored private(set) var currentRun: AnswerRun?`.

- [ ] **Step 1: Write the failing `PeelGateTests`**
  - `peelOnlyWhileOpen`: new gate `peel() == false`; after `open()`, `peel() == true`, `isPeeled`, `!isOpen`.
  - `peelTwiceIsRefused`: open, peel, second `peel() == false`.
  - `peelAfterCloseIsRefused`: open, `close() == false`, then `peel() == false`, `!isPeeled`.
  - `closeAfterPeelReportsBackground`: open, peel, `close() == true`.
  - `openAfterCloseStaysClosed`: open, close, open → `!isOpen`.
- [ ] **Step 2: Run** `swift test --package-path ClickBaitCore --filter PeelGateTests` — expect FAIL; implement `PeelGate`; run — expect PASS.
- [ ] **Step 3: Implement `AnswerRun`** in `ClickBait/App/AnswerRun.swift` per the interface.
- [ ] **Step 4: Route `respond()` through the run** — create `let run = AnswerRun(question: display, kind: snip != nil ? .snip : .answer, homeBundleID: frontmostBundleID, homePID: frontmostPID)`, `currentRun = run` just before `provider.stream(request)`; call `run.gate.open()` there; replace `onPartialAnswer?(…)` with `run.stream(…) { onPartialAnswer?($0) }` and every `speaker.speak(…)` in the stream/flush section with `run.speak(…, using: speaker)`. Right after the stream completes (and in the `catch`), `let background = run.gate.close(); currentRun = nil`. No `peel()` caller exists yet, so `background` is always false and behaviour is unchanged.
- [ ] **Step 5: Build** (`xcodegen generate`, then the Debug `xcodebuild` build) — zero warnings. Manual smoke: ask a spoken question → it still speaks sentence by sentence; a ⌥⌘ explanation still streams into the chat.
- [ ] **Step 6: Commit** (if asked): `PeelGate.swift`, `PeelGateTests.swift`, `AnswerRun.swift`, `AskCoordinator.swift` hunks from this task only; message `Route a streaming answer through an AnswerRun that can change hands`.

### Task 5: Peeling off in the coordinator + `BackgroundJobs`

**Files:**
- Create: `ClickBait/App/BackgroundJobs.swift`
- Modify: `ClickBait/App/AskCoordinator.swift` — `begin()` (~line 443), `respond()` post-stream branch, new `peel()`, new chat hand-over helpers

**Interfaces:**
- Consumes: `BackgroundJob` (Task 1), `PeelGate`/`AnswerRun` (Task 4).
- Produces:
  ```swift
  @MainActor @Observable final class BackgroundJobs {
      struct Entry: Identifiable { var job: BackgroundJob; var task: Task<Void, Never>?; var chatLines: [ChatModel.Message]; var id: UUID { job.id } }
      private(set) var entries: [Entry]             // oldest first
      var isFull: Bool                              // entries.count >= CapsuleLayout.maxCapsules
      func add(_ entry: Entry) -> Bool              // false when full
      func update(_ job: BackgroundJob)
      func stop(_ id: UUID)                         // cancels task, job.stop(), removes
      func remove(_ id: UUID)
      var onChange: (() -> Void)?
  }
  ```
  `AskCoordinator` additions:
  - `var canPeel: Bool { currentRun?.gate.isOpen == true }`
  - `@ObservationIgnored var onPeel: ((BackgroundJob, Task<Void, Never>?) -> Void)?` — AppDelegate adds the entry (Task 9) and asks the chat for its lines.
  - `@ObservationIgnored var onPeelRefused: (() -> Void)?`
  - `@ObservationIgnored var onJobUpdate: ((BackgroundJob) -> Void)?`
  - `@ObservationIgnored var jobsAreFull: (() -> Bool)?`
  - `func adoptChat(_ conversation: Conversation)` — sets `conversation`, `chatShown = true`, `snipMemory = nil`.
  - `func detachChat() -> Conversation?` — returns the open chat's conversation (if any and not answering), clears `conversation`, `chatShown`, `snipMemory`.

- [ ] **Step 1: `begin()`** — before the existing `guard state != .listening, state != .thinking, !isAnswering`, add: if `(state == .thinking || isAnswering) && canPeel` → if `jobsAreFull?() == true` { `onPeelRefused?()`; return } else `peel()` and continue into the normal press.
- [ ] **Step 2: `peel()`** — `guard let run = currentRun, run.gate.peel()`; build `BackgroundJob(question: run.question, kind: run.kind, homeBundleID: run.homeBundleID, homePID: run.homePID, conversation: conversation ?? Conversation())`; `run.handOver(to:)`; `run.onJobChange = { [weak self] in self?.onJobUpdate?($0) }`; `speaker.stop()`; `onPeel?(job, askTask)`; then `askTask = nil`, `currentRun = nil`, `conversation = nil`, `snipMemory = nil`, `chatShown = false`, `isAnswering = false`, `pointedInstantly = false`, `state = .idle` (do not cancel the task); log `Peeled off: <kind> to the background (<n> working)`.
- [ ] **Step 3: Background branch in `respond()`** — where Task 4 computes `background`: in the `catch`, if `background`, `run.fail(error.localizedDescription)`-style update (via `run.job` + `onJobUpdate`) and `return` before touching `state`/chat. After `ResponseParser.parse` and `ExplanationCleaner`, if `background`: finish the job with `Prompt.userText(for: request)`, `parsed.response.speech`, `.code`, `.language`; `onJobUpdate?(job)`; log `Background answer done in <duration>`; `return`. Also, for any foreground run: when its first chunk arrives while a job is working, log `First chunk waited behind <n> background answer(s)` (the GPU queue wait the spec asks to record) (skips pointers, snapping, chat, parts, refine, `state`). Add `AnswerRun.finish(...)`/`fail(_:)` wrappers that mutate `job` and return it.
- [ ] **Step 4: Implement `BackgroundJobs`**; `add` refuses beyond 3; `stop` cancels the task.
- [ ] **Step 5: Build** — zero warnings. (Nothing calls `onPeel` yet besides the coordinator; AppDelegate wiring is Task 9.)
- [ ] **Step 6: Commit** (if asked): message `Peel a streaming answer off to the background on ⌃⌥`.

### Task 6: Capsules on screen — `CapsuleView` + `CapsuleController`

**Files:**
- Create: `ClickBait/Overlay/CapsuleView.swift`, `ClickBait/Overlay/CapsuleController.swift`

**Interfaces:**
- Consumes: `BackgroundJobs.Entry`, `CapsuleLayout`, `CompanionTriangle(tone:pulsing:spinning:angle:)`, `Glow`, `CompanionTone`.
- Produces:
  ```swift
  @MainActor final class CapsuleController {
      var onGoThere: ((UUID) -> Void)?
      var onStop: ((UUID) -> Void)?
      var onDismiss: ((UUID) -> Void)?              // "ok" on a failed job
      func sync(_ entries: [BackgroundJobs.Entry])  // create/update/remove panels, re-dock in order
      func slotCenter(forIndex index: Int) -> CGPoint?   // AppKit global, for the peel flight
      func removeAll()
  }
  ```

- [ ] **Step 1: `CapsuleView`** (SwiftUI, given an entry + `isExpanded` binding):
  - Collapsed: 44×28 capsule, `Color.black.opacity(0.55)` fill + `.ultraThinMaterial`, shadow in the tone colour at `Glow.opacity`/`Glow.radius`; mini `CompanionTriangle` (size via `.scaleEffect(0.8)` is fine) with `spinning: isWorking`, `pulsing: isWorking`; a 6 pt dot of the tone colour at the top-right corner when `.done` or `.failed`.
  - Expanded card (280 wide) under it: working → question (1 line, truncated) + `working on it…` + `stop`; done → summary + `go there!` + `later, pls`; failed → `Couldn't answer: <reason>` + `ok`. Buttons styled like the existing confirm pills (`ConfirmController`'s `ConfirmCard`), lowercase.
  - Reduce Motion: no pulse/spin (CompanionTriangle already honours it; the capsule's own glow pulse must check `accessibilityReduceMotion`).
  - Progress bar (spec amendment 2026-10-07): a reusable `CapsuleProgressBar(progress: JobProgress)` — 3 pt, rounded, tone colour on a faint track — shown in the working card. `JobProgress` (in `BackgroundJobs.swift`): `.counted(done: Int, total: Int)` or `.uncounted`; answers are `.uncounted` → a sweeping highlight (Reduce Motion: still, half-filled). Hidden once done, failed or stopped. The tidy-folder plan adds counted progress later.
- [ ] **Step 2: `CapsuleController`** — one `NSPanel` subclass per entry: `[.borderless, .nonactivatingPanel]`, `canBecomeKey/canBecomeMain = false`, `isOpaque = false`, clear background, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, `sharingType = .none`, `hidesOnDeactivate = false`; hosting view subclass with `acceptsFirstMouse` → `true`. Frames from `CapsuleLayout.slot(i, in: mainVisible)` (main = `NSScreen.screens.first`, converted to Core `Rect`); expanded → panel frame = union of slot and `CapsuleLayout.card(under:height:in:)` (card height from the SwiftUI view's measured size). Click on the capsule toggles expanded; a global + local `.leftMouseDown` monitor collapses an expanded card on any click outside its panel. Re-dock on `NSApplication.didChangeScreenParametersNotification`.
- [ ] **Step 3: Build** (`xcodegen generate` first) — zero warnings.
- [ ] **Step 4: Commit** (if asked): message `Add background capsules docked at the top right`.

### Task 7: The peel flight and the fresh companion

**Files:**
- Modify: `ClickBait/Overlay/OverlayController.swift` (new `peel(to:tone:completion:)`, companion pop)
- Modify: `ClickBait/Overlay/OverlayModel.swift` (pop counter), `ClickBait/Overlay/OverlayViews.swift` (pop scale in `CompanionBubbleView`)

**Interfaces:**
- Produces: `func peel(to target: CGPoint, tone: CompanionTone, completion: @escaping @MainActor () -> Void)` on `OverlayController`; `OverlayModel.companionPop: Int` (bumped to replay the pop).

- [ ] **Step 1: Flight** — a one-off `StagePanel` (via `OverlayController.makePanel`) on the companion's screen holding a `CompanionTriangle(tone:pulsing:false, spinning: true)`. Animate with Core Animation on the stage layer's `sublayerTransform` (not per-frame `setFrameOrigin`): 0.12 s stretch (scale 1.35 along the flight direction, 0.8 across), then 0.33 s ease-in-out translate to `target`, scaling to 0.8; on completion remove the panel and call `completion`. If the target isn't on the companion's screen, or Reduce Motion is on, skip the flight and call `completion` at once.
- [ ] **Step 2: Pop** — at flight start bump `companionPop`; `CompanionBubbleView` scales the triangle 0 → 1 over 0.2 s (spring) whenever it changes; Reduce Motion: opacity fade instead.
- [ ] **Step 3: Build** — zero warnings.
- [ ] **Step 4: Commit** (if asked): message `Animate a companion peeling off to its capsule`.

### Task 8: Chat hand-over and reopening

**Files:**
- Modify: `ClickBait/Chat/ChatController.swift`

**Interfaces:**
- Produces:
  - `func stash() -> [ChatModel.Message]` — if open: returns `model.messages`, closes without the shrink animation and without calling `model.onClose`; else `[]`.
  - `func reopen(_ messages: [ChatModel.Message], logoAt logoCenter: CGPoint, in app: NSRunningApplication?)` — `open(logoAt:)`, then `model.messages = messages`, `model.isBusy = false`, and `adopt(app)` when `app` is non-nil.

- [ ] **Step 1: Implement both** per the interface, reusing `open`, `closeNow`, `adopt`.
- [ ] **Step 2: Build** — zero warnings.
- [ ] **Step 3: Commit** (if asked): message `Let a chat be stashed with a background answer and reopened later`.

### Task 9: Wire it together, docs, and the manual check

**Files:**
- Modify: `ClickBait/App/AppDelegate.swift`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Wiring in `AppDelegate`** — own `let jobs = BackgroundJobs()` and `let capsules = CapsuleController()`.
  - `coordinator.jobsAreFull = { jobs.isFull }`.
  - `coordinator.onPeelRefused = { overlay.showShortAnswer("three's a crowd") }`.
  - `coordinator.onPeel = { job, task in` lines = `chat.stash()` (append the job's streamed `answer` as an assistant line only at reopen time); `jobs.add(Entry(job:task:chatLines:))`; `capsules.sync(jobs.entries)`; `overlay.peel(to: capsules.slotCenter(forIndex: jobs.entries.count - 1) ?? …, tone: job.kind == .snip ? .capture : .processing) { }` }.
  - `coordinator.onJobUpdate = { jobs.update($0); capsules.sync(jobs.entries) }`.
  - `capsules.onStop = { jobs.stop($0); capsules.sync(jobs.entries) }`; `capsules.onDismiss = { jobs.remove($0); capsules.sync(…) }`.
  - `capsules.onGoThere = { id in` take the entry; remove it; if `coordinator.detachChat()` returns a conversation, add a done entry: `BackgroundJob` finished with summary `your chat about <first user turn>` (via a `BackgroundJob` init + `finish`, kind `.answer`, chatLines `chat.stash()`); find the home app by `homePID` (`NSRunningApplication(processIdentifier:)`), `activate()` it if running; `coordinator.adoptChat(job.conversation)`; `chat.reopen(lines + [assistant: job.answer], logoAt: overlay.companionTriangleCenter, in: app)`; `capsules.sync` }.
  - On quit (`applicationWillTerminate`): `capsules.removeAll()`.
- [ ] **Step 2: Build** — `xcodegen generate`, Debug build, zero warnings; `swift test --package-path ClickBaitCore` all green.
- [ ] **Step 3: `CLAUDE.md`** — add a short "### Background ClickBaits" section (gesture, capsules, buttons, limits, what doesn't go to the background, the Mission Control risk and its fallback) in the file's existing style.
- [ ] **Step 4: Manual check** with the app running (report results to the user; these can't be built-tested):
  1. Peel mid-answer: glide to top-right, new companion listens at once, answer lands in the capsule with a dot and no speech.
  2. ⌃⌥ while transcribing/deciding: ignored.
  3. A new foreground question is undisturbed when the background answer finishes (state, chat, pointer, speech).
  4. 4th peel → `three's a crowd`, answer carries on in front.
  5. `stop`; `go there!` from another app and another desktop; `later, pls`; click elsewhere folds.
  6. `go there!` with another chat open → that chat becomes a capsule (`your chat about …`).
  7. Over a full-screen app; during Mission Control; Mission Control thumbnails not black (if black: switch capsule panels to `[.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]` and re-order them front on `activeSpaceDidChangeNotification`, as `OverlayController.followSpaces` does).
  8. Reduce Motion; Esc leaves capsules alone; quitting clears them; Ollama quit mid background answer → `Couldn't answer: …` + `ok`.
- [ ] **Step 5: Commit** (if asked): `AppDelegate.swift`, `CLAUDE.md`; message `Wire background ClickBaits: peel, capsules, go there`.
