# ClickBait

> The only clickbait worth following.

ClickBait is a free, open-source (Apache 2.0), local-first AI companion that lives next to your cursor on macOS. Hold a hotkey, ask a question out loud, and it looks at your screen, answers by voice, and **points at exactly what to click**.

## Product principles
1. **Free and private by default.** Default path uses local models only. No account, no server, no telemetry. Screenshots never leave the machine unless the user opts into a cloud provider.
2. **Bring your own key (BYOK).** Users can plug in their own API key (Anthropic first) for smarter answers and agents. Keys live in the macOS Keychain, never in plain files.
3. **Point, don't just talk.** The overlay pointer is the core magic. Accuracy matters more than eloquence.
4. **Fast feels smart.** Target: spoken answer starts < 1.5s (cloud) / < 3s (local) after the hotkey is released. Stream everything.
5. **Portable core.** Keep logic that isn't macOS-specific in `ClickBaitCore` (no AppKit/SwiftUI imports) so a Windows shell can come later.

## Differentiators (earlier ideas; the master roadmap below takes precedence)
- **Guides: "show it once, it guides forever."** Record a workflow → saved as a portable JSON guide (steps + target element descriptions + AX identifiers, not video) → anyone can replay it with the pointer guiding them on their own screen. Guides re-locate targets on the live UI so they survive UI changes.
- **Autonomy slider.** Show me → Do it with me (ghost cursor, approve each click) → Do it for me.
- **Context-aware dictation.** Speak, it cleans up the text using what's on screen, inserts it into the focused field.
- **Background agents** (BYOK only) via tool-use loop + MCP.

## Tech stack
- Swift 5.10+, SwiftUI + AppKit, **macOS 14+, Apple Silicon**.
- Project generated with **XcodeGen** (`project.yml`). Never hand-edit `.xcodeproj`; regenerate it.
- Non-sandboxed app (needs Accessibility + Screen Recording). Hardened runtime on.
- Dependencies via Swift Package Manager:
  - `WhisperKit` (argmaxinc) for on-device speech-to-text.
  - Nothing else unless justified in the PR/commit message.
- Local LLM: **Ollama** HTTP API at `http://localhost:11434` (user installs Ollama and pulls a vision model). Model name configurable in Settings.
- Cloud LLM (BYOK): Anthropic Messages API with image input. Model name configurable.
- TTS: `AVSpeechSynthesizer` (free, on-device). Speak sentence-by-sentence as text streams in.

## Architecture
```
ClickBait/                 macOS app target (AppKit/SwiftUI shell)
  App/                     AppDelegate, menu bar (NSStatusItem), Settings window
  Input/                   HotkeyMonitor (hold Control+Option via flagsChanged), AudioRecorder (AVAudioEngine)
  Capture/                 ScreenCapturer (ScreenCaptureKit, display under cursor)
  Accessibility/           AXInspector: frontmost app, focused element, hit-testing, element snapping
  Overlay/                 OverlayController: one transparent NSPanel per screen, pointer + label + companion bubble
  Speech/                  Transcriber (WhisperKit), Speaker (AVSpeechSynthesizer)
  Permissions/             Permission checks + onboarding window
ClickBaitCore/             Platform-agnostic Swift package (Package.swift lives here)
  Sources/ClickBaitCore/
    Providers/             LLMProvider protocol, OllamaProvider, AnthropicProvider
    Prompting/             System prompt, request builder, response parser
    Models/                AssistantResponse, Pointer, ScreenContext, Guide (future)
    Geometry/              Screenshot-pixel ↔ screen-point mapping
  Tests/ClickBaitCoreTests/  Unit tests (parser, geometry, prompt builder) — Swift Testing
```

### Ask flow (Milestone 1)
1. User **holds Control+Option** → start mic recording, capture screenshot of the display under the cursor, snapshot AX context (frontmost app name, window title, focused element role/title).
2. User **releases** → stop recording → transcribe with WhisperKit.
3. Downscale screenshot so the long edge is ≤ 1280px (keep the scale factor!) → send screenshot + transcript + context to the selected `LLMProvider`.
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

### Explain flow (added during M1)
Highlight text, then press and release **Option+Command** alone (no other key in between; `ChordDetector` in Core). The selected text is read via AX (`kAXSelectedTextAttribute`), sent with a screenshot for context, and the model returns a concise 2–4 sentence explanation in `speech` (usually no pointers). Same blocklist, provider and privacy rules as Ask.

