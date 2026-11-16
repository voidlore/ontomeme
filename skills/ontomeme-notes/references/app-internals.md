# Ontomeme internals and lessons learned (for agents changing the app)

## Map

| File | Owns |
|---|---|
| `note.tscn` / `note.gd` | main window: sidebar (folders, vault switcher, drag/drop, context menu), toolbar modes, palette (Ctrl+P), disk watcher, Journey wiring |
| `app_theme.gd` | the whole Theme in code: palette colours, type variations (`NoteItem`, `FlatButton`, `AccentButton`, `CardPanel`, `H1Label`…) |
| `layer_engine.gd` | Markdown → Read/Outline views, fence handling, link rendering, the objective chip under a quiz or deck with an `objective:` line |
| `note_scene3d.gd` | every ```` ```3d ```` card: presets, objects, quiz, flashcards, input |
| `vault_store.gd` / `vault_registry.gd` | notes on disk (`.tres` ContentLayer), folders, vault switching, recent vaults (`user://vaults.json`) |
| `progress_store.gd` | per-vault quiz progress → ✓ / ● marks |
| `journey_store.gd` / `journey_panel.gd` | Learning Journey data and tab UI. `journey.json` format, sanitizing and file safety: `objectives-protocol.md` (v1) |
| `icons.gd` | code-drawn icons |
| `tag_ops.gd` | `TagOps`: the one tag normalization (`normalize`: lowercase, no `#`, whitespace as `-`) and the tag helpers (`counts`, `sort_by_use`, `has`, `rename`, `color_index`) shared by the tag chips, the TAGS section, the sidebar filter, the importer and the MCP tools (`list_tags`, normalized tag writes). Notes on disk are stored normalized on their next save, never rewritten just for that |
| `wiki_links.gd` | `WikiLinks`: the one `[[link]]` parser and resolver (a whole title, ignoring case; `[[Title#Heading]]` opens Title; nothing in a code span or fence is a link), used by Read view and its LINKED FROM section, link clicks and both graphs. `md_export.gd` still has its own link regex |
| `rename_cascade.gd` | `RenameCascade`: what follows a rename (`VaultStore.rename_note` retitles a note, renames its file and refuses a title another note has; "untitled" may repeat and moves nothing): other notes' `[[links]]`, quiz `learn:` / `next:` lines, Journey and progress keys. The app (`apply`: save_note, stopping at a conflict copy or a failed save) and MCP `update_note` (`run`: each write hash-gated) share it |
| `md_export.gd` | Export as Markdown (top bar, palette, right-click; Export all / folder): front matter + relative links. Writes into a folder marked `.ontomeme-export`, which every vault scan skips (`VaultStore._is_skipped_dir`, given the scanned vault's root), as does an import of a folder that holds one (a vault export carries it); the per-vault folder is saved in `<vault>/.ontomeme/export.json` |
| `starter_content.gd` | first-run vault: `tutorials_content.gd` (the tutorials + starter Journey), `godot_course_content.gd` (Godot folder) and `ontomeme-notes/` imported into a Memetics folder |
| `ui_scale.gd` | interface scale = screen scale (Retina 2×, Windows DPI) × user zoom (Ctrl/Cmd += - 0), saved in `user://display.json` |
| `note_importer.gd` | Markdown folder → notes (front matter, topics, objectives); used by `scripts/import_notes.gd`, first run and the app's imports (`VaultStore.import_paths`: Import notes from a folder…, drag and drop), which rename a taken title "<title> (2)" instead of rewriting the note |
| `tests/*_test.gd` | SceneTree test scripts (headless). `tests/seed_*.gd` = seeders |
| `scripts/*.gd` | lint / import / snapshot tools used by the notes skill |

## Running

- All tests: `GODOT=$GODOT tests/run_all.sh` (what CI runs). One test:
  `$GODOT --headless --path . -s res://tests/<name>_test.gd`. Each prints
  `RESULT: ALL PASS (0 failures)` and exits non-zero on failure; the runner
  also fails on any `SCRIPT ERROR` line, a hang, or an engine `ERROR:` line
  the test didn't expect. A test that triggers one on purpose prints
  `EXPECT-ERROR: <fixed substring>` first (see `first_run_test.gd`). The
  text must be what every OS logs: `make_dir_recursive` names the first
  folder it can't create (`'/proc'` on macOS, not the path you passed).
  `first_run_test.gd` checks its own with a `Logger` (`OS.add_logger`).
- `tests/boot_test.gd` is the "app starts" gate: every script compiles and the
  window builds on an empty and a seeded vault. Run it before every commit.
- A test or script that takes args: `… -s res://x.gd -- arg1 --flag`. Read them
  with `OS.get_cmdline_user_args()`.
- The same tests with a display (drop `--headless`, pass an out dir) also save
  screenshots. Look at them: several real bugs were visible only in pixels.
- An exported build: `scripts/smoke_first_run.sh <binary> --linux-sandbox`
  launches it twice as a brand-new user in a throwaway HOME/XDG dir and checks
  the seeded vault (Tutorials 8, Godot 5, Memetics 6 notes, `models/rocket.glb`,
  the starter-seeded marker), `vaults.json`'s `last`, no error lines in the
  output or `godot.log`, and no re-seed on launch 2. On macOS and Windows pass
  the app's own `--docs <Documents> --userdata <user://>` instead; it refuses
  a vault or `vaults.json` that already exists. Update its `COURSES` line when
  a course gains or loses a lesson. `tests/smoke_first_run_test.sh` (not run
  by `run_all.sh`) drives it against a stand-in app, with `work` exported:
  a variable a script `rm -rf`s on exit must be set first, or a caller's
  environment picks the folder.
- What an export packs: `python3 -I scripts/pck_list.py <artifact>` lists the
  PCK (v2 to v4) inside an `.x86_64`, `.exe`, `.pck`, the macOS zip, a Windows
  zip or a Linux tarball. It finds an embedded pack as Godot does: through the
  executable's `pck` section first, then the `<size>GDPC` trailer at the end,
  which a signed `.exe` no longer has (its certificate table comes after).
  `scripts/check_pck_contents.sh <artifact>` fails on dev or methodology files
  (`docs/`, `tests/`, `scripts/`, `media/`, an `AGENTS`, `CLAUDE` or
  `component` note…), on bytes matching
  `.publish/forbidden`, and on a missing `project.binary`, `note.tscn.remap`,
  `mcp/note_guide.md`, lesson or font import. `tests/pck_audit_test.sh` (not run by `run_all.sh`)
  builds its own packs; `PCK_AUDIT_GODOT=$GODOT` adds real Linux and Windows
  exports of HEAD and a signed copy of the `.exe`. A folder Godot should skip
  needs a `.gdignore`, or its `.import` files get packed.

## Lessons (each one cost a debugging round)

- **Headless window = minimum size.** Headless Godot ignores
  `window_set_size`, so the root is the project's minimum (820×520). Any UI
  wider than that pushes the layout off-screen, and synthetic clicks land
  outside the window and fail silently. Test with
  `get_combined_minimum_size().x <= 820` and keep `ScrollContainer`
  horizontal scrolling on `AUTO`, not `DISABLED`.
- **Click with real input events** (`InputEventMouseMotion` then press/release
  `InputEventMouseButton` through `get_root().push_input`). Calling `pressed`
  handlers directly hid "buttons don't respond to the mouse" bugs. Scroll the
  target into view first (`ScrollContainer.ensure_control_visible`). Debug
  with `get_root().gui_get_hovered_control()`, and check it before each
  click so a click that would miss fails the test.
  `tests/first_user_e2e_test.gd` walks a new user from first launch to a
  passed Tutorial 1 quiz and a relaunch that way. A `[[link]]` in a
  RichTextLabel: pushed mouse motion doesn't fire `meta_hover_started`
  (4.7.2 headless), so find the link where `get_cursor_shape(pos)` is
  `CURSOR_POINTING_HAND`, then click it for real.
- **Fonts lack many glyphs** (▾ ▸ ✕ ✓ ●). Draw icons in code (`icons.gd`,
  `ProgressStore.icon`) instead of trusting Unicode.
- **BBCode injection:** escape `[` as `[lb]` before adding BBCode tags, and keep
  code spans out of the emphasis regexes.
- **Fences:** a fence closes only on a line with at least as many backticks.
  The renderer, lint and `JourneyStore.scene_blocks` must all agree, or
  activity indices drift.
- **Tests open a throwaway vault:** `TestVault.open("<name>")`
  (`tests/test_vault.gd`) after setting the store `file_override`s. It wipes
  `user://test-vault-<name>/` and seeds the tutorials and Godot course. A test
  that relies on notes already in the user's vault passes on your machine and
  fails in CI.
- **First run = the default vault (`~/Documents/Ontomeme`) does not exist
  yet.** `VaultStore.open_startup_vault` then seeds it and the app opens Start
  Here: Tutorials. Simulate a brand-new user without touching yours:
  `XDG_CONFIG_HOME=<tmp>/config XDG_DATA_HOME=<tmp>/data` with
  `<tmp>/config/user-dirs.dirs` setting `XDG_DOCUMENTS_DIR`. A vault folder
  that exists but can't be listed or written (macOS refused access to
  Documents, or chmod 000) is never a first run: `open_startup_vault` sets
  `startup_warning` ("can't read your notes folder…", shown in the status
  bar) and falls back to `user://vault`, as it does for a folder it can't
  create. The unreadable folder stays `last` in `user://vaults.json` (the
  fallback only joins the recent list), so each launch tries it again and
  opens it once access is granted. A vault inside a folder that can't be
  listed (how a denied `~/Documents` shows up) looks missing, but it is the
  same can't-read case, never "couldn't create": nothing is created there.
  Once it can be listed, a launch makes and seeds a new default vault there,
  without the notes kept in the fallback: the Mac warning says to move them
  first (`VaultStore._mac` shows it on any OS), and a first run while the
  fallback is still a recent vault says they are still there. When the
  user's vault was already there (Documents Folder turned off, or Don't
  Allow when macOS asks again after an update), the fallback stands in for
  it: `<fallback>/.ontomeme/stand-in.json` names it and hashes the notes the
  fallback held then, and a fallback for a vault `vaults.json` knows isn't
  seeded. A launch that opens that vault again counts the notes written or
  changed in the fallback since, which the vault has no copy of
  (`import_title`'s twin), and says to import them; ↓ Import then opens on
  the fallback (`VaultStore.kept_in_fallback`). Opening the fallback as the
  vault (`open_vault` with remember) deletes `stand-in.json`.
  `first_run_test.gd` covers all three with chmod 000 folders, remembering
  vaults as a real launch does. A last vault hidden that way is still the one a
  launch opens (`VaultStore.startup_path`): `VaultRegistry.startup_vault()`
  alone takes it for gone and picks the default vault.
- **A launch first looks for an earlier build's relative vault.** Before
  `default_vault()` read `user-dirs.dirs` itself, Linux without
  `xdg-user-dir` stored `"last": "Ontomeme/"`: the vault sat in the folder
  the app ran from, the release folder the README's update steps delete.
  The autoload's `_ready` calls `VaultStore.open_launch_vault`:
  `adopt_relative_vaults` finds each relative entry again (the working
  folder, else `<release folder>/Ontomeme` beside the program's folder, or a
  vault of that name opened by hand since) and stores it absolute; one it
  can't find stays and warns at every launch. Then it opens
  `startup_path()`. `program_folder_warning` warns while a known vault sits
  beside `Ontomeme.x86_64` or `.exe` (`tests/relative_vault_test.gd`).
- **Seeding matches by title *and* folder.** The starter courses find their
  notes with `VaultStore.find_note(title, folder)` (Tutorials, Godot, and
  `NoteImporter.scope_to_folder` for Memetics), so "Add the tutorials and
  starter course" never rewrites or moves a user's own "Signals" or
  "Introduction", and writes `models/rocket.glb` only if it's missing.
  `scripts/import_notes.gd` still upserts by title anywhere, as documented.
  `tests/starter_seed_test.gd` holds this.
- **Outside edits are never overwritten.** VaultStore remembers each note
  file's SHA-256 when it loads or saves it; `save_note()` finding other bytes
  on disk keeps them and writes the app's version as "<title> (conflict
  copy)" (`last_conflict_copy`), and the editor opens that copy. A file that
  is gone (renamed or deleted outside; the MCP server's `update_note` renames
  a note's file with its title) is a conflict too: writing the old path again
  would bring a renamed note back under its old title. The copy
  carries its original's vault-relative path (`ContentLayer.conflict_of`);
  `VaultStore.conflict_original` finds the original by it, else by the
  "(conflict copy[ n])" title (a copy renamed away from that is a note of
  its own). While such a copy is open, a bar above the views offers Use
  this version (`take_conflict_copy`, hash-checked like any save), Keep
  “X” and Compare (`line_diff`); both settling buttons trash the copy the
  way Delete does, so Ctrl+Z brings it back. So write
  notes only through `save_note()` (`stamp = false` to keep a chosen
  `modified`); a direct `ResourceSaver.save` leaves a stale hash and the next
  edit becomes a spurious conflict copy. Likewise move and delete files only
  through VaultStore: `move_note`/`move_folder` carry each file's hash, mtime,
  size and failed-save mark to its new path (`_rekey`), and deletes forget them
  (`_forget`), so a note moved away and back isn't a conflict. Rescans keep
  the hash of a file deleted outside (the open note's save must still see
  it gone), so a new note written at a free path (`create_note`, an
  import, `recreate_note`) forgets that path first. A rescan reloads a changed note in
  place and takes its new hash, so it must never do that to text the editor
  holds: `VaultStore.editor_note` (set by `_open_note`) is left alone by
  every `refresh_note_list()` except the watcher's `refresh_note_list(true)`,
  which then reopens it. Until then its change stays pending (`_mtimes`,
  `_sizes` and `_hashed_at` are not updated) and a save keeps the outside
  edit as a conflict copy.
- **A `.tres` from outside the vault can run code when loaded** (an embedded
  GDScript sub-resource, or any script it names), and garbage text makes
  Godot's parser log a `Parse Error`, which fails `run_all.sh`. Imports
  (`VaultStore.import_paths`) load a file only after `_importable_note`
  accepts it, with `CACHE_MODE_IGNORE`; don't add another import path that
  skips that check. A raw copy is no way around it: once a `.tres` sits in a
  folder the vault scans, the next rescan loads it. So an import copies into
  `models/` and `images/` only the file types in `VaultStore.IMPORT_ASSETS`,
  and a root folder that isn't in `ASSET_DIRS` is imported as notes.
- **Saves can fail, and say so.** `save_note()` returns an `Error` and sets
  `VaultStore.last_save_error`; `create_note()` returns null when its file
  can't be written. Check them: the editor shows "Couldn't save …" and
  retries, and a caller that ignores a null note crashes on it. A note whose
  save failed joins note.gd's `_unsaved` (its words stay in the
  ContentLayer) and is retried on `_retry_timer`, every flush, close and
  focus-out, whichever note is open; the status keeps naming it, a vault
  switch waits for it, and VaultStore's rescans, stars and pins don't
  reload it over its words (`_unsaved_paths`). A rename whose save failed
  finishes when a retry saves it (`_finish_rename`: the file takes the
  title's name and `RenameCascade` runs), whichever note is open: when the
  cascade rewrites the open note, the editor's typing joins it first and the
  editor reloads, keeping its caret and a typed title, or its next save
  would write the old `[[link]]` back. Writes are
  atomic (`VaultStore.atomic_save`: a temp file in `.ontomeme/tmp`, then a
  rename; the MCP tools use the same helper, and `atomic_write_text` for
  `.txt` notes and the lock). The temp file is read back before the rename
  (`VaultStore.saved_matches`, a byte compare for text): ResourceSaver
  returns OK for a small note whose bytes failed at close (disk full,
  quota), and that truncated file must never replace the note. The rename keeps what a plain
  write kept: a symlinked note is followed (the link stays, its target gets
  the edit), a read-only file (`chmod 444`) is refused up front, and the
  file's mode carries over. A read-only folder (`chmod 555`) fails the
  rename itself. On Windows Godot's rename deletes the target before the
  move; if the move then fails, the temp file (named
  `<stamp>-<rand>-<uri-encoded note path>`) is kept as the only copy and
  `open_vault` moves it back (`_recover_tmp_files`, never over an existing
  note). Tests act that out with `VaultStore.rename_hook`.
- **Nothing is hard-deleted.** Delete moves a note's file to
  `<vault>/.trash/<its path>` (`VaultStore.trash_note`, the layout and
  "<stem> (deleted <stamp>[ n]).tres" collision naming of the MCP server's
  `delete_note`) and saves a pending edit first, so the trashed file holds the
  last words. A note whose save failed (`_unsaved`) still goes, but its
  file lacks those words: its `_trashed` entry keeps them (`unsaved`, from
  `_note_fields`), the status says so, and a restore puts them back and
  saves again (a failure leaves it in `_unsaved`). That entry is their only
  copy: a vault switch waits for it like for `_unsaved` (`_words_at_risk`),
  a restore whose file left `.trash` writes the note anew from them
  (`VaultStore.recreate_note`, same object, same path), and a restore that
  fails keeps the entry for another try. note.gd keeps the
  `_trashed` stack: Ctrl+Z outside the editor and the palette's "Restore
  last deleted note" (`restore_trash`) put the newest back
  (`restore_from_trash`, beside its old path if a new note took it) and
  open it; there is no confirmation dialog. A trashed note's title is free,
  so a rename may take it, progress and Journey keys and all
  (`ProgressStore._move_keys` and `JourneyStore.rename_note_keys` trade the
  keys: the renamed note never writes over its results or takes over its
  objectives); the restore then names it "<title> (2)"
  (`VaultStore.free_title`) and gives it back the results `trash_note`
  copied and the demos and scores it noted (`note_trashed` / `note_restored`
  in both stores; the Journey finds them by demo id and log entry, wherever
  a trade put them). However a note takes the title (a rename, Ctrl+N's
  untitled note named so, which no trade covers, a created or imported note,
  another restore, a note written outside the app), `JourneyStore.title_taken`
  (called by `VaultStore.create_note`, `rename_note`, `_import_tres` and
  `note_restored`) first moves the trashed note's demos and scores to a title
  no note has, so its objectives never log the new holder's scores. The MCP
  server is another process and knows nothing of the app's trash
  (`_in_trash` lives in the app's memory): `refresh_note_list` hands
  `JourneyStore.notes_listed` what each path's title was, and a note listed
  with a trashed note's title it didn't have takes it the same way, but only
  while that note's file is still in `.trash` (one moved back by hand is
  that note, and keeps its objectives). A text field holding the keyboard lets go after a
  delete (`_let_go_of_keyboard`: a note's, and a folder's that kept unsaved
  words), or it would take that Ctrl+Z as its own undo: a right-click moves
  no focus, so the context menu's "Delete note" and its folder "Move to
  trash…" (confirm dialog included) left it in the editor. `delete_folder` moves the
  folder to `.trash/<rel>`. The sidebar's Trash (`_show_trash_panel`) lists
  `VaultStore.trash_entries` and restores either kind; `.trash/.deleted.json`
  records dates and which folders are one entry. It saves a pending edit first, changes
  nothing when the folder can't be moved, and gives each of its notes in
  `_unsaved` a `_trashed` entry (`folder`) at a free trash path
  (`VaultStore.trash_slot`), which a restore writes again from its words. Scans and `disk_signature` skip dot
  folders, so `.trash` never shows in the sidebar.
- **Two undos, never both at once.** Inside the editor Ctrl+Z / Ctrl+Y are
  the TextEdit's own undo. Outside it (and the palette's Undo/Redo) they run
  the app's history, `UndoRedoEngine`: note.gd pushes a snapshot (the text
  as last saved) before saving each edit; `undo()`/`redo()` write the
  snapshot's text into the note *and its file* (`last_save_result`) and
  note.gd re-renders the view. A snapshot holds the note object, never a
  path or title: renames and moves keep the object (`take_over_path`), and
  `restore_from_trash` hands back the object that went into the trash, so
  the history follows the note; a snapshot applies only while its note is
  in `note_list`, so it never lands on another note with the same title, a
  new note at a path its note left, or another vault (`switch_vault` also
  clears the history). A step also records the text it left
  (`push_snapshot(note, new_text)`) and applies only while the note still
  holds it, so text from outside (the watcher's reload, a save that became
  a conflict copy) is never undone over; a Ctrl+Z whose flush meets an
  outside edit only opens the conflict copy (`_flush_pending_save()`
  returns true). A step that wouldn't change the text is skipped. A
  deleted note is stamped with `UndoRedoEngine.tick()`, so Ctrl+Z undoes
  whichever came last (restore or edit; `next_undo_at`).
