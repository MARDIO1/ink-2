extends SceneTree
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[HandPoses] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	var level: Node = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	paused = true
	var hand: Node = level.get_node("Player/Arm/Hand/HandControl")
	var mass: float = hand.body.mass
	var inertia: float = hand.body.inertia
	hand.set_rotation_mode(false)
	hand._update_pose(0.1, false)
	_check("idle extended finger", hand.art_unfold.visible and not hand.art_grab.visible and not hand.art_climb.visible)
	hand._update_pose(0.04, true)
	_check("smooth half transition", is_equal_approx(hand.art_grab.modulate.a, 0.5) and is_equal_approx(hand.art_unfold.modulate.a, 0.5))
	hand._update_pose(0.04, true)
	_check("held grip", hand.art_grab.visible and not hand.art_unfold.visible)
	hand.set_rotation_mode(true)
	hand._update_pose(0.1, true)
	_check("climb held keeps open palm", hand.art_climb.visible and not hand.art_grab.visible)
	hand._update_pose(0.1, false)
	_check("climb released keeps open palm", hand.art_climb.visible and not hand.art_unfold.visible)
	_check("pose never changes physical mass or inertia", hand.body.mass == mass and hand.body.inertia == inertia)
	var sheet := Image.create_empty(660, 210, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.94, 0.92, 0.87))
	var index := 0
	for art in [hand.art_unfold, hand.art_grab, hand.art_climb]:
		var image: Image = art.texture.get_image()
		_check("common aligned image size", image.get_size() == Vector2i(44, 34) and art.position == Vector2.ZERO)
		image.resize(176, 136, Image.INTERPOLATE_NEAREST)
		sheet.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i(22 + index * 220, 35))
		index += 1
	DirAccess.make_dir_recursive_absolute("D:/Ink/output")
	sheet.save_png("D:/Ink/output/hand_pose_preview.png")
	# 检测区附近能抓到，明显远处不能隔空抓；两种模式分别验证。
	var target = level.get_node("Ground").body
	var hit = hand.Query.closest_point_on_shape(target.shapes[0], target.com_world())
	for climbing in [false, true]:
		hand.set_rotation_mode(climbing)
		hand._remove_arm()
		hand.body.rotation = 0.0
		var anchor: Vector2 = hand.CLIMB_ANCHOR if climbing else hand.FINGERTIP
		hand.body.position = hit.point - anchor - hand.body.local_com
		hand.body.refresh_com()
		hand.body.update_aabb()
		hand.set_grip(true)
		hand._update_grip(0.1)
		_check("mode grab zone acquires ground", hand.grabbed_body == target)
		hand._release_grab()
		hand._remove_arm()
		hand.body.position = hit.point + Vector2(0, -100) - anchor - hand.body.local_com
		hand.body.rotation = 0.0
		hand.body.refresh_com()
		hand.body.update_aabb()
		hand._update_grip(0.1)
		_check("mode rejects distant ground", hand.grabbed_body == null)
	hand.clear_grip_override()
	paused = false
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
