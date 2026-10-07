@tool
extends Sprite2D
## 瓶子里的墨水 —— 玩家体内的**假液体**图层。
##
## ## 怎么画的：引擎的「裁剪子节点」，一个 shader 都没有
##
## 本节点自己不画像素：它的贴图是**瓶内遮罩**（alpha 1 = 瓶内），
## `clip_children = 仅裁剪` 让它只当模板。唯一的子节点 `Liquid` 是一个
## **世界轴对齐**的大方块，顶边就是液面；引擎把方块按本节点的 alpha 裁一遍，
## 屏幕上剩下的就是「方块 ∩ 瓶内」。所以：
##   · 液面永远世界水平 —— 方块不跟玩家转，玩家翻跟头液面也不翻；
##   · 玩家躺下 / 倒立，瓶内遮罩跟着剪影转，墨水照灌；
##   · 全程没有逐像素坐标判别，也就没有「拿帧缓冲坐标当局部坐标」那类坑
##     （上一版 shader 正是死在 VERTEX 上：液面从来不生效，往左躺整层消失）。
##
## 瓶内遮罩由 _build_interior() 对剪影贴图的**封闭空腔**做一次四边界泛洪算出：
## 描边（不透明）、瓶盖外的空白、剪影外都不算瓶内，所以角色永远是黑线稿，
## 墨水只出现在瓶身内部。剪影一变（被打掉像素）就重算。
##
## ## 边界：墨水**不进物理像素**
##
## 本节点不是形状节点（没有 build_shape / get_shape），`Liquid` 也一样 ——
## PixelBody2D.collect_shapes() 与 PixelSprite2D._collect() 都看不到它们。
## 玩家的碰撞形状、像素数、连通性、破坏行为完全不受墨水量影响。
##
## 墨水的质量走**已有的合成质量管线**：写 shape.density_scale -> PWorld.refresh_mass()
## -> 密度推给 Rapier 并重算碰撞体质量。
## ⚠️ 绝不直接写 body.mass：GDScript 侧与 Rapier 侧的质量一旦分叉，抓取这类按 mass
##    算力的控制器会过冲成振荡（见 native/rapier_bridge/src/lib.rs 里 rb_body_set_density
##    的墓碑注释：密度差 7.8 倍时一步过冲 8.4 倍，±280 抽搐）。
##
## ⚠️ 代价：改一次质量 = 逐像素扫描 + 贪心分解 + 重推密度（玩家 4 千多像素约 2~3 ms），
##    所以按 mass_quantum 量化，只在液面变化超过阈值时才重算 —— 不是每帧。

@export_group("来源")
## 玩家物理节点（持有 PBody 的那个）。
@export var body_path := NodePath("..")
## 剪影来源：抄它的贴图 / offset / 变换，不重新烘焙。
@export var mask_path := NodePath("../Visual")
## 液面方块：本节点的子节点，变换每帧按世界竖直重算。
@export var liquid_path := NodePath("Liquid")
## 像素世界节点：取重力方向，并用于重算质量。
@export var world_path := NodePath("../../")

@export_group("墨水")
## 墨水生命值节点：液面比例每帧从它的 ratio() 读，本图层不再自己存 fill。
@export var health_path := NodePath("../InkHealth")
## 满瓶墨水的等效质量（引擎质量单位）。0 = 墨水只画，不参与质量。
@export var capacity_mass := 0.0
## 质量重算的量化粒度：density_scale 变化小于它就不重算。
@export_range(0.0, 1.0) var mass_quantum := 0.02

var _body = null
var _health = null
var _mask: Sprite2D = null
var _liquid: Sprite2D = null
## 本帧的液面比例：从 InkHealth 同步来，供液面与质量共用。
var _fill := 1.0
## 未装墨水时的基准质量（density_scale = 1）。只取一次。
var _base_mass := 0.0
var _applied_scale := -1.0
## 剪影贴图 —— 注意不是本节点自己的贴图，那已经是瓶内遮罩了。
var _src_tex: Texture2D = null
## 瓶内遮罩的缓存键。剪影贴图和外接框不变就不重算。
var _interior_key := ""


func _ready() -> void:
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_physics_process(not Engine.is_editor_hint())
	_health = get_node_or_null(health_path)
	_liquid = get_node_or_null(liquid_path)
	if _liquid != null and _liquid.texture == null:
		var one := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
		one.fill(Color.WHITE)
		_liquid.texture = ImageTexture.create_from_image(one)
		_liquid.centered = false
		_liquid.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sync_visual()


func _physics_process(_delta: float) -> void:
	_sync_visual()
	_sync_mass()


