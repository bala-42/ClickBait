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

## Vision Memory: the user's control (2026-11-01, user's asks)
Settings ▸ **Vision Memory** (`VisionMemorySection`), rules in Core's `VisionMemory`:
- **Describe pictures** on/off; one button: **Pause** while learning, **Learn** while paused, **Done!** when every picture is described; a status line
  ("1,240 of 3,000 pictures described · 8 MB on disk · paused until 3:00 PM").
- **Folders it reads** (Desktop, Downloads, Documents, Pictures, the screenshot folder by
  default) and **Never look in**: excluded folders are skipped while walking and left out of
  search results, Spotlight's included.
- **Screenshots and documents** on/off: off, they're only labelled as such (no text, no caption).
- **Secret-looking text** (passwords, keys, card and ID numbers: `Memory.looksSecret`) is never
  kept; such pictures are marked `sensitive` and the brain doesn't describe them.
- **Right-click a picture** in results: **Edit description…** (kept over the brain's, never
  overwritten; empty lets the brain describe again) or **Forget this picture** (out of the
  index, never read again: `vision-forgotten.json`).
- **Respects the Mac** (`VisionOptions.mayWork`), checked before each picture and caption: not
  while an ask is under way (`AskActivity`), not in Low Power Mode or when the Mac is hot, not on
  battery unless "Work on battery" is on.
- **Copies**: size + SHA-256 of the first 64 KB (`contentKey`); a copy reuses what was read and
  described, and search shows one result with "N copies". Older entries are fingerprinted on
  the next pass without being read again.
- **Sync**: folders are watched (`PictureWatcher`, FSEvents, 5 s): a quick pass (pictures only)
  follows any change; a file gone since it was read never shows in results.
- **Per-kind captions**: documents, charts and screenshots are described by kind, subject and
  key details; photos by who, what, where.
- **A new brain** describes again in the background, after the undescribed pictures
  (`captionModel`); the user's own descriptions are kept.
- **Storage**: vectors as half-precision bytes (`VisionMemory.pack`): this Mac's index went from
  30.9 MB to 8.2 MB (3,059 entries) with identical search results. **Delete Vision Memory…**
  empties it (pictures untouched).

**Editing a description in place (2026-11-01, user's report: the dialog was "counter intuitive", one line, and had to be dragged).** Right-click ▸ **Edit description** now opens `DescriptionEditor` inside the results card, under the pictures: the picture, a field of 3–8 lines in the chat's own field look (glass in the overlay, solid dark in the notch: `resultsInNotch`), and Describe again / Cancel / Save (Return saves, Esc cancels). Its window takes the keyboard, the notch included. The Vision Memory settings use the standard rows: progress with a bar and a Pause menu, folders in an inset list with Add… / Exclude…, Delete as a row.

**More than one result (2026-11-01, user: "only generating one result when I clearly have more").** Nothing was lost (all 3,000 pictures described, none missing on disk; 120 copies merged by design): the ranking kept only results within 0.25 of the best, so when one pulled far ahead — a file Spotlight matched by name (+0.3) with the words in its name — every other good match was cut, often leaving one. Now a result stays if it's good on its own (score ≥ 0.4) or close to the best; every good match shows, up to 60, to scroll through in the chat (user: "why is 8 the limit?"; 80 candidates ranked, 80 Spotlight hits).

**Why it was weak: the index was full of junk (2026-11-01, user: "still weak and not smart enough").** 2,643 of the 3,000 indexed pictures were 16-pixel handwritten digits from a dataset in a Desktop project (USPS test images): the newest 3,000 were taken, so the junk crowded out most real pictures, which were never read. Now `pictureFiles` skips data folders (`VisionMemory.isDataFolder`: dataset(s), data, node_modules, venv, site-packages, build, DerivedData, checkpoints…), images under 100 px on their longer side (read from the header), and folders with more than 40 number-named pictures (dumps, `isNumberedName`). Captions also start with the kind of picture ("A photo of…", "A painting of…", "A screenshot of…"): only 1 of 3,000 said "photo" and 5 "painting", so nothing told a group photo from a painting of a crowd; older captions are redone in the background (`captionModel` = brain + `captionStyle`). After the change the index held 317 real pictures (on battery, so no new reading yet). Tried and not adopted: the brain re-ranking the top candidates (a ranked list, then a yes/no per item) — gemma4:e4b put blurry fragments over code screenshots and kept group photos for "a painting with lots of people"; the captions were the limit.

**Videos (2026-11-01, user: "find shampoo videos… not working").** Search knew no "video" kind, so "videos" was a word every result had to hold (none did). Now `SmartSearch.Kind.video` ("video(s)", "clip(s)", "movie(s)", "recording(s)", "footage"); a short phrase naming a kind is a search without "find" ("shampoo videos", "beach photos"); Spotlight results get their kind from the extension (`Kind.of`). Vision Memory reads videos too — "Describe multimedia" in Settings (user: "it should also consider videos and other multimedia"): a frame from the middle of each video (`middleFrame`, AVAssetImageGenerator) gets Vision's labels and text, and a brain caption starting "A video of…"; videos show as thumbnails in the results grid and open in the player. Audio-only files aren't described (nothing to see; transcribing them is a later step). Live (debug-only `org.clickbait.debug.search`): "find shampoo videos" → 8 shampoo videos (two ASMR downloads, six shampoo_input clips).
