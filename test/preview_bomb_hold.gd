extends SceneTree


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1200, 650)
	root.content_scale_size = root.size
	var paper := ColorRect.new()
	paper.size = Vector2(root.size)
	paper.color = Color(0.94, 0.93, 0.89)
	root.add_child(paper)
	for index in 3:
		var rig := (load("res://actor/monster/imported/bomb_side/scenes/bomb_side_character.tscn") as PackedScene).instantiate() as Node2D
		root.add_child(rig)
		var animation := rig.get_node("AnimationPlayer") as AnimationPlayer
		animation.play(["RESET", "walk", "throw"][index])
		animation.seek([0.0, 0.25, 0.55][index], true)
		animation.pause()
		rig.update_masks()
		var arm := rig.get_node("Skeleton2D/BodyHead/RightArm") as Bone2D
		print("[BombHoldPreview] ", index, " arm=", arm.global_transform, " palm=", arm.to_global(Vector2(arm.length, 0)))
		var bounds := Rect2()
		for sprite: Sprite2D in rig.find_children("*", "Sprite2D", true, false):
			if not sprite.visible:
				continue
			var rect := Rect2(sprite.texture.get_image().get_used_rect())
			if sprite.flip_h:
				rect.position.x = sprite.texture.get_width() - rect.end.x
			rect.position += sprite.get_rect().position
			var world_rect: Rect2 = sprite.global_transform * rect
			bounds = world_rect if bounds.size == Vector2.ZERO else bounds.merge(world_rect)
			print("[BombHoldPreview] ", sprite.get_path(), " bounds=", world_rect)
		rig.position = Vector2(200 + index * 400, 340) - bounds.get_center()
		var label := Label.new()
		label.text = ["Rest", "Walk", "Throw pose"][index]
		label.position = Vector2(150 + index * 400, 575)
		label.modulate = Color.BLACK
		root.add_child(label)
	await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png("res://.codex-tmp/bomb_hold_preview.png")
	quit(0 if error == OK else 1)
