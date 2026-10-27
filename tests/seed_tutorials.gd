extends SceneTree
## Seeds the beginner tutorial series (+ a sample rocket.glb) into the vault.
## Idempotent: re-running rewrites the tutorial notes and the model.
##   godot --headless --path . -s res://tests/seed_tutorials.gd

const T1: String = "Tutorial 1: Writing Notes"
const T2: String = "Tutorial 2: Linking Notes"
const T3: String = "Tutorial 3: Your First 3D Scene"
const T4: String = "Tutorial 4: Shapes and Colors"
const T5: String = "Tutorial 5: Making a Quiz"
const T6: String = "Tutorial 6: Importing 3D Models"
const T7: String = "Tutorial 7: Learning Objectives"
const FOLDER: String = "Tutorials"
const START: String = "Start Here: Tutorials"

const NOTES: Array = [
[START, """Seven short tutorials. Each one adds **one new idea** on top of the last, so take them in order — by the end you'll write notes, link them, fill them with 3D scenes, build a quiz about shapes and colors, bring in your own 3D models, and plan your own learning.

1. [[Tutorial 1: Writing Notes]] — headings, lists, **bold** and *italic*
2. [[Tutorial 2: Linking Notes]] — connect notes with links
3. [[Tutorial 3: Your First 3D Scene]] — a live 3D scene inside a note
4. [[Tutorial 4: Shapes and Colors]] — place your own shapes
5. [[Tutorial 5: Making a Quiz]] — a quiz about shapes and colors
6. [[Tutorial 6: Importing 3D Models]] — your own models
7. [[Tutorial 7: Learning Objectives]] — plan and track what you learn

## Two views you'll use all the time
- **Edit** (Ctrl+1) shows the text you type.
- **Read** (Ctrl+3) shows the finished page.

Every tutorial ends with a short quiz. If you miss a question, a **Review** button takes you straight back to the tutorial that explains it.

Ready? Start with [[Tutorial 1: Writing Notes]].
"""],

[T1, """A note is just text. A few symbols — called **markup** — turn that text into headings, lists and emphasis. You type the symbols in Edit view, and Read view shows the result.

## Edit and Read
- **Edit** (Ctrl+1): the text you type, symbols and all.
- **Read** (Ctrl+3): the finished page — what you're looking at now.

Try it: press Ctrl+1 to see how this very note is written, then Ctrl+3 to come back.

## Headings
Start a line with `#` and a space. More `#` signs make a smaller heading:
````text
# Big title
## Section
### Small heading
````

## Paragraphs
Just type. Leave an empty line between paragraphs.

## Lists
Start each line with `-` and a space:
````text
- eggs
- flour
- milk
````

## Bold, italic and code
- `**bold**` becomes **bold**
- `*italic*` becomes *italic*
- Wrap a word in backticks (the key left of 1) to show it as `code`

## Try it
1. Press Ctrl+N to make a new note, and type a title at the top.
2. Write a heading, a short list, and one **bold** word.
3. Press Ctrl+3 to read it.

## Check yourself
This is a quiz — you'll learn to build your own in Tutorial 5. Click an answer.
```3d
preset: quiz
caption: Tutorial 1 · 3 questions
height: 440
q: Which line makes a heading?
a: - Shopping
a*: # Shopping
a: **Shopping**
a: *Shopping*
why: A # and a space at the start of a line makes a heading.
learn: Tutorial 1: Writing Notes
q: Which line is a list item?
a*: - milk
a: # milk
a: *milk*
a: milk:
why: A dash and a space starts a list item.
learn: Tutorial 1: Writing Notes
q: Which view shows the finished page?
a: Edit (Ctrl+1)
a: Outline (Ctrl+2)
a*: Read (Ctrl+3)
a: Graph (Ctrl+4)
why: Edit shows the symbols; Read shows the result.
learn: Tutorial 1: Writing Notes
```

Next: [[Tutorial 2: Linking Notes]]
"""],

[T2, """Notes get powerful when they point at each other. Put a note's title in double square brackets to link to it:
````text
See [[Tutorial 1: Writing Notes]] for the basics.
````
In Read view that becomes a link you can click: see [[Tutorial 1: Writing Notes]] for the basics.

## Show different words
Add a bar `|` and the words you want people to see:
````text
Go back to [[Tutorial 1: Writing Notes|the first tutorial]].
````
Go back to [[Tutorial 1: Writing Notes|the first tutorial]].

## Links can create notes
Link to a title that doesn't exist yet, then click the link — Ontomeme creates that note for you and opens it, ready to write. This is the easiest way to grow your notes: write the link first, fill it in later.

## Links work with everything from Tutorial 1
- In lists: **[[Start Here: Tutorials]]**
- Next to *italic* and `code`

## See all your links
Press Ctrl+4 for **Graph** view: every note is a dot, every link a line.

## Try it
1. Open the note you made in Tutorial 1 (Ctrl+1 to edit).
2. Add a line: `See [[My Second Note]]`
3. Press Ctrl+3 and click the link — a brand-new note opens.

## Check yourself
```3d
preset: quiz
caption: Tutorial 2 · 3 questions
height: 440
q: How do you link to a note called Recipes?
a: (Recipes)
a*: [[Recipes]]
a: # Recipes
a: **Recipes**
why: Double square brackets around the title make a link.
learn: Tutorial 2: Linking Notes
q: You click a link to a note that doesn't exist yet. What happens?
a: Nothing
a: An error appears
a*: Ontomeme creates the note and opens it
a: The link is deleted
why: Write the link first, fill in the note later.
learn: Tutorial 2: Linking Notes
q: Which markup makes a word bold?
a: *word*
a*: **word**
a: # word
a: [[word]]
why: Two stars on each side make bold; one star makes italic.
learn: Tutorial 1: Writing Notes
```

Next: [[Tutorial 3: Your First 3D Scene]]
"""],

[T3, """Remember code blocks from [[Tutorial 1: Writing Notes]]? Three backticks before and after. Write `3d` right after the first three backticks and the block becomes a **live 3D scene**:
````text
```3d
```
````
That's the whole thing. An empty 3d block shows a galaxy:
```3d
caption: An empty 3d block
```

## Look around
- **Drag** inside the scene to orbit around it.
- **Ctrl + mouse wheel** zooms. The plain wheel still scrolls the note.
- **Expand** fills the window; press Esc to close it.

## Settings
Inside the block, put one setting per line as `name: value`. The `preset` setting picks a ready-made scene: galaxy, knot, terrain, waves, atom or graph.
````text
```3d
preset: knot
color: #6c8cff
caption: A blue torus knot
```
````
```3d
preset: knot
color: #6c8cff
caption: A blue torus knot
```

Other settings you can add:
- `caption:` the text under the scene
- `height:` how tall the scene is, in pixels
- `color:` a main color, as a hex code like #ff8800
- `speed:` 2 is twice as fast, 0.5 half
- `autorotate:` on or off

## Shortcut
Press Ctrl+P and choose "Insert 3D scene" to add one without typing.

## Try it
In your own note, add a 3d block with `preset: terrain` and `caption: My world`, then press Ctrl+3.

## Check yourself
```3d
preset: quiz
caption: Tutorial 3 · 4 questions
height: 440
q: What turns a code block into a 3D scene?
a: Putting it under a heading
a*: Writing 3d right after the first ```
a: Adding a [[link]] inside it
a: Making it bold
why: The word after the opening backticks says what kind of block it is.
learn: Tutorial 3: Your First 3D Scene
q: How do you zoom without scrolling away?
a: Mouse wheel
a*: Ctrl + mouse wheel
a: Double-click
a: Right-click
why: The plain wheel scrolls the note; hold Ctrl to zoom.
learn: Tutorial 3: Your First 3D Scene
q: How do you write a setting inside a 3d block?
a: [[preset knot]]
a: # preset knot
a*: preset: knot
a: **preset** knot
why: One setting per line, name then colon then value.
learn: Tutorial 3: Your First 3D Scene
q: Which line links to a note called Space?
a: (Space)
a: # Space
a: *Space*
a*: [[Space]]
why: Links use double square brackets.
learn: Tutorial 2: Linking Notes
```

Next: [[Tutorial 4: Shapes and Colors]]
"""],

[T4, """Presets are ready-made. Now you'll build a scene yourself. Inside a 3d block, write a **shape**, a colon, and a **color** — one shape per line:
````text
```3d
cube: red
sphere: blue
cone: yellow
```
````
```3d
cube: red
sphere: blue
cone: yellow
caption: cube: red · sphere: blue · cone: yellow
height: 280
```
Shapes line up left to right, sitting on the floor. Hover over one to see its name.

## The shapes
cube, sphere, cylinder, cone, pyramid, torus (a ring), capsule and prism:
```3d
cube: white
sphere: white
cylinder: white
cone: white
pyramid: white
torus: white
capsule: white
prism: white
labels: on
caption: All eight shapes · labels: on shows every name
height: 300
```

## The colors
Use a name — red, blue, yellow, green, orange, purple, pink, cyan, white, black, gray, brown, gold — or any hex code like #ff8800.

## Primary colors
In paint, **red, yellow and blue** are the primary colors. Mix two of them and you get a secondary color:
- red + yellow = **orange**
- yellow + blue = **green**
- blue + red = **purple**

## Put shapes where you want
After the color, add a comma and `at` with three numbers: how far **right**, how far **up**, and how far **toward you**. Other extras: `size 2` (twice as big), `spin`, and `label` with your own name for it.
````text
```3d
sphere: red, at -2 0 0
sphere: yellow, at 0 0 0
sphere: blue, at 2 0 0
cube: orange, at -1 0 1.8, size 0.6
cube: green, at 1 0 1.8, size 0.6
cube: purple, at 0 0 -1.8, size 0.6, spin
labels: on
```
````
```3d
sphere: red, at -2 0 0
sphere: yellow, at 0 0 0
sphere: blue, at 2 0 0
cube: orange, at -1 0 1.8, size 0.6
cube: green, at 1 0 1.8, size 0.6
cube: purple, at 0 0 -1.8, size 0.6, spin
labels: on
caption: Primary colors (spheres) and the secondary colors they mix into (cubes)
height: 360
```

## Try it
Build a snowman: three white spheres stacked with `at` and `size`, and an orange cone for the nose.

## Check yourself
```3d
preset: quiz
caption: Tutorial 4 · 4 questions
height: 440
q: Which line puts a green cube in a scene?
a*: cube: green
a: green: cube
a: [[green cube]]
a: # cube green
why: Shape first, then a colon, then the color.
learn: Tutorial 4: Shapes and Colors
q: Which of these is NOT a primary color?
a: Red
a: Yellow
a: Blue
a*: Green
why: Green is a secondary color: yellow + blue.
learn: Tutorial 4: Shapes and Colors
q: How do you put a shape 2 steps to the right?
a: cube: red, right 2
a*: cube: red, at 2 0 0
a: cube: red, size 2
a: cube: red, spin 2
why: at takes three numbers: right, up, toward you.
learn: Tutorial 4: Shapes and Colors
q: What turns a code block into a 3D scene?
a: A heading above it
a*: 3d after the first ```
a: A link inside it
a: Bold text
why: The word after the opening backticks names the block.
learn: Tutorial 3: Your First 3D Scene
```

Next: [[Tutorial 5: Making a Quiz]]
"""],

[T5, """You've answered a quiz at the end of every tutorial. Now you'll write one — a quiz about **shapes and colors**, using everything from [[Tutorial 4: Shapes and Colors]].

## Step 1: one question
A quiz is a 3d block with `preset: quiz`. Write the question after `q:` and each answer after `a:`. Put a star on the right one: `a*:`
````text
```3d
preset: quiz
q: Which is a primary color?
a: Green
a*: Red
a: Orange
a: Purple
```
````
```3d
preset: quiz
q: Which is a primary color?
a: Green
a*: Red
a: Orange
a: Purple
caption: Step 1 · one question
```

## Step 2: explain, and link back
- `why:` a short reason, shown after someone answers.
- `learn:` the title of the note that teaches the idea. If someone gets it wrong, a **Review** button opens that note.
````text
why: Red, yellow and blue are the primary colors.
learn: Tutorial 4: Shapes and Colors
````

## Step 3: shapes as answers
Write an answer as a **color and a shape** — like `blue sphere` — and it appears as that 3D shape. Players click the shape itself.
````text
q: Click the blue sphere.
a: red cube
a*: blue sphere
a: yellow cone
a: green cylinder
````

## Step 4: show a shape with the question
`show:` puts a shape beside the question, and the answers stay as text:
````text
q: What color is this?
show: cube yellow
a: Red
a*: Yellow
a: Blue
a: Green
````

## Step 5: more questions
Keep adding `q:` lines. Each question collects the `a:`, `why:`, `learn:` and `show:` lines below it.

## The finished quiz: Shapes and Colors
Press Ctrl+1 to see exactly how this was written.
```3d
preset: quiz
caption: Shapes and Colors · 7 questions
height: 470
q: Click the blue sphere.
a: red cube
a*: blue sphere
a: yellow cone
a: green cylinder
why: Blue is the color; a sphere is the round ball.
learn: Tutorial 4: Shapes and Colors
q: What color is this?
show: cube yellow
a: Red
a: Blue
a*: Yellow
a: Green
why: Yellow — one of the three primary colors.
learn: Tutorial 4: Shapes and Colors
q: Which shape has six square faces?
a: white sphere
a*: white cube
a: white cone
a: white cylinder
why: A cube has six square faces.
learn: Tutorial 4: Shapes and Colors
q: What shape is this?
show: torus purple
a: Sphere
a*: Torus
a: Cone
a: Capsule
why: A torus is a ring, like a donut.
learn: Tutorial 4: Shapes and Colors
q: Mix red and yellow paint. Which color do you get?
a: green sphere
a*: orange sphere
a: purple sphere
a: pink sphere
why: Red + yellow = orange.
learn: Tutorial 4: Shapes and Colors
q: Click the primary color.
a: orange cube
a: green cube
a*: blue cube
a: purple cube
why: Blue is primary; the others are mixes.
learn: Tutorial 4: Shapes and Colors
q: Which shape comes to a point at the top?
a: gray cylinder
a: gray sphere
a*: gray cone
a: gray capsule
why: A cone narrows to a single point.
learn: Tutorial 4: Shapes and Colors
```

## Try it
Press Ctrl+P and choose "Insert quiz" to get a starter quiz, then change the questions.

## Check yourself
```3d
preset: quiz
caption: Tutorial 5 · 3 questions
height: 440
q: How do you mark the right answer?
a: a: with a ! at the end
a*: Start the line with a*:
a: Make it **bold**
a: Put it first
why: The star after a marks the right one.
learn: Tutorial 5: Making a Quiz
q: What does learn: do?
a: Shows a hint before answering
a*: Names the note the Review button opens
a: Links two quizzes together
a: Adds a new question
why: Wrong answers offer a Review button that opens that note.
learn: Tutorial 5: Making a Quiz
q: Which line adds a red cube to a scene?
a*: cube: red
a: red: cube
a: [[red cube]]
a: # red cube
why: Shape, colon, color.
learn: Tutorial 4: Shapes and Colors
```

Next: [[Tutorial 6: Importing 3D Models]]
"""],

[T6, """Shapes are great, but you can bring in **any 3D model** — a character, a chair, a planet you made in Blender.

## Which files work
- **.glb** — best choice: one file with everything inside
- **.gltf** — also fine; it comes with a .bin file and textures, and Ontomeme copies them too
- **.fbx** — works for many models

Where to get models: export from Blender (File → Export → glTF 2.0, format "glTF Binary"), or download free ones from Poly Pizza, Kenney or Sketchfab (choose the glTF download).

## Bring one in
- Press Ctrl+P and choose **Import 3D model…**, then pick the file, **or**
- **drag the file** onto the Ontomeme window.

Ontomeme copies the model into a `models` folder inside your notes, then adds a block for it:
````text
```3d
model: rocket.glb, spin
caption: Rocket
```
````
```3d
model: rocket.glb, spin
caption: Rocket · a sample model made for this tutorial
height: 320
```

## Same extras as shapes
`model:` lines take the same extras as shapes from [[Tutorial 4: Shapes and Colors]]: `at`, `size`, `spin`, `label`, and a color to repaint the whole model. Mix models and shapes in one scene:
````text
```3d
model: rocket.glb, size 2.2, spin 0.4
sphere: blue, at -3 0 0, size 1.6, label Earth
sphere: gray, at 3 0 0, size 0.7, label Moon
labels: on
```
````
```3d
model: rocket.glb, size 2.2, spin 0.4
sphere: blue, at -3 0 0, size 1.6, label Earth
sphere: gray, at 3 0 0, size 0.7, label Moon
labels: on
caption: A model and two shapes in one scene
height: 340
```

If a model has an animation, it plays by itself.

## Models in quizzes
Write `model` and the file name anywhere a quiz takes a shape — as an answer, or with `show:`:
````text
q: Click the rocket.
a*: model rocket.glb
a: red cube
a: blue sphere
````

## Check yourself
```3d
preset: quiz
caption: Tutorial 6 · 4 questions
height: 460
q: Click the rocket.
a: red cube
a*: model rocket.glb
a: blue sphere
a: yellow cone
why: Models can be answers, just like shapes.
learn: Tutorial 6: Importing 3D Models
q: Which file type is the easiest to import?
a*: .glb
a: .png
a: .txt
a: .mp3
why: A .glb is one file with the model, colors and textures inside.
learn: Tutorial 6: Importing 3D Models
q: Where does Ontomeme keep imported models?
a: On the desktop
a*: In a models folder inside your notes
a: In the cloud
a: Inside the note text
why: Copying it in means the note keeps working if the original moves.
learn: Tutorial 6: Importing 3D Models
q: Which line shows a spinning blue cone?
a: blue: cone, spin
a*: cone: blue, spin
a: [[cone blue]]
a: cone spin: blue
why: Shape, colon, color, then extras after commas.
learn: Tutorial 4: Shapes and Colors
```

Next: [[Tutorial 7: Learning Objectives]]
"""],

[T7, """You can now make notes that teach. This last tutorial is about **you**: deciding what you want to learn, and tracking whether you've learned it.

## What is a learning objective?
A learning objective is one specific thing you want to be able to **do**. Good ones start with a verb:
- *Name the three primary colors.*
- *Build a 3D scene with five shapes.*
- *Explain what a link between notes is for.*

“Learn colors” is too fuzzy — how would you know you're done? “Name the three primary colors” is easy to check.

## Topics hold objectives
A **topic** is a subject, like *Colour theory*. Inside it you write the objectives. Open the **Journey** tab (Ctrl+5, or the Journey button at the top) to see yours — there's a starter topic, *Ontomeme Basics*, made from these tutorials.

## Pick a goal for each objective
Every objective has a **competency goal**:
- **Fluent** — you want to know it cold (90% or more).
- **Learning** — you're working on it (pass with two thirds).
- **Forget** — not a goal any more; it stops nagging you.

## Prove it with demonstrations
A **demonstration** is a way to show you know something — a quiz or a flashcard deck from your notes. In an objective, click **Add demonstration** and pick one. Then choose its **score output** — what gets written down when you finish:
- **Score as %** — 5 of 7 is logged as 71%.
- **Correct answers** — logged as “5 / 7 correct”.
- **Pass / fail** — logged as Pass or Fail.

Click **Launch** and Ontomeme opens the note and starts it. When you finish, the score is logged under the objective with the date, and the chart shows how you're improving.

## Flashcards
Flashcards are the quickest demonstration to make. Each card is a `q:` (the front) and an `a:` (the back):

````
```3d
preset: flashcards
caption: Primary colors
objective: Name primary shapes and colors
q: Which three colors are primary?
a: Red, yellow and blue
q: Red + blue make…
a: Purple
```
````

The `objective:` line is a shortcut: when you finish the deck, the score is logged to the objective with that name — no clicking needed. Try this one:

```3d
preset: flashcards
caption: Primary colors and shapes
objective: Name primary shapes and colors
q: Which three colors are primary?
a: Red, yellow and blue
q: Red + yellow make…
a: Orange
q: Blue + yellow make…
a: Green
q: Red + blue make…
a: Purple
q: Which shape has six square faces?
a: A cube
q: Which shape is perfectly round from every side?
a: A sphere
```

Be honest when you grade yourself — the score is only useful if it's true.

## Check yourself

```3d
preset: quiz
caption: Learning objectives · 3 questions
q: Which is the best learning objective?
a: Learn colors
a*: Name the three primary colors
a: Colors are nice
a: Read about art
why: It starts with a verb and you can easily check whether you can do it.
learn: Tutorial 7: Learning Objectives
q: You want to know something cold. Which goal?
a*: Fluent
a: Learning
a: Forget
a: None
why: Fluent means 90% or more on every demonstration.
learn: Tutorial 7: Learning Objectives
q: On a flashcard, which line is the back of the card?
a: q:
a*: a:
a: back:
a: card:
why: q: is the front, a: is the back.
learn: Tutorial 7: Learning Objectives
```

## You finished!
You can write notes, link them, build 3D scenes, make quizzes and flashcards, import models — and plan your own learning journey. Back to [[Start Here: Tutorials]].
"""],
]


