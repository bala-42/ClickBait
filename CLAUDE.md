# ClickBait

> The only clickbait worth following.

ClickBait is a free, open-source (Apache 2.0), local-first AI companion that lives next to your cursor on macOS. Hold a hotkey, ask a question out loud, and it looks at your screen, answers by voice, and **points at exactly what to click**.

## Product principles
1. **Free and private by default.** Default path uses local models only. No account, no server, no telemetry. Screenshots never leave the machine.
2. **No paid keys, ever (decided 2026-10-10).** ClickBait must work fully for someone without any API key or paid account — most users, and the developer, don't have one. Local models answer; the optional internet features are free and keyless. The Anthropic provider was removed (roadmap D, done 2026-10-10); Ollama is the only provider.
3. **Point, don't just talk.** The overlay pointer is the core magic. Accuracy matters more than eloquence.
4. **Fast feels smart.** Target: spoken answer starts < 3s after the hotkey is released (measured: ~8 s for a screen question on qwen3.5:9b; instant pointing ~0.05 s). Stream everything.
5. **Portable core.** Keep logic that isn't macOS-specific in `ClickBaitCore` (no AppKit/SwiftUI imports) so a Windows shell can come later.

## Differentiators (earlier ideas; the master roadmap below takes precedence)
- **Guides: "show it once, it guides forever."** Record a workflow → saved as a portable JSON guide (steps + target element descriptions + AX identifiers, not video) → anyone can replay it with the pointer guiding them on their own screen. Guides re-locate targets on the live UI so they survive UI changes.
- **Autonomy slider.** Show me → Do it with me (ghost cursor, approve each click) → Do it for me.
- **Context-aware dictation.** Speak, it cleans up the text using what's on screen, inserts it into the focused field.
- ~~**Background agents** (BYOK only) via tool-use loop + MCP.~~ Dropped with BYOK (2026-10-10); revisit only with a free, local route.

## Tech stack
- Swift 5.10+, SwiftUI + AppKit, **macOS 14+, Apple Silicon**.
- Project generated with **XcodeGen** (`project.yml`). Never hand-edit `.xcodeproj`; regenerate it.
- Non-sandboxed app (needs Accessibility + Screen Recording). Hardened runtime on.
- Dependencies via Swift Package Manager:
  - `WhisperKit` (argmaxinc) for on-device speech-to-text.
  - Nothing else unless justified in the PR/commit message.
- Local LLM: **Ollama** HTTP API at `http://localhost:11434` (user installs Ollama and pulls a vision model). Model name configurable in Settings.
- No cloud model and no API keys (2026-10-10): the Anthropic provider was removed (roadmap D).
- TTS: `AVSpeechSynthesizer` (free, on-device). Speak sentence-by-sentence as text streams in.

## Architecture
```
ClickBait/                 macOS app target (AppKit/SwiftUI shell)
  App/                     AppDelegate, menu bar (NSStatusItem), Settings window
                           AskCoordinator: state in AskCoordinator.swift, each flow in AskCoordinator+<Flow>.swift
                           (Chat, Dictation, Background, Explain, Actions, Tutorials, Snip, Answering)
  Input/                   HotkeyMonitor (hold Control+Option via flagsChanged), AudioRecorder (AVAudioEngine)
  Capture/                 ScreenCapturer (ScreenCaptureKit, display under cursor)
  Accessibility/           AXInspector: frontmost app, focused element, hit-testing, element snapping
  Overlay/                 OverlayController: one transparent NSPanel per screen, pointer + label + companion bubble
  Speech/                  Transcriber (WhisperKit), Speaker (AVSpeechSynthesizer)
  Permissions/             Permission checks + onboarding window
ClickBaitCore/             Platform-agnostic Swift package (Package.swift lives here)
  Sources/ClickBaitCore/
    Providers/             LLMProvider protocol, OllamaProvider (the only provider), WikipediaClient
    Prompting/             System prompt, request builder, response parser
    Models/                AssistantResponse, Pointer, ScreenContext, Guide (future)
    Geometry/              Screenshot-pixel ↔ screen-point mapping
  Tests/ClickBaitCoreTests/  Unit tests (parser, geometry, prompt builder) — Swift Testing
```