- **An autosave touches one row, never the whole vault.** In a 1000-note
  vault a rescan or a sidebar rebuild is a visible typing hitch, so
  `save_note()` on a note already in `note_list` only moves it to its new
  place there (`_resort`, with `_sort_by_modified`); creating, moving,
  deleting and a save that had to make its folder again still rescan.
  note.gd's autosave then updates that note's row alone (`_show_saved_row`
  → `_update_note_row`: text, status icon, its place among its folder's
  rows) while its title, folder and tags are what the list was built with
  (`_listed_key`); a rename, a tag change or a shown search rebuilds it. So
  anything a row or the TAGS section shows about the open note must either
  be updated there too or change `_row_key`. `ProgressStore` keeps the
  missed questions by title and `quiz_count` by text between calls (the
  sidebar asks each row), dropped on `record_*`, `reset` and `invalidate`;
  rows use `note_status(note)`, which skips the title lookup.
  The watcher must not undo that a tick later: a save changes its file's
  line in `disk_signature()` (`<rel> <mtime> <size>`, plus the file's
  SHA-256 while it is within `FRESH_SECS` of its mtime), so
  `check_disk_changes` asks `VaultStore.changed_outside(old, new)` and
  rescans only when a folder or file came or went, or a line's mtime or
  size isn't the one `_mtimes`/`_sizes` hold, or its hash isn't `_hashes`'
  (the app loaded or wrote it); its own saves just move `_last_sig` on, and the
  status keeps "Saved". `tests/scale_test.gd` holds it to that with
  `VaultStore.refresh_count` and note.gd's `refresh_count`, through the
  watcher's next tick.
