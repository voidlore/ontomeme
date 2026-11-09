# Learning-objectives protocol, version 1

How a vault states what its learner wants to know, and records the evidence
that they know it. Three places carry it:

1. `<vault>/.ontomeme/journey.json`: the record. Topics, objectives, the
   activities that demonstrate each objective, and every logged score.
2. Front matter `topic:` / `objective:` lines in source `.md` files: they
   create topics and objectives at import (`import_notes.gd` only).
3. The `objective:` key in a quiz or flashcards block: it links that activity
   to an objective, at import and again when someone finishes it.

Source of truth: `journey_store.gd` (file, sanitizing, scoring),
`note_importer.gd` (front matter), `note_scene3d.gd` (`_report_score`). If
this file and the code disagree, the code wins. Fix this file.

## journey.json (v1)

```json
{
	"version": 1,
	"topics": [
		{
			"id": "19a3f0c2b41a7f",
			"name": "Colour theory",
			"description": "Paint primaries, not light.",
			"objectives": [
				{
					"id": "19a3f0c2b5e0c1",
					"name": "Mix secondary colours",
					"description": "Say what two primaries make orange, green, purple.",
					"goal": "fluent",
					"demos": [
						{"id": "19a3f0c2b61d22", "activity": "Lesson 2: Mixing#quiz0", "output": "percent"}
					],
					"log": [
						{"date": "2026-11-07T10:42:05", "activity": "Lesson 2: Mixing#quiz0",
						 "score": 2, "max": 3, "output": "percent", "value": 67}
					]
				}
			]
		}
	]
}
```

| Entry | Field | Rule (what the app does otherwise) |
|---|---|---|
| file | `version` | integer, first key. The app writes `1`. A file without it (written before v1) has the same shape and reads as v1 |
| file | `topics` | list. Not a list, or the file doesn't parse: the whole file is unreadable (see Safety) |
| topic | `name` | text, required (else the topic is dropped) |
| topic | `id` | non-empty text, unique in the file (missing or repeated: a new one) |
| topic | `description` | text (missing: `""`; not text: `""`) |
| topic | `objectives` | list (missing: `[]`; not a list: the topic is dropped) |
| objective | `name` | text, required (else dropped). Matched case-insensitively by `objective:` lines |
| objective | `id`, `description` | as for a topic |
| objective | `goal` | `fluent`, `learning` or `forget` (anything else: `learning`) |
| objective | `demos`, `log` | lists (missing: `[]`; not a list: the objective is dropped) |
| demo | `activity` | text, required: an activity key (below) |
| demo | `output` | `percent`, `correct` or `pass` (missing: `percent`; anything else: dropped) |
| demo | `id` | as for a topic |
| log entry | `score`, `max`, `value` | numbers, required (else dropped) |
| log entry | `activity` | text, required |
| log entry | `output` | as for a demo |
| log entry | `date` | local time `YYYY-MM-DDTHH:MM:SS` (missing: `""`) |

Every load runs one sanitize pass (`JourneyStore.sanitize`): a broken entry
is dropped and nothing around it, and **keys the app doesn't know are kept**
on every entry and at the top level, so a newer writer's data survives an
older app's save. Name your own keys `x_<writer>` (`x_agent`, `x_hermes`) so
they never collide with a later version's fields.

### Scores

An activity reports `score` of `max` when finished. Each demo's `output`
decides the logged `value`:

| output | value | Shown as | Counts as (0..1) |
|---|---|---|---|
| `percent` | `round(100 * score / max)` | `67%` | `value / 100` |
| `correct` | `score` | `2 / 3 correct` | `score / max` |
| `pass` | `1` if `score >= max * 2/3`, else `0` | `Pass` / `Fail` | `value` |

### Goals

An objective is **met** when it has at least one demo, and the *latest* log
entry for every one of its demos counts as at least:

