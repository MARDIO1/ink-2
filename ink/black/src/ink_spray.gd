extends Node2D
## 黑墨喷溅：伤害落地时在受击点溅出一簇墨，随伤害放大范围，之后慢慢淡掉。
##
## **纯 shader**：没有粒子、没有贴图、没有刚体。整个效果就是一张盖住喷溅范围的四
## 边形 + 一个片元着色器；每次喷溅只在着色器里存一条 (位置, 方向, 出生时刻, 强度)，
## 墨滴的轨迹是解析解 —— 不需要逐帧模拟，也不需要存轨迹点。
##
## 喷出方向 = 受击方被推的方向（砸地朝上、被侧撞朝撞击方向），见 impact_damage._record_hit()。
##
## 纯表现：不进物理世界、不动墨水账。受击方是玩家时按黑墨喷（InkHealth 只扣黑墨），
## 其余按受击处的材料色 —— 材料不是墨水就不喷。
## 由 SimulationRuntime 通过 observe_damage 能力接口调用，本脚本不认识伤害规则。

#region 依赖
const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const SPLAT_SHADER := preload("res://ink/black/asset/ink_splat.gdshader")
## 着色器里同时能演的喷溅条数。⚠️ 必须和 ink_splat.gdshader 里的数组长度 8 一致。
const MAX_SPLATS := 8
#endregion


#region 配置
## 低于该等效像素伤害不喷：轻碰不该溅。
@export var min_damage: float = 2.0
## 强度 = 1 的伤害档位。再往上强度继续涨（对数）。
@export var reference_damage: float = 40.0
## 强度封顶。默认 1.0 = 参考伤害就是最猛的表现，再重的伤害也不会更强（免得特效炸飞）。
## 想让巨额伤害还能更强就把它调大，那时对数增长段才生效。
@export var max_strength: float = 1.0
## 强度曲线指数。>1 = 前段更平缓（斜率更小），轻中伤不会一上来就满；到 reference_damage 仍是 1。
@export var strength_curve: float = 1.6
## 满配时的初速区间（px/s），和寿命一起决定喷溅范围。
@export var min_speed: float = 90.0
@export var max_speed: float = 260.0
## 喷溅锥角（度），围绕受击表面朝外的方向。
@export_range(0.0, 180.0, 1.0) var spread_degrees: float = 62.0
## 粒子寿命（秒）；越大消去越慢。
@export_range(0.1, 4.0, 0.05) var lifetime: float = 1.35
## 视觉重力（px/s²），不进物理世界。墨滴要飞得出去：太大就变成"刚喷出来就往下掉"。
@export var gravity: float = 280.0
## 墨的不透明度。<1 就是「带点透明的黑」：单层能透出底色，叠得密的地方才更黑。
@export_range(0.05, 1.0, 0.01) var opacity: float = 0.9
## 墨滴方块的边长上限（px）。硬边小方块，着色器里再取整到 1..它。
@export var drop_size: float = 5.0
## 刚过阈值 / 满配时的墨点数量；中间按伤害线性插值。
@export_range(1, 64, 1) var drop_min: int = 12
@export_range(1, 64, 1) var drop_max: int = 48
## 整簇的透明渐变强度：0 = 整簇一样淡，1 = 只有落点浓、飞到远处几乎看不见。
@export_range(0.0, 1.0, 0.01) var gradient: float = 0.35
## 方块自转速度（弧度/秒）。每颗的出生角度随机、转向和快慢也各不相同。
@export var spin_speed: float = 2.5
## 同一处的重复伤害抑制：格边长（px）与冷却（秒）。
@export var dedup_cell: float = 24.0
@export_range(0.0, 1.0, 0.01) var dedup_seconds: float = 0.12
## 一个固定步最多喷几簇；同一步里碎裂会产生大量事件，只演最大的几次。
@export_range(1, 32, 1) var max_sprays_per_step: int = 4
#endregion


