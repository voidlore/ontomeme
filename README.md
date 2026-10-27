# Ontomeme

**Notes you can step inside.** Ontomeme is a desktop note-taking app for
learning: you write plain Markdown, and a fenced ```` ```3d ```` block turns into
a live 3D scene right inside the note — a model to orbit, a quiz whose answers
float in space, a deck of flashcards.

- **Markdown notes in real folders** — your vault is a directory on disk. Open
  it in any editor, back it up, version it.
- **Live 3D scenes** — procedural presets, or drop in your own `.glb` / `.gltf`
  models.
- **3D quizzes and flashcards** — answer by clicking objects in the scene;
  progress marks show what you've passed and what needs review.
- **Learning Journey** — a tab that strings lessons into a path and tracks how
  far along it you are.
- **`[[links]]` between notes**, with missing targets created on click.
- **Built-in tutorials** that teach the app from inside the app.

Built with [Godot 4](https://godotengine.org): a native desktop app, no browser,
no account, no cloud. Your notes stay on your machine.

## Download

Builds for Windows, macOS (Apple Silicon) and Linux will be on the
[Releases](../../releases) page from v0.1.0.

## Run from source

1. Install [Godot 4.7](https://godotengine.org/download).
2. Clone this repository and open `project.godot` in Godot, or run
   `godot --path .` from the repository root.

## Tests

```
godot --headless --path . -s res://tests/<name>_test.gd
```

Each test prints `RESULT: ALL PASS` on success. See `AGENTS.md` for the tools
used to write and check lesson notes.

## License

MIT — see [LICENSE](LICENSE).
