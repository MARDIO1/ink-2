@tool
extends Sprite2D
## 瓶子里的墨水 —— 玩家体内的**假液体**图层。
##
## ## 怎么画的：瓶内遮罩 + 专用液位 shader
##
## 本节点的贴图是**瓶内遮罩**（alpha 1 = 瓶内）。专用 shader 用贴图 UV 对瓶内空腔
## 做投影，并用与 HUD 相同的 InkHealth.ratio() 裁出液面以下部分。重力方向会转换到
## 角色局部坐标，所以玩家躺下 / 倒立时液面仍保持世界水平。
## 液位判据只使用 UV / 贴图像素坐标，不再混用 VERTEX 帧缓冲坐标。
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
## 旧版液面方块路径；节点保留用于场景兼容，但已隐藏，不参与渲染。
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
## 实际瓶内空腔在贴图中的范围。液面只在这个范围内按 InkHealth 比例换算，
## 避免瓶盖、角色外轮廓和透明留白把液面行程拉长。
var _interior_rect := Rect2()


func _ready() -> void:
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# HUD 能在暂停/绘图界面中通过信号立即刷新；体内液面也必须保持相同行为。
	# ALWAYS 只影响显示同步，不会推进玩家物理。
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_physics_process(not Engine.is_editor_hint())
	_health = get_node_or_null(health_path)
	if _health != null and _health.has_signal("changed"):
		_health.changed.connect(_on_health_changed)
	_liquid = get_node_or_null(liquid_path)
	if _liquid != null:
		# 中间液位不再依赖 clip_children；保留节点只为旧场景兼容。
		_liquid.visible = false
	if _liquid != null and _liquid.texture == null:
		var one := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
		one.fill(Color.WHITE)
		_liquid.texture = ImageTexture.create_from_image(one)
		_liquid.centered = false
		_liquid.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sync_visual()


## 与 HUD 监听同一个 changed 信号。这样画布扣墨时，即使场景树暂停或还没到下一物理帧，
## 角色体内液面也会立即读取最新的 InkHealth.ratio()。
func _on_health_changed() -> void:
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
	_fill = _health.ratio() if _health != null and _health.has_method("ratio") else 1.0
	visible = _fill > 0.0
	if not visible:
		return
	_update_liquid_material()


## 专用 shader 直接裁切瓶内遮罩。这样 0..1 的中间液位也会真实改变渲染结果，
## 不再依赖「1x1 子精灵 + clip_children」这个在顶点 shader 下失效的组合。
## down 转到角色局部坐标后再投影，所以玩家翻转时液面仍保持世界水平。
func _update_liquid_material() -> void:
	var shader_material := material as ShaderMaterial
	if shader_material == null or not _interior_rect.has_area():
		return
	var down_local := _down_world().rotated(-global_rotation).normalized()
	var fill_rect := _interior_rect
	var corners: Array[Vector2] = [
		fill_rect.position,
		fill_rect.position + Vector2(fill_rect.size.x, 0.0),
		fill_rect.position + Vector2(0.0, fill_rect.size.y),
		fill_rect.end,
	]
	var lo := INF
	var hi := -INF
	for corner: Vector2 in corners:
		var projected := corner.dot(down_local)
		lo = minf(lo, projected)
		hi = maxf(hi, projected)
	shader_material.set_shader_parameter("fill", clampf(_fill, 0.0, 1.0))
	shader_material.set_shader_parameter("liquid_down_local", down_local)
	shader_material.set_shader_parameter("projection_low", lo)
	shader_material.set_shader_parameter("projection_high", hi)


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
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	for i in w * h:
		if reached[i] == 0 and rgba[i * 4 + 3] == 0:
			out[i * 4 + 3] = 255
			var px := i % w
			var py := i / w
			min_x = mini(min_x, px)
			min_y = mini(min_y, py)
			max_x = maxi(max_x, px)
			max_y = maxi(max_y, py)
	if max_x >= min_x and max_y >= min_y:
		_interior_rect = Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x + 1, max_y - min_y + 1))
	else:
		_interior_rect = Rect2()
	return ImageTexture.create_from_image(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out))


## 泛洪的一步：空像素且没走到过就标记入栈。
func _push_empty(reached: PackedByteArray, stack: PackedInt32Array, rgba: PackedByteArray, idx: int) -> void:
	if reached[idx] != 0 or rgba[idx * 4 + 3] != 0:
		return
	reached[idx] = 1
	stack.append(idx)
#endregion
