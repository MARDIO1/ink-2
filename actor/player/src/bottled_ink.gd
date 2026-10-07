@tool
extends Sprite2D
## 瓶子里的墨水 —— 玩家体内的液体图层。
##
## ## 怎么画的：PBF 粒子流体，烘成一张贴图
##
## 本节点自己就是那张贴图：容器内每格要么是"玻璃色"（空），要么是"墨色"（有液体）。
## 液体由 addons/pixel_destruction/fluid/fluid_pbf.gd 模拟 —— 纯表现，不进物理像素。
## 算法与参数见那个文件；这里只管"容器是哪一块、重力朝哪、颜色怎么上"。
##
## ## ⚠️ 本节点画在线稿**下面**（z_index = -1）
##
## 所以三件事必须同时成立，少一件就看不见墨水：
##   1. 本节点的 z_index < Visual 的（见 player.tscn）；
##   2. Visual 的**瓶身填充（材质 5）必须是透明的** —— 它是 58x34 的实心块，
##      不透明就会把墨水整个盖住（见 player.tscn 里 Visual.palette 的第 6 项）；
##   3. 空瓶时那块地方由本节点的**玻璃色**补上，否则角色看起来是漏的。
## 黑线稿（材质 2）在线稿层，永远压在墨水上面 —— 所以脸不会被淹掉。
##
## ## 容器 = 整个瓶身（含身体块），不是"被围住的透明像素"
##
## 上一版用的是"四边泛洪到不了的透明像素"。那在角色身上得到的是一个**环**：
## 瓶身中间那块身体是**不透明**的（player_body_0 的白色填充），所以"被围住的空像素"
## 只剩它外面那一圈，而侧通道只有 1 像素宽 —— 装不住任何液体。
##
## 现在分四步（见 _build_container）：
##   ① 从四边泛洪出"外面"（只走透明像素）；
##   ② "被围住的透明像素" = 里面那些；
##   ③ 取②里**最大连通分量**的外接框 —— 这一步是为了**排除头/瓶盖**：
##      头部的线稿空腔和身体是连着的，不框住的话墨水会灌进脑袋；
##   ④ 框内所有"不是外面"的格子都算容器 —— 于是不透明的身体块被并进来，
##      得到一个**没有洞的实心瓶身**（PBF 的 solidMask 支持任意形状，见引擎侧说明）。
##
## ## 边界：墨水不进物理像素
##
## 本节点不是形状节点（没有 build_shape / get_shape），PixelBody2D.collect_shapes()
## 与 PixelSprite2D._collect() 都看不到它。玩家的碰撞形状、像素数、连通性、
## 破坏行为完全不受墨水量影响。
##
## 墨水的质量走**已有的合成质量管线**：写 shape.density_scale -> PWorld.refresh_mass()
## -> 密度推给 Rapier 并重算碰撞体质量。
## ⚠️ 绝不直接写 body.mass：GDScript 侧与 Rapier 侧的质量一旦分叉，抓取这类按 mass
##    算力的控制器会过冲成振荡。
## ⚠️ 代价：改一次质量 = 逐像素扫描 + 贪心分解 + 重推密度（玩家 4 千多像素约 2~3 ms），
##    所以按 mass_quantum 量化，只在液面变化超过阈值时才重算 —— 不是每帧。

const FluidPBF := preload("res://addons/pixel_destruction/fluid/fluid_pbf.gd")

@export_group("来源")
## 玩家物理节点（持有 PBody 的那个）。
@export var body_path := NodePath("..")
## 剪影来源：抄它的贴图 / offset / 变换，不重新烘焙。
@export var mask_path := NodePath("../Visual")
## 像素世界节点：取重力方向，并用于重算质量。
@export var world_path := NodePath("../../")
## 墨水生命值节点：液面比例每帧从它的 ratio() 读，本图层不自己存 fill。
@export var health_path := NodePath("../InkHealth")

@export_group("墨水")
## 有液体处的颜色。
@export var ink_color := Color(0.09, 0.11, 0.28, 1)
## 容器内**没有**液体处的颜色。**默认全透明** —— 空的那部分应该透出背景。
##
## ⚠️ 别设成不透明白色：容器掩码在外接框内是一整块（瓶子剪影本来就接近圆角矩形），
##    不透明白会把整块画出来 —— 角色背后糊一个**白方块**。
##    上一版那个白色瓶身是 Visual 的材质 5 画的，现在已经改成透明了（见 player.tscn）。
@export var glass_color := Color(1, 1, 1, 0)
## 每步最多增删几个粒子。这就是"液面一格一格往下走"的来源，别调太大。
@export_range(1, 64) var fill_rate := 2

