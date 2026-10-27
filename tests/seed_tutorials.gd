extends SceneTree
## Seeds the beginner tutorial series (+ a sample rocket.glb) into the vault.
## Idempotent: re-running rewrites the tutorial notes and the model.
##   godot --headless --path . -s res://tests/seed_tutorials.gd

const Tutorials = preload("res://tutorials_content.gd")


func _init() -> void:
	await process_frame
	Tutorials.seed_vault()
	quit()
