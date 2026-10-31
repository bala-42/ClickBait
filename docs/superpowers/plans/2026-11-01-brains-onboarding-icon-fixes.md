# Brains, Taby-style onboarding, the new icon, and five fixes

Date: 2026-11-01. Status: plan, not built. Order: fixes first (they ship), then brains with
onboarding, then the icon. Each part is its own commit; core tests and an app build before
every push, as usual.

Taby (`com.heytaby.desktop` 1.0.13, SIA TRIIIS) is closed source. We copy its *flow and
lessons*, never its code, wording or artwork. Everything below is written fresh for ClickBait.

## 1. Fixes (reproduce live first, then fix)

Each one starts with a live reproduction on this Mac, written down with its exact steps, then a
fix in the layer that owns it, then the same steps again.

| # | Fix | Where | Suspected cause (from reading the code, to confirm live) |
|---|---|---|---|
| 1 | Shelf: drag a file out into another app | `NotchViews.swift` `.draggable(url)` on the file tile; `MultiFileDragView` | (a) `.draggable(URL)` exports a URL, not a file, so some apps get a link or text instead of the file. (b) The notch folds 0.4 s after the pointer leaves it (`leaveHold`), so dragging *out* of the notch can tear down the view that owns the drag. Fix: one AppKit drag source for single and multi-file drags (file URLs on the pasteboard, `.copy`), and keep the notch open while a drag it started is in flight. |
| 2 | AirDrop from the notch | `AirDropSender` in `NotchSources.swift`, `AirDropPad` | `NSSharingService` is given no source window (`sharingService(_:sourceWindowForShareItems:sharingContentScope:)`), so from the non-activating notch panel the AirDrop window can open behind other windows, or not anchor at all; the notch folding as the pointer moves to it can strand the "choosing…" state. The comment "ClickBait has no Dock icon" is stale since it became a regular app. Fix: anchor to a window, keep the shelf open while AirDrop is choosing, reset status when the window closes without a callback. |
| 3 | Follow-ups on a dock document card | `AgentDockViews.swift`, `AskCoordinator+Background.swift` | To map live: asking a follow-up on a card that answered about a document should carry the document's text and the card's conversation, answer in the same card, and not open a chat or lose the card. |
| 4 | Cleaner answers in the chat and the cards | `ChatView.swift`, `AgentDockViews.swift` | Both render markdown on their own. One shared renderer: paragraphs spaced, lists with real bullets and numbers, inline code and code blocks, bold, headings shrunk to card size, no stray `**` or `#`. Measured on saved real answers before and after (renders, as the chat renders already do). |
| 5 | Walkthrough "Back" returns to exactly where you were | `AppDelegate.swift` (`tutorial.onFinished`: `home.activate()`) | Today "Back" only brings the app forward. The dock's "go there!" already returns to the exact window and browser tab (`returnHome`). Fix: record the window title, frame and tab when the walkthrough starts, and reuse that path for "Back". |

## 2. Four brains

ClickBait keeps Ollama (it reads the screen with vision models). Brains are named by size, in
plain words, the model behind an (i), as Taby does:

| Brain | Ollama model | Download | Recommended for |
|---|---|---|---|
| Light brain | `gemma4:e2b` | to measure | 8 GB Macs |
| Standard brain | `gemma4:e4b` | ~9.5 GB on disk | 16 GB and up (the default) |
| Big brain | `qwen3.5:9b` | 6.6 GB | a deliberate choice; today's built-in default |
| Galaxy brain | `gemma4:12b` | to measure | 32 GB and up, a deliberate choice |

- **Recommendation** (Taby's lesson: on 8 GB Macs 48 of 58 Standard installs failed and answers
  took a median 41 s against Light's 6.5 s): recommend the largest brain that fits comfortably,
  never above Standard; Big and Galaxy are offered, marked by memory ("needs 32 GB"), never
  recommended. Memory from `ProcessInfo.physicalMemory`.
- **Settings → AI model** becomes **Settings → Brain**: the four brains, which is installed, the
  download size, "recommended for this Mac", switch, and remove a download. A custom Ollama model
  name stays under Advanced. "Quick orders" stays as it is.
- **Measure before shipping:** each brain on ClickBait's labelled questions and the screen bench
  (`ModelCompareTests`, `AskBench`): accuracy, first answer time, memory. Publish the numbers in
  `docs/features/ask-and-answers.md`. If Light can't point usefully, Light says so in its (i).
- **Default** moves from `qwen3.5:9b` to the recommended brain for the Mac, for new installs only;
  existing settings are kept.

## 3. Onboarding, Taby's flow, ClickBait's steps

Taby's order: hello → choose your brain (recommended for this machine, its download size) → the
brain installs **in the background while setup carries on** → place the notch → notifications
(skippable) → say hello (a voice check) → "almost ready" → try your first question (tap a
suggestion, it's asked for you). Back on any step undoes that step's choice.

ClickBait's setup already goes one step at a time and already downloads the model itself with
progress (`OllamaSetup.pull`, `ModelSetupSection`). The new order:

1. **Hello:** the bean says hi; one line on what ClickBait is; "step 1 of 7".
2. **Choose your brain:** the four cards, the recommended one preselected, size and "runs on
   this Mac (24 GB)". No Ollama: one button to get it, then the step checks again by itself.
3. **The brain downloads in the background** and setup moves on; a small progress line stays in
   the corner of every later step.
4. **Microphone**, 5. **Accessibility**, 6. **Screen Recording** (as now, with the relaunch it
   needs, resuming on the same step).
7. **The notch:** on a Mac with a notch, point at it to see it peek; a toggle to leave it off.
8. **Say hello:** hold ⌃⌥ and say "hello"; the triangle listens in pumpkin and answers. Also
   checks the speech model (downloads it here if missing).
9. **Your first question:** three suggested questions to tap ("where's the share button?", a
   highlight-and-explain, "dark mode on"); tapping one asks it for real once the brain is ready,
   otherwise "your brain is still downloading, 2 min".

Every step has Back (undoes its choice) and the existing small-letters look.

## 4. The icon

- A see-through pearl bean (the notch bean's shape and pearl), its eyes the top two loops of ⌘
  worn as round glasses, the white companion triangle as an eyepatch over one lens.
- Behind it, the Hubble Ultra Deep Field, the same picture as the website's closing "say hello"
  and the bean's hyperspace in the notch. NASA/ESA, CC BY 4.0: credited in About and
  `THIRD_PARTY_NOTICES.md`.
- Drawn as vector art, exported to every `AppIcon` size; checked at 16 px (the glasses and patch
  must still read) and in the Dock on light and dark wallpapers. The menu bar keeps the plain
  triangle.

## Out of scope

Taby's productive mode, site blocking, cloud brain and analytics; any Taby code, copy or art.