## 满血时瓶子装到多少（0..1）。
##
## ⚠️ 别用 1.0：容器被填满时**没有液面**，晃动就完全看不出来了。
##    0.9 留出一成空腔，液面才有地方晃。
@export_range(0.1, 1.0) var max_fill := 0.9

## 每步最多消掉剩余差额的百分之几。小变化由 fill_rate 兜住、大变化靠它加速。
@export_range(0.0, 0.5) var fill_gain := 0.06
## 一个流体格子占几个像素。**默认 1 = 掩码与容器的单位像素 1:1。**
##
## 这是性能旋钮，而且很陡：代价大致随格子数线性涨。
##   1 = 逐像素（瓶子 60x59 = 3540 格 / 3540 粒子，实测 **~2.4 ms/步**）
##   2 = 2x2 像素一格（约 30x30 = 900 格 / 1000 粒子，**~0.5 ms/步**）
##
## ⚠️ 别为了省性能随手调大它：掩码是**降采样**出来的，格子越大，
##    容器边界越难和剪影对齐（并集规则会外胖、中心采样会让细边消失），
##    液面台阶也越粗。要省性能优先看 gravity_px / fill_rate，或者接受更小的瓶子。
@export_range(1, 8) var cell_px := 1

## 重力大小（像素/秒²）。和引擎默认的 600~900 同量级。
##
## ⚠️ 它和 spacing 一起决定流体的"节奏"。参照实现是 域高 0.7 单位 / 重力 9.8，
##    落到地上约 0.38 秒；这里是 域高 60 像素 / 重力 900，约 0.36 秒 —— 同量级，
##    所以那套调好的参数（overRelaxation 1.9 / stiffness 1.0 / flipRatio 0.9）直接可用。
## ⚠️ 这个值直接决定"晃得多快"。觉得太急就往下调 —— 落到底的时间是
##    sqrt(2 * 域高 / g)，所以 900 -> 600 会慢 1.22 倍，900 -> 400 慢 1.5 倍。
##    墨水是黏的，慢一点更像。
@export var gravity_px := 600.0
## 满瓶墨水的等效质量（引擎质量单位）。0 = 墨水只画，不参与质量。
@export var capacity_mass := 0.0
## 质量重算的量化粒度：density_scale 变化小于它就不重算。
@export_range(0.0, 1.0) var mass_quantum := 0.02

var _body = null
var _health = null
var _mask: Sprite2D = null
## 本帧的液面比例：从 InkHealth 同步来，供流体与质量共用。
var _fill := 1.0
## 未装墨水时的基准质量（density_scale = 1）。只取一次。
var _base_mass := 0.0
var _applied_scale := -1.0
## 剪影贴图 —— 注意不是本节点自己的贴图，那是烘出来的液体图。
var _src_tex: Texture2D = null
## 容器缓存键。剪影贴图和外接框不变就不重算。
var _container_key := ""

# ---- 容器 / 流体 ----
var _fluid = null
## 容器外接框在剪影局部像素空间里的原点。
var _grid_origin := Vector2i.ZERO
var _gw := 0
var _gh := 0
## 1 = 容器内。长度 _gw * _gh。**这张是给模拟用的**（fluid.solid_mask）。
var _container := PackedByteArray()
## 1 = 该格可以画墨水。长度 _gw * _gh。
##
## ⚠️⚠️ 和 _container 是**两张不同的掩码**，别合并：
##   · 模拟要的是**连通**：容器里那些不透明的像素（脸的黑线稿）不该是障碍，
##     液体得能从脸后面流过去 —— 所以 _container 把它们算成可通行；
##   · 渲染要的是"不盖住线稿"：那些格子**不该出墨水**，否则脸会被淹掉
##     （线稿虽然画在上面能挡住，但墨水会从线稿**边缘**糊出来一圈）。
## 甜甜圈形状的容器同理：中间的洞在模拟里连通、在画面上留空。
var _draw := PackedByteArray()
## 烘出来的图（每帧重填）
var _img: Image = null
var _tex: ImageTexture = null
var _pixels := PackedByteArray()


func _ready() -> void:
	centered = false
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_physics_process(not Engine.is_editor_hint())
	_health = get_node_or_null(health_path)
	_sync_visual()