## Feature docs (binding, like this file)

Each feature's rules, measurements and user decisions live in `docs/features/`. Read the feature's doc before changing it, and update it in the same commit.

- [`docs/features/ask-and-answers.md`](docs/features/ask-and-answers.md): The ⌃⌥ ask flow, ⌥⌘ explain, spoken commands, the models, instant answers (no model), pointing accuracy and listening.
- [`docs/features/orders.md`](docs/features/orders.md): Places and file orders, built-in app orders, orders in other words, and who asks first (`ActionPolicy`).
- [`docs/features/memory-and-routing.md`](docs/features/memory-and-routing.md): Remembered facts and saved answers, the app cards the model is given, and the intent router in shadow mode.
- [`docs/features/dictation.md`](docs/features/dictation.md): Screen-aware dictation: hold fn+⌃, words spelled from the screen, tidied and pasted.
- [`docs/features/companion-and-chat.md`](docs/features/companion-and-chat.md): Companion motion, the greeting on coming back, where the chat opens, pills before the chat, typing to ask, and chat bubbles.
- [`docs/features/tutorials.md`](docs/features/tutorials.md): Walkthroughs: planning, steps, checking, lavender holds.
- [`docs/features/tours-and-snips.md`](docs/features/tours-and-snips.md): Circling and snipping (hold ⌥⌘), the parts tour and its binding standard, Wikipedia lookups for tours, and the tour measurements.
- [`docs/features/notch.md`](docs/features/notch.md): The island: rhythm, layout, bean, home, ask, shelf, settings, music, volume HUD.
- [`docs/features/background-jobs.md`](docs/features/background-jobs.md): Peeling answers to the dock, tiles, done cards and progress lines.

## Cross-cutting rules

### Internet Mode (🌐, free lookups)
Menu bar title "🔒 ClickBait" / "🌐 ClickBait" (text, set only when toggled — `StatusBarController.showInternetMode`; per-state changes stalled the companion), first menu item "Internet: off 🔒 / on 🌐", "Recent Searches" submenu (`InternetMode.recent`, ≤5, memory; cleared when switched off). A plain answer (not pointing, orders, walkthroughs or snips) looks things up when `WebLookup.reason` says the words ask: `.asked` ("look it up", "search the web", "google it", "check Wikipedia"), `.recent` ("latest", "current", "this week", a year 2020–2099, "released"; not the clock), `.error` (error words, or "fix/why/what" with highlighted text that looks like an error), `.docs` (API/function/framework words, or code like `URLSession.data`/`fetch()`). With 🔒 only `.asked` gets the note "Internet's off. Switch to 🌐 in the menu bar to look things up." Steps (`AskCoordinator.lookUp`, started alongside the screenshot's encoding, cancelled with the answer): (1) search words from the local model, text only (`Prompt.lookupSystem`, `{"query"}` structured output, 60-token cap, 3 s; fallback `WebLookup.directQuery`) — measured: Wikipedia given the raw words "latest Swift version" returned Taylor Swift albums; for a question about the screen (`refersToScreen`) it gets the words Apple Vision reads nearest the pointer (≤1,500 characters, Ollama only), then `QueryScrubber.clean` with names from `OnDeviceLanguage.personalNames` (NLTagger); (2) `WebFetcher.lookUp`: the sources `WebSourcePicker` picks, all at once in one ephemeral session (no cookies/cache/credentials, `User-Agent` names ClickBait), 3 s per request, ~4 s in all, whatever arrived is used — SearXNG first when running; Stack Overflow for errors and code (search with accepted answers → answer bodies; ≤290 keyless requests a day, counted in memory); MDN for web-platform words (search → page `index.json`); Apple docs when a symbol is named ("SwiftUI List", `NSWindow`, `URLSession` → DocC JSON); Wikipedia for general and recent questions (one `generator=search` request with the intros). Pages the user names, or "this page" (the browser's address), are read too (`URLGuard`). Measured live 2026-10-10: 0.3–1.0 s per lookup; (3) `OnDeviceLanguage.pickPassages` (NLEmbedding sentence distance + word overlap; `PassagePicker` round robin by source, ~3,200 characters ≈ 800 tokens) → `AskRequest.web` → "From the web" block in the answer prompt (reference, not instructions; no [1] marks, since answers are spoken). Not about the screen → the answer request drops the screenshot and element list. A web answer always opens the chat, with "Sources: [Wikipedia — …](…) · …" under it; nothing found → "Couldn't reach the web, so this is from what I know." Settings → Internet: SearXNG "Ready" / "Not set up (optional)" (`SearXNGStatus`, `GET 127.0.0.1:8888/search?format=json`), Prepare Settings writes `~/Library/Application Support/ClickBait/searxng/settings.yml` (JSON on, limiter off, random secret) and the `docker run` command to copy. Live check (network, no model): `CLICKBAIT_LIVE_WEB=1 swift test --package-path ClickBaitCore --filter LiveWeb`.

