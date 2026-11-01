# Smart search

_Added 2026-11-01 (user's ask, after Taby's smart search)._

"Find that note about the plumber", "find the march invoice pdf", "show me the picture of the
airport", "do I have a reminder about the car?" — asked by voice or typed — are answered by
smart search on this Mac, not the model. The reply lists up to five things with where they are
and a line of what they say; files and pictures are links that open them. Spoken, it's just
"Found 3."

## What it searches
- **Files and PDFs** by name or the text inside: Spotlight (`mdfind`, home folder only; Library,
  Trash, `.git`, `node_modules`, apps skipped), at search time.
- **Pictures** in Desktop, Downloads, Documents, Pictures and the screenshot folder: each read
  once with Apple's Vision (what it shows, and any text in it), newest 3,000, up to 400 per pass.
- **The Photos library**, only with Settings ▸ Behavior ▸ "Search the Photos library" on (asks
  for Photos access). Thumbnails only; iCloud originals aren't downloaded.
- **ClickBait's own**: remembered facts, the notes folder, saved answers, the notch's quick note.
- **Reminders** (open, and done in the last 90 days) when ClickBait may read them.
- **Apple Notes**, newest 1,500, through Notes itself (asks for Automation once).

## By meaning
nomic-embed-text through Ollama is ClickBait's standard embedding model: downloaded with every
brain (brain sizes include its 0.3 GB), or fetched in the background on Macs whose brain came
first. Queries and documents get nomic's `search_query: ` / `search_document: ` labels. Score =
0.7 × meaning (nomic's similarity, spread from its 0.5–0.75 band to 0…1) + 0.3 × shared words,
+0.3 when Spotlight matched a file's contents, a small nudge for the kind asked for. Without
nomic (still downloading) Apple's on-device sentence model stands in.

The index is `~/Library/Application Support/ClickBait/search-index.json`: refreshed a minute
after launch, every 30 minutes, and when a search finds it older than 10 minutes. Only changed
things are re-read and re-embedded. Nothing leaves the Mac.

## Limits
- First pass reads 400 pictures; the rest come in over later passes (every 30 minutes).
- Big leaps of meaning miss: "dentist" doesn't find a note that only says "cleaning on Tuesday"
  (nomic scored it below unrelated notes in testing).
- Questions about on-screen controls ("find the settings menu") stay pointing questions.
- Photos-library results have no file to open; they name the day.
