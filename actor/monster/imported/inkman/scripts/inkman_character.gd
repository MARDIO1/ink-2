@tool
extends Node2D
class_name InkmanCharacter

signal expression_changed(index: int)
signal ink_amount_changed(value: float)
signal hand_pose_changed(gripping: bool)

enum Mood {
	COMMON,
	SAD,
	ANGRY,
	SURPRISED,
	FURIOUS,
	SPEECHLESS,
}

const FACE_TEXTURES: Array[Texture2D] = [
	preload("res://actor/monster/imported/inkman/assets/unified/face_common.png"),
	preload("res://actor/monster/imported/inkman/assets/unified/face_sad.png"),
	preload("res://actor/monster/imported/inkman/assets/unified/face_angry.png"),
	preload("res://actor/monster/imported/inkman/assets/unified/face_surprised.png"),
	preload("res://actor/monster/imported/inkman/assets/unified/face_furious.png"),
	preload("res://actor/monster/imported/inkman/assets/unified/face_speechless.png"),
]
const HAND_OPEN: Texture2D = preload("res://actor/monster/imported/inkman/assets/unified/hand_open.png")
const HAND_GRIP: Texture2D = preload("res://actor/monster/imported/inkman/assets/unified/hand_grip.png")
const EXPRESSION_NAMES := ["common", "sad", "angry", "surprised", "very angry", "speechless"]
const WOBBLE_POSITIONS := [
	Vector2(0.0, 0.0),
	Vector2(0.80, -0.35),
	Vector2(-0.60, 0.30),
	Vector2(0.45, 0.35),
	Vector2(-0.75, -0.20),
	Vector2(0.55, -0.30),
	Vector2(-0.35, 0.20),
]
const WOBBLE_ROTATIONS_DEGREES := [0.0, -0.22, 0.16, -0.12, 0.21, -0.15, 0.10]
const WOBBLE_SCALES := [
	Vector2(1.0, 1.0),
	Vector2(1.004, 0.996),
	Vector2(0.997, 1.003),
	Vector2(1.003, 0.997),
	Vector2(0.996, 1.004),
	Vector2(1.004, 0.997),
	Vector2(0.997, 1.003),
]
const FACE_WOBBLE_OFFSETS := [
	Vector2(0.0, 0.0),
	Vector2(0.35, 0.0),
	Vector2(-0.30, 0.20),
	Vector2(0.25, -0.20),
	Vector2(-0.35, 0.0),
	Vector2(0.30, 0.20),
	Vector2(-0.20, -0.20),
]

@export_enum("common", "sad", "angry", "surprised", "very angry", "speechless") var expression: int = Mood.COMMON:
	set(value):
		expression = clampi(value, 0, FACE_TEXTURES.size() - 1)
		_apply_expression()
		expression_changed.emit(expression)
@export_range(0.0, 1.0, 0.01) var ink_amount := 0.72:
	set(value):
		ink_amount = clampf(value, 0.0, 1.0)
		_apply_ink_amount()
		ink_amount_changed.emit(ink_amount)
@export var center_when_run_alone := true
@export var mouse_hand_follows_cursor := true
@export_range(0.0, 40.0, 0.5) var mouse_follow_speed := 22.0
@export var mouse_hand_offset := Vector2.ZERO
@export_range(0.05, 1.5, 0.05) var grip_hold_time := 0.3
@export_group("Hand-drawn Wobble")
@export var hand_drawn_wobble := true:
	set(value):
		hand_drawn_wobble = value
		_apply_wobble_playback()
@export_range(2.0, 5.0, 0.05) var wobble_fps := 3.33
@export_range(0.0, 1.0, 0.05) var wobble_strength := 0.85
@export_range(4.0, 24.0, 0.5) var wobble_smoothing := 12.0
@export var preview_wobble_in_editor := false

@onready var face: Sprite2D = $Body/Face
@onready var ink_fill: InkFill2D = $Body/InkFill
@onready var body_visual: Node2D = $Body
@onready var bottle_shell: AnimatedSprite2D = $Body/BottleShell
@onready var mouse_hand: Sprite2D = $MouseHand
var _mouse_pressed := false
var _hold_elapsed := 0.0
var _hand_gripping := false
var _suppress_mouse_follow := false
var _wobble_elapsed := 0.0
var _body_rest_position := Vector2.ZERO
var _body_rest_rotation := 0.0
var _body_rest_scale := Vector2.ONE
var _face_rest_position := Vector2.ZERO


