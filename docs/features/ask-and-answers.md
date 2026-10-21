# Asking and answering

The ⌃⌥ ask flow, ⌥⌘ explain, spoken commands, the models, instant answers (no model), pointing accuracy and listening. Part of the project rules (see `CLAUDE.md`).

#### Ask flow (Milestone 1)
1. User **holds Control+Option** → start mic recording, capture screenshot of the display under the cursor, snapshot AX context (frontmost app name, window title, focused element role/title).
2. User **releases** → stop recording → transcribe with WhisperKit.
3. Downscale screenshot so the long edge is ≤ 1280px (keep the scale factor!) → send screenshot + transcript + context to Ollama (`OllamaProvider`).
4. Model must reply with JSON matching `AssistantResponse`:
   ```json
   {
     "speech": "Click the Share button in the top right.",
     "pointers": [{ "x": 1180, "y": 42, "label": "Share" }]
   }
   ```
   Coordinates are in the **downscaled screenshot's pixel space**. Parser must tolerate code fences / leading text and fall back to speech-only if JSON is invalid.
5. Map pointer coords → global screen points (account for downscale factor, Retina backing scale, display origin; AppKit's origin is bottom-left).
6. **Snap**: hit-test the AX element at that point; if a nearby actionable element (button, link, menu item, text field) within ~40pt better matches `label`, move the pointer to that element's center. Log original vs snapped.
7. Speak `speech`, animate pointer on the overlay, auto-dismiss after ~6s or on next click/Escape.

#### Explain flow (added during M1)
Highlight text, then press and release **Option+Command** alone (no other key in between; `ChordDetector` in Core). The selected text is read via AX (`kAXSelectedTextAttribute`), sent with a screenshot for context, and the model returns a concise 2–4 sentence explanation in `speech` (usually no pointers). Same blocklist, provider and privacy rules as Ask. When Accessibility gives no selection, the fallback sends ⌘C (`SelectionReader`, clipboard restored) — but only once a possible second tap has passed (a double tap opens the chat and needs no selection), and never when the app's ⌘C menu item is disabled (`SelectionReader.copyIsEnabled`, read by its shortcut): a ⌘C with nothing highlighted made macOS play its alert sound on every ⌥⌘ double tap (2026-10-12).

**Missed releases (2026-10-21, adapted from Sentient OS).** A password field hides key events from monitors, so a hotkey release can go missing. Every `HotkeyMonitor.healthInterval` (1.5 s) the monitor puts back a missing monitor and compares a hold with the keyboard (`NSEvent.modifierFlags`); if they disagree on two checks in a row, the hold is cancelled (`ChordDetector.reconcile`), never completed. The notch's Esc comes from `InputInterceptor.onEscapeSeen` (the tap already sees every key), not a global key monitor of its own.

#### Commands (added after M1, step 10)
Direct orders spoken with ⌃⌥ are recognised from the transcript by `CommandParser` (Core) — plain rules, never the vision model (qwen2.5vl:7b missed real orders and acted on questions). Questions never act. Built-ins: open/quit app, volume, mute, Dark/Light Mode; plus Shortcuts the user ticked in Settings (the tick is the permission — they run without a prompt). Everything goes through `ActionCatalog.resolve` before `ActionExecutor` runs it. Unknown app names fall through to a normal answer.

#### Models (2026-10-04)
- **One model by default: qwen3.5:9b** for everything — screen questions, pointing, snips, parts, plans, sorting, progress checks and order checks. A second model for order checks (qwen2.5vl:3b, ~0.15 s vs ~0.6–1.8 s) is optional in Settings ("Quick orders"), off by default: with both loaded (~10 GB) and Chrome, a VM and Xcode open, a 24 GB Mac had 14% memory free and was swapping, and both models ran at half speed (a 20 s answer; prompts read at ~200 tokens/s). With one model: 42% free, text prompts read at 400–630 tokens/s. If a second model is set and pushes the main one out, `OllamaProvider.fastModelEvictsMain` routes everything to the main model for the run.
- Models load at launch and stay loaded while ClickBait runs (`keep_alive: -1`); `unload()` frees them when it quits.
- Requests send `"think": false`: Qwen 3.5 otherwise thinks first (~10 s on a one-line answer; it once used the whole reply budget and returned nothing).
- Qwen 3 / 3.5 give positions as 0–1000 of the image whatever the prompt says (`CoordinateScale.thousandths`, chosen by model name); the element list is given in that scale (`PromptElement.line(for:)`, header without a unit) and `ResponseParser.parse(…, scale:)` converts back. Saying "0–1000" in the prompt made it refuse to point (19/39 vs 27/39).
- qwen3.5 can't reuse an unchanged prompt between requests (Ollama: "forcing full prompt re-processing … hybrid/recurrent memory"): every request reads its whole prompt. A screen question is ~2,800 tokens (instructions ~1,050, screenshot ~920, element list ~700) ≈ 8 s at ~350 tokens/s.
- Model replies to orders pass `OrderCheck.sanitized` (an app to open/quit must be named in the order; "this file" is never a new name).

#### Instant answers (no model, 2026-10-04)
Only when there's no doubt; anything less takes the normal model path (user's rule: speed must never compromise functionality or robustness).
- **Pointing:** "where's / show me / point at / find the X" (`InstantAnswer.locateTarget`) with exactly one on-screen element named exactly X (`uniqueElement`; two of them in different places → the model decides) points at once (blue, ~0.1 s). The model still answers in words; its own pointers are ignored that time (`AskCoordinator.pointedInstantly`).
- **Menu walkthroughs:** a how-to or order whose task words (`taskPhrase`: openers, "my/the/this", the app's name stripped) equal exactly one menu item (`menuPlan`: "clear history" → History ▸ Clear History…) starts at once with open-the-menu + choose-the-item; what follows (a dialog's button) is planned by the model once the item is chosen.
- **"Show me …" always points (blue)** — the thing, or even "show me how to…" (`TutorialQuestion.asksToBeShown`; user's rule): never a lavender walkthrough, except a well-known website visit, which stays a typing step. "How do I… / walk me through… / orders" are walkthroughs.
- **Finding from the element list (text only):** a "where's / show me / point at / find X" whose X isn't named exactly is matched by a close name first (`closeElement`: every word of X in one element's name, "sidebar" → "Show Sidebar"), then by the model picking from the element list as text (`Prompt.pickSystem`, `pickElement`: ~1.5 s instead of ~9 s with the screenshot; 9/10 on a Safari toolbar test). The pick can return several elements (`{"ids": [...]}`, `pickedIDs`, at most 3): "show me where the back and forward buttons are" needs one per thing named, or it falls back to the screenshot (it used to pick only Back). "Show me / tell me where the X is/are (located)" and polite leads ("can you…") are recognised by `locateTargets`, so names on screen match instantly. **Content isn't picked from the list:** a request naming a date, day, month, number or event ("point to October 27th", "today's date", "my 3pm meeting", `InstantAnswer.namesContent`) skips the exact match and the pick and reads the screenshot. The list holds controls only, so in Calendar the pick landed on the nearest button ("Today" for Oct 27, "View" for today's date). Each pick must also fit what was named (`InstantAnswer.pick(_:fits:)`: a word of the target or a synonym — settings/preferences, back/previous, refresh/reload… — in the element's name), else the screenshot; the pick prompt says content is never in the list. The log names the target words and the picked element ("Pick for back + forward: \"Back\", \"Forward\"") so a wrong pick can be read off. Nothing fits → the screenshot as before. Finding questions skip the order check (~1.5 s). Unnamed text fields and areas are listed as "text box" ("where do I type?"). The pick runs for any locating question ("where do I type my message?", "which button sends it?" — `ImpliedPointer.isLocating`), not only "where's the X"; "show me how…" (possibly several pointers) still reads the screenshot. "… in Safari / on the toolbar / at the top" is where to look, not part of the name (dropped when something follows the preposition, so "Sign In" stays). An app named in a finding question that isn't in front ("show me the Share button in Safari") is opened or switched to first (green, `openForTutorial`), then ClickBait looks again and points (blue).
- An instant pointer answers without the model ("Here's New chat."): the model's sentence cost ~8 s of the GPU and the next question queued behind it.
- Pointing is always blue (`OverlayModel.tone`: guiding → idle), even while the words are still streaming.
- "Where are the back and forward buttons?" points at both when each is named exactly once (`locateTargets`; all or nothing). When the app in front has nothing on the cursor's display, the element list comes from the app whose window is under the cursor (`AXInspector.appPID(at:)`; its main window if it has no focused one) — instant pointing found 0 elements otherwise.
- An app menu named like its app ("Safari ▸ Clear History…") is a menu step, not an app to open (`separatingSetup` skips steps whose instruction says "menu").
- Element lists read the menu bar's titles before the window (a web page could use up the 0.4 s / 150-item budget, and the "Safari" menu wasn't found for 7 s).
- After the last planned step: if it was a dialog's button (AXButton) and that button is gone, the walkthrough finishes at once; otherwise the model is asked as before (a menu item usually opens a dialog).
- Guide motion: glide period 0.38 s, turn 0.3 s, label 0.22 s (was 0.6 / 0.45 / 0.3: "pointing must be immediate and quick"). A finished walkthrough shows a tick ("done" with ✓; "✓ Done!" in the chat).
- **Sorting how-tos (qwen3.5, ~0.8 s):** before planning, a request that isn't an instant website/menu walkthrough and doesn't ask outright ("show me how / walk me through / guide me / teach me / step by step": `insistsOnWalkthrough`) is sorted (`Prompt.sortSystem`, `sortRequest`): "answer" (about content — code, text, facts) skips the plan, which used to take 4–8 s and come back empty (one question took 20 s). Unsure or slower than 3 s → plan as before. The sort runs **alongside** the plan (both `async let`; a "question" verdict drops the plan), not before it, and is skipped for a how-to that names an installed app ("how do I open Safari history"). qwen3.5 sorted 23/24 and 15/16 unseen; qwen2.5vl:3b called every Mac task an answer (14/24, 16/24), so it isn't used.
- Models load at launch and stay loaded while ClickBait runs (`keep_alive: -1`, user's decision); `OllamaProvider.unload()` frees them when ClickBait quits.

#### Pointing accuracy
Spoken and typed asks send the model a numbered list of up to 50 clickable things (question-word matches first, then open-menu items, then screen order) Accessibility reports on the captured display (`AXInspector.visibleElements`: open menus first, then the focused window, then menu bar titles; 0.4 s budget). The model may point by `"element": id`; when it gives x/y with a name that matches a listed element within 250 px, the parser uses that element's exact center. At ⌃⌥ press ClickBait sets `AXManualAccessibility` on the frontmost app so Chrome/Electron apps build their tree. Pointers no accessibility element confirms get a second look: a 1280×800 close-up (640×400 pt at 2× — qwen2.5vl's coordinates drift at other sizes) with the locate prompt; the triangle starts toward the rough spot and is retargeted when the close-up answers (~3–5 s). A new question cancels a running close-up. The close-up result is checked with Accessibility: a name match snaps onto the element; if Accessibility sees something else there (or the close-up finds nothing where Accessibility can see), the pointer is withdrawn ("I couldn't find that on screen"). Pointers are only kept for where/how/show/click/open questions.