- **Close and focus-out flush the autosave.** note.gd saves a pending title
  and body on `NOTIFICATION_WM_CLOSE_REQUEST` and
  `NOTIFICATION_APPLICATION_FOCUS_OUT`. Only a title the user typed is
  committed: the field is compared with `_title_shown` (what the app put
  there), never with the note, which a rescan may have renamed from disk,
  and the watcher refreshes an untouched field after an outside rename.
  In a SceneTree test send them with
  `get_root().propagate_notification(Node.NOTIFICATION_…)` (SceneTree itself
  lacks the WM constants). A close that leaves words at risk
  (`_words_at_risk`) turns `auto_accept_quit` off and asks Quit anyway /
  Keep open (`_hold_close_if_at_risk`). `propagate_notification` also
  reaches the app's dialogs, which cancel themselves on a close request,
  while the engine skips child Windows: send it that way to see a dialog
  stay (`held_words_test.gd`).
- **One window per vault.** The window holds `<vault>/.ontomeme/app.lock`
  (JSON pid, instance, started, heartbeat; `VaultLock.hold_vault_lock`,
  written atomically), refreshes it every 10 s (`_lock_timer` →
  `refresh_vault_lock`) and removes it in `_exit_tree`, which a quit runs
  too. Opening or switching to a vault whose lock another live window holds
  (`vault_lock_holder`: another instance, a live pid, a heartbeat under
  30 s) asks Quit (Cancel for a switch) or Open anyway; a stale lock is
  taken over silently. `OS.is_process_running` only knows the app's own
  child processes (and logs an ERROR for any other pid), so
  `VaultLock.process_alive` reads `/proc`, asks `tasklist` or `kill -0`.
  `VaultLock` is `vault_lock.gd`, preloaded by note.gd only: it runs a
  program, and no script the MCP server loads may (`mcp_boot_test`).
  Read what `OS.execute` collected as text (`"".join(out)`), never
  `str(out)`, which quotes and escapes each line: tasklist's `"1234"` then
  never matched and every lock looked stale on Windows
  (`tasklist_lists`, tested on Linux with a canned CSV row; CI never runs
  Windows). The MCP server never reads or writes the lock (`_serving_mcp`). Every
  test that builds the window writes a lock in its throwaway vault; a test
  that wants the question writes a lock with another `instance`
  (`tests/instance_lock_test.gd`).
