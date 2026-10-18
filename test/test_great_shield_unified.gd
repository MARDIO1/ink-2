extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, condition: bool) -> void:
	print("[ShieldUnified] ", label, ": ", "PASS" if condition else "FAIL")
	if not condition:
		failures += 1

func _run() -> void:
	var rig = load("res://actor/monster/imported/great_shield/scenes/great_shield_body_rig.tscn").instantiate()
	rig.hand_drawn_wobble = false
	root.add_child(rig)
	await process_frame
	var animation: AnimationPlayer = rig.get_node("AnimationPlayer")
	var masks_cover_strokes := true
	for part in rig.PART_BONES:
		var bone: Bone2D = rig.get_part_bone(part)
		var prefix: String = "Body" if part == &"body" else str(bone.name)
		var art: Sprite2D = bone.get_node(prefix + "Art")
		var mask: Sprite2D = bone.get_node(prefix + "OcclusionMask")
		var image := art.texture.get_image()
		var silhouette := mask.texture.get_image()
		_check(str(part) + " mask matches texture dimensions", image.get_size() == silhouette.get_size())
		for y in range(0, image.get_height(), 3):
			for x in range(0, image.get_width(), 3):
				if image.get_pixel(x, y).a > 0.5:
					masks_cover_strokes = masks_cover_strokes and silhouette.get_pixel(x, y).a > 0.5
		_check(str(part) + " mask leaves exterior transparent", silhouette.get_pixel(0, 0).a == 0.0)
	_check("filled masks cover visible ink strokes", masks_cover_strokes)
	for mirrored in [false, true]:
		rig.scale = Vector2(-0.65 if mirrored else 0.65, 0.65)
		rig.rotation = 0.4
		for clock in [0.0, 0.6, 1.2, 1.8]:
			animation.play("walk")
			animation.seek(clock, true)
			animation.pause()
			rig.get_part_bone(&"left_arm").rotation += 1.37
			rig._update_occlusion_materials()
			var aligned := true
			for part in rig.PART_BONES:
				var bone: Bone2D = rig.get_part_bone(part)
				var prefix: String = "Body" if part == &"body" else str(bone.name)
				var art: Sprite2D = bone.get_node(prefix + "Art")
				var mask: Sprite2D = bone.get_node(prefix + "OcclusionMask")
				aligned = aligned and art.global_transform.is_equal_approx(mask.global_transform) and not mask.visible
			for path in rig.OCCLUDERS:
				var material: ShaderMaterial = rig.get_node(path).material
				var occluders: Array = rig.OCCLUDERS[path]
				aligned = aligned and int(material.get_shader_parameter("mask_count")) == occluders.size()
				for index in occluders.size():
					var mask: Sprite2D = rig.get_node(occluders[index])
					var expected := mask.global_transform.affine_inverse()
					var actual: Vector2 = material.get_shader_parameter("mask_%d_inv_origin" % index)
					aligned = aligned and actual.is_equal_approx(expected.origin)
			_check("mask alignment: mirror=%s walk=%s with shield shove and tilt" % [mirrored, clock], aligned)
	animation.play("RESET")
	animation.advance(0)
	animation.stop()
	_check("RESET restores refitted hips", rig.get_part_bone(&"left_leg").position.is_equal_approx(Vector2(-145,18)) and rig.get_part_bone(&"right_leg").position.is_equal_approx(Vector2(65,18)))
	for entry in [[&"left_leg", Vector2(87.734486, -33.744037)], [&"right_leg", Vector2(91.592773, 21.136792)]]:
		var bone: Bone2D = rig.get_part_bone(entry[0])
		var art: Sprite2D = bone.get_node(str(bone.name) + "Art")
		var shift := (art.position - Vector2(entry[1])).rotated(bone.rotation) * 0.5
		_check(str(entry[0]) + " lowered three pixels at prefab scale", shift.distance_to(Vector2(0, 3)) < 0.001)
	rig.queue_free()
	await process_frame
	quit(1 if failures else 0)
