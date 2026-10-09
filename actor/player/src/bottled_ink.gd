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
## 所以两件事必须同时成立，少一件就看不见墨水：
##   1. 本节点的 z_index < Visual 的（见 player.tscn）；
##   2. Visual 的**瓶身填充（材质 5）必须是透明的** —— 它是 58x34 的实心块，
##      不透明就会把墨水整个盖住（见 player.tscn 里 Visual.palette 的第 6 项）。
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
##   ③ 取②里**与材质 5（瓶身填充）重叠最多**的连通分量的外接框 —— 外接框是为了
##      **排除头/瓶盖**：头部的线稿空腔和身体是连着的，不框住的话墨水会灌进脑袋；
##      ⚠️⚠️ 以前比的是**面积最大**，那会跟着美术走：实测最大的那圈是瓶壁与身体轮廓之间的
##      「框」，真正的瓶身内部反而排第二 —— 症状是墨水只画在瓶子两侧的细条上，瓶身中间空着；
##   ④ 框内所有"不是外面"的格子都算容器 —— 于是不透明的身体块被并进来，
##      得到一个**没有洞的实心瓶身**（PBF 的 solidMask 支持任意形状，见引擎侧说明）。
##      可画区域 = 框内**属于③那个分量**的格子（见 _draw）。
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
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

@export_group("来源")
## 玩家物理节点（持有 PBody 的那个）。
@export var body_path := NodePath("..")
## 剪影来源：抄它的贴图 / offset / 变换，不重新烘焙。
@export var mask_path := NodePath("../Visual")
## 剪影里「瓶身填充」的材质号 —— **墨水的可画区域就是它**（见 _fill_mask）。
##
## ⚠️⚠️ 别再回到「面积最大的被围空腔」那个判据：它**跟着美术走**。实测（2026-10-09 的角色美术）
##    最大的那圈是**瓶壁与身体轮廓之间的「框」**（1436 px），真正的瓶身内部反而排第二
##    （1248 px）—— 于是 _draw 选中的是框，墨水只画在瓶子两侧各一格宽的细条上，瓶身中间
##    一滴都不画（就是「流体 mask 不对」）。材质 5 是美术**显式画出来**的瓶身填充，
##    换线稿 / 重烤角色都不会翻车。
@export var fill_material := 5
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
@export_range(0.1, 1.0) var max_fill := 1.0

## 每步最多消掉剩余差额的百分之几。小变化由 fill_rate 兜住、大变化靠它加速。
@export_range(0.0, 0.5) var fill_gain := 0.06
## 一个流体格子占几个像素。
##
## ⚠️⚠️ **不是纯性能旋钮 —— 它同时决定流体稳不稳。**
##    真正决定"沸腾不沸腾"的是**每步走几格**：
##        cells/step = dt * sqrt(2 * gravity_px * num_y)
##    而 num_y = 容器高 / cell_px。实测自由落体末速：
##        cell_px 1 -> num_y 59 -> 4.43 格/步   （参照实现约 1.6）
##        cell_px 2 -> num_y 30 -> 3.17 格/步
##        cell_px 4 -> num_y 15 -> 2.24 格/步
##    密度场和 MAC 网格都是**按格**的，一帧走 4 格时压力求解根本跟不上：
##    粒子互相穿过 -> 最近邻距离掉到 min_dist 的 0.5 倍（99% 的粒子都重叠）
##    -> push_apart 每步都在补救 -> 永远静不下来。降分辨率是**同时**解决
##    "太贵"和"太沸"的那一个旋钮。
## 代价大致随格子数线性涨：1 = 逐像素（60x59 = 3540 格 / 4169 粒子），
##    2 = 2x2 像素一格（约 30x30 = 900 格 / 1000 粒子），4 = 再少四分之三。
## ⚠️ 格子越大，液面台阶越粗（一格 = cell_px 个像素）—— 这是看得见的代价。
@export_range(1, 8) var cell_px := 2

