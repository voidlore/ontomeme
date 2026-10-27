extends SceneTree
## Seeds the "Godot Fundamentals" course + quiz notes into the vault (idempotent).
##   godot --headless --path . -s res://tests/seed_quiz_notes.gd

const NOTES: Dictionary = {
"Nodes and Scenes": """# Nodes and Scenes

Everything in Godot is a **node**: a Sprite2D draws, a Camera3D looks, a Timer counts, a Button clicks. Nodes are arranged in a tree — every node has one parent and any number of children — and the whole running game is one big tree, the **SceneTree**.

## Scenes are saved node trees
A **scene** is a tree of nodes saved as a reusable resource (a .tscn file). A player, a door, a menu or this whole app window are each scenes. Scenes nest: a Level scene contains Player and Enemy scenes as children.

## Instancing
Design an Enemy scene once, then **instance** it as many times as you like. Each instance is an independent copy; change the original scene and every instance updates.

```gdscript
var enemy_scene: PackedScene = preload("res://enemy.tscn")
func spawn(at: Vector2) -> void:
	var enemy := enemy_scene.instantiate()
	enemy.position = at
	add_child(enemy)
```

## Worlds inside worlds
A **SubViewport** renders its own world into a texture, and a SubViewportContainer shows that texture inside a 2D UI. That is exactly how the live cards in [[3D Scenes]] work.

Next: how nodes talk to each other — [[Signals]].
""",

"Signals": """# Signals

A **signal** is a message a node emits when something happens: a Button emits pressed, a Timer emits timeout, an Area2D emits body_entered. Other nodes **connect** a function to the signal and get called back. The emitter never needs to know who is listening — that loose coupling is the point.

## Connecting
```gdscript
func _ready() -> void:
	$SaveButton.pressed.connect(_on_save_pressed)

func _on_save_pressed() -> void:
	print("saved")
```
Polling instead (checking is_pressed() every frame) wastes work and misses quick clicks.

## Your own signals
Declare with the signal keyword, fire with emit():
```gdscript
signal health_changed(new_value: int)

func take_damage(amount: int) -> void:
	health -= amount
	health_changed.emit(health)
```

## Check yourself
```3d
preset: quiz
caption: One-question check
q: A Timer finished counting. What does it do so other nodes can react?
a: Calls every node's _process()
a*: Emits its timeout signal
a: Sets a global variable
a: Quits the scene
why: Listeners connect to timeout and get called back.
```

Built on: [[Nodes and Scenes]]. Next: [[Shaders]].
""",

"Shaders": """# Shaders

A **shader** is a small program that runs on the GPU. Godot's spatial (3D) shaders have two main stages:

- **vertex()** runs once per vertex — move, bend or displace geometry.
- **fragment()** runs once per pixel — decide its colour (ALBEDO), glow (EMISSION), roughness and so on.

## Animating with TIME
The built-in **TIME** counts seconds since the engine started. Feed it into sin() and things move with zero CPU work:
```glsl
shader_type spatial;
void vertex() {
	VERTEX.y += sin(VERTEX.x * 2.0 + TIME) * 0.2;
}
void fragment() {
	ALBEDO = vec3(0.85, 0.47, 0.34);
}
```

## Uniforms
A **uniform** is a parameter set from GDScript with material.set_shader_parameter("speed", 2.0) — one shader, many looks.

## See it live
Every bar below is drawn by one MultiMesh, and one vertex shader sets its height from two interfering sine waves driven by TIME:
```3d
preset: waves
height: 280
caption: One vertex shader, 1,936 bars
```

## Check yourself
```3d
preset: quiz
caption: One-question check
q: Which shader function runs once per pixel?
a: vertex()
a*: fragment()
a: _process()
a: _ready()
why: vertex() shapes geometry; fragment() colours pixels.
```

See also: [[Nodes and Scenes]], [[3D Scenes]].
""",

"Containers and Layout": """# Containers and Layout

Godot UIs are built from **Control** nodes, and **containers** arrange their children automatically — you rarely position anything by hand.

- **HBoxContainer** lays children out left-to-right; **VBoxContainer** top-to-bottom.
- **MarginContainer** adds padding; **PanelContainer** draws a background behind one child.
- **HSplitContainer** puts a draggable divider between two children — this app's sidebar | editor split.
- **ScrollContainer** scrolls a child that is bigger than itself.

## Size flags decide who gets the space
Inside a box container, a child with **SIZE_EXPAND_FILL** takes all the leftover space; children with plain SIZE_FILL keep their minimum size. A fixed-width sidebar next to an editor with SIZE_EXPAND_FILL gives you the classic note-app layout.

## Themes instead of overrides
A **Theme** resource holds colours, fonts and StyleBoxes for every Control type. **Type variations** (e.g. SidebarPanel based on PanelContainer) let one Theme style many kinds of panel. This app builds its whole dark and light look that way, so switching theme is a single assignment.

Related: [[Nodes and Scenes]].
""",

"Quiz: Godot Fundamentals": """# Quiz: Godot Fundamentals

Eight questions on the course notes. Get one wrong and a **Review** tile appears inside the scene — it opens the note that explains the idea. Your results screen lists every note worth revisiting.

The notes: [[Nodes and Scenes]] · [[Signals]] · [[Shaders]] · [[Containers and Layout]]

```3d
preset: quiz
caption: Godot Fundamentals · 8 questions
height: 460
q: In Godot, what is a scene?
a: A single script file
a*: A tree of nodes saved as a reusable resource
a: A level that only loads at startup
a: A folder of imported assets
why: Scenes are node trees you can save, nest and instance.
learn: Nodes and Scenes
q: You designed one Enemy. How do you put fifty in a level?
a: Copy-paste the nodes fifty times
a: Write fifty scripts
a*: Instance the Enemy scene fifty times
a: Duplicate the .tscn file fifty times
why: instantiate() makes independent copies of one scene.
learn: Nodes and Scenes
q: A Button was pressed. What's the idiomatic way for other nodes to react?
a: Poll is_pressed() every frame
a*: Connect a function to its pressed signal
a: Subclass Button once per listener
a: Watch a global variable
why: Signals call listeners back; the emitter doesn't need to know them.
learn: Signals
q: Which line fires a custom signal you declared?
a: connect("health_changed")
a: signal health_changed
a*: health_changed.emit(health)
a: notify(health_changed)
why: Declare with signal, fire with .emit().
learn: Signals
q: Which shader function runs once per pixel?
a: vertex()
a*: fragment()
a: _process()
a: _physics_process()
why: vertex() shapes geometry; fragment() colours pixels.
learn: Shaders
q: Which built-in makes a shader animate with no script at all?
a*: TIME
a: DELTA
a: FRAME
a: CLOCK
why: TIME counts seconds; feed it to sin() for motion.
learn: Shaders
q: In an HBoxContainer, which size flag makes the editor take all the leftover width?
a: SIZE_FILL
a: SIZE_SHRINK_CENTER
a*: SIZE_EXPAND_FILL
a: SIZE_SHRINK_END
why: EXPAND claims spare space; FILL alone keeps the minimum.
learn: Containers and Layout
q: How does this app style every panel without per-node colour overrides?
a: A shader on every Control
a*: One Theme with type variations
a: CSS stylesheets
a: modulate on each node
why: Type variations let one Theme style many kinds of panel.
learn: Containers and Layout
```
""",

"Quiz: Senedril": """# Quiz: Senedril

How well do you know this app? Wrong answers link straight back to the note that covers them.

```3d
preset: quiz
caption: Senedril basics · 4 questions
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
q: Which component is Senedril's note data model?
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


## Write the course and quiz notes into the open vault. Tests call this directly.
static func seed_vault() -> void:
	VaultStore.refresh_note_list()
	for title in NOTES:
		var idx: int = VaultStore.get_note_index(title)
		var note: ContentLayer = VaultStore.note_list[idx] if idx >= 0 else VaultStore.create_note(title)
		note.raw_text = NOTES[title]
		if title.begins_with("Quiz"):
			note.tags.assign(["quiz"])
		else:
			note.tags.assign(["godot", "course"])
		VaultStore.save_note(note)
		print("seeded: ", title, " -> ", note.resource_path)
