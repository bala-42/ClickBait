# Background ClickBaits — design

Date: 2026-10-07 · Status: built (capsules); amended 2026-10-11 to HeyClicky's agent dock, awaiting review

## Why

A model answer takes ~8–20 s on a local model, and today ClickBait does nothing else meanwhile: holding ⌃⌥ while it's thinking is ignored (`AskCoordinator.begin()` returns). The user wants to send that answer away to finish on its own, keep a fresh companion at the cursor, and pick the result up later — quietly, without pop-ups or stolen focus. *One ClickBait went to work; another stayed with you.*

## Scope

In: answers in progress (orange) and snip explanations (red), sent to the background by ⌃⌥; up to 3 capsules docked top-right; expand → summary → [go there!] / [later, pls].

Out (later, each its own design):
- Walkthroughs, Mac actions and long file jobs in the background (no long file job exists yet).
- Internet Mode (🔒/🌐, `InternetManager`). It overturns the "no web lookups" privacy rule in CLAUDE.md, so it gets its own decision and design.
- Keeping capsules across relaunches. Capsules live in memory only.

## Behaviour

### Peeling off (amended 2026-10-11: HeyClicky's spawn)
- Allowed only while the model is writing a plain answer: after the instant-answer, order, sorting and walkthrough decisions have passed. Before that (transcribing, deciding), ⌃⌥ stays ignored as today.
- Holding ⌃⌥ then **peels** it, timed from HeyClicky's demo video (102.5–103.2 s, stepped at 1/30 s; `AgentDock.spawn`):
  1. 0–0.1 s: the companion turns the job's colour (Pumpkin answer, Strawberry snip; Shamrock for a future tidy-up) and grows to 2× with its glow.
  2. 0.1–0.65 s: it flies to the top slot on `FlightArc`'s curve, swell and easing, but in a fixed 0.55 s (the video's flight; an ordinary flight of that distance would take 1.4 s). The new tile fades in at the slot during the first 30% and the older tiles slide down a slot at the same time, so the triangle flies into a tile that is already there. Past halfway it shrinks to the tile's 14 pt and turns upright.
  3. As it leaves (0.1 s), a fresh Azure companion pops in at the cursor (scale 0 → 1 over 0.2 s) and listens. The same press is the next question.
- Any speech from that answer stops; background answers never speak or point.
- Reduce Motion: no flight. The tile fades in and the companion turns back to Azure.
- A 4th while 3 exist: refused with a short pill "three's a crowd"; the answer carries on in front, nothing listens.
- If the answer was a follow-up in an open chat, that chat steps away with it (hidden, conversation kept in the job).

### The tile (amended 2026-10-11, replaces the capsule)
Measured from the video at ~2.1 px a point (`AgentDock`):
- A dark rounded square, 33×33 pt, corner 10 pt (continuous), ~90% opaque (#26292A), a hairline edge, and a soft glow in the job's colour (drawn once and faded, never re-blurred).
- Its triangle inside, 14 pt, pointing up, with the pills' softer glow.
- A 6 pt status dot, centred 4.5 pt in from the top-right corner: Azure while working, Aqua green when done, grey when failed or stopped.
- Working: the triangle turns a third at a time (the companion's spin, from its cached drawing). Done: the tile's glow pulses until the card is opened. Failed or stopped: dimmed and desaturated. Reduce Motion: working pulses slowly instead of spinning.
- No sound, no pop-up, no focus change, no dock bounce.

### Docking (amended 2026-10-11)
- Top-right of the main display (the one with the menu bar): one column, the first tile 32 pt below the menu bar, the tiles' right edge 27 pt from the screen's edge, 42 pt top to top, at most 3. **Newest on top**: a new job takes the top slot and the others slide down. When one goes, the ones below move up.
- Each tile and card is its own small window (never a screen-sized one): on every desktop, over full-screen apps, stationary in Mission Control, never in screenshots or screen sharing.
- Above normal windows, below system notification banners (a banner may pass over them).

### Progress bar (amended 2026-10-07)
Every expanded capsule shows a slim progress bar (3 pt, tone colour on a faint track, rounded) under its text while work runs:
- Determinate when real counts exist (a tidy-up: files read, filed, moved, put back).
- An answer has no countable steps: a slim sweeping highlight instead — never a made-up percentage.
- Reduce Motion: the sweep is replaced by a still, half-filled track; determinate bars just update.
- Hidden once the job is done, failed or stopped.

### Cards (amended 2026-10-11: HeyClicky's cards)
Clicking a tile hangs a card 8 pt under it, right edges lined up, kept on screen: 288 pt wide, corner 12 pt, dark see-through glass (blur, #1C1E1E at 84%, a 5% tint of the job's colour), a hairline edge and a glow in the job's colour. Padding: 14 pt at the sides, 15 pt at the top. The title row: the question in UPPERCASE (10 pt semibold, one line, truncated), a lowercase status badge in the job's colour (~36×15 pt), and a ✕ (14 pt circle). Clicking the tile again, or anywhere else, folds it.
- **Working:** a terminal icon and the line the answer is writing now (12 pt grey, ≤2 lines, the latest streamed sentence), then the progress bar. ✕ = stop: it cancels the job and the tile goes.
- **Done:** "done", the summary (13 pt semibold, ≤3 lines; `JobSummary`), then **suggested next:** up to 2 pill buttons (20 pt tall), written by the local model when the card first opens (text only, ~1 s, its own request; nothing is shown if it's slow or empty). A suggestion is sent as a typed follow-up in that job's chat (it goes there). **follow up:** [text] (the chat opens there with the field focused) and [voice] (the chat opens there, listening as with ⌃⌥). Then **[later, pls]** (folds the card, the tile stays) and **[go there!]** (the job's colour). ✕ dismisses the job.
- **Failed:** "failed" in grey, "Couldn't answer: <reason>", ✕ removes it.

### The result pill (added 2026-10-11)
When a job finishes, its summary shows once in a pill beside the companion, wherever the cursor is (12.5 pt medium, white, on the job's colour, ≤2 lines, ≤330 pt wide, corner 4 pt). It fades after ~5 s. It waits while ClickBait is speaking, during a walkthrough or a tour, and while the user is holding a hotkey, then shows. The tile's dot turns Aqua green either way.

### The menu bar
"Background ClickBaits" stays: it lists the jobs and their status.

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