- **The VaultStore autoload opens the startup vault only if none is open.**
  Before that guard existed, its `_ready()` silently replaced a vault a test had
  opened in `_init`, so UI tests ran against the user's real vault.
- **A test that awaits before opening its vault gets the real one.** The
  autoload becomes ready at the test's first `await` and, with no vault open
  yet, opens the startup vault: `~/Documents/Ontomeme`, seeded and remembered
  in `user://vaults.json` on a fresh machine. Call `TestVault.hold()` first
  thing in `_init` (it opens an empty `user://test-vault-hold/`), then await.
  `tests/run_all.sh` gives each run a temp XDG home (its own `user://` and
  Documents folder, so parallel runs in other worktrees don't wipe each
  other's `user://test-vault-*`) and fails the first test that creates the
  default vault. It asks the app where that is
  (`tests/print_default_vault.gd`): with no `xdg-user-dir` on PATH, Godot
  finds no Documents folder (it says `""`), so `default_vault()` reads
  `user-dirs.dirs` itself, else `~/Documents`. A relative `Ontomeme/` would
  sit beside the executable, and an update extracted to a new folder would
  start an empty vault (`tests/vault_registry_test.gd`).
  `RUN_ALL_NO_SANDBOX=1` skips the sandbox on macOS and Windows, where XDG
  doesn't apply; `hold()` still guards them.
- **Tests must never touch the user's data:** set
  `ProgressStore.file_override` / `JourneyStore.file_override` to `user://test_*.json`,
  and `VaultStore.open_vault(tmp_dir, false)` (`false` = don't remember it in
  the recent-vaults list). Restore `user://vaults.json` if a test switches vaults.
- **`.tres` timestamps are per second**, and the sidebar sorts by `modified`.
  Seeders space notes a second apart to control order.
- **mtime resolution is ~1 s:** wait over a second before an external edit
  in watcher tests. The watcher itself still sees a second write in the same
  second at the same size (Claude's create_note then update_note): it
  compares a fresh file's bytes (`_unsettled`, `tests/watch_test.gd`).
- **Disk mirroring:** the app polls a cheap signature of the vault tree every
  1.5 s and on window focus. It skips the poll while an autosave is pending
  or the open note's save failed, so it doesn't fight the editor; another
  note waiting to be saved doesn't hold it. A changed signature rescans
  only for what another program did (`VaultStore.changed_outside`), never
  for the app's own saves. Don't absorb a save by setting `_last_sig =
  disk_signature()` after it: the poll is skipped while the user types, so
  that would swallow what another program wrote to other notes meanwhile.
  The app's own vault changes (a new note or folder, a move, a rename, a
  delete) call `_take_own_change(held)` instead, which leaves `_last_sig`
  alone while the editor's note has an outside edit their rescan kept
  pending (`VaultStore.change_pending`), so the watcher still shows it.
  The same poll (even while typing) re-reads `progress.json` /
  `journey.json` when their SHA-256 changed (`reload_if_changed()`; the MCP
  server's renames move their keys), and the stores' writes call it first.
  Journey panel editors hold the store's dictionaries, so a reload must be
  followed by `journey_panel.refresh()`.
- **Shortcuts: test `_cmd(k)` (Ctrl or Cmd), never `ctrl_pressed` alone.**
  Mac users press Cmd; a Ctrl-only check made every shortcut dead on macOS.
- **Headless skips UiScale** (no screen); note.gd still sets the window's
  minimum size there, because a headless window *is* its minimum size and
  without it the root shrinks to 64×64 and every synthetic click misses.
- **Static typing:** `Array.any()` on `PackedStringArray` and `clip_text` on
  `LinkButton` don't exist. Run `--check-only --script res://file.gd` on every
  changed script before running tests.
- **Shared checkout:** other agents may commit in the same repo. Commit
  only your own paths, with an explicit pathspec, `pull --rebase` before
  push, and check `git ls-remote origin HEAD` afterwards.
- `.godot/` (editor cache) churns on every run. Don't commit it.
