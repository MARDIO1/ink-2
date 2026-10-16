extends SceneTree

const MAIN_SCENE := preload("res://map/asset/imported/main.tscn")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check("grey friction is zero", is_zero_approx(Palette.GREY.friction))
	_check("red explosion strengths are halved",
		is_equal_approx(Palette.RED.compress_strength, 25.0)
		and is_equal_approx(Palette.RED.resolved_shear(), 7.5))

	var scene := MAIN_SCENE.instantiate()
	scene.auto_step = false
	scene.auto_render = false
	scene.set_physics_process(false)
	root.add_child(scene)
	await process_frame

	var hand: Node = scene.get_node("Player/Arm/Hand/HandControl")
	var shape := PixelShape.new()
	shape.fill_rect(Rect2i(0, 0, 4, 4), Palette.GREY.id)
	var grey_body := PBody.new()
	scene.world.add_body(grey_body, [shape])
	var grabbed: bool = hand._begin_grab(grey_body, grey_body.to_world(Vector2(1.5, 1.5)))
	_check("grey ink cannot be grabbed", not grabbed and hand.grip_joint == null)

	shape.owner_body = null
	scene.world.remove_body(grey_body)
	grey_body.shapes.clear()
	scene.queue_free()
	await process_frame
	print("[InkMaterialRules] %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


func _check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("PASS: ", label)
	else:
		_failed += 1
		push_error("FAIL: " + label)
