# Agent guide — Ontomeme (this repo)

Ontomeme is a Godot 4.7 note-taking app: Markdown notes with live ```` ```3d ````
scenes, 3D quizzes, flashcards, real folders, and a Learning Journey tab.

## Writing notes, lessons or courses

Read and follow `skills/ontomeme-notes/SKILL.md` (also linked at
`.claude/skills/` and `.agents/skills/`). In short: write `.md` files, then
run the three tools below and look at the PNGs.

```
$GODOT --headless --path . -s res://scripts/lint_notes.gd   -- <src_dir> --vault=<tmp_vault>
$GODOT --headless --path . -s res://scripts/import_notes.gd -- <src_dir> --vault=<tmp_vault>
$GODOT            --path . -s res://scripts/snapshot_note.gd -- "<Note Title>" <out_dir> --vault=<tmp_vault> --answer
```

## Changing the app

Read `skills/ontomeme-notes/references/app-internals.md` first (file map, test
harness, and the traps that already cost a debugging round).

- Tests: `$GODOT --headless --path . -s res://tests/<name>_test.gd`, one per
  file. All must print `RESULT: ALL PASS`.
- Never point tests at the user's vault, progress or journey files (use the
  `file_override` / `open_vault(tmp, false)` pattern from existing tests).
- Don't commit `.godot/`. Other agents may share this checkout, so commit with
  explicit pathspecs.
