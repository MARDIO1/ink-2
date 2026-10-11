extends SceneTree

const Nail := preload("res://actor/nail/src/nail.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	Nail.map_editor_active = true
	Nail.visuals_visible = true

	var editor_nail := Nail.new()
	root.add_child(editor_nail)
	editor_nail.set_physics_process(false)
	editor_nail.setup(null, Vector2i.ZERO, true)

	var gameplay_nail := Nail.new()
	root.add_child(gameplay_nail)
	gameplay_nail.set_physics_process(false)
	gameplay_nail.setup(null, Vector2i.ZERO, false)

	var valid := editor_nail.visible and gameplay_nail.visible
	Nail.map_editor_active = false
	editor_nail.refresh_visibility()
	gameplay_nail.refresh_visibility()
	valid = valid and not editor_nail.visible and gameplay_nail.visible

	Nail.map_editor_active = true
	Nail.visuals_visible = false
	editor_nail.refresh_visibility()
	gameplay_nail.refresh_visibility()
	valid = valid and not editor_nail.visible and gameplay_nail.visible

	Nail.map_editor_active = false
	Nail.visuals_visible = true
	print("[MapEditorNailVisibility] ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
