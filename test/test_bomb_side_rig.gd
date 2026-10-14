extends SceneTree

var valid := true

func _initialize() -> void:
	run.call_deferred()

func check(label: String, condition: bool) -> void:
	print("[BombSideImport] ", label, ": ", "PASS" if condition else "FAIL")
	valid = valid and condition

func run() -> void:
	var level := (load("res://map/asset/imported/main.tscn") as PackedScene).instantiate()
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	root.add_child(level)
	await process_frame
	creative.set_active(true)
	var button: Button = null
	for candidate in creative._monster_buttons:
		if int(candidate.get_meta("monster_kind")) == 2:
			button = candidate
	check("tool button visible in palette", button != null and button.text == "炸弹狂")
	if button != null:
		button.pressed.emit()
	check("button selects bomb placement", creative._monster_mode == 2 and button.button_pressed)
	var count: int = creative.monster_count()
	var monster = creative.place_monster(2, Vector2(500, -300), true, "bomb-import-check")
	check("map placement", monster != null and creative.monster_count() == count + 1)
	var visual: Node2D = monster.get_node("Visual")
	check("standalone visual without demo UI", visual.get_node_or_null("UI") == null and visual.get_node_or_null("BoneOverlay") == null)
	check("latest mirrored skeleton", visual.get_node("Skeleton2D").scale == Vector2(-1, 1))
	check("five original bones", visual.find_children("*", "Bone2D", true, false).size() == 5)
	check("five masks", visual.find_children("OcclusionMask", "Sprite2D", true, false).size() == 5)
	var animation: AnimationPlayer = visual.get_node("AnimationPlayer")
	for animation_name in [&"idle", &"walk", &"throw"]:
		check("animation " + str(animation_name), animation.has_animation(animation_name))
		animation.play(animation_name)
		animation.seek(0.55, true)
		visual.update_masks()
		var aligned := true
		for index in visual.FRONT_TO_BACK.size():
			var bone := visual.get_node(visual.FRONT_TO_BACK[index])
			var art := bone.get_node("Art") as Sprite2D
			var mask := bone.get_node("OcclusionMask") as Sprite2D
			aligned = aligned and art.global_transform.is_equal_approx(mask.global_transform) \
				and art.flip_h == mask.flip_h and art.z_index == 4 - index
			if index > 0:
				aligned = aligned and int(art.material.get_shader_parameter("mask_count")) == index
		check("mask order/alignment in " + str(animation_name), aligned)
	animation.play("RESET")
	animation.advance(0.0)
	animation.pause()
	var bottom := -INF
	for path in visual.FRONT_TO_BACK:
		var art: Sprite2D = visual.get_node(path).get_node("Art")
		var image := art.texture.get_image()
		for y in image.get_height():
			for x in image.get_width():
				if image.get_pixel(x, y).a > 0.1:
					var local: Vector2 = art.get_rect().position + Vector2(image.get_width() - x if art.flip_h else x, y + 1)
					bottom = maxf(bottom, monster.to_local(art.to_global(local)).y)
	print("[BombSideImport] visible bottom relative to placement origin = ", bottom)
	check("feet match placement origin", absf(bottom) < 0.1)
	check("undo placement", creative.undo_last_edit())
	await process_frame
	check("undo removes bomb", creative.monster_count() == count)
	monster = creative.place_monster(2, Vector2(500, -300), false, "bomb-delete-check")
	check("delete placed bomb", creative.remove_monster_at(monster.global_position))
	await process_frame
	check("undo restores deleted bomb", creative.undo_last_edit() and creative.monster_count() == count + 1)
	level.queue_free()
	await process_frame
	print("[BombSideImport] overall: ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