## 重力大小（像素/秒²）。
##
## ⚠️⚠️ **不能往小调** —— 试过 150，理由是"每步位移超了 CFL"（见下），
##    结果是**液面永远静止不下来**：静水压力建立得极慢，实测 20 秒里
##    液面从 92% 一路阴跌到 76%（还在跌），玩家一动就更不收敛。
##    人对"液面在慢慢沉"比对"体积差一成"敏感得多，所以这条路是死的。
##
##    CFL 那件事是真的：自由落体末速 = dt * sqrt(2 * gravity_px * 容器高/cell_px)，
##    而密度场和 MAC 网格都是**按格**的。但解法是**加阻尼**或**降分辨率**
##    （见 cell_px 的说明），不是减重力。
##
## ⚠️ 落到底的时间是 sqrt(2 * 域高 / g)：600 -> 0.44 秒。觉得晃得太急就往下调一点
##    （900 -> 600 慢 1.22 倍），但**别调过头**，上面那个坑就在下面。
@export var gravity_px := 150.0

## 脸部留空区域 —— **剪影贴图的像素坐标**（和 _grid_origin 同一套），不是格子坐标。
## 墨水不在这个矩形里渲染；**模拟照旧连通**（液体照常从脸后面流过去）。
##
## ⚠️⚠️ 为什么是"手填的矩形"而不是自动识别 —— 两条自动判据都试过，都不可靠：
##    · **材质**：实测剪影只有 0（没画）/ 2（线稿）/ 5（瓶身填充）三种，
##      而脸**内部**就是材质 5，和瓶身其他地方一模一样 —— 分不出来。
##    · **连通性**（"四临域泛洪走不到的不透明像素 = 脸"）：在**贴图空间**里
##      瓶壁和瓶盖本来就断成两截（中间 4 行没有任何像素），于是整条瓶壁都被当成
##      "孤岛"，框出来的矩形把肩线一起吞了；而在**格子空间**（cell_px=2）里，
##      一像素粗的线稿只盖住半格 —— 判"整格透明"会连瓶身中段一起挡掉，
##      判"有透明像素就算"又一点都挡不住。**格子太粗，线稿做不了障碍。**
##    脸的位置是**美术事实**，推不出来，所以写成显式参数，可以在检查器里直接调。
@export var face_rect := Rect2i()   # 默认空 = 关；自动掩码挡不住时再手填

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
## 抖动 uniform 的缓存键（剪影尺寸 / 容器原点 / cell_px）—— 这三样不变就不重设。
var _wobble_key := ""

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
## 判据 = 格里有**③选中的那个分量**的像素（= 材质 5 围出来的瓶身内部），
## 所以眼睛/嘴这类**别的**被围空腔照旧不出墨水，而瓶身内部照旧画满。
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
	_sync_wobble_uniforms()
	_fill = _health.ratio() if _health != null and _health.has_method("ratio") else 1.0
	visible = _fluid != null
	if not visible:
		return
	_fluid.set_fill_ratio(_fill)