#### Listening
Recording continues 0.35 s after ⌃⌥ is released. `AudioConditioner` skips silent recordings (peak < 0.01), lifts quiet ones (up to 12×) and adds 0.2 s lead-in; Whisper's own no-speech filter is off. What was heard shows in a tiny pill while thinking.

## Speed

**Screenshot size bench (`AskBench`, Debug, 2026-10-21; qwen3.5:9b, 3024×1964 capture, Chrome and Terminal in front).** One capture kept in memory, sent at several long edges: a general question, the menu bar read from the picture, and "where is …?" with the element list as ClickBait sends it. Three runs:

| long edge | general answer (median) | menu names read | where-is hits (with list) |
|---|---|---|---|
| 1280 | 8.3 / 8.4 / 8.0 s | 9/12, 15/30 | 10/12, 15/18 |
| 1024 | 7.1 / 9.0 s | 9/12 | 10/12 |
| 896 | 6.7 / 8.0 / 7.1 s | 10/12, 15/30 | 10/12, 15/18 |

896 px saves ~0.4–1.6 s with the same pointing and menu reading. Not measured: reading small text (code, error messages, 11–13 pt), which a smaller picture risks most. Without the element list the model found no menu-bar item from the picture alone, even at 1280. `ScreenshotEncoder.maxLongEdge` stays 1280 until small-text reading is measured. Run with `open -W -n --env CLICKBAIT_ASK_BENCH=1280,896 --env CLICKBAIT_ASK_BENCH_OUT=<folder> <ClickBait.app>` (through `open`, so the app's own Screen Recording permission applies), with ClickBait not in use.

**Model comparison (2026-10-21; M4 Pro, 24 GB; `ModelCompareTests` + `AskBench` with `CLICKBAIT_ASK_MODEL`).** qwen3.5:9b (6.6 GB, llama.cpp runner) against gemma4:e4b (9.5 GB on disk, 10 GB loaded, nvfp4, Ollama's MLX runner, vision, Apache-2.0), both with thinking off as ClickBait sends them.

| task (text, ClickBait's prompts and parsers) | qwen3.5:9b | gemma4:e4b |
|---|---|---|
| code questions (16; explain, fix, write) | 15/16, median 3.3 s | 8/16, 0.6 s — never fills `code` (0/7 that need it); one backwards fix |
| route (10), orders (8), pick (4) | all right, 0.9–1.8 s | all right, 0.1–0.2 s |
| dictation (4), search words (3), suggestions (2), morning (2) | all right, 0.8–1.5 s | all right, 0.2–0.5 s |
| screen: where-is with the element list (30, two captures) | 25/30, ~10 s | 23/30, ~0.5 s |
| screen: general answer | ~9.5 s | 0.4–2.3 s |
| screen: menu names from the picture alone | weak (guesses Finder's menus) | weak (same guess) |

qwen's two text "misses" were right answers in other words. The bench found two real bugs, fixed in 01da35e: the pick schema forced one id (the model could never say none), and the morning prompt's examples were copied onto unrelated days. Run: `CLICKBAIT_LIVE_COMPARE=qwen3.5:9b,gemma4:e4b CLICKBAIT_COMPARE_OUT=<folder> swift test --package-path ClickBaitCore --filter ModelCompare`; screens: `open -W -n --env CLICKBAIT_ASK_BENCH=1280 --env CLICKBAIT_ASK_MODEL=<model> --env CLICKBAIT_ASK_BENCH_OUT=<folder> <ClickBait.app>`.