### Commands (added after M1, step 10)
Direct orders spoken with ⌃⌥ are recognised from the transcript by `CommandParser` (Core) — plain rules, never the vision model (qwen2.5vl:7b missed real orders and acted on questions). Questions never act. Built-ins: open/quit app, volume, mute, Dark/Light Mode; plus Shortcuts the user ticked in Settings (the tick is the permission — they run without a prompt). Everything goes through `ActionCatalog.resolve` before `ActionExecutor` runs it. Unknown app names fall through to a normal answer.

### Pointing accuracy
Spoken and typed asks send the model a numbered list of up to 50 clickable things (question-word matches first, then open-menu items, then screen order) Accessibility reports on the captured display (`AXInspector.visibleElements`: open menus first, then the focused window, then menu bar titles; 0.4 s budget). The model may point by `"element": id`; when it gives x/y with a name that matches a listed element within 250 px, the parser uses that element's exact center. At ⌃⌥ press ClickBait sets `AXManualAccessibility` on the frontmost app so Chrome/Electron apps build their tree. Pointers no accessibility element confirms get a second look: a 1280×800 close-up (640×400 pt at 2× — qwen2.5vl's coordinates drift at other sizes) with the locate prompt; the triangle starts toward the rough spot and is retargeted when the close-up answers (~3–5 s). A new question cancels a running close-up.

### Listening
Recording continues 0.35 s after ⌃⌥ is released. `AudioConditioner` skips silent recordings (peak < 0.01), lifts quiet ones (up to 12×) and adds 0.2 s lead-in; Whisper's own no-speech filter is off. What was heard shows in a tiny pill while thinking.

### Places and file orders (phase E, steps 1–2)
- A box/circle snip in Finder selects the items under it (`AXInspector.finderItemNames` → `FinderSelection.select`; names reach AppleScript only via `AppleScriptText` escaping), so "combine these" acts on them.
- Rule-based orders (typed in a chat too): "make a new folder [in <place>] [called X]", "open Downloads", "move/copy these to <place>", "rename this to X", "put these in a new folder called X". Places: Desktop, Downloads, Documents, Applications, iCloud Drive; Home/Music/Pictures/Movies only with "folder". Names keep the user's casing and are validated (no `/`, `:`, leading `.`). Nothing is overwritten (numbered names); rename refuses clashes and keeps the extension.

### Built-in app orders (phase E, step 3)
"make a note: …" (Notes), "remind me to …" (Reminders) — text keeps the user's casing, passed only as escaped AppleScript strings; "play/pause/next song/previous track" post the keyboard media keys (any player); "take a screenshot" (full: ScreenCaptureKit, without ClickBait or blocked apps; "area"/"window": macOS's own picker) saved to the Screenshot app's folder or the Desktop; "new Finder window"; "show desktop" (Mission Control). Timers/Focus need an allowed Shortcut.

### Orders in other words (phase E, step 4)
When the rules don't recognise something that looks like an order (not a question), a text-only request (`Prompt.orderSystem`, no screenshot, ~1.3 s on qwen2.5vl:7b, 8 s timeout) asks which catalog action it is, or none. The proposal must pass `ActionCatalog.resolve` and the Finder check. Safe actions run at once; `ActionCatalog.needsConfirmation` ones (trash, move, rename, move into folder, quit, shortcuts, Wi-Fi off, lock, sleep display) show a green confirm card (Do it / Cancel, "yes"/"cancel" by voice, Esc; 20 s timeout). Rule-recognised orders still run directly.

### Snips (phase C)
Hold ⌥⌘ for 0.4 s to arm (companion turns red, trackpad tick); only then a transparent layer covers every screen (below the companion, which turns Strawberry Red). Moving traces a red line; click-drag draws a box (the click never reaches the app). Release decides (`SnipTracker`): a box ≥ 12 pt or a trace ≥ 60 pt long is a snip, anything else is a tap → explain highlighted text. The screenshot is cropped around the region (`SnipLayout`) with the shape drawn in red (`SnipRenderer`), sent with `AskRequest.snip`, answered in a chat bubble like an explanation (no pointers, no speech). Failsafe: the layer cancels itself if ⌥⌘ is no longer held or after 60 s. Trade-off: ⌥⌘-click/drag in other apps (e.g. Finder alias drag) is captured while the chord is held.