## 墨层要跟线框**同相位**抖：把"剪影的像素空间"喂给 player_liquid_wobble.gdshader。
##
## ⚠️⚠️ 为什么不能像 Visual 那样用默认值：本节点的贴图只是**瓶身内部那块子矩形**
##    （_gw x _gh 格），还被 scale=cell_px 放大过 —— UV 与 Visual 不是一套。
##    shader 拿这三个值把 UV 映回剪影像素空间再算位移，两边才会同相（见那个 shader 的注释）。
func _sync_wobble_uniforms() -> void:
	var mat := material as ShaderMaterial
	if mat == null or _src_tex == null:
		return
	var key := "%s|%s|%d" % [str(_src_tex.get_size()), str(_grid_origin), cell_px]
	if key == _wobble_key:
		return
	_wobble_key = key
	mat.set_shader_parameter("visual_size", _src_tex.get_size())
	mat.set_shader_parameter("grid_origin", Vector2(_grid_origin))
	mat.set_shader_parameter("cell_px", float(cell_px))


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
	# ⚠️⚠️ **别用调大 fluid.stiffness 的办法去托体积。**
	#
	#    试过（stiff 6 / over_relaxation 0.8）：覆盖确实从 0.62 涨到 0.88，
	#    但液面变成一根**没有阻尼的弹簧** —— 一直重复"压缩 -> 释放 -> 压缩"。
	#    原因：这个压力项给的是**速度**，而 FLIP（flip_ratio 0.9）会把那个向外速度
	#    一直留着，冲过平衡点之后重力再压回来 —— 一个无阻尼振子。
	#    实测（test/probe_rest_small.gd，12x48 判定台，每步位移 4.0 格，
	#    "覆盖"取 600~900 帧的 min/max，目标是初始的 0.87）：
	#      stiff 6 + over 0.8        -> 覆盖 0.63~0.99 摆，速度 3.7   ← 弹簧
	#      stiff 2 + over 0.8        -> 覆盖 0.52~0.54 摆，速度 1.1   ← 稳了但体积塌
	#      stiff 6 + 2 子步          -> 覆盖 0.63~0.65 摆，速度 1.2   ← 稳了但体积塌
	#      stiff 6 + 每步 vel*=0.95  -> 覆盖 0.54~0.59 摆，速度 1.8   ← 弹簧被杀掉
	#      stiff 20 + 每步 vel*=0.90 -> 覆盖 0.85~0.96 摆，速度 4.0   ← 体积也托住了
	#
	#    也就是说：**"稳"和"体积"要同时拿到，必须先给速度加阻尼，再加刚度。**
	#    而阻尼是引擎里没有的项 —— 要 fluid_pbf.gd 与 fastphys.cpp 两边一起加
	#    并重跑闸门（两边必须逐位相同）。没有它之前，stiffness 保持引擎默认的 1.0：
	#    **宁可体积塌，也不要弹簧**（人对"液面停不下来"比对"少装一成"敏感得多）。
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

	# ①.5 瓶身填充（材质 5）—— ③ 与 ④ 的判据，见 _fill_mask
	var fill := _fill_mask(w, h)

	# ② 被围住的**透明**像素（老 _build_interior 的那一步）
	var cavity := PackedByteArray()
	cavity.resize(n)
	for i in n:
		if outside[i] == 0 and rgba[i * 4 + 3] == 0:
			cavity[i] = 1

	# ③ 选「瓶身内部」那个连通分量：**与材质 5 重叠最多**的，回退才是面积最大
	#    外接框同时用来**排除头和瓶盖** —— 它们的空腔和身体是连着的，不框住墨水会灌进脑袋。
	# ⚠️⚠️ 判据不能只比面积：实测最大的那圈是瓶壁与身体轮廓之间的「框」（1436 px），
	#    真正的瓶身内部（材质 5 那一片）反而排第二（1248 px）。见 fill_material 的说明。
	var comp := PackedInt32Array()
	comp.resize(n)
	comp.fill(-1)
	var best := -1
	var best_fill := 0
	var best_area := 0
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	var cid := 0
	for i in n:
		if cavity[i] == 0 or comp[i] >= 0:
			continue
		comp[i] = cid
		stack.clear()
		stack.append(i)
		var area := 0
		var hits := 0
		var clo := Vector2i(1 << 30, 1 << 30)
		var chi := Vector2i(-(1 << 30), -(1 << 30))
		while not stack.is_empty():
			var sp := stack.size() - 1
			var p := stack[sp]
			stack.resize(sp)
			var px := p % w
			var py := p / w
			area += 1
			if fill[p] != 0:
				hits += 1
			clo.x = mini(clo.x, px); clo.y = mini(clo.y, py)
			chi.x = maxi(chi.x, px); chi.y = maxi(chi.y, py)
			for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = px + off.x
				var ny: int = py + off.y
				if nx < 0 or nx >= w or ny < 0 or ny >= h:
					continue
				var q := ny * w + nx
				if cavity[q] == 0 or comp[q] >= 0:
					continue
				comp[q] = cid
				stack.append(q)
		if hits > best_fill or (hits == best_fill and area > best_area):
			best_fill = hits
			best_area = area
			best = cid
			lo = clo
			hi = chi
		cid += 1
	if best < 0:
		push_warning("BottledInk：剪影里没有被围住的空腔，墨水层不启用。")
		return

	# ④ 框内所有"不是外面"的格子 —— 不透明的身体块由此并进来，容器变成无洞的实心瓶身
	#    按 cell_px 降采样：一格里有**任意一个**源像素属于容器，整格就算容器（并集）。
	#
	# ⚠️⚠️ 判据是**并集（向外拓）**，不是多数票、也不是取中心。
	#    · 多数票（曾经用过）：格子越大，容器越**往里缩** —— 液面到不了瓶壁，
	#      四周留出一圈空，看上去就是"墨水没装满"。cell_px=2 时缩 1 个源像素，
	#      cell_px=4 时缩到 3 个，越省性能越明显。
	#    · 取中心：瓶壁那一圈细边会整片消失，容器直接漏。
	#    · 并集：容器朝外**胖出最多 cell_px-1 个源像素**，墨水会盖到瓶壁**下面**。
	#      这一条是**有意的**：瓶壁线稿有 2 像素厚、又画在墨水上面，正好压住；
	#      而"墨水贴不到墙"是一眼就能看出来的。两害相权取其轻。
	#      ⚠️ 换个 1 像素厚的细线稿时这里会露馅 —— 那时要么调小 cell_px，要么
	#      给 _draw 单独用保守判据（它管画不画，本来就该比 _container 严）。
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
			var owned := 0
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
					if comp[yy * w + xx] == best:
						owned += 1
			# 并集：任意一个源像素在容器里，整格就是容器 —— 见上面④的说明
			var is_container := total > 0 and inside > 0
			_container[gy * _gw + gx] = 1 if is_container else 0
			# 模拟掩码管"能不能流过去"，这张管"画不画" —— 见 _draw 的说明。
			# 取并集：只要格里有**瓶身内部**（③那个分量）的像素就允许出墨水，
			# 墨水于是能贴到瓶壁下面，而眼睛这类**别的空腔**照旧排除。
			_draw[gy * _gw + gx] = 1 if (is_container and owned > 0) else 0

	# ⑤ 脸部留空 —— 见 face_rect 的说明
	_carve_face(lo)

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


