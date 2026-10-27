---
name: ontomeme-notes
description: Write Ontomeme lesson notes with 3D scenes, quizzes, cards.
version: 0.1.0
author: Joseph Sailor Usher (Joseph-Sailor-Usher), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [ontomeme, godot, notes, tutorials, quizzes, flashcards, learning, 3d]
    related_skills: []
---

# Ontomeme Notes

Ontomeme (this repo; Godot 4.7) is a note app whose notes are Markdown plus
```` ```3d ```` blocks that render as live 3D scenes, clickable 3D quizzes and
flip-card decks, with a Learning Journey tab that logs scores against learning
objectives. This skill is how to **author new notes and whole courses** that
look and teach like the built-in tutorials, and how to prove they work.
You write plain `.md` files; repo scripts lint them, import them into a vault
(folders mirror directories), and screenshot them as a reader sees them.

## When to Use

- "Write a lesson / course / tutorial / quiz / flashcards" for Ontomeme.
- Adding notes to an Ontomeme vault, or turning existing material into one.
- Setting up learning objectives (Journey) for a set of notes.
- Don't use for: changing the app's own code — read
  `references/app-internals.md` first, then work like any Godot project.

## Prerequisites

- A Godot 4.7 binary. Below, `$GODOT` means it (`godot`, `godot4`, or a path).
- Run everything from the repo root (the folder with `project.godot`).
  After pulling new `.gd` files run `$GODOT --headless --path . --import` once.
- Screenshots need a display and GPU (no `--headless`). On Linux over SSH set
  `DISPLAY` (and `XAUTHORITY`) for the desktop session.
- Vault: the app's current vault, or pass `--vault=DIR` to any script below.
  **Use a throwaway vault** (`--vault=/some/new/dir`) until a course is done.

## Quick Reference

```
$GODOT --headless --path . -s res://scripts/lint_notes.gd   -- <src_dir> [--vault=DIR]
$GODOT --headless --path . -s res://scripts/import_notes.gd -- <src_dir> [--vault=DIR] [--dry-run]
$GODOT            --path . -s res://scripts/snapshot_note.gd -- "<Note Title>" <out_dir> [--vault=DIR] [--answer]
$GODOT --path . -- --vault=DIR          # open the app on a vault
```

Lint exits 1 on errors. Import upserts by title (safe to re-run). Snapshot
writes `<slug>_00_top.png` plus one PNG per 3D block; `--answer` also plays
each quiz to its results board and flips each deck's first card.

Cheat sheet (full grammar: `references/markup.md`):

````text
# Heading   ## Section   ### Small        - list item
**bold**  *italic*  `code`  [[Other Note]]  [[Other Note|shown text]]

```3d                          ```3d                         ```3d
cube: red, at -1 0, spin       preset: quiz                  preset: flashcards
sphere: blue, size 1.5         caption: Shapes · 2 questions caption: Colour mixing
model: rocket.glb, spin 0.4    objective: Name shapes        objective: Mix colours
caption: My shapes             q: Click the cube.            q: Red + yellow make…
labels: on                     a: blue sphere                a: Orange
```                            a*: red cube                  ```
                               why: A cube has six faces.
                               learn: Lesson 2: Shapes
                               next: Lesson 3: Colour
                               ```
````

## Procedure

1. **Plan the arc before writing.** List the lessons; give each exactly one new
   idea that builds on the previous one (see `references/teaching-design.md`).
   Name the learning objectives: one verb-first, checkable sentence each.
   Done when every lesson has one new idea and maps to one objective or more.
2. **Lay out a source directory** that mirrors the vault you want:
   `course/<Folder>/NN_<name>.md` (the `NN_` prefix sets sidebar order),
   models in `course/models/`. Start from
   `templates/sample-course/` (copy it, then rename and rewrite).
   Front matter per file: `title:` (exact note title, used by links),
   `tags:`, and on the hub note `topic:` + one `objective: name | goal | description`
   line per objective (goal = `fluent`, `learning` or `forget`).
   Done when every `[[link]]`, `learn:` and `next:` names a `title:` that exists.
3. **Write each lesson**: a short intro, one heading per sub-step, a live
   example of the idea (a 3D scene, a `show:` prop, a real link), then a
   "Check yourself" quiz (3–5 questions, each with `why:` and `learn:`), then
   a closing `Next: [[...]]` line. Only if the course teaches Ontomeme itself:
   after each live example, show its markup in a four-backtick literal block.
   State any assumption the subject needs (e.g. paint vs light primaries).
   Done when each lesson ends in a quiz or deck that has `objective:`.
4. **Lint until clean**: `lint_notes.gd -- course --vault=<throwaway>`.
   Done when it reports `0 errors`; read each WARN and fix or accept it.
5. **Import** into the throwaway vault: `import_notes.gd -- course --vault=<throwaway>`.
   Done when it prints `create`/`update` for every file, `goal` for each new
   objective and `demo … → <objective>` for each quiz/deck with `objective:`.
6. **Look at it**: run `snapshot_note.gd -- "<title>" out --vault=<throwaway> --answer`
   for every lesson and open the PNGs (vision). Check: text not clipped in 3D
   tiles, shapes visible and the right colour, results board reached, no
   "Add questions to this block" placeholder. Snapshots capture each quiz's
   **first question** and its results board only. If a later question has
   shape answers you need to see, temporarily move it to the top.
   Expected in snapshots: the status bar says "add it as a demonstration…"
   even for linked quizzes, because snapshot runs use a throwaway Journey file
   and never record real scores. A quiz tile's bottom edge is unlit, so it can
   look cut off. Check that it's ~36 px tall before reporting clipping.
   Done when every 3D block's PNG shows the intended scene.
7. **Deliver**: import into the real vault (drop `--vault`, or the user's
   vault path) only when the user asks; re-running updates notes in place.
   Report: notes created, objectives created, lint summary, PNGs inspected.

## Pitfalls

- **Scene lines need a colon** (`model: rocket.glb`, `cube: red`); quiz
  answers drop it (`a*: model rocket.glb`, `a: red cube`). Lint catches
  `model rocket.glb` in a scene.
- **A quiz answer is a 3D object only when every answer is**
  `<colour> <shape>` / `<shape> <colour>` / `model <file>`. Mix in one text
  answer and the whole question renders as text tiles.
- **Questions are dropped silently** in the app when they have <2 answers or
  no `a*:`. More than one `a*:` keeps only the last. Lint reports all three.
- **Literal examples need a longer fence.** A ```` ``` ```` inside a ```` ``` ````
  block ends it early. Wrap examples in four backticks. Lint and the Journey ignore
  blocks inside a four-backtick fence, so examples don't count as activities.
- **Activity identity is (note title, kind, index).** Quizzes and decks are
  numbered per note in order (`Note#quiz0`, `Note#cards1`). Renaming a note,
  or inserting a quiz above another, re-points logged history. Fix titles
  before anyone plays, and add new quizzes after existing ones.
