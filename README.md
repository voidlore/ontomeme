# Ontomeme

The multimedia note-taking app for humans and their agents. Notes are stored as text files, and Godot-native text resource files. Designed to optimize AI via MCP toward autodidactic pursuits, self-directed educational goals, and knowledge sharing.
Write plain Markdown, and ```` ```3d ```` blocks which turn into live 3D scenes right inside your notes. Display 3d models and orbit around them. Create a quiz whose answers float in space.

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

## Install

Download Ontomeme from the [Releases](../../releases) page. Pick the file for
your computer:

| Computer | File to download |
|---|---|
| Windows | `Ontomeme-<version>-windows-x86_64.zip` |
| Mac (Apple Silicon or Intel) | `Ontomeme-<version>-macos.zip` |
| Linux | `Ontomeme-<version>-linux-x86_64.tar.gz` |

Ontomeme is free and not yet "signed" with a paid certificate from Apple or
Microsoft. That means your computer will warn you the first time you open it.
This is expected. The steps below show you how to open it anyway. You only
need to do this once.

Your notes are kept in a folder called **Ontomeme** inside your **Documents**
folder.

### Windows

1. Open your **Downloads** folder and find the `.zip` file you downloaded.
2. Right-click it and choose **Extract All…**, then click **Extract**.
3. Open the new folder and double-click **Ontomeme**.
4. A blue box may appear saying *"Windows protected your PC"*. Click
   **More info**, then click **Run anyway**.

Tip: to find Ontomeme easily next time, right-click **Ontomeme** and choose
**Pin to Start**, or move the folder somewhere you like, such as your
Documents folder.

### Mac

1. Open your **Downloads** folder and double-click the `.zip` file. You will
   get an app called **Ontomeme**.
2. Drag **Ontomeme** into your **Applications** folder.
3. Open **Applications**, then **right-click** (or hold **Control** and click)
   **Ontomeme** and choose **Open**. In the box that appears, click **Open**
   again.

If your Mac says *"Ontomeme can't be opened"* or *"Apple could not verify…"*
and there is no **Open** button:

1. Click **Done** (or **OK**) to close the message.
2. Click the **Apple menu** (the apple in the top-left corner of the screen) → **System Settings** → **Privacy & Security**.
3. Scroll down to the **Security** section. Next to the line about
   Ontomeme, click **Open Anyway**.
4. Enter your Mac password if asked, then click **Open Anyway** once more.

After the first time, Ontomeme opens with a normal double-click.

### Linux

1. Extract the download, for example by right-clicking it and choosing
   **Extract Here**, or in a terminal:
   ```
   tar -xzf Ontomeme-*-linux-x86_64.tar.gz
   ```
2. Make sure the app is allowed to run (the download should already allow
   this):
   ```
   chmod +x Ontomeme-*-linux/Ontomeme.x86_64
   ```
3. Double-click **Ontomeme.x86_64**, or run it from a terminal:
   ```
   ./Ontomeme-*-linux/Ontomeme.x86_64
   ```

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
