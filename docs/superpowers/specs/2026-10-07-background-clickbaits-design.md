# Background ClickBaits — design

Date: 2026-10-07 · Status: draft for review

## Why

A model answer takes ~8–20 s on a local model, and today ClickBait does nothing else meanwhile: holding ⌃⌥ while it's thinking is ignored (`AskCoordinator.begin()` returns). The user wants to send that answer away to finish on its own, keep a fresh companion at the cursor, and pick the result up later — quietly, without pop-ups or stolen focus. *One ClickBait went to work; another stayed with you.*

## Scope

In: answers in progress (orange) and snip explanations (red), sent to the background by ⌃⌥; up to 3 capsules docked top-right; expand → summary → [go there!] / [later, pls].

Out (later, each its own design):
- Walkthroughs, Mac actions and long file jobs in the background (no long file job exists yet).
- Internet Mode (🔒/🌐, `InternetManager`). It overturns the "no web lookups" privacy rule in CLAUDE.md, so it gets its own decision and design.
- Keeping capsules across relaunches. Capsules live in memory only.

## Behaviour

### Peeling off
- Allowed only while the model is writing a plain answer: after the instant-answer, order, sorting and walkthrough decisions have passed. Before that (transcribing, deciding), ⌃⌥ stays ignored as today.
- Holding ⌃⌥ then: the companion stretches toward the top-right, snaps and glides (~0.45 s) to its capsule slot, the capsule fading in as it lands. At once a fresh triangle pops in (~0.2 s) at the cursor and starts listening — the same press is the next question.
- Any speech from that answer stops; background answers never speak.
- Reduce Motion: no stretch or glide; the capsule fades in.
- A 4th while 3 exist: refused with a short pill "three's a crowd"; the answer carries on in front, nothing listens.
- If the answer was a follow-up in an open chat, that chat steps away with it (hidden, conversation kept in the job).

### The capsule
- A dark translucent pill (~44×28 pt) with a mini triangle inside, a soft glow in its state colour (`Glow` settings): Pumpkin for an answer, Strawberry Red for a snip explanation.
- Working: capsule and triangle pulse; the triangle keeps its turn-a-third spin.
- Done: pulse stops, glow stays, a small dot of the same colour appears in its corner. No sound, no pop-up, no focus change, no dock bounce.
- Failed: as done, and the card says why.

### Docking
- Top-right of the main display (the one with the menu bar), 8 pt below the menu bar and 8 pt in from the right edge, stacked downward with 6 pt gaps, at most 3, oldest on top. When one goes, the others close up.
- On every desktop, over full-screen apps, stationary in Mission Control; never in screenshots or screen sharing.
- Above normal windows, below system notification banners (a banner may pass over them).

### Progress bar (amended 2026-10-07)
Every expanded capsule shows a slim progress bar (3 pt, tone colour on a faint track, rounded) under its text while work runs:
- Determinate when real counts exist (a tidy-up: files read, filed, moved, put back).
- An answer has no countable steps: a slim sweeping highlight instead — never a made-up percentage.
- Reduce Motion: the sweep is replaced by a still, half-filled track; determinate bars just update.
- Hidden once the job is done, failed or stopped.