- **`objective:` matches by name, case-insensitively.** An objective that
  doesn't exist logs nothing. Define it in front matter (step 2).
- **Colours:** only the 14 names in `references/markup.md` or `#rrggbb`.
  Godot names like `lime` and `navy` are ignored without an error (lint warns).
- **Pass marks:** a quiz passes at ⅔; Journey goals are Fluent ≥ 90% and
  Learning ≥ ⅔ on the latest attempt of every demonstration.
- **Don't hand-write `.tres` note files.** Strings need Godot escaping, and
  file names, folders and timestamps are managed by `VaultStore`. Import `.md`.
- **Sidebar order = file-name order** after import (the importer timestamps
  notes so the first file is on top). Prefix files `00_`, `01_`… and set the
  real title in front matter. Editing a note in the app moves it to the top.
- **Scene depth:** the camera looks down −z from the front. `at x z` with a
  non-zero `z` moves objects back (smaller) or forward (bigger). Keep
  comparison rows at the same `z`, and use `at x y z` to stack rows vertically.
- `[[Link]]` to a missing note isn't broken: clicking it creates the note.
  Lint only warns.

## Verification

- `lint_notes.gd` prints `0 errors` for the source dir.
- `import_notes.gd` lists every file. Re-running shows `update` and creates no
  duplicates (count `*.tres` in the vault: same number).
- `snapshot_note.gd --answer` exits 0 for every lesson, and you looked at
  each PNG (quiz `_results` shows a score, deck `_flipped` shows the answer).
- The Journey (Ctrl+5 in the app, on the throwaway vault) shows the topic,
  its objectives, and one demonstration per quiz/deck that had `objective:`.
- Self-check: `templates/sample-course/` must lint with 0 errors and import
  2 objectives and 3 demos into an empty vault. If it doesn't, the scripts or
  this skill are out of date with the code.
