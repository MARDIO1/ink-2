extends CanvasLayer
## 常驻的切换遮罩：遮屏期间暂停世界，真实加载完成后揭幕。

enum Style { PAGE, INK, TEAR, DRAFT }
const OverlayShader := preload("res://ui/transition/transition.gdshader")
const LoadingInk := preload("res://ui/transition/loading_ink.gd")
const UIFont := preload("res://ui/theme/asset/ipix_ui_font.tres")
var busy := false
var style := Style.PAGE
var duration := 0.34
var _previous_pause := false
var _cover: ColorRect
var _material: ShaderMaterial
var _loading: VBoxContainer
var _label: Label
var _ink: Control

func _ready() -> void:
	layer = 1000
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cover = ColorRect.new()
	_cover.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cover.mouse_filter = Control.MOUSE_FILTER_STOP
	_material = ShaderMaterial.new()
	_material.shader = OverlayShader
	_cover.material = _material
	add_child(_cover)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cover.add_child(center)
	_loading = VBoxContainer.new()
	_loading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading.add_theme_constant_override("separation", 20)
	center.add_child(_loading)
	_ink = Control.new()
	_ink.set_script(LoadingInk)
	_ink.custom_minimum_size = Vector2(160, 105)
	_ink.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_loading.add_child(_ink)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_override("font", UIFont)
	_label.add_theme_font_size_override("font_size", 24)
	_loading.add_child(_label)
	visible = false

func _input(_event: InputEvent) -> void:
	if busy:
		get_viewport().set_input_as_handled()

func begin(next_style: int, message: String) -> bool:
	if busy:
		return false
	busy = true
	style = next_style
	_previous_pause = get_tree().paused
	get_tree().paused = true
	visible = true
	_material.set_shader_parameter("style", style)
	_material.set_shader_parameter("amount", 0.0)
	_ink.dark = style == Style.INK
	_label.add_theme_color_override("font_color", Color(0.94, 0.92, 0.85) if _ink.dark else Color(0.12, 0.13, 0.17))
	_label.text = message
	_loading.modulate.a = 0.0
	await _animate(0.0, 1.0)
	_loading.modulate.a = 1.0
	# 先呈现等待动画，再进行可能需要主线程的场景实例化。
	await get_tree().process_frame
	return true

func finish() -> void:
	if not busy:
		return
	# 在纸面仍完整遮屏时恢复世界，让相机先对齐新玩家，避免揭幕后跳镜头。
	get_tree().paused = _previous_pause
	await get_tree().physics_frame
	await get_tree().process_frame
	_loading.modulate.a = 0.0
	await _animate(1.0, 0.0)
	visible = false
	busy = false

func _animate(from: float, to: float) -> void:
	var tween := create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_method(_set_amount, from, to, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tween.finished

func _set_amount(value: float) -> void:
	_material.set_shader_parameter("amount", value)