## A small rocket, built from primitives and exported with Godot's glTF
## exporter, so the import tutorial has a real .glb to show.
static func _build_rocket() -> Node3D:
	var root := Node3D.new()
	root.name = "Rocket"
	var white := StandardMaterial3D.new()
	white.albedo_color = Color("eeeef2")
	white.roughness = 0.35
	var red := StandardMaterial3D.new()
	red.albedo_color = Color("e5484d")
	red.roughness = 0.4
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color("3e7bfa")
	glass.roughness = 0.1
	glass.metallic = 0.3
	var flame := StandardMaterial3D.new()
	flame.albedo_color = Color("ffb020")
	flame.emission_enabled = true
	flame.emission = Color("ff8a00")
	flame.emission_energy_multiplier = 2.0

	var parts: Array = [
		["Body", _cyl(0.32, 0.36, 1.6, 32), white, Vector3(0, 0.8, 0), Vector3.ZERO],
		["Nose", _cyl(0.0, 0.32, 0.6, 32), red, Vector3(0, 1.9, 0), Vector3.ZERO],
		["Window", _ring(0.11, 0.15), red, Vector3(0, 1.15, 0.33), Vector3(PI / 2, 0, 0)],
		["Glass", _sphere(0.12), glass, Vector3(0, 1.15, 0.3), Vector3.ZERO],
		["Nozzle", _cyl(0.2, 0.28, 0.22, 24), red, Vector3(0, -0.11, 0), Vector3.ZERO],
		["Flame", _cyl(0.2, 0.0, 0.45, 24), flame, Vector3(0, -0.44, 0), Vector3.ZERO],
	]
	for k in range(3):
		var a: float = k * TAU / 3.0
		parts.append(["Fin%d" % k, _box(Vector3(0.05, 0.6, 0.38)), red,
			Vector3(sin(a) * 0.48, 0.25, cos(a) * 0.48), Vector3(0, a, 0)])
	for p in parts:
		var mi := MeshInstance3D.new()
		mi.name = p[0]
		mi.mesh = p[1]
		mi.mesh.surface_set_material(0, p[2])
		mi.position = p[3]
		mi.rotation = p[4]
		root.add_child(mi)
		mi.owner = root
	return root


