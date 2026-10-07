@tool
extends Node2D
## **场景里的物理世界**：把子节点里的 @@PixelBody2D@@ 烘焙成刚体，然后驱动它们。
##
## ## 性能设计（这是本节点存在的关键）
##
## 烘焙只发生**一次**（@@_ready()@@ 里）。之后每帧只做两件事：
##   @@world.step(dt)@@       —— 全是 RefCounted，不碰任何 Node
##   @@renderer.prune(...)@@  —— 只在刚体增删时才有实际工作
##
## 所以"用场景节点摆刚体"**不会**让物理变慢：热循环里的数据结构和
## 纯代码构建时**完全一样**。子节点在烘焙后不参与任何每帧工作。
##
## 实测（500 个刚体，跑 300 步）：
##   代码构建   step 合计与节点构建**逐位相同**
##   节点构建   额外的只有一次 _ready 烘焙（见 tools/bench_nodes.py）
##
## ## 用法
##
## 场景里放一个 PixelWorld，把 PixelBody2D 作为它的**直接子节点**摆好，
## 运行即可。编辑器里也会把像素和碰撞形状画出来（@tool）。

const PWorld := preload("res://addons/pixel_destruction/physics/pworld.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PixelRenderer := preload("res://addons/pixel_destruction/render/pixel_renderer.gd")
const _PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
# ⚠️ 用 preload 而不是依赖全局 class_name：addon 里也有同名脚本，
#    靠 class_name 解析在某些缓存状态下会失败，preload 是确定的。
const _PixelMaterial := preload("res://addons/pixel_destruction/nodes/pixel_material.gd")
const _PixelSprite2D := preload("res://addons/pixel_destruction/nodes/pixel_sprite_2d.gd")
const _PixelJoint2D := preload("res://addons/pixel_destruction/nodes/pixel_joint_2d.gd")
const PixelScale := preload("res://addons/pixel_destruction/core/pixel_scale.gd")


## **每个固定步**走完时发出，参数就是这个世界。
##
## ⚠️ 三条契约（按接口请求实现，改动前先读这里）：
##   1. **恰好一次**：发在 _physics_process 的 while 循环**内部**、world.step() 之后 ——
##      所以"一帧补多个 step"就会发多次，不会漏也不会重；
##   2. **零 step 帧不发**（累加器不够一个 fixed_dt 时循环体根本不执行）；
##   3. **同步回调**：消费者在这里读的 world.contacts 是**本次 step 的完整结果**，
##      可以当场提交破坏（改完形状/刚体后，下一次 step 前不会再有别的 step 插进来）。
##
## ⚠️ 为什么需要它：接触事件（world.contacts）**每步开头清空**，而一帧可能补多个 step ——
##    不挂在"步完成"上就没法保证"每次 step 的接触都被消费一次"。
signal physics_step_finished(world)

@export_group("物理")
@export var gravity := Vector2(0, 600)
@export var fixed_dt := 1.0 / 60.0
@export var max_substeps := 4
@export var sleeping := true
@export var terminal_speed := 650.0
## 线速度上限（世界单位/秒，0 = 不钳）。引擎默认 40000 —— 它用来挡数值爆炸，不是手感旋钮。
@export var max_linear_velocity := 40000.0
## 角速度上限（rad/s，0 = 不钳）。见 PWorld.max_angular_velocity 的说明
## （Rapier 只有线速度上限，角速度这条是引擎自己钳的）。
@export var max_angular_velocity := 1000.0
## 轻碎片**豁免子步估计**的质量阈值（0 = 关）。见 PWorld.ccd_ignore_mass：
## 子步数取的是"全世界最快"的那个刚体，所以一个轻碎片就能拖慢全世界。
@export var ccd_ignore_mass := 0.0

@export_group("破坏")
## 碎片小于这么多**像素**就不要了（在分裂时就丢掉，不生成刚体）。见 PWorld.min_fragment_pixels。
@export var min_fragment_pixels := 4
## 灰尘清理：质量 <= 它 **且** 运动 >= debris_min_speed 的刚体直接删（两个都 > 0 才生效）。
## ⚠️ 删掉会打破体素守恒（玩家会看到碎片凭空消失），所以默认关。
@export var debris_max_mass := 0.0
@export var debris_min_speed := 0.0

@export_group("材质")
## 全部材质。**在这里加一条就是加一种材质** —— 颜色、密度、强度一次设好。
##
## ⚠️ 以前颜色/密度/强度是三张散落的表（还分居两个对象），改一处忘另一处是静默 bug。
##    现在它们是同一份数据的三个视图，由 rebuild() 一次性播到物理层和渲染层。
##
## 没列进来的 id 会退回下面的 fallback 表。
@export var materials: Array[_PixelMaterial] = []

## 兜底颜色表（下标即材质 id，0 必须是透明）。只在 materials 里没覆盖到该 id 时用。
@export var palette_fallback: Array[Color] = [
	Color(0, 0, 0, 0),
	Color(0.62, 0.60, 0.56),
	Color(0.72, 0.52, 0.32),
	Color(0.55, 0.58, 0.66),
	Color(0.80, 0.32, 0.30),
]
## 兜底密度表（下标即 id，缺省 1.0）
@export var densities_fallback: Array[float] = [0.0, 2.5, 0.6, 7.8, 2.0]

@export_group("观感")
## 体素在屏幕上的大小：1 = 细腻，3 = 大块像素（默认），8+ = Teardown 那种粗块。
##
## ⚠️ 它**只影响"一个体素画多大"**：物理、破坏、笔刷、质量全部以**体素**为单位，
##    改它不会牵动重力、速度、质量 —— 这是本框架的核心约定（见 pixel_scale.gd）。
##
## 编辑器里改完立刻生效（@tool）；运行时改也立刻生效（Demo 里 - / = / 0 三个键）。
@export_range(1.0, 32.0, 0.5) var voxel_size := 3.0:
	set(v):
		var nv := clampf(v, PixelScale.MIN_SCALE, PixelScale.MAX_SCALE)
		if is_equal_approx(nv, voxel_size) and is_equal_approx(PixelScale.get_scale(), nv):
			return
		voxel_size = nv
		PixelScale.set_scale(nv)
		_apply_voxel_size()
		queue_redraw()


## 游戏里**实际可见的世界范围**（世界单位）。
##
## ⚠️ 这个值与分辨率**无关**，推导：
##      zoom      = voxel * render_scale = voxel * (视口高 / 540)
##      可见高度  = 视口高 / zoom = **540 / voxel**
##      可见宽度  = 可见高度 x 项目宽高比
##    所以 1080p 和 720p 看到的**世界范围完全一样**（只是每体素占的屏幕像素不同）。
##    这也解释了为什么不能拿编辑器面板的高度去算：面板一拉，范围就变了。
func game_view_size() -> Vector2:
	var h := 540.0 / maxf(PixelScale.get_scale(), 0.001)
	var pw := float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920))
	var ph := float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	var aspect := pw / ph if ph > 0.0 else 16.0 / 9.0
	return Vector2(h * aspect, h)


