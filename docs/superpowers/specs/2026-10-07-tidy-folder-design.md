# Tidy this folder — design

Date: 2026-10-07 · Status: draft for review
Depends on: `2026-10-07-background-clickbaits-design.md` (capsules, built first)

## Why

Roadmap phase E: file management beyond the Finder selection. "Tidy my Downloads" is the first long job worth a background capsule: ClickBait reads the folder, proposes a clean-up, and moves nothing until the user approves — "bulk changes the model proposes are shown for confirmation" (CLAUDE.md). The whole job lives in its capsule; no chat opens.

## Decisions (from brainstorming)

- Sorting uses names, types, dates and a short peek inside files, read on this Mac.
- A tidy-up may only move files into folders inside that folder. No renames, no Trash, no deletes, no overwrites.
- Review and approval happen in the expanded capsule card: a checklist of folders, each expandable to its files.
- Undo from the done card, kept in memory until the capsule is dismissed or ClickBait quits.
- Fast, sensible and clean: obvious files by rules, the rest by a two-step model plan (folders first, then filing constrained to those folders), text-only.
- Every capsule shows a sleek progress bar when expanded (added to the background ClickBaits spec).

## Behaviour

### Starting
- Spoken or typed: "tidy / clean up / organise / organize / sort (out)" + "this folder" or a place ("my Downloads", "the Desktop", "Documents", any place `Places` already knows). "This folder" = the front Finder window's folder (`FinderSelection.frontFolder`).
- Rule-recognised (`CommandParser`), resolved by `ActionCatalog.resolve`. Starting needs no confirmation (it only reads); moving is confirmed by **do it!**.
- It starts straight in a capsule: the companion turns green and peels off to a new green capsule (Shamrock, `CompanionTone.action`); a fresh blue companion stays at the cursor.
- No folder found / unreadable → a short error pill, no capsule. Three capsules up → "three's a crowd", nothing starts.

### In the capsule (card copy is exact)
1. **Reading / filing** — green pulse. Card: "looking through <Folder>", a progress bar (files read, then files filed), **stop**.
2. **Plan ready** — still, with the dot. Card:
   - One row per folder: tick, "Receipts / 2026 · 23". A row's arrow expands it to its files, each with its own tick.
   - "<n> files stay where they are." (omitted when 0)
   - When the 500 cap applied: "Looked at the newest 500 of <total> files."
   - **do it!** · **no** ("no" drops the plan and removes the capsule).
   - The list scrolls inside the card, card height ≤ 360 pt.
3. **Moving** — pulse again; the progress bar counts files moved.
4. **Done** — dot. "Moved <n> files into <biggest folder> and <m> more into <k> folders." (variants below), **go there!** (opens the folder in Finder with the new folders selected), **undo**, **later, pls**.
5. **Undo** — progress bar while putting back; then "Put back <n> files." and **ok**.
6. **Failed** — "Couldn't tidy <Folder>: <reason>" and **ok**. If some files had already moved, the card says how many and still offers **undo**.

Summary variants: one folder → "Moved 23 files into Receipts / 2026."; one file → "Moved 1 file into …"; several → "Moved 23 files into Receipts / 2026 and 31 more into 4 folders." (and "1 more into 1 folder").

Folder access refused by macOS → "Couldn't tidy Downloads: ClickBait can't read it. Allow it in System Settings → Privacy & Security → Files and Folders."

### Never
- Renames, Trash, deletes, overwrites (clashes get numbered names).
- Opening or rearranging existing subfolders (they can be reused as destinations).
- Touching hidden files, packages/apps, aliases, files changed in the last 10 minutes, or files ending `.download`, `.crdownload`, `.part`.
- Esc doesn't stop it; **stop** does. Quitting mid-move finishes the current file, then stops; the undo record is lost on quit (memory only).

### Clean results
- At most 8 folders, at most one sublevel ("Receipts / 2026").
- Short plain names; an existing subfolder with the same name (ignoring case) is reused.
- No folder for fewer than 3 files: those files stay.
- Rule folders (no model): "Screenshot …" → Screenshots; "Screen Recording …" → Screen Recordings; `.dmg`, `.pkg` → Installers; `.zip`, `.rar`, `.7z`, `.tar.gz`, `.tgz` → Archives — each only when ≥ 3 files would go there.
- At most the 500 newest files are considered.

### The user comes first
Ollama answers one request at a time. Before each model call the tidy waits while a foreground question is listening, thinking or answering, so it never delays the user. Logged: "Tidy waited <t> for a question".

## Architecture