### Chat bubbles (added after M1)
Every answer or ⌥⌘ explanation opens a chat bubble (`ChatController`: borderless non-activating panel that can become key, so typing never activates ClickBait and the user's app stays frontmost). Pinned where it appeared, draggable, sized to its card, open until ✕/Escape. Memory (`Conversation` in Core) is scoped to the bubble, text only, first exchange + last 9 kept; each message gets a fresh screenshot; gone on close, never written to disk. Typed follow-ups get text replies; ⌃⌥ voice follow-ups go into the open chat and are spoken; ⌥⌘ explanations are text and replace the open bubble.

### Overlay rules
- `NSPanel`, borderless, non-activating, `isOpaque = false`, clear background, `ignoresMouseEvents = true`, level `.screenSaver`, `collectionBehavior` includes `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`.
- Companion follows the cursor (display-link driven): a small equilateral triangle in the state colour, vertex aimed up-left at the cursor; a Liquid Glass card beside it for listening / thinking / explaining / errors (material fallback before macOS 26).
- Pointing (phase B): no separate arrow. The triangle detaches, glides to each target and turns its vertex onto it, with a label pill on the side away from the target ("1/2 · File"). Advances on any click or after 8 s; Esc, a new question or closing the chat sends it back. Reduce Motion: it jumps instead of gliding.

## Permissions
Microphone, Screen Recording, Accessibility. On first launch show an onboarding window that checks each, explains why in one sentence, and deep-links to the right System Settings pane. App must degrade gracefully (e.g. no AX → no snapping, still points).

## Privacy rules (non-negotiable)
- No network calls except: Ollama on localhost, the user's chosen cloud provider when BYOK is enabled, and the one-time WhisperKit model download from Hugging Face — which must be started explicitly by the user (onboarding/Settings), never in the background.
- No analytics, no crash reporting services.
- No web lookups for answers or ⌥⌘ explanations (decided 2026-10-01): they use only the screen and the model's own knowledge.
- Never write screenshots or audio to disk except to a temp dir that is deleted after the request (debug mode may keep them, off by default).
- Settings include an app blocklist: if the frontmost app is blocked (default: password managers, Keychain Access), refuse to capture.

## Milestones
- **M1 – Ask & Point**: done (plus explain, chat bubbles, commands, file actions).

## Master roadmap (from 2026-10-03; supersedes M2–M5 above)
Philosophy: 100% local on Apple Silicon via Ollama, permanently free, works offline. Be honest about speed: local inference takes seconds, so promise "private and offline", not "zero latency".

- **A. Identity & quick wins** (done): ⌘C/⌘V/⌘A etc. in the chat bubble; equilateral-triangle companion; synchronized colour states on companion and chat banner — Azure (#007FFF) idle/tracking, Mango Orange input & processing (pulsing), Shamrock Green Mac actions & document processing, Strawberry Red circling/snipping.
- **B. Companion guides you** (done): after inference the triangle detaches from the cursor, glides and rotates to point its vertex at each target, then returns. Replaces the separate pointer arrow.
- **C. Circling & snipping** (done; Red): **hold ⌥⌘** — move to trace/circle, or click-drag a box; release fires. A *tap* of ⌥⌘ still explains the highlighted text. The traced shape/box is sent to the model drawn on the screenshot (or cropped).
- **D. Air-gapped mode**: the optional Anthropic provider is pending a decision (the user is deciding whether to remove it); Whisper model import from a local file as an alternative to the one-time download.
- **E. File management** beyond the Finder selection: inspect/organize/clean up across folders. Clear orders stay rule-based; bulk changes the model proposes are shown for confirmation. Trash only, never permanent deletes.
- **F. Thought Space banner & memory**: a working-memory board beside the companion. Persistent memory is **opt-in, off by default, local only, browsable and deletable in Settings, never records blocked apps**, and samples on app switches rather than continuously.

## Working conventions for Claude Code
- Plan before large changes; keep commits small and descriptive.
- After every meaningful change: `xcodegen generate` (if project.yml changed) then build with
  `xcodebuild -scheme ClickBait -configuration Debug -destination 'platform=macOS' build` and fix all errors and warnings before moving on.
- Run `ClickBaitCoreTests` for anything touching parsing, geometry, or prompting:
  `swift test --package-path ClickBaitCore` (fast) or `xcodebuild -scheme ClickBait -destination 'platform=macOS' test`.
- Signing lives in `Config/Signing.xcconfig` (ad-hoc + forced hardened runtime + `ENABLE_DEBUG_DYLIB = NO` by default). A git-ignored `Config/Local.xcconfig` (see `.example`) sets a developer's own team so TCC grants survive rebuilds. Never put a team ID in `project.yml`.
- Logs: `/usr/bin/log show --last 5m --predicate 'subsystem == "org.clickbait.ClickBait"'` (use the full path — zsh has a `log` builtin). Use `.notice` for events worth seeing in `log show`.
- Prefer Swift concurrency (`async/await`, actors) over callbacks. UI work on `@MainActor`.
- No force-unwraps outside tests. Errors surface to the user in plain language via the companion bubble.
- Things you cannot verify by building (permissions prompts, overlay visuals, hotkey feel, audio): tell the user exactly what to test manually and what to look for.
- Keep `README.md` up to date with setup steps (Ollama install, model pull, permissions).