## 场景里（或往上）第一个 Camera2D。编辑器里 get_viewport().get_camera_2d() 会拿到
## **编辑器自己的**视图相机，不是场景里的那台，所以必须这样找。
func _preview_camera() -> Camera2D:
	var base: Node = owner if owner != null else get_parent()
	if base == null:
		return null
	for c in base.find_children("*", "Camera2D", true, false):
		return c as Camera2D
	return null


## 把体素尺寸播到"相机取景 + 渲染贴图"。
##
## ⚠️ 相机 zoom 必须**同时**乘上 `render_scale(cam)`（相机所在视口高度 / 540）：
##    只乘 voxel_size 的话，换个尺寸的视口取景就会变。
##    注意 render_scale 取的是**相机自己的视口**，不是窗口 —— 相机挂在 SubViewport 里时
##    两者不一样（见 pixel_scale.gd 的说明）。
func _apply_voxel_size() -> void:
	if not is_inside_tree():
		return                                  # 场景加载时 setter 先于入树，交给 _ready
	var cam := get_viewport().get_camera_2d()
	# ⚠️ 编辑器里**不写**相机 zoom：那是往场景里写"运行时值"（它还乘了 render_scale，
	#    而 render_scale 取决于编辑器面板高度）—— 会把场景标脏，还会把面板尺寸固化进场景。
	#    编辑器里要看取景，看 _draw() 画的那个"游戏取景框"（按项目分辨率算，和游戏一致）。
	if cam != null and not Engine.is_editor_hint():
		cam.zoom = Vector2.ONE * PixelScale.get_scale() * PixelScale.render_scale(cam)
	if renderer != null and world != null:
		for b in world.bodies:
			renderer.sync(b)


@export_group("运行")
@export var auto_step := true
@export var auto_render := true
## 是否在每次重建时打印烘焙数量。
##
## ⚠️ 默认 **false**：编辑器里拖一下就会重建一次，日志会刷屏。
##    排查"节点没被烘焙""数量不对"时再打开。
@export var log_bake := false

var world = null
var renderer: PixelRenderer = null
var _accum := 0.0
var _rebuild_queued := false
## 编辑器拖动关节节点时，积压的"要重烘焙的关节"（防抖：本帧内多次只做一次）。
var _joint_rebake_queued := {}
var _transform_queued := false
## 与 world.bodies 一一对应的节点（用来判断谁自带精灵）
var _body_nodes: Array = []
## 烘焙过的关节节点（与 world.joints 不是一一对应：烘焙失败的不进来）
var _joint_nodes: Array = []


