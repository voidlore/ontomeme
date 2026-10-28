# Ontomeme internals and lessons learned (for agents changing the app)

## Map

| File | Owns |
|---|---|
| `note.tscn` / `note.gd` | main window: sidebar (folders, vault switcher, drag/drop, context menu), toolbar modes, palette (Ctrl+P), disk watcher, Journey wiring |
| `app_theme.gd` | the whole Theme in code: palette colours, type variations (`NoteItem`, `FlatButton`, `AccentButton`, `CardPanel`, `H1Label`…) |
| `layer_engine.gd` | Markdown → Read/Outline views, fence handling, link rendering |
| `note_scene3d.gd` | every ```` ```3d ```` card: presets, objects, quiz, flashcards, input |
| `vault_store.gd` / `vault_registry.gd` | notes on disk (`.tres` ContentLayer), folders, vault switching, recent vaults (`user://vaults.json`) |
| `progress_store.gd` | per-vault quiz progress → ✓ / ● marks |
| `journey_store.gd` / `journey_panel.gd` | Learning Journey data and tab UI |
| `icons.gd` | code-drawn icons |
| `starter_content.gd` | first-run vault: `tutorials_content.gd` (the tutorials + starter Journey), `godot_course_content.gd` (Godot folder) and `ontomeme-notes/` imported into a Memetics folder |
| `ui_scale.gd` | interface scale = screen scale (Retina 2×, Windows DPI) × user zoom (Ctrl/Cmd += - 0), saved in `user://display.json` |
| `note_importer.gd` | Markdown folder → notes (front matter, topics, objectives); used by `scripts/import_notes.gd` and first run |
| `tests/*_test.gd` | SceneTree test scripts (headless). `tests/seed_*.gd` = seeders |
| `scripts/*.gd` | lint / import / snapshot tools used by the notes skill |

## Running

- All tests: `GODOT=$GODOT tests/run_all.sh` (what CI runs). One test:
  `$GODOT --headless --path . -s res://tests/<name>_test.gd`. Each prints
  `RESULT: ALL PASS (0 failures)` and exits non-zero on failure; the runner
  also fails on any `SCRIPT ERROR` line or a hang.
- `tests/boot_test.gd` is the "app starts" gate: every script compiles and the
  window builds on an empty and a seeded vault. Run it before every commit.
- A test or script that takes args: `… -s res://x.gd -- arg1 --flag`. Read them
  with `OS.get_cmdline_user_args()`.
- The same tests with a display (drop `--headless`, pass an out dir) also save
  screenshots. Look at them: several real bugs were visible only in pixels.

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
  with `get_root().gui_get_hovered_control()`.
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
  `<tmp>/config/user-dirs.dirs` setting `XDG_DOCUMENTS_DIR`.
- **Outside edits are never overwritten.** VaultStore remembers each note
  file's SHA-256 when it loads or saves it; `save_note()` finding other bytes
  on disk keeps them and writes the app's version as "<title> (conflict
  copy)" (`last_conflict_copy`), and the editor opens that copy. So write
  notes only through `save_note()` (`stamp = false` to keep a chosen
  `modified`); a direct `ResourceSaver.save` leaves a stale hash and the next
  edit becomes a spurious conflict copy.
- **The VaultStore autoload opens the startup vault only if none is open.**
  Before that guard existed, its `_ready()` silently replaced a vault a test had
  opened in `_init`, so UI tests ran against the user's real vault.
- **Tests must never touch the user's data:** set
  `ProgressStore.file_override` / `JourneyStore.file_override` to `user://test_*.json`,
  and `VaultStore.open_vault(tmp_dir, false)` (`false` = don't remember it in
  the recent-vaults list). Restore `user://vaults.json` if a test switches vaults.
- **`.tres` timestamps are per second**, and the sidebar sorts by `modified`.
  Seeders space notes a second apart to control order.
- **mtime resolution is ~1 s:** wait over a second before an external edit
  in watcher tests.
- **Disk mirroring:** the app polls a cheap signature of the vault tree every
  1.5 s and on window focus. It skips the poll while an autosave is pending,
  so it doesn't fight the editor.
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