func _ready() -> void:
	var user_args := OS.get_cmdline_user_args()
	_suppress_mouse_follow = "--capture-preview" in user_args or "--validate-rig" in user_args
	_body_rest_position = body_visual.position
	_body_rest_rotation = body_visual.rotation
	_body_rest_scale = body_visual.scale
	_face_rest_position = face.position
	if not Engine.is_editor_hint() and center_when_run_alone and get_tree().current_scene == self and position.is_zero_approx():
		position = get_viewport_rect().size * 0.5
	_apply_expression()
	_apply_ink_amount()
	_apply_wobble_playback()
	_set_hand_gripping(false)
	if "--validate-rig" in user_args:
		_validate_rig_and_quit()
	elif "--capture-preview" in user_args:
		_capture_preview()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if preview_wobble_in_editor:
			_update_visual_wobble(delta)
		return
	_update_mouse_hand(delta)
	_update_hand_hold(delta)
	_update_visual_wobble(delta)


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		set_hand_pressed(event.pressed)


func set_expression_index(index: int) -> void:
	expression = index


func get_expression_name() -> String:
	return EXPRESSION_NAMES[expression]


func set_hand_pressed(pressed: bool) -> void:
	_mouse_pressed = pressed
	_hold_elapsed = 0.0
	if not pressed:
		_set_hand_gripping(false)


func is_hand_gripping() -> bool:
	return _hand_gripping


func reset_pose() -> void:
	_wobble_elapsed = 0.0
	set_hand_pressed(false)


func _update_visual_wobble(delta: float) -> void:
	if not is_instance_valid(body_visual) or not is_instance_valid(face):
		return
	_wobble_elapsed += delta
	var pose_count := WOBBLE_POSITIONS.size()
	var pose_index := int(floor(_wobble_elapsed * maxf(wobble_fps, 0.01))) % pose_count
	var active_strength := wobble_strength if hand_drawn_wobble else 0.0
	var desired_position: Vector2 = _body_rest_position + WOBBLE_POSITIONS[pose_index] * active_strength
	var desired_rotation := _body_rest_rotation + deg_to_rad(WOBBLE_ROTATIONS_DEGREES[pose_index]) * active_strength
	var pose_scale: Vector2 = WOBBLE_SCALES[pose_index]
	var desired_scale := Vector2(
		_body_rest_scale.x * lerpf(1.0, pose_scale.x, active_strength),
		_body_rest_scale.y * lerpf(1.0, pose_scale.y, active_strength)
	)
	var desired_face_position: Vector2 = _face_rest_position + FACE_WOBBLE_OFFSETS[pose_index] * active_strength
	var blend := 1.0 - exp(-maxf(wobble_smoothing, 0.01) * delta)
	body_visual.position = body_visual.position.lerp(desired_position, blend)
	body_visual.rotation = lerp_angle(body_visual.rotation, desired_rotation, blend)
	body_visual.scale = body_visual.scale.lerp(desired_scale, blend)
	face.position = face.position.lerp(desired_face_position, blend)


func _apply_wobble_playback() -> void:
	var target_bottle := bottle_shell if is_instance_valid(bottle_shell) else get_node_or_null("Body/BottleShell") as AnimatedSprite2D
	if target_bottle == null:
		return
	if hand_drawn_wobble:
		target_bottle.play(&"boil")
	else:
		target_bottle.pause()
		target_bottle.frame = 0


func _apply_expression() -> void:
	var target_face := face if is_instance_valid(face) else get_node_or_null("Body/Face") as Sprite2D
	if target_face != null:
		target_face.texture = FACE_TEXTURES[clampi(expression, 0, FACE_TEXTURES.size() - 1)]


func _apply_ink_amount() -> void:
	var target_fill := ink_fill if is_instance_valid(ink_fill) else get_node_or_null("Body/InkFill") as InkFill2D
	if target_fill != null:
		target_fill.amount = ink_amount


