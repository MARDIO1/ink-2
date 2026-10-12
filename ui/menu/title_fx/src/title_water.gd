extends Node
## 给主菜单标题加交互水面。挂在 menu.tscn 的 Title 下面即可（父节点就是要作用的 TextureRect）。
##
## 只引用模块 asset 下的 shader。ViewportTexture 不能自引用，
## 因此两张 SubViewport 交替读取对方的高度场，每帧推进一次波动模拟。

const SIM_SHADER := "res://ui/menu/title_fx/asset/ripple_sim.gdshader"
const TITLE_SHADER := "res://ui/menu/title_fx/asset/ripple_title.gdshader"

@export var enabled := true
@export var sim_size := Vector2i(192, 118)
## 最小鼠标位移（UV）；阈值过大会使慢速拖动的涟漪不连续。
@export var mouse_step := 0.0005
## 参考速度：移动速度等于它时按原强度注入；更快更强、更慢更弱
@export var mouse_speed_ref := 0.010
## 平时也在轻轻荡：每隔这么久随机落一颗
@export var ambient_min := 1.0
@export var ambient_max := 2.2

var _title: TextureRect
var _mat_a: ShaderMaterial
var _mat_b: ShaderMaterial
var _title_mat: ShaderMaterial
var _last_mouse := Vector2(-1.0, -1.0)
var _drop_timer := 0.0
var _next_drop := 1.5
var _pending_drop := Vector2(-1.0, -1.0)


## KEEP_ASPECT_CENTERED 的 shader UV 对应居中的贴图绘制区，不包含矩形留白。
func _local_to_uv(local: Vector2) -> Vector2:
	var size := _title.size
	if size.x <= 0.0 or size.y <= 0.0:
		return Vector2(-1.0, -1.0)
	if _title.stretch_mode != TextureRect.STRETCH_KEEP_ASPECT_CENTERED or _title.texture == null:
		return Vector2(local.x / size.x, local.y / size.y)
	var ta := float(_title.texture.get_width()) / float(_title.texture.get_height())
	var ra := size.x / size.y
	var drawn := Vector2(size.x, size.x / ta) if ta > ra else Vector2(size.y * ta, size.y)
	var off := (size - drawn) * 0.5
	var uv := (local - off) / drawn
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return Vector2(-1.0, -1.0)   # 落在留白上，不注入
	return uv


func _make_sim() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = sim_size
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	# SubViewport 不是 Control，子 ColorRect 必须显式设置尺寸，不能依赖锚点。
	rect.position = Vector2.ZERO
	rect.size = Vector2(sim_size)
	var mat := ShaderMaterial.new()
	mat.shader = load(SIM_SHADER)
	mat.set_shader_parameter("sim_size", Vector2(sim_size))
	rect.material = mat
	vp.add_child(rect)
	return vp


func _ready() -> void:
	_title = get_parent() as TextureRect
	if _title == null or not enabled:
		set_process(false)
		return

	var vp_a := _make_sim()
	var vp_b := _make_sim()
	_mat_a = (vp_a.get_child(0) as ColorRect).material as ShaderMaterial
	_mat_b = (vp_b.get_child(0) as ColorRect).material as ShaderMaterial
	add_child(vp_a)
	add_child(vp_b)
	# A 读 B、B 读 A（自引用在 Godot 里不成立）
	_mat_a.set_shader_parameter("ripple_tex", vp_b.get_texture())
	_mat_b.set_shader_parameter("ripple_tex", vp_a.get_texture())

	_title_mat = ShaderMaterial.new()
	_title_mat.shader = load(TITLE_SHADER)
	_title_mat.set_shader_parameter("sim_size", Vector2(sim_size))
	_title_mat.set_shader_parameter("ripple_tex", vp_b.get_texture())   # 后渲染的那张 = 最新
	_title.material = _title_mat


func _process(delta: float) -> void:
	if _mat_a == null or _title == null:
		return
	var size := _title.size
	if size.x <= 0.0 or size.y <= 0.0:
		return

	# 只在鼠标移动时注入，避免静止光标持续改变水面。
	var mouse_uv := Vector2(-1.0, -1.0)
	var uv := _local_to_uv(_title.get_local_mouse_position())
	var speed := 0.0
	if uv.x >= 0.0:
		if _last_mouse.x >= 0.0:
			speed = uv.distance_to(_last_mouse)
		# 只要在动就注入（每帧），这样慢速移动也能拖出连续的水痕
		if _last_mouse.x < 0.0 or speed > mouse_step:
			mouse_uv = uv
		_last_mouse = uv
	else:
		_last_mouse = Vector2(-1.0, -1.0)

	# 环境落点：让水面平时也在轻轻荡
	_drop_timer += delta
	if _drop_timer >= _next_drop:
		_drop_timer = 0.0
		_next_drop = randf_range(ambient_min, ambient_max)
		_pending_drop = Vector2(randf(), randf())   # 绘制区 UV，天然落在贴图范围内

	# 注入强度跟着移动速度走：慢慢划是细水痕，快速划过是明显的波
	var amp := 2.20 * clampf(speed / maxf(mouse_speed_ref, 1e-5), 0.60, 2.0)
	_mat_a.set_shader_parameter("mouse", mouse_uv)
	_mat_b.set_shader_parameter("mouse", mouse_uv)
	_mat_a.set_shader_parameter("mouse_amp", amp)
	_mat_b.set_shader_parameter("mouse_amp", amp)
	_mat_a.set_shader_parameter("drop", _pending_drop)
	_mat_b.set_shader_parameter("drop", _pending_drop)
	_pending_drop = Vector2(-1.0, -1.0)
