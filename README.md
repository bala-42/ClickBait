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

> **Local builds:** debug builds are ad-hoc signed, so macOS may forget the Screen Recording and
> Accessibility grants after a rebuild. If ClickBait stops seeing the screen or hearing the hotkey,
> remove it from those lists in System Settings → Privacy & Security and add it again.

## Usage

1. Hold **Control+Option**.
2. Ask your question out loud, e.g. *"How do I share this document?"*
3. Let go. ClickBait answers out loud and points at what to click.

## Project layout

```
ClickBait/          macOS app (AppKit/SwiftUI shell)
ClickBaitCore/      Platform-agnostic Swift package (providers, prompting, parsing, geometry)
  Tests/            Unit tests
project.yml         XcodeGen spec
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