func _physics_process(delta: float) -> void:
	_sync_visual()
	_tick_fluid(delta)
	_render()
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
	if _src_tex != _mask.texture:
		_src_tex = _mask.texture
		_container_key = ""
	_ensure_container()
	# offset：先抄 Visual 的，再叠上容器外接框的原点 —— 我们的贴图比剪影小一块。
	# scale：贴图是"每格 cell_px 像素"，所以放大 cell_px 倍刚好铺满外接框。
	# （centered = false 时贴图从 offset 起画，放大后覆盖
	#   [offset, offset + 尺寸*scale] —— 正好是外接框。）
	# ⚠️⚠️ offset 要**除以 cell_px**：贴图在局部空间是从 offset 画到 offset+尺寸，
	#    再被 scale 映射出去，所以屏幕上的落点是 **scale*offset**，不是 offset。
	#    直接给 mask.offset + 框原点会让它被放大 cell_px 倍 —— 症状是**整层错位**
	#    （cell_px=2 时偏出 (4,23)）。
	offset = (_mask.offset + Vector2(_grid_origin)) / float(cell_px)
	scale = Vector2(cell_px, cell_px)
	_fill = _health.ratio() if _health != null and _health.has_method("ratio") else 1.0
	visible = _fluid != null
	if not visible:
		return
	_fluid.set_fill_ratio(_fill)


## 跑一步流体。
##
## ⚠️ 重力必须是**瓶子局部**方向：世界重力转到局部系。PBF 里没有"下"这个概念，
##    转动 = 换一个向量 —— 这就是"玩家翻跟头液面跟着晃"的全部来源。
func _tick_fluid(delta: float) -> void:
	if _fluid == null:
		return
	_fluid.dt = delta
	# ⚠️⚠️ 重力必须**乘 spacing** —— 流体的域是以 spacing 为单位的，不是像素。
	#
	#    漏了这一步的症状极具误导性：域高 59 格 = 2.42 单位，而 gravity_px = 900
	#    被当成"每秒 900 单位"，落到底只要 0.073 秒（该是 0.36 秒）——
	#    快 5 倍，稳定条件直接崩。表现是**粒子塌缩成一坨**：实测单格挤了 65 个粒子、
	#    平均速度 21（每帧跑过 8 个域高），而画面看着像"墨水没灌满"。
	#    往"排布写错了 / 掩码没生效 / 压力求解没收敛"哪个方向查都是错的。
	#
	#    判据：想要"和世界一样重"就传 gravity_px * spacing ——
	#    这样域高 num_y*spacing、重力 g*spacing，落到底的时间是尺度无关的。
	# ⚠️ 显式标 Vector2：_fluid 是 Object，_fluid.spacing 是 Variant，
	#    整条乘法表达式就成了 Variant，var g := ... 会 "Cannot infer the type of g"。
	var g: Vector2 = _local_gravity() * gravity_px * _fluid.spacing
	_fluid.step(g.x, g.y)


## 世界重力方向 -> 本节点（= 瓶子）局部方向。
func _local_gravity() -> Vector2:
	var down := Vector2(0.0, 1.0)
	var pw = get_node_or_null(world_path)
	if pw != null and "world" in pw and pw.world != null:
		var g: Vector2 = pw.world.gravity
		if g.length_squared() > 0.0:
			down = (pw.global_transform.basis_xform(g)).normalized()
	# global_rotation 已经把世界节点的旋转算进去了，所以减掉它就是局部方向。
	return down.rotated(-global_rotation)


#region 容器
## 剪影变了才重算。键带 Visual 的 _sig（含每个 shape 的 revision），
## 所以挖洞 / 掉像素都会换键；每帧只是比一个字符串。
func _ensure_container() -> void:
	if _src_tex == null:
		return
	var size: Vector2 = _src_tex.get_size()
	var key := "%d:%d:%d:%s" % [_src_tex.get_instance_id(), int(size.x), int(size.y),
		_mask.get("_sig")]
	if key == _container_key:
		return
	_container_key = key
	_build_container(_src_tex)


