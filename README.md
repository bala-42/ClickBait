# ClickBait

> The only clickbait worth following.

ClickBait is a free, open-source, local-first AI companion that lives next to your cursor on macOS:
a small triangle that follows the pointer. Hold **Control+Option**, ask out loud, let go — it looks at
your screen, answers, **points at exactly what to click**, or walks you through a task step by step.

- **Private.** Answers come from a local model through [Ollama](https://ollama.com); speech is
  recognised on your Mac (WhisperKit). No account, no server, no telemetry, no API keys. Screenshots
  and audio never leave your Mac and are never saved. The optional Internet Mode sends only short
  search words, and only when you ask.
- **Free, for good.** Nothing to sign up for or pay for. Once the models are downloaded it works offline.
- **Honest about speed.** Pointing at a button it can name is near-instant; anything where the model
  has to look and think takes several seconds on your own Mac.

> **Status:** in active development, not yet released. Ask & Point (Milestone 1) is done, along with
> explanations, snips with parts tours, guided walkthroughs, Mac actions and background answers.

## Requirements

- macOS 14 or later on Apple Silicon; 16 GB of memory (24 GB recommended), about 10 GB free
- Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to build)
- [Ollama](https://ollama.com/download) with `qwen3.5:9b`

## Setup

### 1. Install Ollama and the model

```sh
# Install Ollama from https://ollama.com/download, then:
ollama pull qwen3.5:9b   # about 6.6 GB
```

Another Ollama vision model can be set in **Settings → AI model**. An optional second, smaller model
("Quick orders") reads spoken orders faster but keeps more memory busy; leave it empty unless your Mac
has memory to spare.

### 2. Build

```sh
xcodegen generate
xcodebuild -scheme ClickBait -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/ClickBait.app
```

Or open `ClickBait.xcodeproj` in Xcode after `xcodegen generate` and press ⌘R.
The `.xcodeproj` is generated — edit `project.yml` instead, then regenerate.

Run the core unit tests with:

```sh
swift test --package-path ClickBaitCore
```

### 3. Grant permissions and get the speech model

On first launch ClickBait asks for these, and offers the speech model (about 145 MB, downloaded once
from Hugging Face when you click Download — never in the background). **No internet?** Click
**Import from a file…** instead and pick the `SpeechModels` folder (or a .zip of it) copied from a Mac
that has it, at `~/Library/Application Support/ClickBait/SpeechModels`; ClickBait checks it's
complete and copies it into place without going online.

| Permission | Why |
|---|---|
| Microphone | To hear your question while you hold the hotkey. |
| Screen Recording | To see the screen you are asking about. |
| Accessibility | To detect the hotkeys anywhere and to aim the pointer at real buttons. |

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

| Do | ClickBait |
|---|---|
| Hold **⌃⌥**, ask, let go | Answers (spoken, or in a small chat), points at what to click, or offers a walkthrough |
| Tap **⌥⌘** with text highlighted | Explains it in plain words |
| Hold **⌥⌘**, circle or box something | Explains it; on an unlabelled picture it tours the parts with "~" best-guess labels |
| Double-tap **⌥⌘**, or **⌥⌘** + right-click | Opens a chat to type into |
| Hold **⌃⌥** while an answer is still coming | Sends it to a background capsule (top right, up to 3) and listens to your next question |
| **Esc** | Stops whatever it's doing |

- **Pointing (blue).** "Where's the share button?" — instant when one button has that name, otherwise
  about 1.5 s. "Show me the share button in Safari" opens Safari first.
- **Walkthroughs (lavender).** "How do I clear my Safari history?" asks first, then points at each
  step on your own screen and ticks off a checklist. It only points; you do the clicking.
- **Mac actions (green).** Open, quit and switch apps; "go to YouTube"; volume, Dark Mode, media keys,
  screenshots; notes and reminders; Shortcuts you tick in **Settings → Commands**. In Finder with files
  selected (or boxed): compress, merge, convert, make smaller, rename, move, put in a new folder, move
  to the Bin. New files never overwrite anything; risky actions ask first.
- **Internet Mode (optional, 🔒 → 🌐).** Off every time ClickBait starts; switch it on from the menu
  bar. Then, when your words ask ("look it up", "what's the latest…", "why this error?", an API
  question), ClickBait looks it up for free on Wikipedia, Stack Overflow, MDN and Apple's developer
  docs (plus [SearXNG](https://docs.searxng.org) on your Mac, if you set it up in **Settings →
  Internet**) and the local model answers, with the sources listed in the chat. Circling a picture
  with 🌐 on checks its name on Wikipedia for the parts tour. Only short search words and page
  addresses leave your Mac — never the screenshot, the screen's text, your voice or a name on screen.
  The last five searches are listed in the menu (memory only).

Both hotkeys only fire when pressed on their own, so shortcuts like ⌃⌥← or ⌥⌘D keep working.

## Project layout

```
ClickBait/          macOS app (AppKit/SwiftUI shell)
ClickBaitCore/      Platform-agnostic Swift package (Ollama provider, prompting, parsing, geometry)
  Tests/            Unit tests (Swift Testing)
site/               The website (Next.js, static export)
project.yml         XcodeGen spec
```

## Credits

The companion's look and motion are modelled on [Clicky](https://github.com/farzaa/clicky) by Farza
(MIT License): its centroid-centred triangle, glow and pointing feel. ClickBait reimplements the
formulas in its own drawing and motion code.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
