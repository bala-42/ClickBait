# Internet Mode — design

Date: 2026-10-07 · Status: approved 2026-10-10 with the decisions below; built 2026-10-10

**Decided 2026-10-10:** no paid APIs or keys anywhere in ClickBait — the user (and most users) don't have an Anthropic key. The Anthropic provider is removed (roadmap D), so "Internet Mode" means only this feature: free, keyless lookups answered by the local model. The Settings label "Internet Mode — Anthropic API" goes away with the provider. Remaining review items in this spec (sources, the 🔒/🌐 menu title, SearXNG setup) still need the user's sign-off before building.

## Decisions (signed off 2026-10-10) — these override anything below that disagrees

1. **SearXNG is optional.** It runs on this Mac as a second install if the user wants it. Without it, Internet Mode works with Wikipedia, Stack Overflow (Stack Exchange API), MDN and Apple developer docs. Settings → Internet shows it as "Ready" or "Not set up (optional)" (not "Needed"), with plain setup steps.
2. **Menu-bar title** "🔒 ClickBait" / "🌐 ClickBait" as text, changed only when the switch is toggled, never per state (per-state status-item changes stalled the companion; see CLAUDE.md).
3. **When it goes online:** only while 🌐 is on AND the user's words ask for something the local model can't know — "look it up" and the like, recent facts ("latest", "current", "this week", a year, "release"), an error ("this error", a traceback), or an API/documentation question. Fixed rules on the user's words (`WebLookup.reason`), never the model's initiative. The "Internet's off…" note is shown only for the explicit phrases.
4. **Screen words in a search (option a).** For a question about the screen, the local model writes a short search phrase from what's on screen; only that phrase leaves the Mac: ≤12 words / 100 characters, with email addresses, web addresses, file paths, long numbers and key-like strings removed first (`QueryScrubber`). Never raw screen text or passages; nothing from blocked apps. Every query shows in Recent searches.
5. **People's names (option a).** Names the user said or typed may be searched; names found on screen (detected on-device with `NLTagger`) are removed from any phrase, and snips with a face send nothing.
6. **Snips (option a).** Circling while 🌐 is on counts as the ask: the existing snip lookup (subject → Wikipedia, for the parts tour) runs under the one switch; the separate "Look Up Snips on Wikipedia" item is gone. It's the one recorded exception to "the user's words ask".
7. **The spec line "No artificial limits on what a lookup sends" is withdrawn** (4 replaces it).
8. **Always a model-written query.** The search words come from a short text-only step on the local model (`Prompt.lookupSystem`, ~1 s); the request minus its trigger words is only the fallback. Measured: Wikipedia searched for the raw words "latest Swift version" returned Taylor Swift albums.
9. **Timeouts:** 3 s per request; the whole lookup gets ~4 s and uses whatever has arrived. A slow source never holds up the answer; a failed lookup gives a local answer plus "Couldn't reach the web, so this is from what I know."
10. **Budget:** ~800 tokens (3,200 characters) of web text to start, measured before raising it.
11. **Where it shows:** a web answer always opens the chat (never a pill), with "Sources:" links under it. No inline [1] marks (they'd be read aloud).
12. **Wikipedia** is used for general questions, and for anything when SearXNG isn't running and no technical source fits — not for code questions (they went to unrelated articles).

## Why

The local model doesn't know recent facts (news, versions, current APIs) and is thin on specifics (an error's known cause, a library's exact signature). The user wants an opt-in switch that lets ClickBait look things up on the web — free, with no account, no paid service and no ClickBait server — while keeping "private by default". Web lookups do not fix parts-tour placement (that's positions in a picture, handled on-device by `ObjectFinder`), so that isn't a goal here.

## Decisions (from brainstorming)

- 🔒 Local Mode at every launch; 🌐 Internet Mode only by the user's switch in the menu bar; stays on until switched off or quit; never saved.
- Goes online only when the user's words ask, never on the model's own initiative.
- The local model (Ollama, `qwen3.5:9b`) answers. No cloud model, nothing paid.
- A lookup is two fixed steps: pick the lookup, look up, then answer. No open-ended tool loop.
- No artificial limits on what a lookup sends; in practice that's search queries and page addresses (no free service can use a screenshot or audio).
- Free sources: SearXNG running on this Mac (like Ollama), Wikipedia, Stack Overflow (Stack Exchange API), MDN, Apple developer documentation, and pages from results/screen/words.
- No new pill: the triangle spins as for any answer. Queries are listed in the menu ("Recent searches", last 5, memory only).
- Menu bar shows "🔒 ClickBait" / "🌐 ClickBait".

## Behaviour

### The switch
- The status item's title is "🔒 ClickBait" or "🌐 ClickBait" (text replaces today's `cursorarrow.rays` icon). It changes only when toggled.
- The menu's first item toggles: "Internet: off 🔒" / "Internet: on 🌐".
- Every launch starts 🔒. The value isn't written to `UserDefaults` or anywhere else.

