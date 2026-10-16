extends Node
## 仅缩放工具原图；不绘制外框、背景或墨点，不移动文字和点击区域。

var _button: Button
var _icon: TextureRect
var _hovered := false
var _held := false
var _tween: Tween
var _selected := false
var _disabled := false

func _ready() -> void:
	_button = get_parent() as Button
	_icon = _button.get_node("ToolIcon") as TextureRect
	_icon.resized.connect(_center_pivot)
	_center_pivot()
	_button.mouse_entered.connect(func(): _hovered = true; _refresh())
	_button.mouse_exited.connect(func(): _hovered = false; _refresh())
	_button.button_down.connect(func(): _held = true; _refresh())
	_button.button_up.connect(func(): _held = false; _refresh())
	_button.visibility_changed.connect(_reset)
	get_window().focus_exited.connect(_reset)
	_disabled = _button.disabled

func _center_pivot() -> void:
	_icon.pivot_offset = _icon.size * 0.5

func _process(_delta: float) -> void:
	var selected := _button.toggle_mode and _button.button_pressed
	if selected != _selected or _disabled != _button.disabled:
		_selected = selected
		_disabled = _button.disabled
		if _disabled:
			_held = false
			_hovered = false
		_refresh()

func _reset() -> void:
	_held = false
	_hovered = false
	if not is_inside_tree():
		if _tween != null:
			_tween.kill()
		return
	_refresh()

func _rest_scale() -> float:
	return 1.035 if _hovered else (1.02 if _selected else 1.0)

func _refresh() -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	var target := 1.0 if _button.disabled else (0.96 if _held else _rest_scale())
	_icon.modulate.a = 0.4 if _button.disabled else 1.0
	_tween.tween_property(_icon, "scale", Vector2.ONE * target, 0.10)

func pulse() -> void:
	if _button.disabled:
		return
	if _tween != null:
		_tween.kill()
	_icon.scale = Vector2.ONE * 0.96
	_tween = create_tween()
	_tween.tween_property(_icon, "scale", Vector2.ONE * _rest_scale(), 0.12).set_trans(Tween.TRANS_SINE)