### Overlay rules
- `NSPanel`, borderless, non-activating, `isOpaque = false`, clear background, `ignoresMouseEvents = true`, level `.screenSaver`, `collectionBehavior` includes `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`.
- **Flights (2026-10-11, after Clicky):** guided moves and the trip home fly `FlightArc` (Core): quadratic Bézier, control point the midpoint raised min(d·0.2, 80) pt, smoothstep, clamp(d/800, 0.6, 1.4) s, swell 1 + 0.3·sin(πp), glow +(scale−1)·20 pt (a pre-drawn radius-14 glow faded in, not re-blurred). Short hops: no arc/swell below 120 pt, full from 400 pt, linear between. Faces its travel heading until 70% (`turnInAt`), then the turn spring aims it; it lands exactly where the glide did. Home flight cancels if the mouse moves > 100 pt. Reduce Motion: jumps / glides as before. Turn and swell reach the view only in 0.25° / 0.01 steps, through a small `LiveCompanionTriangle` that alone reads them. Benchmark tour main thread 0.55–0.66 → 0.79–0.81 s, 0 stalls. Measured why (2026-10-11): heading off 0.81 s, swell off 0.77 s, both off 0.57 s — any SwiftUI change to the triangle during flights costs ~0.2 s per tour, nearly independent of how often (60 Hz cap: 0.72–0.74 s, dropped as not worth losing 120 Hz). The remaining fix would be turning/scaling the triangle with Core Animation outside SwiftUI (not done: its rotation sign can't be checked by screenshot, the overlay has `sharingType = .none`).
- **Guide labels pop in (2026-10-11, after Clicky):** each label (`GuidePill`, one view kept across stops, reset on `onChange(of: label)` in the same update as the new words) pops from scale 0.5 to 1 with `.spring(response: 0.4, dampingFraction: 0.6)`, its glow starting bright (+1.0 opacity, +16 pt at half size) and settling — a glow drawn once behind the pill and faded out, since animating the shadow's radius re-blurred it every frame (+0.12 s a tour, a 91 ms stall). Blue points type themselves out, 30–60 ms a character, in ONE `Text` of the whole label with the untyped rest drawn clear (`AttributedString`), so the pill never changes size and its far-side placement holds; two stacked texts (full + typed) and a new view per label (`.id`) each caused ~90 ms stalls on tours. Lavender instructions and red "~ name" pills only pop (red keeps `InkCentring`). VoiceOver reads the whole label at once; Reduce Motion: no pop, no typing, the plain fade. Benchmark: tour 0.74–0.84 s, point 0.17–0.21 s, spin 0.35–0.37 s, 0 stalls in 4 runs.
- Companion follows the cursor (display-link driven, an underdamped spring: response 0.2 s, damping 0.6): a 16 pt equilateral triangle in the state colour (solid, solid radius-8 glow), centred 35 pt right / 25 pt below the hotspot, vertex aimed up-left at −35°; a Liquid Glass card beside it for listening / thinking / explaining / errors (material fallback before macOS 26).
- Pointing (phase B): no separate arrow. The triangle detaches, glides to each target and turns its vertex onto it, with a label pill on the side away from the target ("1/2 · File"). Advances on any click, a new question or Esc, when the mouse reaches a blue target, or once its hold is over — all timed from **arrival** (`GuideTiming`, Core): a single blue target holds 3 s, each of several blue targets 2 s, each red tour part 2.4 s; walkthrough steps wait for a click. Arrived = the flight is over (or none, Reduce Motion), the triangle is at its final spot and has finished turning onto the target (`GuideTiming.hasArrived`); a new or corrected flight resets it; the pulse (`isGuideSettled`) also starts then. Logged: "Guide: arrived at target N after X s". Safety cap 12 s from setting off (`GuideTiming.maxStop`). Until 2026-10-11 both the blue hold (1 s) and the tour hold (2.4 s) were timed from the first frame, before the flight had moved, so a blue point left ~1 s after setting off. A new question or closing the chat sends it back. Esc stops whatever ClickBait is doing (listening, thinking, speaking, snip, pending confirmation, close-up, pointing); with nothing going on it closes the chat. Reduce Motion: it jumps instead of gliding.

### Esc (user's rule, 2026-10-11)
**Esc while ClickBait is working, thinking or listening only puts ClickBait back to idle blue — it never reaches, closes or stops anything else on the Mac.** `InputInterceptor` (an event tap) takes Esc, its repeats and its key-up whenever ClickBait owns it: `AskCoordinator.ownsEscape` (`isBusy`, plus a walkthrough offer waiting, an explanation still undoable, an app opening for a walkthrough) or `OverlayController.looksBusy` (listening/thinking/working words, spinning, pulsing, red over a snip, pointing, touring) or a card/ready pill of ClickBait's own. A taken Esc runs `overlay.onEscape`: `stopActivity()`, a card still up answers "no" (`ConfirmController.cancel`, so its asker hears back), then `resetToIdle()` (no guide, no red, no words, companion shown). It never closes the chat and never stops a background job. Idle, Esc passes through untouched (logged "Esc passed to the front app"). A watchdog re-enables the tap every 3 s if macOS switched it off. Check (no model): `open --env CLICKBAIT_BENCH=esc …/ClickBait.app` posts a real Esc while idle (must pass) and while spinning (must be taken, then "bubble idle, spinning false").

**Guidance (2026-10-17)** — `GuidanceController` (app) + `Guidance` (Core). One API, `show(GuideRequest(kind: .highlight | .arrow, target: .element(id:pid:) | .node(AXUIElement) | .bounds | .point, label:, priority:, armed:, pulse:, onArmedClick:))` → a `GuideHandle` (`update`, `dismiss`). Highlight: translucent system-blue rounded box (padding 6, radius 10) with a subtle border; arrow: its tip exactly on the point (or the element's near edge), its 64 pt tail turned away from nearby boxes and kept on screen. Labels go around the box (below, above, right, left), or past an arrow's tail, never over a box, a critical rect, an arrow, or another label. Several at once: the highest priority (latest on a tie) is primary, on top at full strength; the others dim to 0.45 where they overlap it. The overlay never takes clicks (`ignoresMouseEvents`); an armed guide watches for the next click on its target (the click still reaches the app), then dismisses and calls `onArmedClick`. Element and node targets are re-read every 0.5 s while shown (resizes, scrolling). Level `WindowLayers.guidance`: over apps, under the menu bar and ClickBait's own windows. Pulse is off with Reduce Motion; each guide is announced to VoiceOver and labelled ("Arrow pointing to …"). DEBUG `CLICKBAIT_TEST_GUIDANCE[=<folder>]` checks primary, labels apart, armed clicks, resize, and clear (and renders `guidance.png`). Not yet wired to tutorials or pointing — that's the next step.

## Permissions
Microphone, Screen Recording, Accessibility. On first launch show an onboarding window that checks each, explains why in one sentence, and deep-links to the right System Settings pane. App must degrade gracefully (e.g. no AX → no snapping, still points).

## Privacy rules (non-negotiable)
- No network calls except: Ollama on localhost, and the one-time WhisperKit model download from Hugging Face — which must be started explicitly by the user (onboarding/Settings), never in the background (or no download at all: the model can be imported from a local folder or .zip, offline) — plus the opt-in lookups below. No paid services or API keys (2026-10-10); no cloud model.
- **Internet Mode (built 2026-10-10):** an opt-in 🌐 switch in the menu bar, off at every launch, never saved, never switched on by ClickBait. The local model writes every answer; no paid services, no keys, no ClickBait server. Only search words and page addresses go out — to Wikipedia, Stack Overflow (Stack Exchange API), MDN, Apple developer documentation, the pages read, and SearXNG on this Mac if it runs — never the screenshot, the screen's text, audio, chats, element lists, or a name found on screen. A search phrase about the screen is written by the local model from on-screen words and cleaned first (≤12 words / 100 characters; email and web addresses, paths, long numbers and key-like strings removed; names found on screen removed unless the user said them). Only when the user's words ask (`WebLookup.reason`); the one exception is a snip while 🌐 is on (its subject → Wikipedia; nothing sent for a face or text). An address is read only if it appeared in the user's words, on screen or in a result (HTTPS; HTTP only for localhost). Web text only informs a written answer — never an order, walkthrough or file action. Recent searches: last 5, memory only. Design: `docs/superpowers/specs/2026-10-07-internet-mode-design.md`.
- No analytics, no crash reporting services.
- No web lookups for answers or ⌥⌘ explanations otherwise (decided 2026-10-01): they use only the screen and the model's own knowledge. The exception is Internet Mode, above, when the user switches it on.
- Never write screenshots or audio to disk except to a temp dir that is deleted after the request (debug mode may keep them, off by default).
- Settings include an app blocklist: if the frontmost app is blocked (default: password managers, Keychain Access), refuse to capture.

## Milestones
- **M1 – Ask & Point**: done (plus explain, chat bubbles, commands, file actions).

## Master roadmap (from 2026-10-03; supersedes M2–M5 above)
Philosophy: 100% local on Apple Silicon via Ollama, permanently free, works offline. Be honest about speed: local inference takes seconds, so promise "private and offline", not "zero latency".

- **A. Identity & quick wins** (done): ⌘C/⌘V/⌘A etc. in the chat bubble; equilateral-triangle companion; synchronized colour states on companion and chat banner — Azure (#007FFF) idle/tracking, Pumpkin (#FF7518, was Marigold #EAA221) input & processing (thinking spins), Shamrock Green Mac actions & document processing, Strawberry Red circling/snipping, Lavender (#B57EDC) guided tutorials.
- **B. Companion guides you** (done): after inference the triangle detaches from the cursor, glides and rotates to point its vertex at each target, then returns. Replaces the separate pointer arrow.
- **C. Circling & snipping** (done; Red): **hold ⌥⌘** — move to trace/circle, or click-drag a box; release fires. A *tap* of ⌥⌘ still explains the highlighted text. The traced shape/box is sent to the model drawn on the screenshot (or cropped).
- **D. Air-gapped mode** (decided 2026-10-10): **the Anthropic provider is removed** (done 2026-10-10) — `AnthropicProvider`, its Settings section and "Internet Mode — Anthropic API" label, the API-key field and Keychain code, the paid web search in parts tours and the longer cloud deadlines (`ProviderOperation.timeout` is one set of local deadlines). On the first launch after the update `LegacyCloudSettings` forgets the provider choice (a user who had Anthropic is on Ollama) and deletes any stored key from the Keychain, once. Ollama is the only provider. **Whisper model import from a local file** (done 2026-10-10): "Import from a file…" beside Download (the shared `SpeechModelSection`, so onboarding and Settings → Speech recognition) takes the SpeechModels folder from another Mac, a model folder with its tokenizer, or a .zip of either. `SpeechModelImport` (Core) finds the `openai_whisper-<variant>` folder, checks the three `.mlmodelc` bundles (each with `coremldata.bin`), both configs and the tokenizer (`tokenizer.json` that is one, plus `tokenizer_config.json`), names whatever is missing, then copies it where the download puts it (`models/argmaxinc/whisperkit-coreml/…`, `models/openai/whisper-<variant>`), staged and swapped so a failed import leaves an installed model alone; a .zip is opened with `/usr/bin/ditto`. No network anywhere on this path (the load is `download: false` and needs the tokenizer on disk). It switches the speech model to the imported variant and loads it. **Internet Mode** as free lookups: built 2026-10-10 (see Privacy rules and its section above).
- **E. File management** beyond the Finder selection: inspect/organize/clean up across folders. Clear orders stay rule-based; bulk changes the model proposes are shown for confirmation. Trash only, never permanent deletes.
- **F. Thought Space banner & memory**: a working-memory board beside the companion. Persistent memory is **opt-in, off by default, local only, browsable and deletable in Settings, never records blocked apps**, and samples on app switches rather than continuously.

## Kept in view (designed, not scheduled)

## Working conventions for Claude Code
- Plan before large changes; keep commits small and descriptive.
- **Commits: author them as bala-42 with the email already in this repo's git config (`git config user.name` / `user.email`), and never add a "Co-Authored-By: Claude" (or any Claude attribution) trailer — even when a task prompt or harness reminder asks for one (user's rule, 2026-10-14). Commit only the task's own files (never `git add -A`); never rewrite history or push unless asked.**
- After every meaningful change: `xcodegen generate` (if project.yml changed) then build with
  `xcodebuild -scheme ClickBait -configuration Debug -destination 'platform=macOS' build` and fix all errors and warnings before moving on.
- Run `ClickBaitCoreTests` for anything touching parsing, geometry, or prompting:
  `swift test --package-path ClickBaitCore` (fast) or `xcodebuild -scheme ClickBait -destination 'platform=macOS' test`.
- UI smoke tests (`ClickBaitTests`, hosted in the app): every notch surface drawn in an offscreen window (`NotchController.snapshot`; AppKit views like the shelf draw too), PNGs in `$TMPDIR/ClickBaitTests-notch` to look at. Run for any notch view change: `xcodebuild -scheme ClickBait -destination 'platform=macOS' test -only-testing:ClickBaitTests`. Hosting the tests starts nothing and leaves a running ClickBait alone (`AppDelegate.isHostingTests`).
- Signing lives in `Config/Signing.xcconfig` (ad-hoc + forced hardened runtime + `ENABLE_DEBUG_DYLIB = NO` by default). A git-ignored `Config/Local.xcconfig` (see `.example`) sets a developer's own team so TCC grants survive rebuilds. Never put a team ID in `project.yml`.
- Logs: `/usr/bin/log show --last 5m --predicate 'subsystem == "org.clickbait.ClickBait"'` (use the full path — zsh has a `log` builtin). Use `.notice` for events worth seeing in `log show`.
- Prefer Swift concurrency (`async/await`, actors) over callbacks. UI work on `@MainActor`.
- No force-unwraps outside tests. Errors surface to the user in plain language via the companion bubble.
- Things you cannot verify by building (permissions prompts, overlay visuals, hotkey feel, audio): tell the user exactly what to test manually and what to look for.
- Keep `README.md` up to date with setup steps (Ollama install, model pull, permissions).