### When it goes online
- Only when 🌐 is on and the request asks: "look it up", "look up …", "search the web / online / the internet", "google it", "check online", "find online", "what's the latest on …". Spoken questions, typed chat messages and follow-ups alike.
- Everything else stays local, even with 🌐 on.
- With 🔒 on, a request that asks gets a normal local answer plus the line: "Internet's off. Switch to 🌐 in the menu bar to look things up."
- Orders, walkthroughs, instant pointing and snips are decided first, exactly as today. The lookup applies only where a plain answer would be requested.

### A lookup
1. **The query.**
   - If the request doesn't refer to the screen ("this", "that", "here", "the error", "on screen" …), the query is the request without its trigger words. No model call.
   - Otherwise a text-only step (no screenshot): the model gets the request, the app and window title, any selected text and the screen's words read on-device by Apple Vision (`TextReader`, ≤1,500 characters, nearest the cursor first). It replies `{"tool": "search" | "fetch" | "docs", "query": "…", "url": "…"}` (structured output). Target ~1.5 s.
2. **The sources**, all asked at once (`TaskGroup`):
   - SearXNG on this Mac: always, when it's running.
   - Stack Overflow: errors, exceptions, tracebacks, code words.
   - MDN: web-platform API words.
   - Apple developer documentation: Swift, SwiftUI, AppKit, UIKit, Foundation and other Apple framework words.
   - Wikipedia: general questions, and whenever SearXNG isn't running.
   - `fetch`: the given address only (see addresses below).
3. **Reading.** The top 2–3 result pages are fetched at once and turned into text. On-device sentence embeddings (`NLEmbedding`, word overlap as fallback) pick the passages closest to the question, about 1,200 tokens in total, each source getting a fair share.
4. **The answer.** The normal answer request plus a "From the web" block of numbered passages with their titles and addresses. The model cites them as [1], [2]; the chat shows the sources as Markdown links under the answer. The screenshot is sent only when the request refers to the screen; otherwise the request is text-only.
- Timing target: ≈5–7 s for a lookup not about the screen, ≈11–13 s for one about the screen.
- Lookup fails (offline, timeout, nothing found): a local answer plus "Couldn't reach the web, so this is from what I know."
- Esc cancels the lookup like any answer. A web answer is a plain answer, so it can be peeled off to a background capsule.