## 见文件头「容器 = 整个瓶身」。返回的掩码 1 = 容器内。
func _build_container(src_tex: Texture2D) -> void:
	_fluid = null
	var img: Image = src_tex.get_image()
	if img == null:
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var rgba := img.get_data()
	var n := w * h

	# ① 从四边泛洪出"外面"。只走透明像素 —— 不透明的是剪影，泛洪穿不过去。
	var outside := PackedByteArray()
	outside.resize(n)
	var stack := PackedInt32Array()
	for x in w:
		_push_out(outside, stack, rgba, x)
		_push_out(outside, stack, rgba, (h - 1) * w + x)
	for y in h:
		_push_out(outside, stack, rgba, y * w)
		_push_out(outside, stack, rgba, y * w + w - 1)
	while not stack.is_empty():
		var sp := stack.size() - 1
		var p := stack[sp]
		stack.resize(sp)
		var px := p % w
		var py := p / w
		if px > 0:
			_push_out(outside, stack, rgba, p - 1)
		if px + 1 < w:
			_push_out(outside, stack, rgba, p + 1)
		if py > 0:
			_push_out(outside, stack, rgba, p - w)
		if py + 1 < h:
			_push_out(outside, stack, rgba, p + w)

	# ② 被围住的**透明**像素（老 _build_interior 的那一步）
	var cavity := PackedByteArray()
	cavity.resize(n)
	for i in n:
		if outside[i] == 0 and rgba[i * 4 + 3] == 0:
			cavity[i] = 1

	# ③ 取最大连通分量的外接框 —— 用来**排除头和瓶盖**（它们的空腔和身体是连着的）
	var seen := PackedByteArray()
	seen.resize(n)
	var best_area := 0
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for i in n:
		if cavity[i] == 0 or seen[i] != 0:
			continue
		seen[i] = 1
		stack.clear()
		stack.append(i)
		var area := 0
		var clo := Vector2i(1 << 30, 1 << 30)
		var chi := Vector2i(-(1 << 30), -(1 << 30))
		while not stack.is_empty():
			var sp := stack.size() - 1
			var p := stack[sp]
			stack.resize(sp)
			var px := p % w
			var py := p / w
			area += 1
			clo.x = mini(clo.x, px); clo.y = mini(clo.y, py)
			chi.x = maxi(chi.x, px); chi.y = maxi(chi.y, py)
			for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = px + off.x
				var ny: int = py + off.y
				if nx < 0 or nx >= w or ny < 0 or ny >= h:
					continue
				var q := ny * w + nx
				if cavity[q] == 0 or seen[q] != 0:
					continue
				seen[q] = 1
				stack.append(q)
		if area > best_area:
			best_area = area
			lo = clo
			hi = chi
	if best_area == 0:
		push_warning("BottledInk：剪影里没有被围住的空腔，墨水层不启用。")
		return

	# ④ 框内所有"不是外面"的格子 —— 不透明的身体块由此并进来，容器变成无洞的实心瓶身
	#    按 cell_px 降采样：一格里**至少一半**的源像素属于容器，整格才算容器。
	#
	# ⚠️⚠️ 判据是"多数票"，不是"任意一个"。
	#    第一版用的是并集（任意一个就算）—— 那会让容器朝外**胖出最多 cell_px-1 个源像素**
	#    （cell_px=2 时就是 1 像素），墨水会渗出瓶壁。当时没看出来是因为瓶壁线稿有
	#    2 像素厚、又画在墨水上面，正好盖住 —— 换个更细的线稿就会露馅。
	#    取中心也不行：瓶壁那一圈细边会整片消失，容器会漏。
	_grid_origin = lo
	_gw = ceili(float(hi.x - lo.x + 1) / float(cell_px))
	_gh = ceili(float(hi.y - lo.y + 1) / float(cell_px))
	_container = PackedByteArray()
	_container.resize(_gw * _gh)
	_draw = PackedByteArray()
	_draw.resize(_gw * _gh)
	for gy in _gh:
		for gx in _gw:
			var inside := 0
			var clear := 0
			var total := 0
			for sy in cell_px:
				var yy := lo.y + gy * cell_px + sy
				if yy > hi.y:
					break
				for sx in cell_px:
					var xx := lo.x + gx * cell_px + sx
					if xx > hi.x:
						break
					total += 1
					if outside[yy * w + xx] == 0:
						inside += 1
					if rgba[(yy * w + xx) * 4 + 3] == 0:
						clear += 1
			var is_container := total > 0 and inside * 2 >= total
			_container[gy * _gw + gx] = 1 if is_container else 0
			# 模拟掩码管"能不能流过去"，这张管"画不画" —— 见 _draw 的说明。
			_draw[gy * _gw + gx] = 1 if (is_container and clear * 2 >= total) else 0

	# 流体：域 = 容器外接框，掩码 = 容器。
	_fluid = FluidPBF.new()
	_fluid.resize_grid(_gw, _gh)
	_fluid.solid_mask = _container.duplicate()
	_fluid.mark_dirty()          # 掩码是原生的权威状态之一，换了要重新灌
	# 先量出"装满容器"是多少，再按 max_fill 从**底部**排一次。
	#
	# ⚠️ 是"量出满量 -> 重排 90%"，不是"排满 -> 删掉 10%"：
	#    init_particles 现在从下往上排，所以直接排 90% 得到的就是**已经沉降好的**
	#    初始状态；而"排满再删"会先悬在半空、再掉下来，画面要等好几秒才像样。
	var full: int = _fluid.init_particles(-1)
	_fluid.max_particles = int(float(full) * max_fill)
	_fluid.init_particles(_fluid.max_particles)
	_fluid.fill_rate = fill_rate
	_fluid.fill_gain = fill_gain
	_fluid.set_fill_ratio(_fill)
	_fluid.snap_fill(0.0, 1.0)
	# 贴图：尺寸跟着容器走，重建（不是 update —— update 不接受尺寸变化）
	_img = Image.create_empty(_gw, _gh, false, Image.FORMAT_RGBA8)
	_pixels = PackedByteArray()
	_pixels.resize(_gw * _gh * 4)
	_tex = ImageTexture.create_from_image(_img)
	texture = _tex
	print("[BottledInk] 容器 %dx%d @ %s，可通行 %d 格，粒子 %d（满量 %d，max_fill %.2f）" % [
		_gw, _gh, str(_grid_origin), _count_nonzero(_container),
		_fluid.particle_count(), full, max_fill])


