extends Control
## 标题：交互水面（两个 SubViewport 互相引用做双缓冲的波动方程）
##
## 独立预览场景：只用 title.png / paper.png 两张图片素材，不引用工程里的任何场景或脚本。
## 空格 = 开关；ESC = 退出；鼠标划过标题会拖出涟漪。

@export var title_texture: Texture2D
@export var paper_texture: Texture2D
@export var auto_quit := false

const SIM_SHADER := "res://ui/menu/title_fx/ripple_sim.gdshader"
const TITLE_SHADER := "res://ui/menu/title_fx/ripple_title.gdshader"
const SIM_SIZE := Vector2i(192, 118)

var _title: TextureRect
var _mat_a: ShaderMaterial
var _mat_b: ShaderMaterial
var _title_mat: ShaderMaterial
var _on := true
var _elapsed := 0.0
var _drop_timer := 0.0
var _next_drop := 1.2
var _pending_drop := Vector2(-1.0, -1.0)
var _last_mouse := Vector2(-1.0, -1.0)


func _make_sim_viewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = SIM_SIZE
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	# ⚠️ SubViewport 不是 Control，子节点没有父 Control 可依，锚点撑不开 —— 必须显式给尺寸，
	#    否则尺寸为 0，什么都不渲染（症状：模拟贴图恒定不变）。
	rect.position = Vector2.ZERO
	rect.size = Vector2(SIM_SIZE)
	var mat := ShaderMaterial.new()
	mat.shader = load(SIM_SHADER)
	mat.set_shader_parameter("sim_size", Vector2(SIM_SIZE))
	rect.material = mat
	vp.add_child(rect)
	return vp


func _ready() -> void:
	var paper := TextureRect.new()
	paper.texture = paper_texture
	paper.set_anchors_preset(Control.PRESET_FULL_RECT)
	paper.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(paper)

	_title = TextureRect.new()
	_title.texture = title_texture
	_title.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_title.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.anchor_left = 0.18
	_title.anchor_top = 0.04
	_title.anchor_right = 0.82
	_title.anchor_bottom = 0.5
	_title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_title.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_title)

	# 两张互相引用的模拟 viewport（Godot 不允许 ViewportTexture 自引用）
	var vp_a := _make_sim_viewport()
	var vp_b := _make_sim_viewport()
	_mat_a = (vp_a.get_child(0) as ColorRect).material as ShaderMaterial
	_mat_b = (vp_b.get_child(0) as ColorRect).material as ShaderMaterial
	add_child(vp_a)
	add_child(vp_b)
	# A 读 B、B 读 A；Godot 按树序渲染 -> A 读 B 上一帧，B 读 A 这一帧，每帧推进一步
	_mat_a.set_shader_parameter("ripple_tex", vp_b.get_texture())
	_mat_b.set_shader_parameter("ripple_tex", vp_a.get_texture())

	_title_mat = ShaderMaterial.new()
	_title_mat.shader = load(TITLE_SHADER)
	_title_mat.set_shader_parameter("sim_size", Vector2(SIM_SIZE))
	_title_mat.set_shader_parameter("ripple_tex", vp_b.get_texture())   # 读后渲染的那张 = 最新
	_title.material = _title_mat

	var hint := Label.new()
	hint.text = "空格 = 开关    ESC = 退出    （鼠标划过标题会拖出涟漪）"
	hint.position = Vector2(16, 10)
	hint.modulate = Color(1, 1, 1, 0.65)
	add_child(hint)


func _process(delta: float) -> void:
	if auto_quit:
		_elapsed += delta
		if _elapsed > 12.0:
			get_tree().quit()
	if not _on or _mat_a == null:
		return
	var size := _title.size
	if size.x <= 0.0 or size.y <= 0.0:
		return

	# 鼠标：只在**移动**时注入，静止不动就不搅水
	var mouse_uv := Vector2(-1.0, -1.0)
	var uv := Vector2(-1.0, -1.0)
	if auto_quit:
		# 录视频时没有真鼠标，自动扫一条路径，好让动图里看到拖尾
		var t := _elapsed
		uv = Vector2(0.5 + 0.30 * sin(t * 0.9), 0.5 + 0.24 * sin(t * 1.4 + 1.1))
	else:
		var local := _title.get_local_mouse_position()
		var inside := local.x >= 0.0 and local.y >= 0.0 and local.x <= size.x and local.y <= size.y
		if inside:
			uv = Vector2(local.x / size.x, local.y / size.y)
	var speed := 0.0
	if uv.x >= 0.0:
		if _last_mouse.x >= 0.0:
			speed = uv.distance_to(_last_mouse)
		# 只要在动就注入（每帧），慢速移动也能拖出连续水痕
		if _last_mouse.x < 0.0 or speed > 0.0005:
			mouse_uv = uv
		_last_mouse = uv
	else:
		_last_mouse = Vector2(-1.0, -1.0)

	# 环境落点：让水面平时也在轻轻荡
	_drop_timer += delta
	if _drop_timer >= _next_drop:
		_drop_timer = 0.0
		_next_drop = randf_range(1.0, 2.2)
		_pending_drop = Vector2(randf(), randf())

	var amp := 2.20 * clampf(speed / 0.010, 0.60, 2.0)
	for m in [_mat_a, _mat_b]:
		m.set_shader_parameter("mouse", mouse_uv)
		m.set_shader_parameter("mouse_amp", amp)
		m.set_shader_parameter("drop", _pending_drop)
	_pending_drop = Vector2(-1.0, -1.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_SPACE:
				_on = not _on
				_title.material = _title_mat if _on else null
			KEY_ESCAPE:
				get_tree().quit()