## 编辑器里画一个**游戏实际取景框**。
##
## ⚠️ 为什么不靠 Godot 自带的相机框：它按**编辑器面板**的大小画 —— 面板不是 16:9 时
##    形状就不对，而且面板一拉，框的世界范围就跟着变。游戏里的可见范围是固定的
##    （见 game_view_size() 的推导），所以这里按项目分辨率算，和实际游戏一模一样。
##    游戏里**不画**（调试信息不该出现在画面里，甲方定的）。
func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var cam := _preview_camera()
	if cam == null:
		return
	var sz := game_view_size()
	var c := to_local(cam.global_position)
	var rect := Rect2(c - sz * 0.5, sz)
	var col := Color(0.35, 0.9, 1.0, 0.9)
	draw_rect(rect, col, false, 1.0)
	draw_string(ThemeDB.fallback_font, rect.position + Vector2(2.0, -4.0),
		"游戏取景 %.0f x %.0f" % [sz.x, sz.y], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)


## 取景框的"指纹"：相机是谁、在哪、转了多少、zoom 多少、offset 多少，加上体素尺寸。
##
## ⚠️ 只比 position 是不够的（第一版就这么写的）：编辑器里**旋转相机、改 zoom、
##    改 offset、换一台相机**都不会改 position —— 框就停在原地不跟。
##    甲方原话："青色面板应该在操作摄像机等时重绘"。
func preview_key() -> Array:
	var cam := _preview_camera()
	if cam == null:
		return [0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, PixelScale.get_scale()]
	return [cam.get_instance_id(), cam.global_position.x, cam.global_position.y,
		cam.global_rotation, cam.zoom.x, cam.zoom.y, cam.offset.x + cam.offset.y,
		PixelScale.get_scale()]


var _preview_cache: Array = []


func _process(_dt: float) -> void:
	# ⚠️ 这个 _process 只在**编辑器**里干活（游戏里第一句就返回，不碰热循环）。
	#    相机被拖动/旋转/缩放、换相机、改体素尺寸时要重画取景框。
	if not Engine.is_editor_hint():
		return
	var key := preview_key()
	if key != _preview_cache:
		_preview_cache = key
		queue_redraw()


func _ready() -> void:
	PixelScale.set_scale(voxel_size)
	# ⚠️ 可能已经被"按需烘焙"建过了（子节点在 _ready 里读了 .body，见 PixelBody2D.body）——
	#    那就别再 rebuild：rebuild 会 PWorld.new() 造一个新世界，把刚拿到的引用作废。
	if world == null:
		rebuild()
	_apply_voxel_size()
	# ⚠️ 显式打开：编辑器里要靠它跟踪相机的变化来重画取景框。
	set_process(true)
	queue_redraw()
	if Engine.is_editor_hint():
		return
	set_physics_process(true)


## 把本节点上的物理旋钮播到 world（gravity / 各种上限 / 破坏策略…）。
##
## ⚠️ 为什么要有这个方法：这些 @export 是给**编辑器**和代码驱动配置用的，而 world 是
##    运行时对象 —— 运行中改了导出值**不会自动生效**（只有 rebuild() 会播）。
##    运行时改完调一次它即可；**别为改一个阈值去调 rebuild()**（那会重建世界、
##    把破坏状态全丢掉）。
func push_physics_settings() -> void:
	if world == null:
		return
	world.gravity = gravity
	world.fixed_dt = fixed_dt
	world.max_substeps = max_substeps
	world.sleeping_enabled = sleeping
	world.terminal_speed = terminal_speed
	world.rp_max_linear_velocity = max_linear_velocity
	world.max_angular_velocity = max_angular_velocity
	world.ccd_ignore_mass = ccd_ignore_mass
	world.min_fragment_pixels = min_fragment_pixels
	world.debris_max_mass = debris_max_mass
	world.debris_min_speed = debris_min_speed


