# Designing lessons that teach

What made the built-in tutorial series (`Tutorials/` in the default vault,
seeded by `tests/seed_tutorials.gd`) work. Follow these unless the user asks
otherwise.

## The arc: incremental and additive

People grasp things in small steps that build on each other. Each lesson
adds **one** new idea, and every lesson uses the ideas before it.
The original series, as a model:

1. Writing notes: headings, paragraphs, lists, bold/italic/code
2. Linking notes: `[[links]]`, link text, links that create notes
3. First 3D scene: an empty ```` ```3d ```` block, then `preset:`, `caption:`
4. Shapes and colours: `cube: red`, then `at`, `size`, `spin`, `label`
5. Making a quiz: text questions first, then questions whose answers are shapes
6. Importing 3D models: `model:` lines, models as quiz answers
7. Learning objectives: Journey, goals, demonstrations, flashcards, `objective:`

A hub note ("Start Here: …") lists the lessons in order with one line each,
says how long and how many there are, and says what you'll be able to do at
the end. Every lesson ends with `Next: [[…]]` and links back to the hub at
the very end.

## Inside a lesson

- **Open with why** in one or two sentences, then the new idea.
- **Show, then reveal the markup.** Put the live result first (a working
  3D block, a real link), then the markup that produced it in a
  four-backtick literal block. Readers can also press Ctrl+1 to see the source.
- **One heading per sub-step.** Keep paragraphs to three lines or fewer.
  Bullets beat prose for lists of options.
- **Remind about the two views** (Edit Ctrl+1 / Read Ctrl+3) early in a
  series. Beginners forget.
- **Plain words.** "Symbols" before "markup". Name a thing once, then use
  that name consistently.
- **Invite doing:** "Try it: change `red` to `blue`…". One small task per
  section at most.

## Quizzes that teach

- End every lesson with "## Check yourself" and a 3–5 question quiz. The
  caption reads `<topic> · N questions`.
- Every question gets `why:` (the reason, in one line) and `learn:` (the
  note that explains it). A miss then sends the reader straight back.
- Test the idea, not trivia: "Which line makes a blue sphere?" with answer
  choices that are near-misses of real syntax (`blue: sphere`, `[[sphere blue]]`).
- Use **shape answers** when the topic is visual ("Click the cone",
  "Which shape is perfectly round?"). Use `show:` to put a prop beside
  text answers ("What colour is this?" `show: green cube`).
- Wrong answers should be plausible. Avoid "all of the above" and joke answers.
- Mix earlier lessons' ideas into later quizzes (spaced review), with
  `learn:` pointing at the earlier lesson.

## Flashcards and objectives

- Use flashcards for recall (facts, vocab, mixing rules). Use quizzes for
  recognition and applying an idea. 5–10 cards per deck.
- Card fronts are questions or prompts ending in "…"; backs are short.
- Objectives start with a verb and are checkable: "Name the three primary
  colours", not "Learn colours". 3–6 per topic.
- Goal choice: `fluent` for foundations the rest builds on, `learning` for
  everything else. `forget` is the reader's choice, not the author's.
- Give every objective at least one demonstration: put `objective:` on the
  quiz or deck, and define the objective in the hub's front matter.

## Visual taste

- 3–6 shapes per scene. Primary colours for beginner content. `spin` on
  one or two objects, not all of them.
- Captions are short labels ("Primary shapes"), not sentences.
- Default `height` (340) suits most blocks. Use 420+ only for scenes people
  should explore.