static func _cyl(top: float, bottom: float, h: float, seg: int) -> Mesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = h
	m.radial_segments = seg
	return _bake(m)


static func _ring(inner: float, outer: float) -> Mesh:
	var m := TorusMesh.new()
	m.inner_radius = inner
	m.outer_radius = outer
	return _bake(m)


static func _sphere(r: float) -> Mesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	return _bake(m)


static func _box(size: Vector3) -> Mesh:
	var m := BoxMesh.new()
	m.size = size
	return _bake(m)


## PrimitiveMesh -> ArrayMesh, so surface materials export with the mesh.
static func _bake(p: PrimitiveMesh) -> ArrayMesh:
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, p.get_mesh_arrays())
	return am


func _init() -> void:
	await process_frame
	seed_vault()
	quit()


## Write the tutorials, the sample model and (if `journey` and it is empty) the
## starter Learning Journey into the open vault. Tests call this directly.
static func seed_vault(journey: bool = true) -> void:
	# Sample model
	var models_dir: String = VaultStore.vault_path.path_join("models")
	DirAccess.make_dir_recursive_absolute(models_dir)
	var rocket := _build_rocket()
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err: int = doc.append_from_scene(rocket, state)
	if err == OK:
		err = doc.write_to_filesystem(state, models_dir.path_join("rocket.glb"))
	print("rocket.glb: ", "ok" if err == OK else "error %d" % err)
	rocket.free()

	VaultStore.refresh_note_list()
	# Write in reverse so "Start Here" is the most recent (top of the sidebar)
	var order: Array = NOTES.duplicate()
	order.reverse()
	var now: int = Time.get_unix_time_from_datetime_string(Time.get_datetime_string_from_system())
	for i in range(order.size()):
		var title: String = order[i][0]
		var idx: int = VaultStore.get_note_index(title)
		var note: ContentLayer = VaultStore.note_list[idx] if idx >= 0 else VaultStore.create_note(title)
		note.raw_text = order[i][1]
		note.tags.assign(["tutorial"])
		VaultStore.save_note(note)
		# One second apart (timestamps are per-second) keeps the sidebar order
		note.modified = Time.get_datetime_string_from_unix_time(now + 60 + i)
		ResourceSaver.save(note, note.resource_path)
		print("seeded: ", title)

	# File the series under a real "Tutorials" folder
	VaultStore.refresh_note_list()
	for row in NOTES:
		var ti: int = VaultStore.get_note_index(row[0])
		if ti >= 0:
			VaultStore.move_note(VaultStore.note_list[ti], FOLDER)
	if journey:
		_seed_journey()

	# Point the welcome note at the tutorials
	var intro_i: int = VaultStore.get_note_index("Introduction")
	if intro_i >= 0:
		var intro: ContentLayer = VaultStore.note_list[intro_i]
		if not intro.raw_text.contains("[[Start Here: Tutorials]]"):
			intro.raw_text = "New here? Start with [[Start Here: Tutorials]].\n\n" + intro.raw_text
			VaultStore.save_note(intro)