### Expanding
Clicking a capsule unfolds a small card (~280 pt wide) beneath it, inside the screen. Lowercase buttons, like the existing [let's see!] [later.] pills:
- Working: the question (one line, truncated), "working on it…", the progress bar, **[stop]** → cancels the job, removes the capsule.
- Done: the summary (first one or two sentences of the answer, ≤140 characters), **[go there!]**, **[later, pls]**.
- Failed: "Couldn't answer: <reason>", **[ok]** → removes it.
- **[later, pls]** or a click anywhere else folds the card back to the capsule; the dot stays.

### Go there
- Activates the app the question was asked in (if it's still running; otherwise stays where the user is) and reopens the chat there with the whole conversation, ready for follow-ups. The capsule goes away.
- If another chat is open at that moment, it isn't lost: it becomes a done capsule itself (summary "your chat about <its first question>"). It always fits: the capsule being opened has just freed its slot.

### Not carried to the background (first version)
Pointing, close-up refinement and snip parts tours are skipped for a peeled answer: by the time the user looks, the screen has moved on. The answer's words still say where things are.

### Other rules
- Esc stops only the foreground, as today; capsules have [stop].
- Quitting ClickBait clears all capsules; nothing is written to disk.
- Blocklist, privacy and provider rules are unchanged (the job already passed them when it started).
- Ollama runs one request at a time: a new foreground question waits behind a background answer. The log records the wait.

## Architecture

### ClickBaitCore (no AppKit; unit-tested)
- `Models/BackgroundJob.swift` — `BackgroundJob` (id, question, tone `.answer | .snip`, home app bundle ID and pid, `Conversation`, status `.working | .done(summary) | .failed(reason) | .stopped`, full answer text). Status changes only forward; `done` is reported once.
- `Prompting/JobSummary.swift` — `JobSummary.make(from answer: String) -> String`: first one or two sentences via `SentenceSplitter`, cleaned with `MessageFormat` (no code blocks, no coordinates), ≤140 characters at a word boundary with "…"; empty → "Done."; a `PillText.fits` answer is kept whole.
- `Geometry/CapsuleLayout.swift` — slot frames from a screen's visible frame (AppKit coordinates, any origin), `maxCapsules = 3`, sizes/gaps above; the expanded card's frame, kept on screen.

### App
- `App/AnswerOutput.swift` — protocol for every output of the answer-streaming part of `respond()`: partial text, sentence to speak, finished (response, pointers), error, chat lines, and "settle" (the state change at the end). `ForegroundAnswerOutput` does exactly what the code does today (speaker, overlay callbacks, chat, `state`). `BackgroundAnswerOutput` only updates its `BackgroundJob`: never speaks, points, opens or untucks a chat, or touches `state`.
- `AskCoordinator`:
  - `answerOutput` (foreground by default); the streaming part of `respond()` and everything after it route through it.
  - `canPeel`: set when the plain-answer model request starts, cleared when it ends.
  - `begin()`: if `state == .thinking || isAnswering` and `canPeel` and fewer than 3 jobs → `peel()`, then continue as a normal press. If `canPeel` and 3 jobs → "three's a crowd" pill, return. Otherwise ignored as today.
  - `peel()`: creates the job, swaps in a `BackgroundAnswerOutput`, hands over `askTask`, `conversation`, `snipMemory` and the chat's messages; stops speech; skips pointers/refine/tour for that run; resets `isAnswering`, `chatShown`, `state = .idle` without cancelling the task.
  - `onPeel: ((BackgroundJob) -> Void)?`.
- `App/BackgroundJobs.swift` — `@MainActor @Observable` list of jobs: add (≤3), update, finish, stop (cancels the task), remove. Each entry holds its work — `.answer(BackgroundJob)` now, `.tidy(TidyRunner)` from the tidy-folder spec — and exposes a shared `JobProgress` (`.counted(done, total)` or `.uncounted`) for the bar.
- `Overlay/CapsuleController.swift` + `Overlay/CapsuleView.swift` — one `NSPanel` per capsule: borderless, non-activating, clickable, never key; `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`; `level = .statusBar`; `sharingType = .none`. `CapsuleView` reuses `CompanionTriangle`, `Glow`, `ToneFill`; the card unfolds inside the same panel (panel resized to `CapsuleLayout`'s card frame). A global mouse-down monitor folds an open card on any click elsewhere. Reduce Motion: no pulse/spin.
- `OverlayController.peel(to slot: CGRect, tone:)` — stretch, then a flying triangle in a small `StagePanel` moved by layer offset (as the companion), ~0.45 s; completion callback shows the capsule. The cursor companion is hidden for the flight start and pops back (scale 0 → 1, 0.2 s).
- `ChatController` / `ChatModel` — reopen with a given conversation's messages (extends the path `undoExplain` uses to restore a detached chat), at the home app.
- `AppDelegate` — wires `onPeel` → jobs + overlay peel + capsules; [go there!] → remove its capsule, turn any open chat into a done capsule, activate the home app, reopen the chat.

### Risk to check
The full-screen overlays deliberately avoid `.canJoinAllSpaces` because screen-sized panels on all desktops turned Mission Control's desktop thumbnails black. Capsule panels are small; this must be checked by hand. Fallback: the overlays' `.moveToActiveSpace` + `followSpaces` approach.

## Testing

Automatic (Swift Testing, `ClickBaitCoreTests`):
- `JobSummary`: first one/two sentences; 140-character cap at a word; no code block or coordinates; empty → "Done."; pill-sized answer kept whole.
- `CapsuleLayout`: three slots below the menu bar on the right; 4th refused; non-zero screen origin; card on screen at the lowest slot.
- `BackgroundJob`: working → done / failed / stopped; done reported once; no change after stopped.
- `swift test --package-path ClickBaitCore` and the Debug `xcodebuild` build, no warnings.

By hand:
1. Peel mid-answer: glide to top-right, new companion listens at once, the answer lands in the capsule with a dot and no speech.
2. ⌃⌥ while transcribing/deciding: ignored.
3. The new foreground question is undisturbed when the background answer finishes (state, chat, pointer).
4. 4th peel: "three's a crowd", answer carries on in front.
5. [stop]; [go there!] from another app and another desktop; [later, pls]; click elsewhere folds.
6. Go there with another chat open → that chat becomes a capsule.
7. Over a full-screen app; during Mission Control; Mission Control thumbnails not black.
8. Reduce Motion; Esc leaves capsules alone; quitting clears them.