func _push_out(reached: PackedByteArray, stack: PackedInt32Array,
		rgba: PackedByteArray, idx: int) -> void:
	if reached[idx] != 0 or rgba[idx * 4 + 3] != 0:
		return
	reached[idx] = 1
	stack.append(idx)


## 材质 5（瓶身填充）在**剪影贴图坐标系**里的掩码。1 = 该像素是瓶身填充。
##
## ⚠️⚠️ 为什么必须回到形状的 mat 数组：剪影贴图是**调色板烘出来的**，材质 0（没画）与
##    材质 5（瓶身填充）在它上面**都是 alpha 0** —— 从贴图上根本分不出来（见 test/probe_face_mat.gd）。
##    而「瓶身内部在哪」是**美术事实**，只能由美术显式标出来 —— 就是材质 5。
func _fill_mask(w: int, h: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(w * h)
	if fill_material < 0 or _mask == null or not _mask.has_method("_collect"):
		return out
	var shapes: Array = _mask.call("_collect")
	if shapes.is_empty():
		return out
	# 贴图空间 = 形状并集的外接框（与 pixel_sprite_2d.rebuild() 同一套换算）
	var box := Rect2i()
	var first := true
	for s in shapes:
		var b: Rect2i = s.local_aabb()
		if b.size.x <= 0:
			continue
		box = b if first else box.merge(b)
		first = false
	if first:
		return out
	for s in shapes:
		for k: int in s.chunks:
			var c = s.chunks[k]
			var bx := (PixelShape.key_x(k) << 3) - box.position.x
			var by := (PixelShape.key_y(k) << 3) - box.position.y
			var bits: int = c.occ
			while bits != 0:
				# ⚠️ 不用 Bits.first_bit_index —— 那个单例不在本工程的全局作用域里（见 probe_face_mat.gd）
				var i := 0
				var probe := bits
				while (probe & 1) == 0:
					probe >>= 1
					i += 1
				bits &= bits - 1
				var gx := bx + (i & 7)
				var gy := by + (i >> 3)
				if gx >= 0 and gx < w and gy >= 0 and gy < h and int(c.mat[i]) == fill_material:
					out[gy * w + gx] = 1
	return out

## 把脸部矩形从 _draw 里挖掉（手动后备：`face_rect` 默认是空矩形 = 关，正常由材质 5 的判据自动挡）。
## **只影响渲染**，_container（模拟）一个字都不动。
func _carve_face(lo: Vector2i) -> void:
	if face_rect.size.x <= 0 or face_rect.size.y <= 0:
		return
	var x0 := clampi(floori(float(face_rect.position.x - lo.x) / float(cell_px)), 0, _gw)
	var y0 := clampi(floori(float(face_rect.position.y - lo.y) / float(cell_px)), 0, _gh)
	var x1 := clampi(ceili(float(face_rect.position.x + face_rect.size.x - lo.x) / float(cell_px)), 0, _gw)
	var y1 := clampi(ceili(float(face_rect.position.y + face_rect.size.y - lo.y) / float(cell_px)), 0, _gh)
	for gy in range(y0, y1):
		for gx in range(x0, x1):
			_draw[gy * _gw + gx] = 0


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
