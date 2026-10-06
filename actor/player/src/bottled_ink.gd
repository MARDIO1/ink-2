@tool
extends Sprite2D
## 瓶子里的墨水 —— 玩家体内的**假液体**图层。
##
## ## 为什么是 shader 而不是逐帧重画一张液体贴图
##
## 液面必须**世界竖直**（跟着重力走水平），而玩家会翻跟头。
## 逐帧在玩家局部像素里重画「液面水平」的贴图，等于每帧扫一遍上千像素，
## 而且玩家一转整张就作废。所以这里一个像素都不动：
## 直接复用**兄弟 Visual 已经烘好的剪影贴图**当遮罩，在 shader 里按世界向下方向
## 把液面以上的像素丢掉 —— 等价于「一个比玩家大的方形液体 ∩ 玩家区域」。
##
## ## 边界：墨水**不进物理像素**
##
## 本节点不是形状节点（没有 build_shape / get_shape），PixelBody2D.collect_shapes()
## 与 PixelSprite2D._collect() 都看不到它 —— 玩家的碰撞形状、像素数、连通性、
## 破坏行为完全不受墨水量影响。
##
## 墨水的质量走**已有的合成质量管线**：写 shape.density_scale -> PWorld.refresh_mass()
## -> 密度推给 Rapier 并重算碰撞体质量。
## ⚠️ 绝不直接写 body.mass：GDScript 侧与 Rapier 侧的质量一旦分叉，抓取这类按 mass
##    算力的控制器会过冲成振荡（见 native/rapier_bridge/src/lib.rs 里 rb_body_set_density
##    的墓碑注释：密度差 7.8 倍时一步过冲 8.4 倍，±280 抽搐）。
##
## ⚠️ 代价：改一次质量 = 逐像素扫描 + 贪心分解 + 重推密度（玩家 4 千多像素约 2~3 ms），
##    所以按 mass_quantum 量化，只在液面变化超过阈值时才重算 —— 不是每帧。

const SHADER := preload("res://actor/player/src/bottled_ink.gdshader")

@export_group("来源")
## 玩家物理节点（持有 PBody 的那个）。
@export var body_path := NodePath("..")
## 剪影遮罩：直接用它的贴图和 offset，不重新烘焙。
@export var mask_path := NodePath("../Visual")
## 像素世界节点：取重力方向，并用于重算质量。
@export var world_path := NodePath("../../")

@export_group("墨水")
## 液面高度比例：0 = 空瓶（不画），1 = 满到剪影沿重力方向的上沿。
@export_range(0.0, 1.0) var fill := 1.0
## 满瓶墨水的等效质量（引擎质量单位）。0 = 墨水只画，不参与质量。
@export var capacity_mass := 0.0
## 墨水颜色。
@export var ink_color := Color(0.09, 0.11, 0.28, 1.0)
## 质量重算的量化粒度：density_scale 变化小于它就不重算。
@export_range(0.0, 1.0) var mass_quantum := 0.02

var _body = null
var _mask: Sprite2D = null
var _material: ShaderMaterial = null
## 未装墨水时的基准质量（density_scale = 1）。只取一次。
var _base_mass := 0.0
var _applied_scale := -1.0


func _ready() -> void:
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture = null
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("ink_color", ink_color)
	material = _material
	set_physics_process(not Engine.is_editor_hint())
	_sync_visual()


func _physics_process(_delta: float) -> void:
	_sync_visual()
	_sync_mass()


## 位置/旋转/贴图全部抄兄弟 Visual —— 一份真源，不用再写一遍像素世界的坐标换算。
func _sync_visual() -> void:
	var node = get_node_or_null(body_path)
	if node == null or node.body == null:
		visible = false
		return
	_body = node.body
	if _mask == null:
		_mask = get_node_or_null(mask_path) as Sprite2D
	if _mask == null or _mask.texture == null:
		visible = false
		return
	global_position = _mask.global_position
	global_rotation = _mask.global_rotation
	offset = _mask.offset
	if texture != _mask.texture:
		texture = _mask.texture
	visible = fill > 0.0
	if not visible:
		return
	var down: Vector2 = _down_world()
	var size: Vector2 = _mask.texture.get_size()
	var corners: Array[Vector2] = [
		offset,
		offset + Vector2(size.x, 0.0),
		offset + Vector2(0.0, size.y),
		offset + size,
	]
	var lo := INF
	var hi := -INF
	for corner: Vector2 in corners:
		var t: float = (global_position + corner.rotated(global_rotation)).dot(down)
		lo = minf(lo, t)
		hi = maxf(hi, t)
	# 液面沿世界向下从剪影最高点走 fill 比例 —— 液面永远世界水平。
	var surface: float = hi - fill * (hi - lo)
	_material.set_shader_parameter("down_local", down.rotated(-global_rotation))
	_material.set_shader_parameter("level", surface - global_position.dot(down))


## 世界「向下」单位向量（全局坐标）。取物理世界的重力方向，取不到就退化成 +Y。
func _down_world() -> Vector2:
	var pw = get_node_or_null(world_path)
	if pw != null and "world" in pw and pw.world != null:
		var g: Vector2 = pw.world.gravity
		if g.length_squared() > 0.0:
			return (pw.global_transform.basis_xform(g)).normalized()
	return Vector2(0.0, 1.0)


## 墨水按**当前液面**进入合成质量：写 density_scale 后走世界的正规重算路径。
func _sync_mass() -> void:
	if _body == null:
		return
	if _base_mass <= 0.0:
		_base_mass = _body.mass
	if capacity_mass <= 0.0 or _base_mass <= 0.0:
		return
	var target: float = 1.0 + fill * capacity_mass / _base_mass
	if absf(target - _applied_scale) < mass_quantum:
		return
	_applied_scale = target
	for s in _body.shapes:
		s.density_scale = target
	var pw = get_node_or_null(world_path)
	if pw != null and "world" in pw and pw.world != null:
		pw.world.refresh_mass(_body)
