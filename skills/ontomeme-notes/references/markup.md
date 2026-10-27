# Ontomeme note markup — full reference

Source of truth: `layer_engine.gd` (text), `note_scene3d.gd` (3D blocks),
`journey_store.gd` (activities). If this file and the code disagree, the code
wins. Fix this file.

## Text (Read view, Ctrl+3)

| Write | Renders |
|---|---|
| `# Title` / `## Section` / `### Small` | H1 / H2 / H3 (a space after the `#`s is required) |
| `- item` or `* item` | bullet (one level, no nesting) |
| `**bold**`, `*italic*`, `` `code` `` | inline emphasis. Code spans stay literal |
| `[[Note Title]]` | accent link. Click opens the note, or creates it if missing |
| `[[Note Title|shown text]]` | link with custom text |
| ```` ```lang ```` … ```` ``` ```` | code block (any `lang` except `3d` / `scene3d`) |
| ```` ```` ```` … ```` ```` ```` | literal block that can contain ```` ``` ```` lines |
| empty line | paragraph break |

A link shows ✓ if every quiz in the target passed, or ● if the reader missed a
question that points there. Not supported: tables, images, numbered-list
renumbering (write `1.` yourself, it shows as typed), nested lists, HTML.

Views: Edit (Ctrl+1, raw text), Outline (Ctrl+2), Read (Ctrl+3),
Graph (Ctrl+4), Journey (Ctrl+5). Ctrl+P opens the command palette, which can
insert block templates and import models.

## 3D blocks

A fence whose info string starts with `3d` (or `scene3d`). The body is
`key: value` lines. A preset can be the second word of the fence
(```` ```3d galaxy ````) or a `preset:` line. With no preset, the block is
`shapes` if it has object lines and `galaxy` otherwise.

### Keys for every preset

| key | default | meaning |
|---|---|---|
| `preset` | see above | `galaxy knot terrain waves atom graph shapes quiz flashcards` (`cards` = flashcards) |
| `caption` | preset name | text in the card's footer |
| `height` | `340` | card height in px, clamped 180–900 |
| `color` | per preset | accent colour (name or `#rrggbb`) |
| `speed` | `1` | animation speed 0–10 |
| `autorotate` | on (off for quiz/cards) | `on`/`off`: slow camera orbit |

Readers drag to orbit, Ctrl+wheel to zoom, and use **Expand** for full screen.

### Preset-specific keys

- `galaxy`: `arms` (1–12, 4), `stars` (500–60000, 16000)
- `knot`: `p`, `q` (1–9; 2, 3), the torus-knot winding numbers
- `terrain`: `seed` (int, 3)
- `waves`, `atom`: `color` only
- `graph`: the vault's link graph. Double-click a node to open that note
- `shapes`: object lines (below); `labels: on` shows names all the time

### Object lines (`shapes`, and extra objects in any visual preset)

```
<shape>: <colour>, at <x> <z> | at <x> <y> <z>, size <n>, spin [<rate>], label <text>
model: <file>,      at …,                       size <n>, spin [<rate>], label <text>, <colour>
```

- Shapes (with synonyms): `cube`/`box`, `sphere`/`ball`, `cylinder`, `cone`,
  `pyramid`, `torus`/`donut`/`ring`, `capsule`, `prism`/`triangle`.
- Colours: `red blue yellow green orange purple pink cyan white black gray
  grey brown gold`, or `#rrggbb`. Nothing else is recognised.
- Axes: x = left/right, y = up, z = toward the viewer (negative z goes back
  and looks smaller). `at x z` keeps objects on the floor; `at x y z` lifts them.
- Without `at`, objects line up left to right on the floor. `size` is
  0.1–20 (default 1; 2 for models). `spin` alone is rate 1.
- `label` names the object (shown on hover, or always with `labels: on`).
  The default name is "<colour> <shape>".
- Models: `.glb` (best), `.gltf`, `.fbx`. A bare file name resolves to
  `<vault>/models/<file>`. `~/…` and absolute paths also work. A colour
  repaints the model. Embedded animations play automatically. Import from
  the app with Ctrl+P → "Import 3D model…" (copies into `models/`), or put
  files in `<src_dir>/models/` and `import_notes.gd` copies them.

### Quiz (`preset: quiz`)

```
q: Question text                     (or question:)
a: wrong answer
a*: the right answer                 (exactly one; *a: also works)
why: one line shown after answering  (or explain:)
learn: Note Title                    (or review:/see:, [[ ]] optional)
show: red cube | model rocket.glb    (optional prop shown beside text answers)
```

Repeat `q:` groups. Block-level keys: `caption`, `color`, `objective`,
`next` (the "Next: …" button when passed; otherwise the next quiz in the note,
or nothing). Layout: if **every** answer of a question is an object
(`red cube`, `cube red`, `model x.glb`), the answers are 3D shapes on
pedestals to click. Otherwise they're text tiles, and `show:` adds a prop.
Use 2–4 answers. Results pass at ⅔. A missed question marks its `learn:`
note "needs review" (●) and puts a Review button on the results board.

### Flashcards (`preset: flashcards`)

```
q: front of the card
a: back of the card
```

Each `q:` must be followed by its `a:`. A `q:` without one is dropped. The
reader clicks to flip, then grades "I knew it" / "Not yet". The score is the
number known. Block-level keys: `caption`, `color`, `objective`.

### `objective:` (quiz and flashcards)

`objective: <exact objective name>`. When the activity finishes, it's linked as
a demonstration of that objective (if one exists by that name, case-insensitive)
and the score is logged. `import_notes.gd` also links it at import time.

## Journey data (per vault)

`<vault>/.ontomeme/journey.json`: topics → objectives
(`name, description, goal, demos[{activity, output}], log[{date, activity,
score, max, output, value}]`). Activity key: `"<note title>#quiz<i>"` or
`"#cards<i>"`, where i counts that kind in note order, ignoring blocks inside
literal fences. Score outputs: `percent` (default), `correct`, `pass`.
Also in `.ontomeme/`: `progress.json` (quiz answers and passes for ✓/●) and
`ui.json` (collapsed folders). Don't edit these by hand while the app runs.

## Front matter (import_notes.gd only. Stripped, never stored in the note)

```
---
title: Exact Note Title
tags: a, b
topic: Journey Topic Name
objective: Verb-first objective | fluent|learning|forget | description
objective: …another…
---
```