## 重建整个世界：把子节点里的 PixelBody2D 全部烘焙一遍。
##
## 编辑器里改完子节点之后调一次即可（@tool 下可以从 Inspector 的
## "调用方法"里点，或者重新打开场景）。运行时不建议调 —— 会丢掉破坏状态。
func rebuild() -> void:
	world = PWorld.new()
	push_physics_settings()
	# ---- 把材质播到物理层与渲染层 ----
	# ⚠️ 这是本节点存在的核心理由之一：材质是**一份数据**，
	#    颜色给渲染、密度给物理、强度给破坏判据 —— 三处必须同源。
	var pal := palette_fallback.duplicate()
	var dens := PackedFloat32Array()
	dens.resize(densities_fallback.size())
	for i in densities_fallback.size():
		dens[i] = densities_fallback[i]
	for m in materials:
		if m == null:
			continue
		var mid := clampi(m.id, 1, 254)
		while pal.size() <= mid:
			pal.append(Color(1, 1, 1))
		pal[mid] = m.color
		while dens.size() <= mid:
			dens.resize(mid + 1)
		dens[mid] = m.density
		world.set_material_friction(mid, m.friction)
		world.set_material_restitution(mid, m.restitution)
		if m.has_strength():
			world.set_material_strength(mid, m.compress_strength, m.resolved_shear())
	# 密度表直接写进 world（与 material_density 同构）
	for i in dens.size():
		world.set_material_density(i, dens[i])
	if renderer == null:
		renderer = PixelRenderer.new()
		renderer.name = "PixelRenderer"
		# ⚠️⚠️ 必须**延迟**加：rebuild() 现在可能被"按需烘焙"从**别的节点的 _ready**
		#    里触发（子节点读 .body，见 PixelBody2D.body），而那时本节点还在
		#    "busy setting up children" 状态 —— 同步 add_child 会失败：
		#      Parent node is busy setting up children, `add_child()` failed.
		#    渲染器的贴图节点挂在它自己的 holder 下，**不需要在树里**也能建，
		#    所以延迟到帧末入树不影响这一趟 rebuild。
		add_child.call_deferred(renderer)
	renderer.palette = pal
	var dens_call := Callable(self, "_density_of")
	_body_nodes.clear()
	var n := 0
	for c in get_children():
		if not (c is _PixelBody2D):
			continue
		# 造 body（配置位置/速度）与「加进世界」是两步，bake_node 一起做完
		if bake_node(c as _PixelBody2D) != null:
			n += 1
	# ---- 关节：必须在**所有刚体之后** ----
	_bake_joints()
	if auto_render:
		# ⚠️ 必须先清空再重建：rebuild 会造出**新的 body.id**，
		#    而渲染器按 id 索引贴图 —— 不清的话旧贴图会留在原地变成幽灵
		#    （表现是"拖动之后原地还有一个不动的影子"）。
		renderer.prune({})
		# ⚠️ 自带 PixelSprite2D 的刚体不进内部渲染器 —— 否则会画两遍
		#    （两份精灵重叠，半透明时尤其明显）。
		var internal: Array = []
		for i in world.bodies.size():
			var b = world.bodies[i]
			if i < _body_nodes.size() and not uses_internal_render(_body_nodes[i]):
				continue
			internal.append(b)
		renderer.sync_all(internal)
	_sync_overlays()
	if log_bake:
		print("[PixelWorld] 烘焙 %d 个刚体（场景节点 -> RefCounted，之后热循环不碰 Node）" % n)
	_preheat()


## 预热擦除路径上的一次性初始化。
##
## ⚠️ 为什么需要它：**第一笔擦除总是明显比之后每一笔慢**。
##    实测（tests/diag_fracture_parts.gd）：
##        笔画 0   合计 31.66 ms
##        笔画 1   合计 25.10 ms
##    差的这 5~6 ms 不是任何一处算法的成本，而是**首次调用付的惰性初始化**：
##    脚本/类缓存、GPU 后端的 device + pipeline 编译（5.5 ms，带窗口 126 ms）、
##    各种 static 变量的首次填充……
##
##    用户的原话是"影响擦除手感"——手会先建立预期，然后被打破。
##    把这些成本**从热路径挪到加载时**，每一笔就都一样了。
##
##    只跑一次；只碰擦除路径上真正会用到的函数，不做多余的事。
var _preheated := false

func _preheat() -> void:
	if _preheated or Engine.is_editor_hint():
		return
	_preheated = true
	var GreedyRects = load("res://addons/pixel_destruction/core/greedy_rects.gd")
	var Destruction = load("res://addons/pixel_destruction/core/destruction.gd")
	if GreedyRects == null or Destruction == null:
		return
	var probe := Rect2i(0, 0, 4, 4)
	for b in world.bodies:
		for s in b.shapes:
			# 这两个正是擦除路径上最重的两个函数的首次调用
			GreedyRects.decompose(s, 64)
			Destruction.touches_boundary(s, probe)
			Destruction.apply_damage_and_split_gpu(s, Destruction.Damage.circle(Vector2.ZERO, 1.0), 25.0)


