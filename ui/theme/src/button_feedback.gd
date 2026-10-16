extends Control
## 只绘制反馈，不移动按钮、标签或命中区域，不接管 pressed 业务信号。

var button: BaseButton
var image_tool := false
var _hovered := false
var _held := false
var _disabled := false
var _selected := false
var _weight := 0.0:
	set(value):
		_weight = value
		queue_redraw()
var _tween: Tween

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.mouse_entered.connect(func(): _hovered = true; _animate())
	button.mouse_exited.connect(func(): _hovered = false; _animate())
	button.button_down.connect(func(): _held = true; _animate())
	button.button_up.connect(func(): _held = false; _animate())
	button.focus_entered.connect(queue_redraw)
	button.focus_exited.connect(_reset_press)
	button.visibility_changed.connect(_reset_press)
	get_window().focus_exited.connect(_reset_press)
	resized.connect(queue_redraw)
	_disabled = button.disabled
	_selected = button.toggle_mode and button.button_pressed

func _reset_press() -> void:
	_held = false
	if not is_inside_tree():
		if _tween != null:
			_tween.kill()
		return
	if not button.is_visible_in_tree() or not get_window().has_focus():
		_hovered = false
	_animate()

func _process(_delta: float) -> void:
	var selected := button.toggle_mode and button.button_pressed
	if _disabled != button.disabled or _selected != selected:
		_disabled = button.disabled
		_selected = selected
		if _disabled:
			_held = false
			_hovered = false
		_animate()

func _animate() -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween()
	var target := 0.0 if button.disabled else (1.0 if _held else (0.6 if _hovered else 0.0))
	_tween.tween_property(self, "_weight", target, 0.09).set_trans(Tween.TRANS_SINE)
	queue_redraw()

func _draw() -> void:
	if button == null or button.disabled or size.x < 6 or size.y < 6:
		return
	# 工具原图保持纯净：只在选中时给文字下方一条短墨线。
	if _selected or (not image_tool and _weight > 0.01):
		# 菜单按钮只显示短墨线，避免宽按钮上出现贯穿整行的白色横条。
		var reach := minf(size.x - 8.0, 14.0 if image_tool else lerpf(18.0, 36.0, _weight))
		var center := Vector2(size.x * 0.5, size.y - 3.0)
		var half := Vector2(reach * 0.5, 0)
		draw_line(center - half, center + half, Color.WHITE, 4.0)
		draw_line(center - half, center + half, Color.BLACK, 2.0 if _held or _selected else 1.0)