## A starter Learning Journey built from the tutorials (only if empty).
static func _seed_journey() -> void:
	if not JourneyStore.topics().is_empty():
		print("journey: already has topics, left alone")
		return
	var t: Dictionary = JourneyStore.add_topic("Ontomeme Basics", "Everything the tutorials teach: notes, links, 3D scenes, quizzes and learning objectives.")
	var shapes_quiz: String = ""
	for a in JourneyStore.activities():
		if a.note == T5 and a.kind == "quiz" and str(a.caption).contains("Shapes and Colors"):
			shapes_quiz = a.key
	var plan: Array = [
		["Write and link notes", "Use headings, lists, bold and italic, and connect notes with [[links]].", "learning",
			[JourneyStore.activity_key(T1, "quiz", 0), JourneyStore.activity_key(T2, "quiz", 0)]],
		["Build 3D scenes with shapes", "Add a 3D scene to a note and place coloured shapes in it.", "learning",
			[JourneyStore.activity_key(T3, "quiz", 0), JourneyStore.activity_key(T4, "quiz", 0)]],
		["Name primary shapes and colors", "Name the primary colors, what they mix into, and the basic shapes.", "fluent",
			[shapes_quiz, JourneyStore.activity_key(T7, "cards", 0)]],
		["Set learning objectives", "Write specific objectives, pick a goal, and attach demonstrations.", "learning",
			[JourneyStore.activity_key(T7, "quiz", 0)]],
	]
	for row in plan:
		var o: Dictionary = JourneyStore.add_objective(t.id, row[0], row[1], row[2])
		for key in row[3]:
			if key != "":
				JourneyStore.add_demo(o.id, key, "percent")
	print("journey: seeded Ontomeme Basics")
