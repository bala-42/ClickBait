# ClickBait

> The only clickbait worth following.

ClickBait is a free, open-source, local-first AI companion that lives next to your cursor on macOS.
Hold **Control+Option**, ask a question out loud, let go — it looks at your screen, answers by voice,
and **points at exactly what to click**.

- **Private by default.** The default setup uses only local models (WhisperKit + Ollama). No account,
  no server, no telemetry. Screenshots never leave your Mac unless you opt into a cloud provider.
- **Bring your own key.** Optionally plug in an Anthropic API key for smarter answers. Keys are stored
  in the macOS Keychain.

> **Status:** early development — Milestone 1 (Ask & Point) is being built.

## Requirements

- macOS 14 or later on Apple Silicon
- Xcode 16 or later (to build)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Ollama](https://ollama.com) with a vision model (for the free, local setup)

## Setup

### 1. Install Ollama and a vision model

```sh
# Install Ollama from https://ollama.com/download, then:
ollama pull qwen2.5vl:7b
```

Any Ollama model that accepts images works; set its name in **Settings → Provider**.
`qwen2.5vl:7b` is the default because it is good at locating UI elements.

### Optional: use Anthropic instead (bring your own key)

In **Settings → Provider**, choose **Anthropic**, paste your API key (stored in the macOS Keychain)
and click **Test Connection**. The default model is `claude-opus-5-5`; any vision-capable Claude
model name works. With Anthropic selected, the screenshot and your question are sent to Anthropic.

### 2. Build

```sh
xcodegen generate
xcodebuild -scheme ClickBait -configuration Debug -destination 'platform=macOS' build
```

Or open `ClickBait.xcodeproj` in Xcode after `xcodegen generate` and press ⌘R.
The `.xcodeproj` is generated — edit `project.yml` instead, then regenerate.

Run the core unit tests with either:

```sh
swift test --package-path ClickBaitCore
xcodebuild -scheme ClickBait -destination 'platform=macOS' test
```

### 3. Grant permissions

On first launch ClickBait asks for:

| Permission | Why |
|---|---|
| Microphone | To hear your question while you hold the hotkey. |
| Screen Recording | To see the screen you are asking about. |
| Accessibility | To detect the hotkey anywhere and to aim the pointer at real buttons. |

> **Local builds:** by default builds are ad-hoc signed, and macOS forgets permission grants after
> every rebuild. To keep them, sign with your own (free) Apple Development certificate:
>
> ```sh
> cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM
> xcodegen generate
> ```
>
> If a grant still looks stuck, remove ClickBait from the list in System Settings → Privacy &
> Security and add it again.

## Usage

**Ask & point**

1. Hold **Control+Option** (⌃⌥).
2. Ask your question out loud, e.g. *"How do I share this document?"*
3. Let go. ClickBait answers out loud and points at what to click.

**Keep the conversation going**

Every answer opens as a small chat bubble pinned where it appeared. Type a follow-up and press
Return (the reply is text), or hold ⌃⌥ and ask out loud (the reply is spoken too). The bubble
remembers the conversation and sees your screen fresh each time; close it with ✕ or Esc and the
conversation is forgotten.

**Explain highlighted text**

1. Highlight some text in any app.
2. Press and release **Option+Command** (⌥⌘).
3. ClickBait explains it in a few sentences, using what's on screen for context.

**Spoken commands**

Hold ⌃⌥ and give an order instead of a question: *"open Safari"*, *"quit Music"*, *"volume 30"*,
*"mute"*, *"dark mode"*, or *"run Focus Time"*. Orders run immediately. Questions (*"how do I…"*)
are never treated as orders. Shortcuts only run if you've ticked them in **Settings → Commands**,
and that tick is the permission: ticked shortcuts run without asking. Switching Dark Mode asks
once for permission to control System Events.

**File actions** (Finder in front, files selected): *"compress these"* (zip), *"merge these"*,
*"convert these to JPEG/PNG"*, *"make these smaller"* (smaller copies of images, PDFs and videos),
*"put these in a new folder"*, *"move these to the Trash"*. New files go next to the originals and
never overwrite anything; originals are left untouched except when moving them.

Both hotkeys only fire when pressed on their own, so shortcuts like ⌃⌥← or ⌥⌘D keep working.
Press **Esc** to cancel or dismiss.

## Project layout

```
ClickBait/          macOS app (AppKit/SwiftUI shell)
ClickBaitCore/      Platform-agnostic Swift package (providers, prompting, parsing, geometry)
  Tests/            Unit tests
project.yml         XcodeGen spec
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
