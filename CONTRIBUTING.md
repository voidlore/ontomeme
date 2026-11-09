# Contributing to Ontomeme

Thank you for helping. Bug reports, fixes, tutorials and new features are
all welcome. This page shows how to run Ontomeme from source, how to test a
change, and what a pull request needs.

## Reporting a bug

[Open a bug report](../../issues/new/choose). The form asks what happened,
how to make it happen again, the line that **About Ontomeme → Copy
diagnostics** copies, and the log file. You don't need to know any code to
send one.

## What you need

- **Godot 4.7.2**, the same version the automatic tests use. Download it
  from the [Godot 4.7.2 release](https://github.com/godotengine/godot/releases/tag/4.7.2-stable)
  page; you don't need the export templates.
- A shell that runs Bash scripts: the Terminal on Linux and macOS, and
  **Git Bash** (it comes with Git for Windows) on Windows.
- Tell the scripts where Godot is with the `GODOT` variable:

  | Computer | Example |
  |---|---|
  | Linux | `GODOT=~/bin/Godot_v4.7.2-stable_linux.x86_64` |
  | macOS | `GODOT=/Applications/Godot.app/Contents/MacOS/Godot` |
  | Windows (Git Bash) | `GODOT=/c/Godot/Godot_v4.7.2-stable_win64_console.exe` |

  On Windows use the `_console.exe` build, so the test output shows up in
  Git Bash.

## Running it from source

```
$GODOT --path .                            # the app, on your usual notes
$GODOT --path . -- --vault=/tmp/try-notes  # the app, on a scratch folder
```

or open `project.godot` in the Godot editor. A `--vault=` folder is created
if it is missing and isn't added to the app's list of recent vaults.

## Tests

Run the whole suite from the repository root. On Linux:

```
GODOT=/path/to/godot tests/run_all.sh
```

On macOS and on Windows (Git Bash), always add `RUN_ALL_NO_SANDBOX=1`:

```
RUN_ALL_NO_SANDBOX=1 GODOT=/path/to/godot tests/run_all.sh
```

On Linux, `run_all.sh` gives the run its own temporary home folders, so
everything the tests write is thrown away afterwards, and a test that would
create the real `Documents/Ontomeme` folder fails. macOS and Windows ignore
those folders, so without `RUN_ALL_NO_SANDBOX=1` the runner looks at your
real `Documents/Ontomeme` and, if it is there, stops before the first test.
Don't delete that folder to get past it: it holds your notes. With the
setting, the tests' own throwaway vaults, below, keep them away from your
notes.

It runs every `tests/*_test.gd` headless, one at a time. Each file prints
`RESULT: ALL PASS` when it passes, and the run ends with `ALL TESTS PASS`.
Keep going until it does. A test fails when it exits non-zero, logs a
script error, hangs past the time limit (240 seconds; pass another number as
the first argument), or logs an engine `ERROR:` line it didn't announce. A
test that means to trigger one prints `EXPECT-ERROR: <part of the message>`
first. The runner needs no GNU `timeout`, so a stock Mac has all it needs.

One test at a time:

```
$GODOT --headless --path . -s res://tests/<name>_test.gd
```

Before every commit, run `tests/boot_test.gd` this way: it checks that every
script compiles and the window builds on an empty and on a seeded vault.
After changing a script, `$GODOT --headless --path . --check-only --script res://<file>.gd`
catches typing mistakes before the tests do.

### Tests never touch your own notes

A test works on throwaway copies, never on your `Documents/Ontomeme`, your
quiz progress or your Learning Journey:

- First point `ProgressStore.file_override` and
  `JourneyStore.file_override` at `user://test_<name>.json` files, and clear
  them again at the end.
- Then, before the test's first `await`, `TestVault.open("<name>")` (in
  `tests/test_vault.gd`) wipes and opens `user://test-vault-<name>/`, seeded
  with the tutorials and the Godot course. While a test waits, the app opens
  its startup vault, your real one, unless a vault is already open. A test
  that has to wait before opening its vault calls `TestVault.hold()` first
  thing in `_init`.
- For a folder of your own, `VaultStore.open_vault(tmp, false)`: `false`
  keeps it out of the recent-vaults list.

`tests/diagnostics_test.gd` follows this pattern from start to end. A test
that relies on notes you happen to have passes on your computer and fails
for everyone else.

## Commits and pull requests

- Keep a pull request to one change, and add or update a
  `tests/*_test.gd` that shows it working.
- Commit only the files you changed, by name (`git add path/to/file`), not
  everything at once.
- Never commit `.godot/` (Godot's cache, which changes on every run) or
  build output.
- For a change you can see, add a screenshot to the pull request.
- The automatic tests (`.github/workflows/test.yml`) run the headless suite
  on every push to `main` and on every pull request. For a first-time
  contributor, the run waits until a maintainer approves it.

## Licence

Ontomeme's code is under the MIT [LICENSE](LICENSE); the fonts in `fonts/`
are under the SIL Open Font License ([fonts/OFL.txt](fonts/OFL.txt)); there
are no other third-party dependencies, and a PR that adds one adds its
licence next to it. By opening a pull request you agree that your
contribution is under the MIT LICENSE too.

## Releases

Maintainers cut releases by pushing a tag; the release workflow builds the
Windows, macOS and Linux downloads and puts them on the
[Releases](../../releases) page.

- Every `v*` tag is an annotated tag whose message carries a few bullets
  of user-visible changes. Those bullets are the release notes.
- `vX.Y.Z-rcN` (`-rc1`, `-rc2`, ...) is a release candidate and is published
  as a GitHub pre-release.
- The final `vX.Y.Z` has no suffix.
- The tag's version matches `config/version` in `project.godot`.
- A CHANGELOG.md comes only when the notes outgrow the tags.
