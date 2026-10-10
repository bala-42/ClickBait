# Wikipedia lookups (a lighter "Internet Mode") — exploration

Date: 2026-10-10 · Status: exploration, nothing built

## Why

The local model (`qwen3.5:9b`) is thin on facts and dates it wasn't trained on. The 2026-10-07 Internet Mode spec reaches for SearXNG, Stack Overflow, MDN and Apple docs, or Anthropic's paid web search. This looks at the smallest step instead: **Wikipedia only**, free, no account, no key, no server of ours, and the screen never leaves the Mac. It does not replace the Anthropic provider decision (roadmap D) and doesn't start Internet Mode.

## What was measured (2026-10-10, from this Mac)

Endpoints, all public, no key:

| Need | Endpoint | Result |
|---|---|---|
| Find the article | `w/api.php?action=query&list=search&srsearch=<terms>&srlimit=3&srprop=` | ~0.3 s cold, ~0.04 s warm |
| Short facts | `api/rest_v1/page/summary/<Title>` | 2.5 KB JSON; intro 100–450 tokens |
| More depth | `w/api.php?action=query&prop=extracts&explaintext=1&redirects=1&titles=<Title>` | Apple M4: ~970 tokens, 7 sections |

**Search needs the subject, not the question.** Raw questions often miss; the subject's name lands first:

| Asked | Raw question → top hit | Subject terms → top hit |
|---|---|---|
| "M4 chip vs i7" | Mac Mini (LGA 2011 3rd) | "Apple M4" → Apple M4 ✓ |
| "what does ZeroDivisionError mean" | Undefined (mathematics) | "ZeroDivisionError" → Division by zero ✓ |
| "what is a supraspinatus" | Rotator cuff | "supraspinatus" → Supraspinatus muscle ✓ |
| "who painted the mona lisa" | Mona Lisa ✓ | — |
| "latest macOS version" | MacOS version history ✓ | — |
| "how does git reset soft work" | Microsoft ✗ | "git reset" → Git (no command detail) |

Findings:
- **Good for:** people, places, things, definitions, history, "what is / who is / when did" — and the parts-tour names ("~ supraspinatus" → its article).
- **Poor for:** how-tos, code, command flags, error fixes. Wikipedia isn't a manual; those still need the model (or a later source like Stack Overflow).
- **Fresh enough:** the macOS article was edited 2026-09-25.
- **Cheap for the local model:** an intro adds ~100–450 tokens (~0.3–1.3 s at ~350 tokens/s); a whole article ~1,000+ (cap it).

## Proposal

- **Opt-in switch**, off at every launch (as in the 07 Oct spec): "Look things up on Wikipedia" in the menu. Off → nothing changes.
- **Only when asked:** "look it up", "check Wikipedia", "search online", "what's the latest on…". The model never decides to go online.
- **The query is subject terms, made on this Mac:** the request's names and nouns via Apple's `NLTagger` (named entities + nouns, on-device, no model call), the trigger words stripped. If that gives nothing, one text-only model call (~1.5 s) names the subject. **Screen text and screenshots are never sent** — only those few words.
- **One lookup:** search (3 hits) → summary of the top hit → that intro (≤ 600 tokens) goes into the prompt as "Reference (Wikipedia: <title>)". No loop, no following links.
- **Credit it:** the chat ends with "Source: Wikipedia — <Title>" as a link. Wikipedia text is CC BY-SA 4.0, so showing it needs the credit and link; we only quote, never store.
- **Etiquette:** a `User-Agent` naming ClickBait and the repo (Wikimedia asks for this), one request at a time, 3 s timeout → answer without it and say so.
- **Nothing kept:** queries live in memory only (a "recent lookups" list of 5, cleared on quit).

## Privacy and the written promises

- This **overturns** the "No web lookups" rule in CLAUDE.md (2026-10-01), and "works offline / it never tells anyone" on the site. If it goes ahead, change the rule to: *"No web lookups unless the user switches on Wikipedia lookups and asks; only the subject words are sent, to Wikipedia; never the screen, audio or screen text."* Update the site's Privacy and FAQ the same day.
- Wikimedia sees the user's IP address and the subject words ([Wikimedia privacy policy](https://foundation.wikimedia.org/wiki/Policy:Privacy_policy)).

## Where it would live

- `ClickBaitCore/Prompting/LookupQuery.swift` — trigger detection + subject terms from tagged words (testable without the network).
- `ClickBaitCore/Providers/WikipediaClient.swift` — search + summary over `URLSession`, parsing tested with recorded JSON.
- `Prompt` gains a reference block; `AskCoordinator.respond` runs the lookup before the stream when the switch is on and the request asks.

## Open questions

1. OK to relax "no web lookups" for Wikipedia only, behind the switch?
2. Trigger words only, or also offer it after a weak answer ("Want me to check Wikipedia?")?
3. English Wikipedia only (matches the English-only speech model), or follow the system language?
4. Should the existing Anthropic "Internet Mode" setting in the build be hidden until roadmap D is decided?