## 把一个 PixelBody2D 子节点烘焙进**当前世界**，返回造出来的 PBody。
##
## ⚠️ 这是 rebuild() 的**增量版**，存在的理由是 rebuild() 太粗暴：
##    它 PWorld.new() 造一个**全新的世界** —— 运行时状态（已经破坏掉的像素、
##    正在飞的碎块、抓取）全部丢失，所以上面的注释写着"运行时不建议调"。
##    但"画完立刻固化出一个刚体"这类需求，必须能在**运行时**往世界里加东西。
##
## 节点没有形状时返回 null（跳过，与 rebuild 的行为一致）。
func bake_node(node: _PixelBody2D) -> PBody:
	if world == null:
		rebuild()
	# ⚠️ 用 collect_shapes() 而不是 build_shape()：
	#    一个刚体可以挂**多个形状子节点**（就像多个 CollisionShape2D），
	#    也可以一个都不挂、退回自身的内置形状。
	var shapes := node.collect_shapes()
	if shapes.is_empty():
		return null
	var b: PBody = world.add_body(node.bake(), shapes, Callable(self, "_density_of"))
	# ⚠️ _body_nodes 与 world.bodies **按下标一一对应**（rebuild 末尾和
	#    has_own_sprite 的过滤都依赖这个不变量）。两边必须同时 append/remove_at。
	#
	# ⚠️⚠️ 但"同时 append"这件事**在别人也往世界里加刚体时不成立**：
	#    门面（pixel_physics.gd）的 spawn_*、以及破坏产生的碎片，都只进 world.bodies，
	#    不进 _body_nodes。这时直接 append 会让下标整体错位 ——
	#    症状是 add_body_node() 第二次调用**返回了别人的刚体**（幂等那条断言就是这么挂的：
	#    tests/validation_fusion.gd "add_body_node 幂等"，13/14）。
	#    修法：先用 **null 占位**补齐（与 sync_world_bodies 的做法同源：不删项，只补位），
	#    这样 append 出来的节点与刚体又对上了。
	while _body_nodes.size() < world.bodies.size() - 1:
		_body_nodes.append(null)
	_body_nodes.append(node)
	if auto_render and renderer != null and uses_internal_render(node):
		renderer.sync(b)
	_sync_overlays()
	return b


## 烘焙所有 PixelJoint2D 子节点。
##
## ⚠️ 顺序：**必须在刚体之后**。关节两端要的是已经进世界的 PBody（见 PixelJoint2D.bake），
##    先建关节的话两端都是 null，会被当成"接静态世界" —— 症状是关节静默挂到世界上，
##    该被连住的地方完全不连（而且不报错）。
func _bake_joints() -> void:
	_joint_nodes.clear()
	var n := 0
	for c in get_children():
		if not (c is _PixelJoint2D):
			continue
		if (c as _PixelJoint2D).bake(world) != null:
			_joint_nodes.append(c)
			n += 1
	if log_bake and n > 0:
		print("[PixelWorld] 烘焙 %d 个关节" % n)


## 运行时把一个 PixelBody2D 加进**活着的世界**：不重建、不丢破坏状态。
##
## 与 rebuild() 的区别就是这一点 —— 这是"节点版"和"门面版"能共存的关键：
## 节点负责**编辑器里摆出来的**部分，运行时新增的部分走这里或门面的 spawn_*，
## 两者落在**同一个 world** 上。
func add_body_node(node: _PixelBody2D) -> PBody:
	if world == null:
		rebuild()
	var i := _body_nodes.find(node)
	if i >= 0:
		return world.bodies[i] as PBody      # 已经烘焙过了，幂等
	return bake_node(node)


## 把一个烘焙过的子节点从世界里摘掉（同样是增量，不重建）。
func remove_body_node(node: _PixelBody2D) -> bool:
	var i := _body_nodes.find(node)
	if i < 0:
		return false
	_body_nodes.remove_at(i)
	if i < world.bodies.size():
		world.remove_body(world.bodies[i])
	if renderer != null:
		renderer.prune(_live_ids())
	_sync_overlays()
	return true


## 供 PixelSprite2D 取用的调色板（保证与物理层同源）。
func palette_for_render() -> Array:
	return renderer.palette if renderer != null else palette_fallback