func _update_mouse_hand(delta: float) -> void:
	if _suppress_mouse_follow or not mouse_hand_follows_cursor or not is_instance_valid(mouse_hand):
		return
	var destination := get_global_mouse_position() + mouse_hand_offset
	var weight := 1.0 if mouse_follow_speed <= 0.0 else 1.0 - exp(-mouse_follow_speed * delta)
	mouse_hand.global_position = mouse_hand.global_position.lerp(destination, weight)


func _update_hand_hold(delta: float) -> void:
	if not _mouse_pressed:
		return
	_hold_elapsed += delta
	if _hold_elapsed >= grip_hold_time:
		_set_hand_gripping(true)


func _set_hand_gripping(gripping: bool) -> void:
	if _hand_gripping == gripping and is_instance_valid(mouse_hand) and mouse_hand.texture != null:
		return
	_hand_gripping = gripping
	var target_hand := mouse_hand if is_instance_valid(mouse_hand) else get_node_or_null("MouseHand") as Sprite2D
	if target_hand != null:
		target_hand.texture = HAND_GRIP if gripping else HAND_OPEN
	hand_pose_changed.emit(gripping)


func _capture_preview() -> void:
	for _frame in range(6):
		await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_error("Viewport returned no preview image")
		get_tree().quit(1)
		return
	image.save_png("res://preview.png")
	get_tree().quit()


func _validate_rig_and_quit() -> void:
	await get_tree().process_frame
	var problems: Array[String] = []
	var required_paths: Array[NodePath] = [
		^"Body/BottleShell",
		^"Body/Face",
		^"MouseHand",
	]
	for path in required_paths:
		var node := get_node_or_null(path)
		if node == null:
			problems.append("Missing node: %s" % path)
		elif node is Sprite2D and node.texture == null:
			problems.append("Texture is not bound: %s" % path)
	var bottle_animation := get_node_or_null("Body/BottleShell") as AnimatedSprite2D
	if bottle_animation == null:
		problems.append("BottleShell is not an AnimatedSprite2D")
	elif bottle_animation.sprite_frames.get_frame_count(&"boil") != 7:
		problems.append("Bottle wobble does not contain 7 frames")
	elif not bottle_animation.is_playing():
		problems.append("Bottle wobble is not playing")
	else:
		var starting_wobble_frame := bottle_animation.frame
		await get_tree().create_timer(0.36).timeout
		if bottle_animation.frame == starting_wobble_frame:
			problems.append("Bottle wobble frame does not advance")
		hand_drawn_wobble = false
		if bottle_animation.is_playing() or bottle_animation.frame != 0:
			problems.append("Wobble toggle does not stop on the rest frame")
		hand_drawn_wobble = true
		if not bottle_animation.is_playing():
			problems.append("Wobble toggle does not restart playback")
	if expression != Mood.COMMON or face.texture != FACE_TEXTURES[Mood.COMMON]:
		problems.append("Initial expression is not common")
	if mouse_hand.texture != HAND_OPEN:
		problems.append("Idle hand is not open")
	set_hand_pressed(true)
	_update_hand_hold(grip_hold_time + 0.01)
	if not is_hand_gripping() or mouse_hand.texture != HAND_GRIP:
		problems.append("Long press does not switch to grip")
	set_hand_pressed(false)
	if is_hand_gripping() or mouse_hand.texture != HAND_OPEN:
		problems.append("Released hand does not return to open")
	for removed_path in [^"Skeleton2D", ^"Targets"]:
		if get_node_or_null(removed_path) != null:
			problems.append("Removed leg node still exists: %s" % removed_path)
	if problems.is_empty():
		print("INKMAN_RIG_VALIDATION: PASS | legs=removed | expression=common | hand=open->grip->open | ink=%.2f | wobble=7f@%.2ffps strength=%.2f" % [ink_fill.amount, wobble_fps, wobble_strength])
		get_tree().quit(0)
	else:
		for problem in problems:
			push_error(problem)
		print("INKMAN_RIG_VALIDATION: FAIL | problems=%d" % problems.size())
		get_tree().quit(1)
