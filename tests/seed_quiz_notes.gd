extends SceneTree
## Seeds the "Godot Fundamentals" course (godot_course_content.gd) plus a quiz
## about the app itself into the vault (idempotent).
##   godot --headless --path . -s res://tests/seed_quiz_notes.gd

const GodotCourse = preload("res://godot_course_content.gd")

const DEV_NOTES: Dictionary = {
"Quiz: Ontomeme": """# Quiz: Ontomeme

How well do you know this app? Wrong answers link straight back to the note that covers them.

```3d
preset: quiz
caption: Ontomeme basics · 4 questions
color: #6c8cff
height: 440
q: What turns into a live 3D scene in Read view?
a: A line starting with #3d
a*: A fenced block tagged 3d
a: An image link ending in .glb
a: Any [[wikilink]]
why: Write ```3d … ``` and switch to Read (Ctrl+3).
learn: 3D Scenes
q: How do you zoom a 3D card without scrolling away from it?
a: Plain mouse wheel
a: Right-click and drag
a*: Ctrl + mouse wheel
a: Double-click
why: Plain wheel keeps scrolling the note; Ctrl+wheel zooms.
learn: 3D Scenes
q: Which shortcut creates a new note?
a: Ctrl+P
a*: Ctrl+N
a: Ctrl+S
a: Ctrl+3
why: Ctrl+P is the command palette; Ctrl+N makes a note.
learn: Getting Started
q: Which component is Ontomeme's note data model?
a: NoteManager
a: LayerRenderer
a*: ContentLayer
a: SceneTree
why: Each note is a ContentLayer resource saved as .tres.
learn: Architecture
```
""",
}


func _init() -> void:
	await process_frame
	seed_vault()
	quit()


## Write the course and the app quiz into the open vault. Tests call this directly.
static func seed_vault() -> void:
	GodotCourse.seed_vault()
	VaultStore.refresh_note_list()
	for title in DEV_NOTES:
		var idx: int = VaultStore.get_note_index(title)
		var note: ContentLayer = VaultStore.note_list[idx] if idx >= 0 else VaultStore.create_note(title)
		note.raw_text = DEV_NOTES[title]
		note.tags.assign(["quiz"])
		VaultStore.save_note(note)
