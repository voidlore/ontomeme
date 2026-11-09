extends SceneTree
## Prints where the app creates its default vault in this environment, for
## the leak gate in tests/run_all.sh:
##   godot --headless --path . -s res://tests/print_default_vault.gd
## Usually <Documents>/Ontomeme. With no xdg-user-dir on PATH, Godot on Linux
## finds no Documents folder and the app reads user-dirs.dirs itself (else
## ~/Documents).


func _init() -> void:
	preload("res://tests/test_vault.gd").hold()   # or the autoload opens the startup vault, creating this one on a first run
	print("DEFAULT-VAULT: " + VaultRegistry.normalize(VaultRegistry.default_vault()))
	quit()
