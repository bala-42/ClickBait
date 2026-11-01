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


## Like Taby's results (2026-11-01, user's ask, from a Taby demo video)
Typed (chat, notch Ask tab) and spoken alike:
- **A sentence about the best find**, from the brain (~0.5 s, ≤ 4 s else "Found 3."):
  "I found a picture called me with dog in your Downloads folder; would you like me to open
  it?" Spoken too when asked by voice.
- **"Open it" / "open the second one" / "show it in Finder"** (`SmartSearch.followUp`) act on
  the last results (`AskCoordinator.lastSearchResults`), skipping orders and walkthroughs.
- **The card**: why the top result matched ("Matches “dog” in the picture", "…in the name",
  "…inside", "Close in meaning"); bigger thumbnails (~3 across); folder · date · size; **Open**
  and a folder button always shown; Copy and Share on hover; **Listen again** (reads the
  sentence even with "Read answers aloud" off).
- **Captions**: the brain (it can see) writes one line per picture in the background, newest
  first, 300 per pass (~0.5 s each with gemma4:e4b): "A woman wearing a fluffy white hat is
  posing indoors." where Vision only had "people, adult". Captions are searched and embedded.
- **"Me"** (`YourFace`): Settings ▸ Behavior ▸ "Your photo, for “me”". Each picture's faces are
  compared with it (Vision feature prints of the face crops, threshold 0.75); matches are
  tagged as the user and come first for "a picture where I'm holding a dog" / "a photo of me".
  Measured on 26 faces from this Mac: unrelated faces never matched under 0.75, but only about
  a quarter of same-folder pairs did, so many photos of the user are missed. A real face
  recognition model would do much better (a further download). Changing the photo re-reads
  every picture.
