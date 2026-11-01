# Smart search

_Added 2026-11-01 (user's ask, after Taby's smart search)._

"Find that note about the plumber", "find the march invoice pdf", "show me the picture of the
airport", "where's the invoice pdf", "do I have a reminder about the car?" — asked by voice or
typed, first question or later in a chat — are answered by smart search on this Mac, not the
model. They skip the order and walkthrough checks. The chat opens (by voice too) with a results
card (`SearchResultsView`, like Taby's): pictures as a thumbnail grid, files with their Quick
Look previews, notes and reminders as rows with a line of what they say. Click opens (Apple
Notes at the note; Reminders and Photos open their app); files and pictures drag out and have
Copy, Show in Finder and Share on hover. Spoken, it's just "Found 3." The chat's memory keeps
the full list.

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
First the brain adds related words (~0.3 s, skipped after 2 s): "dentist" → toothache,
cleaning, appointment. They join the text nomic embeds, and an item holding one of them gets a
word bonus. Measured 2026-11-01: plain nomic put "cleaning on Tuesday" below the plumber note
for "dentist"; with the words it came first, and "leaky pipe" found the plumber.

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
- Questions about on-screen controls ("find the settings menu") stay pointing questions.
- Photos-library results have no file to open; they name the day.