## 位置 / 旋转 / offset 全部抄兄弟 Visual —— 一份真源，不用再写一遍像素世界的坐标换算。
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
	if _src_tex != _mask.texture:
		_src_tex = _mask.texture
		_interior_key = ""
	_ensure_interior()
	_fill = _health.ratio() if _health != null else 1.0
	visible = _fill > 0.0
	if not visible:
		return
	_place_liquid()


## 液面 = 世界水平面。方块整个摆在世界系里：局部 X 轴 = 世界水平、局部 Y 轴 = 世界向下、
## 左上角压在液面上。方块取剪影对角线的两倍，保证罩得住整只瓶子。
func _place_liquid() -> void:
	if _liquid == null:
		return
	var down: Vector2 = _down_world()
	var right := Vector2(-down.y, down.x)
	var size: Vector2 = _src_tex.get_size()
	var corners: Array[Vector2] = [
		offset,
		offset + Vector2(size.x, 0.0),
		offset + Vector2(0.0, size.y),
		offset + size,
	]
	var lo := INF
	var hi := -INF
	var mid := Vector2.ZERO
	for corner: Vector2 in corners:
		var p: Vector2 = global_position + corner.rotated(global_rotation)
		mid += p
		lo = minf(lo, p.dot(down))
		hi = maxf(hi, p.dot(down))
	mid /= 4.0
	# 液面沿世界向下从剪影最高点走 _fill 比例 —— 液面永远世界水平。
	var surface: float = hi - _fill * (hi - lo)
	var span: float = size.length() * 2.0
	var origin: Vector2 = right * (mid.dot(right) - span * 0.5) + down * surface
	_liquid.global_transform = Transform2D(right * span, down * span, origin)


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
	var target: float = 1.0 + _fill * capacity_mass / _base_mass
	if absf(target - _applied_scale) < mass_quantum:
		return
	_applied_scale = target
	for s in _body.shapes:
		s.density_scale = target
	var pw = get_node_or_null(world_path)
	if pw != null and "world" in pw and pw.world != null:
		pw.world.refresh_mass(_body, Callable(pw, "_density_of"))


#region 瓶内遮罩
## 遮罩只在**剪影真的变了**时重算：Visual 的 _sig 已经把「外接 + revision」都编进去了，
## 所以破坏 / 挖洞 / 掉像素都会换键；每帧只是比一个字符串，代价是零。
func _ensure_interior() -> void:
	if _src_tex == null:
		return
	var size: Vector2 = _src_tex.get_size()
	var key := "%d:%d:%d:%s:%s" % [_src_tex.get_instance_id(), int(size.x), int(size.y), offset,
		_mask.get("_sig")]
	if key == _interior_key:
		return
	_interior_key = key
	texture = _build_interior(_src_tex)


## 瓶内 = 从贴图四边泛洪**到不了**的空像素（被剪影围死的那部分），做成 alpha 遮罩：
## alpha 1 = 瓶内，0 = 别处。描边自己是实心像素，不算瓶内，所以它永远保持黑线稿。
## clip_children 只看 alpha，所以 RGB 留 0 就行。
func _build_interior(src_tex: Texture2D) -> ImageTexture:
	var img: Image = src_tex.get_image()
	if img == null:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var rgba := img.get_data()
	var reached := PackedByteArray()
	reached.resize(w * h)
	var stack := PackedInt32Array()
	for x in w:
		_push_empty(reached, stack, rgba, x)
		_push_empty(reached, stack, rgba, (h - 1) * w + x)
	for y in h:
		_push_empty(reached, stack, rgba, y * w)
		_push_empty(reached, stack, rgba, y * w + w - 1)
	while not stack.is_empty():
		var sp := stack.size() - 1
		var p := stack[sp]
		stack.resize(sp)
		var px := p % w
		var py := p / w
		if px > 0:
			_push_empty(reached, stack, rgba, p - 1)
		if px + 1 < w:
			_push_empty(reached, stack, rgba, p + 1)
		if py > 0:
			_push_empty(reached, stack, rgba, p - w)
		if py + 1 < h:
			_push_empty(reached, stack, rgba, p + w)
	var out := PackedByteArray()
	out.resize(w * h * 4)
	for i in w * h:
		if reached[i] == 0 and rgba[i * 4 + 3] == 0:
			out[i * 4 + 3] = 255
	return ImageTexture.create_from_image(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out))


## 泛洪的一步：空像素且没走到过就标记入栈。
func _push_empty(reached: PackedByteArray, stack: PackedInt32Array, rgba: PackedByteArray, idx: int) -> void:
	if reached[idx] != 0 or rgba[idx * 4 + 3] != 0:
		return
	reached[idx] = 1
	stack.append(idx)
#endregion
