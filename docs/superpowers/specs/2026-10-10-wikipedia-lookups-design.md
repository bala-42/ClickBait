# Wikipedia lookups (a lighter "Internet Mode") — exploration

Date: 2026-10-10 · Status: snip parts tours built, now part of Internet Mode (🌐); questions are covered by `2026-10-07-internet-mode-design.md`

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

## Decided and built (2026-10-10): snip parts tours only

Discussed with the user, in order: looking things up at hotkey release (too early: there's only audio), during the circling (too early: no subject yet, and only screen text or titles could be sent), then **after the snip is done, as soon as the model names its subject**. That's what was built.

1. **Switch:** Internet Mode (🌐), off at every launch, never saved (`AppSettings.internet`). (It was its own menu item, "Look Up Snips on Wikipedia", until Internet Mode absorbed it the same day.)
2. **User lets go of the snip.** The close-up goes to the model as before; text reading and object finding start on the Mac.
3. **Subject first.** With the switch on, a first snip explanation is asked for `"subject"` (an encyclopedia title, 1–4 words; "none" for people, text, code or an app's screen), and Ollama's structured output makes it the first key. Prompt alone: qwen3.5:9b put it after "speech" or left it out (2 runs); enforced: first in 4 of 4. The reply streams, so the subject arrives with the first words (~5 s after release on the solar-system test; the explanation took ~11.6 s).
4. **Lookup on that word** (`StreamingSubject` → `AskCoordinator.startLookup` → `WikipediaClient`): search (1 hit) → its REST summary, intro trimmed to 1,200 characters, 3 s timeout, `User-Agent` naming ClickBait. Measured live: 0.7–0.8 s for both requests, done long before the explanation ends.
5. **Guards before anything is sent:** a face in the close-up (`FaceFinder`) → no lookup (a person's name is never sent); mostly text (`PartsTour.isMostlyText`) → no lookup (no tour follows); background (peeled) answers and follow-ups → no lookup.
6. **Used for the pills:** the intro goes into the marks request ("Background from Wikipedia…") so the model can tell the named things apart. Placement stays on-device (`ObjectFinder`); Wikipedia can't fix look-alikes or a wrong subject.
7. **Credit:** when the marks were named with it, the chat's answer gets "Source: [Wikipedia — Title](url)" (CC BY-SA).

Not built: lookups for spoken or typed questions (timing proposed: after transcription and the rule checks, alongside the ~2.4 s screenshot encode), per-pill descriptions, a "recent lookups" list.

Privacy: CLAUDE.md's "no web lookups" rule now has this one exception, and the site's FAQ says so. Wikimedia sees the user's IP address and the subject words ([privacy policy](https://foundation.wikimedia.org/wiki/Policy:Privacy_policy)).

## Open questions

1. Extend to spoken and typed questions (automatic when switched on, or only on "look it up")?
2. English Wikipedia only (matches the English-only speech model), or follow the system language?
3. ~~Should the existing Anthropic "Internet Mode" setting in the build be hidden until roadmap D is decided?~~ Decided 2026-10-10: the Anthropic provider is removed entirely; Internet Mode becomes the wider free lookups (`2026-10-07-internet-mode-design.md`), which these Wikipedia lookups become part of.