#region 状态
var _rect: ColorRect
var _material: ShaderMaterial
## 正在演的喷溅，最多 MAX_SPLATS 条；满了顶掉最老的一条。
var _splats: Array = []
var _time: float = 0.0
var _head := PackedVector4Array()
var _tail := PackedVector4Array()
var _tint := PackedVector4Array()
## 受击格 -> 上次喷溅时刻（毫秒）。
var _last_spray_ms: Dictionary = {}
## 已喷出的簇数。着色器在 headless 下画不出来，「到底喷没喷」只能靠它变成可断言的事实。
var sprayed_count: int = 0
#endregion


#region 生命周期
func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = SPLAT_SHADER
	_head.resize(MAX_SPLATS)
	_tail.resize(MAX_SPLATS)
	_tint.resize(MAX_SPLATS)
	_rect = _build_rect()
	add_child(_rect)
	_push_shader_params()


## 整个效果就是这一张四边形：着色器按 rect_origin / rect_size 把 UV 还原成世界坐标。
## ⚠️ mouse_filter 必须是 IGNORE：画布落笔会查 gui_get_hovered_control()，
##    一张盖住半屏的 Control 会把画笔全挡掉。
func _build_rect() -> ColorRect:
	var rect := ColorRect.new()
	rect.color = Color.WHITE
	rect.material = _material
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	return rect


## 只在 _ready 推一次：这些是着色器侧的固定形状参数。
func _push_shader_params() -> void:
	_material.set_shader_parameter("gravity", gravity)
	_material.set_shader_parameter("min_speed", min_speed)
	_material.set_shader_parameter("max_speed", max_speed)
	_material.set_shader_parameter("spread", deg_to_rad(spread_degrees))
	_material.set_shader_parameter("drop_size", drop_size)
	_material.set_shader_parameter("drop_min", float(drop_min))
	_material.set_shader_parameter("drop_max", float(drop_max))
	_material.set_shader_parameter("gradient", gradient)
	_material.set_shader_parameter("spin_speed", spin_speed)
#endregion


#region 规则接口
## SimulationRuntime 在每个固定步后调用；只生成表现，返回前不改任何物理状态。
func observe_damage(_context: Dictionary, hits: Array) -> void:
	if hits.is_empty():
		return
	var candidates: Array = []
	for hit in hits:
		if _has_damage(hit):
			candidates.append(hit)
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["amount"]) > float(b["amount"]))
	var sprayed: int = 0
	for hit in candidates:
		if sprayed >= max_sprays_per_step:
			break
		if not _claim(hit):
			continue
		_spray(hit)
		sprayed += 1
#endregion


#region 事件判定
## 伤害够大、且受击处认得出是墨水，才值得演。
func _has_damage(hit: Dictionary) -> bool:
	return float(hit.get("amount", 0.0)) >= min_damage and _ink_color(hit).a > 0.0


## 认领一次事件：同一处在冷却内只喷一次，避免碎裂的连续子步连喷。
func _claim(hit: Dictionary) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	var key := _cell_key(hit["position"])
	if now_ms - int(_last_spray_ms.get(key, -1000000)) < roundi(dedup_seconds * 1000.0):
		return false
	_last_spray_ms[key] = now_ms
	if _last_spray_ms.size() > 256:
		_prune_history(now_ms)
	return true


## 玩家只扣黑墨，所以玩家挨打永远喷黑墨；其余按受击处材料，不是墨水返回透明。
func _ink_color(hit: Dictionary) -> Color:
	if bool(hit.get("player", false)):
		return InkPalette.color_of(InkPalette.BLACK)
	return InkPalette.color_for_material_id(int(hit.get("material", 0)))


func _cell_key(position: Vector2) -> Vector2i:
	return Vector2i((position / maxf(dedup_cell, 1.0)).floor())


func _prune_history(now_ms: int) -> void:
	var keep_ms: int = maxi(roundi(dedup_seconds * 2000.0), 1000)
	for key in _last_spray_ms.keys():
		if now_ms - int(_last_spray_ms[key]) > keep_ms:
			_last_spray_ms.erase(key)
#endregion


