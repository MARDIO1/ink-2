extends SceneTree

const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas: Node = scene.get_node("SmallCanvas")
	var surface: Area2D = canvas.get_node("CanvasSurface")
	var player = scene.get_node("Player")
	var player_body = player.get("body")
	player_body.position = surface.global_position + Vector2(12, 12)
	var ink_shape := PixelShape.new()
	ink_shape.fill_rect(Rect2i(0, 0, 32, 32), 1)
	var before: int = ink_shape.pixel_count()
	var removed: int = canvas.solid._remove_overlaps(ink_shape, surface, [player_body])
	var valid: bool = player_body.tags.has("living")
	valid = valid and removed == 0 and ink_shape.pixel_count() == before
	print("[SolidifyLivingOverlap] living actors do not carve the ink: ", "PASS" if valid else "FAIL")
	scene.queue_free()
	await process_frame
	quit(0 if valid else 1)