### ClickBaitCore — `Sources/ClickBaitCore/Tidy/` (no AppKit; tested)
- `TidyFile` — `url`, `name`, `ext`, `kind` (pdf, image, text, installer, archive, video, audio, document, other), `modified`, `size`, `peek: String?`, flags (`isHidden`, `isPackage`, `isAlias`, `isDirectory`).
- `TidyScan.candidates(_ files: [TidyFile], now: Date) -> (kept: [TidyFile], skipped: Int, total: Int)` — skip rules above; newest 500.
- `TidyRules.place(_ files: [TidyFile]) -> (placed: [URL: String], rest: [TidyFile])`.
- `TidyPlan` — `folders: [String]`, `assignments: [URL: String]`; `TidyPlan.cleaned(proposed: [String], existing: [String]) -> [String]` (≤8, ≤1 sublevel, valid names via the existing name validation, reuse existing case-insensitively); `TidyPlan.make(rules:modelAssignments:folders:)` drops folders under 3 files.
- `Prompt.tidyPlanSystem` / `tidyPlanRequest(sample: [TidyFile], existing: [String])` → `{"folders": ["Receipts / 2026", …]}`.
- `Prompt.tidyFileSystem` / `tidyFileRequest(batch: [TidyFile], folders: [String])` → `{"1": "Receipts / 2026", "2": "leave", …}`; `TidyReply.parse(_ reply: String, batch: [TidyFile], folders: [String]) -> [URL: String]` (wrong numbers ignored; unknown folder or "leave" → stays; a file appears at most once).
- File line format for both: `<n>. <name> · <kind> · <yyyy-mm-dd> · "<peek ≤ 200 chars>"`.
- `TidyJob` — states `reading(done, total)`, `filing(done, total)`, `planReady(TidyPlan)`, `moving(done, total)`, `done(summary, MoveLog)`, `undoing(done, total)`, `undone(summary)`, `failed(reason, MoveLog?)`, `stopped`; transitions only forward along that path (undo only from done/failed-with-moves); progress never decreases or exceeds total.
- `TidySummary.done(_ moved: [String: Int]) -> String`, `TidySummary.undone(_ count: Int) -> String` — exact copy above.
- `MoveLog` — `moves: [(from: URL, to: URL)]`, `createdFolders: [URL]`; `undoSteps` in reverse order.

### App — `ClickBait/Tidy/`
- `TidyReader` — `FileManager.contentsOfDirectory` with resource keys (hidden, package, alias, directory, modification date, size); peeks 4 at a time: PDF first page text (PDFKit), text files' first 200 characters (UTF-8), images' words (Vision, fast recognition, ≤ 200 images).
- `TidyRunner` — `@MainActor` owner of one job: read → rules → plan call → filing batches of 40 → plan ready; after **do it!**: for each ticked file re-check it's there with the same size and date, create folders, move (`FileManager.moveItem`, numbered on clash using the `FileActions` unique-name helper made shared), record in `MoveLog`; undo moves a file back only if it's still at its new place; removes created folders only if empty. Waits for a free model before each call (`isUserBusy: () -> Bool`).
- `CommandParser` / `ActionRequest` — new `tidyFolder(Place?)`; `ActionCatalog.resolve` validates it; `ActionExecutor` hands it to the coordinator, which calls `onTidyStart(folder)`.
- Background capsule changes (see the amended capsule spec): `BackgroundJobs.Entry` holds `work: .answer(BackgroundJob) | .tidy(TidyRunner)`; capsule tone from the work; `CapsuleView` tidy cards (progress, plan checklist, done with undo) and the shared progress bar.
- `AppDelegate` — `onTidyStart` → add entry, peel flight, start the runner; **go there!** → `NSWorkspace.shared.activateFileViewerSelecting(createdFolders)` (or open the folder).

## Testing

Automatic (Swift Testing, `ClickBaitCoreTests`):
- `TidyScan`: each skip rule; the 10-minute rule at its boundary; newest 500 kept, total reported.
- `TidyRules`: screenshots, screen recordings, installers, archives recognised; under 3 → none.
- `TidyPlan`: >8 folders and second sublevels trimmed; bad names refused; "receipts" reuses "Receipts"; folders under 3 dropped, their files stay.
- `TidyReply`: wrong numbers ignored; unknown folder / "leave" → stays; duplicates; missing files stay.
- `TidyJob`: allowed transitions; nothing after stop; progress monotonic and ≤ total; undo only from done or failed-with-moves.
- `TidySummary`: every copy variant, singular and plural.
- `MoveLog`: reverse order; only empty created folders removed.
- Real files in a test-made temporary folder: full tidy then undo restores every file and leaves no extra folders; a clash gets a numbered name; a file changed after planning is skipped; a file moved away by hand before undo is left alone. (Uses a Core-level mover with injected `FileManager` work so it runs in `swift test`.)

By hand:
1. "Tidy my Downloads": green flight; the bar fills while reading and filing; dot when the plan is ready.
2. Untick a folder and a single file; **do it!** moves only what's ticked.
3. **go there!** opens Finder with the new folders selected.
4. **undo** puts everything back; made folders gone.
5. Ask a question mid-tidy: the answer isn't slowed (log shows the tidy waiting).
6. **stop** while reading; **no** on the plan; quitting mid-move.
7. Folder access refused → the plain failure line.
8. "tidy this folder" with no Finder window → error pill.