func _push_out(reached: PackedByteArray, stack: PackedInt32Array,
		rgba: PackedByteArray, idx: int) -> void:
	if reached[idx] != 0 or rgba[idx * 4 + 3] != 0:
		return
	reached[idx] = 1
	stack.append(idx)


func _count_nonzero(a: PackedByteArray) -> int:
	var c := 0
	for v in a:
		if v != 0:
			c += 1
	return c
#endregion


#region 上色
## 容器 -> RGBA8。每格只有两种颜色（墨 / 玻璃），容器外透明。
##
## ⚠️ 只在**真的变了**的格子上写 4 个字节：3540 格逐格写 4 字节是 1.4 万次写入，
##    每帧都做是白烧。先比一个字节、变了才写。
func _render() -> void:
	if _fluid == null or _img == null:
		return
	var ir := int(ink_color.r * 255.0)
	var ig := int(ink_color.g * 255.0)
	var ib := int(ink_color.b * 255.0)
	var ia := int(ink_color.a * 255.0)
	var gr := int(glass_color.r * 255.0)
	var gg := int(glass_color.g * 255.0)
	var gb := int(glass_color.b * 255.0)
	var ga := int(glass_color.a * 255.0)
	var changed := false
	var gw := _gw
	var gh := _gh
	for gy in gh:
		for gx in gw:
			var i := gy * gw + gx
			var o := i * 4
			# ⚠️⚠️ 流体的索引是 **x*ny + y**（x 主序，见 fluid_pbf.gd 文件头），
			#    而贴图是**行主序**。拿同一个 i 去查 ink 等于把整张图**转置** ——
			#    症状是**一道斜杠贯穿瓶身**（下满的液面被映射成右满），
			#    而且看起来像"液面在横着乱晃 / 粒子动得太快"。
			#    两套索引必须显式换算，不能靠"它们应该一样"。
			var fi := gx * gh + gy
			if _container[i] == 0:
				if _pixels[o + 3] != 0:
					_pixels[o] = 0; _pixels[o + 1] = 0; _pixels[o + 2] = 0; _pixels[o + 3] = 0
					changed = true
				continue
			# ⚠️ 必须显式标 bool：_fluid 是 Object，_fluid.ink[fi] 是 Variant，
			#    写成 var wet := ... 会 "Cannot infer the type of wet"。
			# ⚠️ 要 **两张掩码都过**：_draw 管"这里该不该出墨水"（线稿/洞上不画），
			#    _container 那半边已经由 fi 对应的 ink 本身保证了。
			var wet: bool = _draw[i] != 0 and _fluid.ink[fi] != 0
			var r := ir if wet else gr
			var g := ig if wet else gg
			var b := ib if wet else gb
			var a := ia if wet else ga
			if _pixels[o] != r or _pixels[o + 1] != g or _pixels[o + 2] != b or _pixels[o + 3] != a:
				_pixels[o] = r
				_pixels[o + 1] = g
				_pixels[o + 2] = b
				_pixels[o + 3] = a
				changed = true
	if not changed:
		return
	_img = Image.create_from_data(_gw, _gh, false, Image.FORMAT_RGBA8, _pixels)
	_tex.update(_img)
#endregion


#region 质量
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
#endregion