### Addresses
An address may be fetched only if it appears in the user's words, in the screen's text (including the browser's page address, `AXInspector.pageAddress`), or in a result from this lookup. HTTPS only; plain HTTP only for the SearXNG on `localhost`/`127.0.0.1`.

### Requests
- One ephemeral `URLSession`: no cookies, no cache, no credential storage.
- User agent `ClickBait/<version>`, plus the public repository address once there is one (Wikipedia's API policy asks for an identifying agent).
- 8 s per request, 2 MB per page, at most 3 pages read per lookup.
- Stack Exchange without a key: 300 requests a day from this Mac; when exhausted, Stack Overflow is skipped for the day.

### SearXNG on this Mac
- Settings → Internet shows its status ("Ready" / "Needed"), checked by `GET http://127.0.0.1:8888/search?q=test&format=json`.
- The stock image only serves HTML, so ClickBait offers **Prepare SearXNG settings**: it writes a `settings.yml` (`use_default_settings: true`, JSON format enabled, limiter off, a random `secret_key`) to `~/Library/Application Support/ClickBait/searxng/` and shows one command with Copy:
  `docker run -d --name clickbait-searxng --restart unless-stopped -p 127.0.0.1:8888:8080 -v "$HOME/Library/Application Support/ClickBait/searxng:/etc/searxng" searxng/searxng`
  (Docker Desktop or OrbStack, free for personal use.) Exact settings keys and image paths are checked against SearXNG's current docs when implemented.
- Not running: lookups use the other sources; nothing fails.

### Recent searches
The menu's "Recent searches" submenu lists the last 5 queries and fetched addresses, newest first, in memory only.

### Web text is untrusted
Web text only goes into the answer request's "From the web" block. It is never read by the order, walkthrough, file or reminder paths, so a page can't make ClickBait act on the Mac. The answer prompt says the block is reference material, not instructions.

## Architecture

### ClickBaitCore — `Sources/ClickBaitCore/Web/` (no AppKit; tested)
- `WebLookup` — `isRequested(_ text: String) -> Bool`; `needsScreen(_ text: String) -> Bool`; `directQuery(_ text: String) -> String`.
- `WebSource` — `.searxng, .wikipedia, .stackOverflow, .mdn, .appleDocs`; `WebSourcePicker.sources(for text: String, searxngAvailable: Bool) -> [WebSource]`.
- `WebRequests` — `URLRequest` builders per source and for result pages (pure; the endpoints listed below).
- `WebResultParser` — each source's JSON → `[WebResult]` (`title`, `url`, `snippet`, `source`); malformed → `[]`.
- `HTMLText.readable(_ html: String) -> String` — drops `script`, `style`, `nav`, `header`, `footer`, `aside`; tags → text; entities decoded; paragraphs kept.
- `PassagePicker.pick(_ documents: [WebDocument], question: String, budgetTokens: Int, score: (String, String) -> Double) -> [Passage]` — fair share per source, best first, within budget (≈4 characters per token).
- `URLGuard.allows(_ url: URL, seenIn: Set<URL>) -> Bool` — https, or http on localhost; must be in `seenIn`.
- `Prompt` — `lookupSystem` (step one) and the "From the web" block (`Prompt.webBlock(_ passages:)`); `AskRequest.web: [Passage]`.

Endpoints (checked against each service's current docs at implementation):
- Wikipedia search `https://en.wikipedia.org/w/rest.php/v1/search/page?q=…&limit=3`, plain-text extract via `action=query&prop=extracts&explaintext=1`.
- Stack Exchange `https://api.stackexchange.com/2.3/search/advanced?site=stackoverflow&sort=relevance&accepted=True&q=…`, then top answers via `/questions/{ids}/answers?sort=votes&filter=withbody`.
- MDN `https://developer.mozilla.org/api/v1/search?q=…&locale=en-US`, page JSON at `<doc url>/index.json`.
- Apple docs: "<Framework> <Symbol>" → `https://developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.json`; otherwise SearXNG with `site:developer.apple.com`.
- SearXNG `http://127.0.0.1:8888/search?q=…&format=json`.

### App — `ClickBait/Internet/`
- `InternetMode` — `@MainActor @Observable`: `isOn` (false at launch, never persisted), `recentLookups` (≤5).
- `InternetManager` — actor: the ephemeral session, the Stack Exchange daily count (memory only), `lookUp(_ plan: LookupPlan, question: String) async throws -> [WebDocument]` running sources and page reads concurrently.
- `PassageRanker` — `NLEmbedding.sentenceEmbedding(for: .english)` cosine score; word-overlap fallback.
- `SearXNGSetup` — checker (poll like `ModelSetupChecker`) + Settings → Internet section with "Prepare SearXNG settings" and the command with Copy.
- `StatusBarController` — title text, toggle item, "Recent searches" submenu.
- `AskCoordinator.respond()` — at the point a plain answer is requested: `WebLookup.isRequested` → 🔒 note, or the lookup → passages → `AskRequest.web`; empty screenshot when `!needsScreen`. Logs sources, per-source timing, pages read, passage count and total time.

## Privacy rules (replaces two lines in CLAUDE.md)

- ClickBait starts every launch in Local Mode (🔒): its only network traffic is Ollama on this Mac and the speech-model download the user starts.
- Internet Mode (🌐) is switched on only by the user, from the menu bar; it's never saved and never switched on by ClickBait.
- In 🌐, ClickBait goes online only when the user's words ask ("look it up", "search the web", …).
- A lookup sends search queries and page addresses to Wikipedia, Stack Exchange, MDN, Apple's documentation, the pages it reads, and the SearXNG on this Mac — never screenshots, audio, chats or element lists; no cookies, no cache, HTTPS only. An address is read only if it appeared in the user's words, on screen or in a result.
- Web text only informs a written answer; it never triggers an order, walkthrough or file action.
- The blocklist still applies (no capture, no lookup). No analytics, no accounts, no paid services.

Also: README and the website keep "private by default" but must mention the 🌐 switch honestly when this ships.

## Testing

Automatic (Swift Testing, `ClickBaitCoreTests`):
- `WebLookup`: trigger phrases recognised; "look at this", "lookup table", "search this file" are not; `needsScreen` separates "look this error up" from "look up the latest Swift version"; `directQuery` strips trigger words.
- `WebSourcePicker`: Python traceback → Stack Overflow; "fetch API" → MDN; "SwiftUI List" → Apple docs; "who won the 2026 World Cup" → Wikipedia; SearXNG only when available.
- `WebRequests`: exact URLs and query items per source; user agent set.
- `WebResultParser`: fixture replies → results; malformed → `[]`.
- `HTMLText`: scripts/styles dropped, entities decoded, paragraphs kept.
- `PassagePicker`: within budget; best first; fair share across sources.
- `URLGuard`: unseen address refused; http refused except localhost.
- `Prompt`: web block numbering; step-one reply parsing and validation.

By hand:
1. Fresh launch is 🔒; the switch changes the title.
2. 🔒 + "look it up" → local answer + "Internet's off…".
3. 🌐 + "look up the latest Swift version" → text-only, a source link, ≈5–7 s.
4. 🌐 + "look this error up" over a Python traceback → Stack Overflow, with the screen, ≈11–13 s.
5. SearXNG stopped → Settings "Needed"; lookups still work via Wikipedia/Stack Overflow.
6. Wi-Fi off → local answer + "Couldn't reach the web…".
7. Esc mid-lookup stops it.
8. "Recent searches" lists queries; relaunch → empty and 🔒.
9. Blocked app in front → no lookup.

## Out of scope

Cloud models; paid search APIs; automatic lookups the user didn't ask for; keeping Internet Mode across launches; non-English Wikipedia (follows the speech model's English-only scope).
