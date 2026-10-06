extends SceneTree
## godot --headless --path . --script res://tools/bake_cli.gd

const BakeArt := preload("res://tools/bake_art.gd")


func _initialize() -> void:
	BakeArt.new().run_all()
	quit(0)