## 这个刚体是否自带 PixelSprite2D —— 自带的话就不进内部渲染器，避免画两遍。
static func has_own_sprite(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	for c in node.get_children():
		if c is _PixelSprite2D:
			return true
	return false


## 这个刚体**要不要由内部渲染器画**。
##
## ⚠️⚠️ 判据**只能有这一个**：rebuild() / bake_node() / _physics_process() /
##    sync_world_bodies() 四处共用。以前只有前两处过滤（has_own_sprite），于是
##    "破坏之后调一次 sync_world_bodies()"就给自带视觉的刚体补画了一张**矩形贴图** ——
##    甲方在 ink-2 的手/臂上实测到：破坏瞬间多出一张矩形手，而且它**停在旧位置**
##    （游戏那边跳过自有视觉的同步，那张矩形就永远留在原地）。
##
## 两条"不要画"的理由（任一成立就不画）：
##   · 它有 PixelSprite2D（自己的视觉）—— 引擎再画一份就是两份精灵重叠；
##   · 它显式关了 internal_render（仅物理：不可见的臂/手，只有碰撞和骨骼）。
##
## ⚠️ 传 null（没有节点对应的刚体，比如破坏产生的碎片）-> **要画**。
##
## ⚠️ 参数**故意不加类型标注**：`_body_nodes` 里允许放"鸭子类型替身" ——
##    tests/validation_node_sync.gd 用的就是 **RefCounted stub**（真 PixelBody2D 进树会触发
##    _ready -> rebuild()，那条路在 headless 下会中止）。加了 `: Node` 的话，传替身会**在调用点**
##    抛类型错误，而那条闸门当场变红（实测：静态 Ground 不再被同步）。
##    所以：拿不到 get_children 的（非 Node）按"要画"处理 = 老行为。
static func uses_internal_render(node) -> bool:
	if node == null or not is_instance_valid(node):
		return true
	if not (node is Node):
		return true                      # 替身（不是节点）-> 当作普通刚体：要画
	if node is _PixelBody2D:
		# ⚠️ 两个入口都要看：节点上的导出（编辑器里摆的）与 **PBody 上的标志**
		#    （代码 spawn / 门面路径设的）。烘焙时节点会把它同步到 PBody，
		#    但游戏层也可能直接改 body.internal_render —— 任一说"不画"就不画。
		if not node.internal_render:
			return false
		if node.body != null and not node.body.internal_render:
			return false
	return not has_own_sprite(node)


func _density_of(material: int) -> float:
	if material >= 0 and material < densities_fallback.size():
		return densities_fallback[material]
	return 1.0


func _physics_process(delta: float) -> void:
	# ⚠️⚠️ 编辑器里绝不推进物理。
	#
	# 陷阱：**定义 _physics_process 这个函数本身就会启用它**。
	# _ready() 里那句
	#     if Engine.is_editor_hint(): return
	#     set_physics_process(true)
	# 是**挡不住**它的 —— 方法一存在，Godot 每帧就会调。守卫必须写在函数体里。
	# （这正是"编辑器里物体自己在动"的原因。）
	if Engine.is_editor_hint():
		return
	if not auto_step:
		return
	_accum += delta
	var steps := 0
	while _accum >= fixed_dt and steps < max_substeps:
		world.step(fixed_dt)
		# ⚠️ 必须发在**循环内部**：发在循环外面就变成"每帧一次"，
		#    一帧补两个 step 时会丢掉一次接触（消费者只看到最后一次的 world.contacts）。
		#    发在这里则"每个 fixed step 恰好一次"是**按构造成立**的。
		physics_step_finished.emit(world)
		_accum -= fixed_dt
		steps += 1
	if _accum > fixed_dt * float(max_substeps):
		_accum = 0.0
	if auto_render:
		renderer.prune(_live_ids())
		# ⚠️ 只同步**动态体**。静态体的像素内容永远不会变，而 sync 对每个刚体
		#    都要算 AABB + 查 _rev（大形状如 768x100 的地面实测 ~840 us/次）。
		#    静态体只在**几何真的变了**时才需要同步，那是破坏/擦除的调用方
		#    显式 renderer.sync(body) 的事，不该每帧兜一遍。
		#
		#    实测（tests/bench_fusion.gd）：601 个刚体时 sync 占 17 ms/帧，
		#    而其中一半是静态的地形。
		# ⚠️ 自带视觉（PixelSprite2D）/ 显式 internal_render=false 的刚体**不进内部渲染器**，
		#    而且要把可能已经建出来的旧贴图**回收**（判据与 rebuild / sync_world_bodies 同一个）。
		for i in world.bodies.size():
			var b = world.bodies[i]
			if b.is_static:
				continue
			if i < _body_nodes.size() and not uses_internal_render(_body_nodes[i]):
				renderer.forget(b.id)
				continue
			renderer.sync(b)


func _live_ids() -> Dictionary:
	var d := {}
	for b in world.bodies:
		d[b.id] = true
	return d


## 把本节点里的调试叠加层也指到这个世界，并让它重绘一次。
##
## ⚠️ 用 set_world() 方法而不是直接赋 c.world —— 直接赋会报
##    "Invalid assignment of property or key 'world'"，而且报错信息不指向真因。
##    方法调用没有这个歧义，也顺便把「注入世界 + 重绘一次」绑成一件事
##    （叠加层在编辑器里不每帧重绘，必须有人叫它画）。
func _sync_overlays() -> void:
	for c in get_children():
		if c != renderer and c.has_method("set_world"):
			c.set_world(world)


## 子节点在编辑器里被拖动/旋转时由 PixelBody2D 调用。
##
## ⚠️ 拖动一次会连续发很多 NOTIFICATION_TRANSFORM_CHANGED，
##    每次都全量重建会卡（每个刚体约 0.2 ms）。这里防抖成"帧末重建一次"。
## 子节点**只是被拖动**（位置/旋转变了）—— 不做重烘焙，只同步位形。
##
## ⚠️⚠️ 这是编辑器拖动卡顿的根因所在。
##
## 之前拖动和"形状变了"走同一条路（on_child_moved -> rebuild），而 rebuild 要：
##     build_shape()  32000 像素的地面 ~38 ms
##     add_body()     贪心分解 + 质量属性 ~11 ms
##     建贴图          ~24 ms（prune({}) 会清掉全部贴图缓存 —— 重烘焙产生新 body id，
##                            缓存按 id 存，所以每次都得从零重建）
## 合计约 50~70 ms/次，拖动时每帧一次 -> 十几 FPS，看起来就是卡死。
##
## 但拖动**根本不需要重烘焙**：形状没变，变的只是刚体的位置和旋转。
## 所以这里只改 position/rotation，代价是几个赋值。
##
## 复用 _rebuild_queued 做防抖 —— 两者都是"本帧内积压多次只做一次"。
func on_child_transformed() -> void:
	if not Engine.is_editor_hint() or _transform_queued:
		return
	_transform_queued = true
	_sync_transforms_deferred.call_deferred()


func _sync_transforms_deferred() -> void:
	_transform_queued = false
	if not is_inside_tree() or not Engine.is_editor_hint() or world == null:
		return
	for i in _body_nodes.size():
		if i >= world.bodies.size():
			break
		var node = _body_nodes[i]
		if node == null:
			continue
		var b = world.bodies[i]
		b.position = node.position
		b.rotation = node.rotation
		b.update_aabb()
		b.compute_swept_aabb(0.0)
		if renderer != null:
			renderer.sync(b)


## 编辑器里拖动一个关节节点 -> 重烘焙**这一个**关节（增量，不动刚体）。
##
## ⚠️ 为什么不能走 rebuild()：那条路会把所有刚体重建一遍（地面一次 50~70 ms），
##    而且会丢掉运行时状态。关节只改了自己的锚点，摘掉旧的、按节点当前位置重建即可。
## 防抖同 on_child_transformed：拖动一次会连发很多 TRANSFORM_CHANGED。
func on_joint_transformed(node) -> void:
	if not Engine.is_editor_hint():
		return
	# ⚠️⚠️ 这句判空不是防御性编程，是**实测过的坑**：
	#    编辑器热重载脚本（@tool 改完保存）时，**已经存在的实例**是旧类，
	#    新加的成员读出来是 **Nil** —— 报错是
	#      Invalid call. Nonexistent function 'has' in base 'Nil'.
	#    行号指向这里，但真因是"实例没跟着脚本一起重载"。
	#    （用户重启编辑器/重开场景后不会再出现，但没必要让人踩一次。）
	if _joint_rebake_queued == null:
		_joint_rebake_queued = {}
	if _joint_rebake_queued.has(node):
		return
	_joint_rebake_queued[node] = true
	_joint_rebake_deferred.call_deferred()


func _joint_rebake_deferred() -> void:
	if _joint_rebake_queued == null:
		_joint_rebake_queued = {}
		return
	var nodes: Array = _joint_rebake_queued.keys()
	_joint_rebake_queued.clear()
	for n in nodes:
		rebake_joint(n)


## 重烘焙一个关节节点：摘掉旧的 PJoint，再按节点当前位姿 bake 一次。
## 返回是否成功（节点没形状 / 两端都空时返回 false，与 bake 一致）。
func rebake_joint(node) -> bool:
	if node == null or world == null:
		return false
	var old = node.joint
	if old != null:
		world.remove_joint(old)
		node.joint = null
	var j = node.bake(world)
	if j == null:
		return false
	if not _joint_nodes.has(node):
		_joint_nodes.append(node)
	node.queue_redraw()
	return true


func on_child_moved() -> void:
	if not Engine.is_editor_hint() or _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild_deferred.call_deferred()


func _rebuild_deferred() -> void:
	_rebuild_queued = false
	if not is_inside_tree() or not Engine.is_editor_hint():
		return
	rebuild()


## 场景节点 -> 烘焙出来的刚体（找不到返回 null）
func body_of(node: Node) -> PBody:
	if node is _PixelBody2D:
		return (node as _PixelBody2D).body
	return null


## 破坏之后把**节点层**与 world 对齐（新增碎片 / 消失的刚体 / 失效关节）。
##
## ⚠️ 为什么必须显式调：_body_nodes 与 world.bodies **按下标一一对应**（见 add_body_node），
##    而破坏会**增删刚体**（碎片是新刚体、被全删的刚体消失）。不对齐的后果：
##    碎片拿不到贴图、消失的刚体留下悬空节点引用、关节指向不存在的刚体。
##
## ⚠️ 碎片允许**只有 PBody**：这里用 **null 占位**，而不是把数组项删掉 ——
##    删掉会让下标整体错位（接口请求点名的验证项："全删和多碎片时节点索引不串位"）。
##
## ⚠️ 渲染要**含静态地形**：_physics_process 只同步动态体（静态体像素不变、sync 又贵），
##    但破坏之后静态 Ground 的像素**真的变了** —— 所以这里显式全量 sync 一次。
##
## ⚠️ 关节：body_a / body_b 为 null 表示"锚在静态世界"，那是**合法**的，
##    不能和"锚点已被删除"一起清掉 —— 只清**非 null 且已不在 world.bodies 里**的。
## 只把 _body_nodes 按下标重新对齐到 world.bodies（**不做渲染**）。
##
## ⚠️ 什么时候需要它：任何**绕过节点层**从 world.bodies 里删刚体的路径
##    （`cull_outside` / `enforce_body_budget` / 游戏层自己调 `remove_body`）
##    都会让"按下标一一对应"这个不变量失效。后果不是崩溃，而是**静默错配**：
##    每帧那句 `uses_internal_render(_body_nodes[i])` 会拿**别人的节点**做判断 ——
##    该画的刚体被判成"自带视觉"而 `forget` 掉（画面上少一块），而引擎不报任何错。
##    demo 的剔除路径实测就是：每 60 帧剔一次，而 _body_nodes 一直错到下一次破坏
##    （`sync_world_bodies`）才自愈。
##
## 代价 O(刚体数) 的两次字典/数组操作，比 sync_world_bodies 便宜得多（那个还要全量
## 同步一遍渲染器）。
func realign_body_nodes() -> void:
	var by_body := {}
	for n in _body_nodes:
		if n != null and is_instance_valid(n) and n.body != null:
			by_body[n.body] = n
	var out: Array = []
	for b in world.bodies:
		out.append(by_body.get(b, null))
	_body_nodes = out


func sync_world_bodies() -> void:
	# ① 节点数组按下标重建：能对上的节点保留，对不上的（碎片/未节点化）用 null 占位
	realign_body_nodes()

	# ② 渲染：全量 sync（含静态地形）+ 清理已经不存在的刚体
	#
	# ⚠️⚠️ 自带视觉 / internal_render=false 的刚体**不画**，而且要把**以前画出来的那张回收**
	#    （forget）—— 否则"破坏之后同步一次"就会给它们补出一张矩形残影，而那张残影
	#    还会停在旧位置（游戏层跳过自有视觉的同步）。判据与 rebuild / _physics_process 同一个。
	#    ⚠️ 必须在 ① 之后做：① 刚把 _body_nodes 按身份重建好，下标才是对的。
	for i in world.bodies.size():
		var b = world.bodies[i]
		if i < _body_nodes.size() and not uses_internal_render(_body_nodes[i]):
			renderer.forget(b.id)
			continue
		renderer.sync(b)
	renderer.prune(_live_ids())

	# ③ 关节：锚点已经不存在的清掉，不留悬空引用
	var alive := {}
	for b in world.bodies:
		alive[b] = true
	for j in world.joints.duplicate():
		var bad := (j.body_a != null and not alive.has(j.body_a)) 			or (j.body_b != null and not alive.has(j.body_b))
		if bad:
			world.remove_joint(j)

	# ④ 关节节点同样清掉失效的（用 get("joint") 取值，不假设字段名）
	var kept_j: Array = []
	for c in _joint_nodes:
		if c != null and is_instance_valid(c) and world.joints.has(c.get("joint")):
			kept_j.append(c)
	_joint_nodes = kept_j


## 破坏的统一入口：调 fracture_pixels 之后**顺手**把节点层对齐。
## ⚠️ 游戏层只要用这一个方法，就不会忘记 sync_world_bodies()（忘了的症状是碎片没有贴图）。
func fracture_pixels_and_sync(body: PBody, removals: Dictionary, burst_speed: float = 0.0,
		dynamic_fragments: bool = false, static_anchors: Dictionary = {}) -> Dictionary:
	var res: Dictionary = world.fracture_pixels(body, removals, burst_speed,
		dynamic_fragments, static_anchors)
	sync_world_bodies()
	return res