| goal | needs | meaning |
|---|---|---|
| `fluent` | 0.9 (90%) | know it cold |
| `learning` | `ProgressStore.PASS_RATIO` (2/3, a quiz's pass mark) | working on it |
| `forget` | nothing | not a goal any more: scores still log, nothing to aim for ("Not tracking", never shown as met) |

## Activity keys

`"<note title>#quiz<i>"` or `"<note title>#cards<i>"`. `i` counts that kind
from 0 in note order: `preset: quiz` blocks are quizzes, `preset: flashcards`
(or `cards`) blocks are decks. Blocks inside a literal fence (four backticks
around a three-backtick example) don't count. The title is trimmed; it may
contain `#` (the key splits at the last one). Renaming a note or inserting a
quiz above another re-points the keys, so history logged before then points
at the old ones (the Journey shows them as "(missing)").

A finished activity logs one entry on every objective with a demo whose
`activity` equals its key.

## Importing a vault's journey

"Import notes from a folder…" (and dropping a folder on the window) merges
the folder's `.ontomeme/journey.json` into the open vault's, after reading
it through the same sanitize pass (`JourneyStore.merge_from`). The file
being imported is never written.

- Topics match by name, objectives by name within their topic, both
  case-insensitive. A topic or objective missing here is added with new
  ids, keeping its goal, description and unknown keys.
- Demos join by `activity`. A log entry is added unless the objective
  already has one with the same `date`, `activity` and `score`, so
  importing the same export twice adds nothing.
- A note the import had to rename ("Quiz" → "Quiz (2)", because this vault
  has another "Quiz") takes its demos and log entries along: their keys
  become `"Quiz (2)#quiz0"`.

## Front matter (import only)

```
---
title: Lesson 2: Mixing
topic: Colour theory
objective: Mix secondary colours | fluent | Say what two primaries make orange, green, purple.
objective: Name the primaries | learning
---
```

- `topic:` names the topic the file's objectives go under: an existing one
  with that name (case-insensitive), else a new one. Without it, objectives
  go under "Imported".
- `objective: name | goal | description`, repeatable. `goal` defaults to
  `learning`, and anything outside the three goals reads as `learning`. An
  objective whose name already exists anywhere in the journey is left alone.
- All files' front matter is read before any note is imported, so a hub note
  can define objectives that lessons sorted before it use.
- Front matter is stripped at import; notes never store it.

## The `objective:` block key

```3d
preset: quiz
objective: Mix secondary colours
q: Red and yellow make…
a*: orange
a: green
```

In a quiz or flashcards block, `objective: <name>` names an objective
(case-insensitive, trimmed). `import_notes.gd` adds the block as a `percent`
demo of it at import; the app does the same when the block is finished (if
it isn't a demo yet) and then logs the score. A name that matches no
objective adds no demo (the importer prints a WARN, and the app's status
bar says so when the block is finished).

Read view shows a chip under each such block. For a name the journey has:
"Feeds objective: <name>" with its status icon, and a click opens it in the
Journey tab. For a name it doesn't have: "“<name>” isn't in your Journey
yet — Create". Create (`JourneyStore.create_linked_objective`) adds the
objective with goal `learning` under a topic named after the note's folder
(its last part; "From notes" at the top level), made if missing, and adds
the block as its `percent` demo.

## Safety

- The app writes `journey.json` atomically: into `journey.tmp` beside it,
  then a rename over it. A crash never leaves half a file. If a save removed
  `journey.json` and couldn't rename `journey.tmp` over it, the next load
  puts `journey.tmp` back as `journey.json` first.
- A `journey.json` that doesn't parse, or whose top level isn't
  `{"topics": [...]}`, is copied byte for byte to
  `journey.unreadable-<YYYYMMDD-HHMMSS>.json` beside it before anything
  writes; the app starts an empty journey and says so in the Journey tab and
  the status bar. When the sanitize pass had to drop or replace something,
  the file is copied the same way first, and the app goes on with the rest.
- A `journey.json` the app can't open at all (no read permission, or held
  by a sync tool or antivirus) can't be copied. The app starts an empty
  journey, says so, and saves nothing over the file until the vault is
  opened again and the file reads.
- `progress.json` (quiz answers and best scores, for the ✓ / ● marks) is
  kept and written the same way. It isn't part of this protocol.
- The MCP server's `get_journey` and `get_progress` read both files without
  writing anything (`JourneyStore.read_journey`,
  `ProgressStore.read_progress`): same sanitize pass, no copy kept, no
  `.tmp` put back. `get_journey` returns this shape plus `met` on
  objectives and `done` / `attempts` / `latest` on demos.
- The app reads the file when a vault opens and holds it in memory, so its
  next change replaces an edit made while it runs. Edit `journey.json` with
  the app closed.
