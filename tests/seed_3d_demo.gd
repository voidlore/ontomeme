extends SceneTree
## Seeds the "3D Scenes" showcase note into the user's vault (idempotent).
##   godot --headless --path . -s res://tests/seed_3d_demo.gd

const BODY: String = """# 3D Scenes

Senedril notes can hold live 3D scenes. Write a fenced block tagged 3d, then switch to Read (Ctrl+3). Drag to orbit, Ctrl+scroll to zoom, and press Expand for a full-window view. Ctrl+P → "Insert 3D scene" adds one for you.

## Spiral galaxy
```3d
preset: galaxy
caption: 9,000 stars · one MultiMesh of additive billboards
```

## Torus knot
```3d
preset: knot
p: 2
q: 3
caption: SurfaceTool tube swept along a (2,3) torus knot
```

## Terrain flyover
```3d
preset: terrain
height: 380
caption: Noise-displaced shader terrain · fog · glow
```

## Wave field
```3d
preset: waves
caption: 1,936 instanced bars driven by one vertex shader
```

## Atom
```3d
preset: atom
caption: Fresnel nucleus · emissive orbitals
```

## Your vault in 3D
Every [[wikilink]] between notes becomes an edge. Double-click a note to open it — try [[Introduction]].
```3d
preset: graph
caption: This vault, force-directed in 3D
```

## Options
- preset: galaxy, knot, terrain, waves, atom, graph, quiz (see [[Quiz: Godot Fundamentals]])
- color / color2: any hex colour, e.g. #d97757
- height: card height in pixels
- speed: animation speed multiplier
- autorotate: true / false
- caption: text under the scene
"""


func _init() -> void:
	await process_frame
	VaultStore.refresh_note_list()
	var idx: int = VaultStore.get_note_index("3D Scenes")
	var note: ContentLayer = VaultStore.note_list[idx] if idx >= 0 else VaultStore.create_note("3D Scenes")
	note.raw_text = BODY
	note.tags.assign(["3d", "showcase"])
	VaultStore.save_note(note)
	print("seeded: ", note.resource_path)
	quit()