#region 喷溅
## 伤害 -> 强度：阈值以下 0，reference_damage 处 1，再往上按对数继续涨，到 max_strength 封顶。
## ratio ≤ 1 段用 pow(ratio, strength_curve) 压平：斜率小了，轻中伤不会一上来就满。
## 对数段也按 strength_curve 放缓（1 + ln(ratio)/curve）。函数连续、单调，只在参考点有个缓弯。
## 各项表现各自还有更细的上限：颗数 ≤ drop_max，速度夹在 1.6 倍强度。
func _strength_for(amount: float) -> float:
	var over: float = amount - min_damage
	if over <= 0.0:
		return 0.0
	var ratio: float = over / maxf(reference_damage, 0.001)
	var curve: float = maxf(strength_curve, 0.01)
	var strength: float = pow(ratio, curve) if ratio <= 1.0 else 1.0 + log(ratio) / curve
	return minf(strength, max_strength)


## 用一条着色器记录演一次伤害：强度、寿命、方向、颜色都进 splat 表。
func _spray(hit: Dictionary) -> void:
	var strength: float = _strength_for(float(hit["amount"]))
	var color: Color = _ink_color(hit)
	color.a *= opacity
	if _splats.size() >= MAX_SPLATS:
		_splats.pop_front()
	_splats.append({"center": hit["position"], "direction": hit["direction"],
		"strength": strength, "life": lifetime * lerpf(0.65, 1.0, strength),
		"birth": _time, "seed": randf(), "color": color})
	sprayed_count += 1


## 推进时间、丢掉演完的喷溅，再把 splat 表和四边形范围推给着色器。
func _process(delta: float) -> void:
	_time += delta
	var alive: Array = []
	for splat in _splats:
		if _time - float(splat["birth"]) <= float(splat["life"]):
			alive.append(splat)
	_splats = alive
	if _splats.is_empty():
		_rect.visible = false
		return
	_push_uniforms()


func _push_uniforms() -> void:
	var bounds := Rect2()
	for i in _splats.size():
		var splat: Dictionary = _splats[i]
		var color: Color = splat["color"]
		var direction: Vector2 = splat["direction"]
		_head[i] = Vector4(splat["center"].x, splat["center"].y, splat["birth"], splat["strength"])
		_tail[i] = Vector4(direction.x, direction.y, splat["life"], splat["seed"])
		_tint[i] = Vector4(color.r, color.g, color.b, color.a)
		var reach := _reach_rect(splat)
		bounds = reach if i == 0 else bounds.merge(reach)
	# 只画屏幕里那部分：喷溅范围可以比一屏还大，着色器没必要为看不见的地方算。
	bounds = bounds.intersection(_visible_rect())
	if not bounds.has_area():
		_rect.visible = false
		return
	_rect.position = bounds.position
	_rect.size = bounds.size
	_rect.visible = true
	_material.set_shader_parameter("splat_count", _splats.size())
	_material.set_shader_parameter("time", _time)
	_material.set_shader_parameter("rect_origin", bounds.position)
	_material.set_shader_parameter("rect_size", bounds.size)
	_material.set_shader_parameter("splat_head", _head)
	_material.set_shader_parameter("splat_tail", _tail)
	_material.set_shader_parameter("splat_tint", _tint)


## 这一坨墨可能波及的世界范围：飞得最远的那颗 + 重力下落 + 半径余量。
func _reach_rect(splat: Dictionary) -> Rect2:
	var speed: float = max_speed * lerpf(0.35, 1.0, float(splat["strength"]))
	var life: float = float(splat["life"])
	var reach: float = speed * life + 0.5 * gravity * life * life + drop_size
	var center: Vector2 = splat["center"]
	return Rect2(center - Vector2(reach, reach), Vector2.ONE * reach * 2.0)


## 相机能看到的世界范围；没有相机就退回视口大小。
func _visible_rect() -> Rect2:
	var camera: Camera2D = get_viewport().get_camera_2d()
	if camera == null:
		return Rect2(Vector2.ZERO, get_viewport_rect().size)
	var size: Vector2 = camera.get_viewport_rect().size / camera.zoom
	return Rect2(camera.get_screen_center_position() - size * 0.5, size)
#endregion
