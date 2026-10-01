# ClickBait

> The only clickbait worth following.

ClickBait is a free, open-source (Apache 2.0), local-first AI companion that lives next to your cursor on macOS. Hold a hotkey, ask a question out loud, and it looks at your screen, answers by voice, and **points at exactly what to click**.

## Product principles
1. **Free and private by default.** Default path uses local models only. No account, no server, no telemetry. Screenshots never leave the machine unless the user opts into a cloud provider.
2. **Bring your own key (BYOK).** Users can plug in their own API key (Anthropic first) for smarter answers and agents. Keys live in the macOS Keychain, never in plain files.
3. **Point, don't just talk.** The overlay pointer is the core magic. Accuracy matters more than eloquence.
4. **Fast feels smart.** Target: spoken answer starts < 1.5s (cloud) / < 3s (local) after the hotkey is released. Stream everything.
5. **Portable core.** Keep logic that isn't macOS-specific in `ClickBaitCore` (no AppKit/SwiftUI imports) so a Windows shell can come later.

## Differentiators (roadmap context; do not build yet unless asked)
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

### Overlay rules
- `NSPanel`, borderless, non-activating, `isOpaque = false`, clear background, `ignoresMouseEvents = true`, level `.screenSaver`, `collectionBehavior` includes `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`.
- Small companion bubble follows the cursor (global `mouseMoved` monitor) showing state: idle / listening / thinking / speaking.
- Pointer: animated arrow/ring + label pill. Respect Reduce Motion.

## Permissions
Microphone, Screen Recording, Accessibility. On first launch show an onboarding window that checks each, explains why in one sentence, and deep-links to the right System Settings pane. App must degrade gracefully (e.g. no AX → no snapping, still points).

## Privacy rules (non-negotiable)
- No network calls except: Ollama on localhost, the user's chosen cloud provider when BYOK is enabled, and the one-time WhisperKit model download from Hugging Face — which must be started explicitly by the user (onboarding/Settings), never in the background.
- No analytics, no crash reporting services.
- Never write screenshots or audio to disk except to a temp dir that is deleted after the request (debug mode may keep them, off by default).
- Settings include an app blocklist: if the frontmost app is blocked (default: password managers, Keychain Access), refuse to capture.

## Milestones
- **M1 – Ask & Point** (current): everything in the Ask flow above, Settings (provider, model name, API key, hotkey help, blocklist), onboarding.
- **M2 – Dictation**: hold a second hotkey, transcribe, clean up with screen context, insert into focused field (AX setValue, fallback simulated Cmd+V with clipboard restore).
- **M3 – Guides**: record workflows → JSON guide → replay with step-by-step pointing; import/export files.
- **M4 – Autonomy slider + agents (BYOK).**
- **M5 – Windows shell** reusing ClickBaitCore.

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
