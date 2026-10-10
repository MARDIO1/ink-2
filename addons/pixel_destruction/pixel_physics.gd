@tool
class_name PixelPhysics
extends Node2D
## pixel_destruction 的**门面** —— 调用方只需要认识这一个类。
##
## ## 为什么需要这一层
##
## 引擎内部是 8 个互相 preload 的类，各自暴露一堆字段。直接用它们意味着调用方要
## 自己保证一堆**跨对象的一致性**，而其中任何一条漏掉都是静默的怪 bug：
##
##   · 材质颜色在 `PixelRenderer.palette`、密度在 `PWorld.material_density` —— 两张表要手动同步；
##   · 破坏会**增删刚体**，渲染层必须跟着 prune，否则残留幽灵贴图；
##   · 破坏的坐标是 **Shape 局部像素空间**，而游戏逻辑手里是世界坐标；
##   · 同一子步里「走哪条路」的判断只能有一个真源（`manifolds` 那三个消费者
##     口径不一致时，拖动一个方块会让其它方块全部掉穿地面 —— 那条路径与字段都已删除，
##     教训见 PWorld 里的墓碑）；
##   · 外力是持久累加器，忘了 `clear_forces()` 就会越加越大。
##
## 门面把这些一次性收口：**一个世界、一张材质表、一套世界坐标、一份内部标志**。
##
## ## 用法
##
## 因为注册了 `class_name`，调用方**连 preload 都不用写**：
##
## ```gdscript
## var px := PixelPhysics.new()
## add_child(px)                                  # 加进树里就会自动 _physics_process
##
## px.define_material(1, Color.SLATE_GRAY, 2.5)   # 石头：颜色 + 密度一次设好
## px.define_material(2, Color.SANDY_BROWN, 0.6)  # 木头
## px.add_ground(Rect2(-400, 300, 800, 40), 1)
##
## var ball := px.spawn_circle(Vector2(0, 0), 14, 2)
## px.explode(Vector2(0, 300), 60.0, 400.0)       # 世界坐标
## px.drag_to(mouse_world_position)               # 拖动
## ```
##
## 不想加进树里（无头测试、自己控节奏）就不 add_child，手动 `step(delta)` 即可。

const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PWorld := preload("res://addons/pixel_destruction/physics/pworld.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PixelRenderer := preload("res://addons/pixel_destruction/render/pixel_renderer.gd")
const Query := preload("res://addons/pixel_destruction/physics/query.gd")
const ShapeOps := preload("res://addons/pixel_destruction/core/shape_ops.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")

## 世界（想直接调底层接口时用它，但优先用门面的方法）。
##
## ⚠️ **故意不写类型注解**（不写 `var world: PWorld`）。原因是 addon 会**自带一份**
##    引擎脚本的副本：`addons/pixel_destruction/physics/pworld.gd`。
##    而在开发仓库里 `src/physics/pworld.gd` 同时存在 —— 两份是**不同的 GDScript
##    资源**，Godot 按脚本身份做类型检查，于是
##        f.world = pixel_world_node.world
##    会报 `Trying to assign value of type 'pworld.gd' to a variable of type 'pworld.gd'`
##    （两边名字一样、报错却看不出所以然）。
##
##    这正是"节点版和门面版是两个并列前端"的底层原因：它们的对象互不认。
##    去掉注解后，跨边界的赋值靠**鸭子类型**通过 —— 两份副本的结构本来就逐字相同
##    （addon 就是 src 的拷贝），所以行为一致。
##
##    纯 addon 项目里两边都用同一份副本，本来就没这个问题；
##    但开发仓库里两套并存，这条边界必须容忍它。
var world = null

## 加进场景树后是否自动 _physics_process
var auto_step := true
## 是否自动维护渲染层（关掉就完全无渲染依赖）
var auto_render := true

var _palette: Array = [Color(0, 0, 0, 0)]
var _renderer: Node2D = null
var _accum := 0.0
## 接管来的世界节点（见 attach_to）。为 null 表示世界是本门面自己建的。
var _world_node = null


func _init() -> void:
	world = PWorld.new()
	Query.attach(world)          # 查询是模块级的，建世界时挂上


## 接管一个**已经存在的**世界（典型来源：场景里的 PixelWorld 节点）。
##
## ⚠️ 为什么需要它：PixelWorld（节点版）和 PixelPhysics（门面版）原本是
##    两个**并列**的前端，各自 PWorld.new() 一个世界 —— 于是编辑器里摆出来的
##    关卡和代码里 spawn 出来的刚体活在两个世界里：互相看不见、也不碰撞。
##    这个方法让门面**接管节点的世界**，两个前端共用一个世界。
##
##    用法：
##        var pw := PixelPhysics.new()
##        add_child(pw)                  # 可选；不加进树就得自己调 step()
##        pw.attach_to($PixelWorld)      # 场景里那个节点
##        pw.spawn_rect(...)             # 加进去的就是**同一个**世界
##
## ⚠️ 接管后会**关掉本门面的 auto_step**：世界由 PixelWorld 节点驱动。
##    两边都 step 会让物理一帧推进两次（而且各自维护累加器，时间尺度也会错）。
func attach_to(world_node) -> void:
	if world_node == null:
		push_error("attach_to: 传进来的世界节点是 null")
		return
	# 节点可能还没 _ready（刚 instantiate、还没进树）—— 先让它把世界建出来
	if world_node.world == null and world_node.has_method("rebuild"):
		world_node.rebuild()
	if world_node.world == null:
		push_error("attach_to: 这个节点里没有 world —— 它是 PixelWorld 吗？")
		return
	world = world_node.world
	_world_node = world_node
	Query.attach(world)
	# 渲染层也必须跟着接管：节点自己已经有一个渲染器，门面再建第二个的话，
	# 同一个刚体会被**画两遍**（两份精灵重叠，半透明时尤其明显）。
	_renderer = world_node.renderer
	if _renderer != null and world_node.has_method("palette_for_render"):
		_palette = world_node.palette_for_render()
	# ⚠️ 两个 auto 都要关：世界由节点驱动。
	#    · auto_step  —— 两边都 step 会让物理一帧推进两次（累加器还各自一份）
	#    · auto_render —— PixelWorld._physics_process 每帧会给世界里的**所有**刚体
	#      同步渲染器（含门面 spawn 出来的），门面再同步一遍是白做。
	auto_step = false
	auto_render = false
	_accum = 0.0


## 解除接管，回到"门面自己持有一个世界"的状态。
func detach() -> void:
	if _world_node == null:
		return
	_world_node = null
	_renderer = null
	world = PWorld.new()
	Query.attach(world)
	auto_step = true
	_accum = 0.0


## 编辑器里是否自动重绘。构建世界的脚本（@tool）在编辑器里摆好刚体之后，
## 由本节点把它们画出来 —— 这样在场景编辑器里就能直接看到像素和碰撞形状。
##
## ⚠️ 编辑器里**只画、绝不 step**：@tool 的 _physics_process 在编辑器里也会跑，
##    一旦推进物理就会污染场景，而且存盘时把结果写进去（很隐蔽的坏味道）。
@export var redraw_in_editor := true

## 编辑器里把调试叠加层也一起重绘
@export var editor_redraw_overlay := true


func _ready() -> void:
	set_physics_process(true)
	# 编辑器里不进 _physics_process，但要在资源变化时重绘
	if Engine.is_editor_hint():
		set_process(redraw_in_editor)


func _process(_delta: float) -> void:
	# 只有编辑器会走到这里（运行时 _process 是关的）
	if not Engine.is_editor_hint():
		return
	if redraw_in_editor:
		resync()


func _physics_process(delta: float) -> void:
	# ⚠️ 编辑器里绝不推进物理
	if Engine.is_editor_hint():
		return
	if auto_step:
		step(delta)


# ============================================================ 配置

## 一次性配置。认识的键（都给默认值，不传也行）：
##   gravity: Vector2      默认 (0, 900)
##   fixed_dt: float       物理步长，默认 1/60
##   max_substeps: float   每帧最多几步，默认 4
##   sleeping: bool        是否允许休眠，默认 true
##   terminal_speed: float 终端速度，默认 650
##   max_linear_velocity: float 线速度上限（0 = 不钳），默认 40000
##   max_angular_velocity: float 角速度上限 rad/s（0 = 不钳），默认 1000
##   min_fragment_pixels: int 碎片小于这么多像素就丢掉，默认 4
##   ccd_ignore_mass: float 轻碎片豁免子步估计的质量阈值（0 = 关），默认 0
##   debris_max_mass / debris_min_speed: 灰尘清理阈值（前者 > 0 才生效；后者 0 = 不限速度），默认关
##   native: bool          是否启用扩展加速（没有扩展会自动回退），默认 true
##   auto_render: bool     默认 true
func configure(opts: Dictionary) -> void:
	if opts.has("gravity"):
		world.gravity = opts["gravity"]
	if opts.has("fixed_dt"):
		world.fixed_dt = opts["fixed_dt"]
	if opts.has("max_substeps"):
		world.max_substeps = int(opts["max_substeps"])
	if opts.has("sleeping"):
		world.sleeping_enabled = bool(opts["sleeping"])
	if opts.has("terminal_speed"):
		world.terminal_speed = opts["terminal_speed"]
	# ---- 速度上限与灰尘策略 ----
	# ⚠️ 这几个都是"**没给就不动**"（与 rp_joint_solver_* 那组同一个规矩）：
	#    它们的默认值已经写进 PWorld，configure 只负责**覆盖**。
	if opts.has("max_linear_velocity"):
		world.rp_max_linear_velocity = float(opts["max_linear_velocity"])
	if opts.has("max_angular_velocity"):
		world.max_angular_velocity = float(opts["max_angular_velocity"])
	if opts.has("min_fragment_pixels"):
		world.min_fragment_pixels = int(opts["min_fragment_pixels"])
	if opts.has("ccd_ignore_mass"):
		world.ccd_ignore_mass = float(opts["ccd_ignore_mass"])
	if opts.has("debris_max_mass"):
		world.debris_max_mass = float(opts["debris_max_mass"])
	if opts.has("debris_min_speed"):
		world.debris_min_speed = float(opts["debris_min_speed"])
	# ⚠️ 这里以前有 opts["native"] -> world.use_native_solve / use_native_broadphase
	#    / use_native_collide。那些开关在"只保留 Rapier"时删掉了，但这几行留了下来
	#    —— 一旦有人传 native 就会报 "Invalid assignment ... on a base object"。
	#    现在物理只有一条路（Rapier），没有可选项。
	if opts.has("auto_render"):
		auto_render = bool(opts["auto_render"])


func set_gravity(g: Vector2) -> void:
	world.gravity = g


# ============================================================ 材质（颜色 + 密度 + 质量）

## 定义一种材质：**颜色和密度一次设好**，不用再去维护两张表。
## id 从 1 开始（0 保留给"空"）。
func define_material(id: int, color: Color, density: float = 1.0) -> void:
	if id <= 0:
		push_error("材质 id 必须 > 0（0 保留给「空」）")
		return
	while _palette.size() <= id:
		_palette.append(Color(1, 1, 1))
	_palette[id] = color
	world.set_material_density(id, density)
	if _renderer != null:
		_renderer.palette = _palette
		resync()


func material_color(id: int) -> Color:
	return _palette[id] if id >= 0 and id < _palette.size() else Color(0, 0, 0, 0)


func material_density(id: int) -> float:
	return world.density_of_material(id)


## 把某个刚体的形状整体换成另一种材质并重算质量（"点燃/结冰/腐蚀"）。
func set_body_material(body: PBody, from_material: int, to_material: int) -> int:
	var n := 0
	for s in body.shapes:
		n += (s as PixelShape).remap_material(from_material, to_material)
	if n > 0:
		world.refresh_mass(body)
		_sync_body(body)
	return n


# ============================================================ 造物体

## 静态地面/墙体（世界坐标矩形）。
func add_ground(rect: Rect2, material: int = 1) -> PBody:
	var s := PixelShape.new()
	var size := Vector2i(int(round(rect.size.x)), int(round(rect.size.y)))
	s.fill_rect(Rect2i(Vector2i.ZERO, size), material)
	var b := PBody.new()
	b.position = rect.position
	b.make_static()
	world.add_body(b, [s])
	_sync_body(b)
	return b


## 动态矩形块（世界坐标位置 = 左上角）。
func spawn_rect(pos: Vector2, size: Vector2, material: int = 1) -> PBody:
	var s := PixelShape.new()
	s.fill_rect(Rect2i(Vector2i.ZERO, Vector2i(int(size.x), int(size.y))), material)
	return spawn_shape(pos, s)


## 动态圆盘。
func spawn_circle(pos: Vector2, radius: float, material: int = 1) -> PBody:
	return spawn_shape(pos, make_circle(radius, material))


## 任意像素团（引擎会自动分解成 OBB）。
func spawn_shape(pos: Vector2, shape: PixelShape) -> PBody:
	var b := PBody.new()
	b.position = pos
	world.add_body(b, [shape])
	_sync_body(b)
	return b


## 程序化生成：solid(x, y) -> bool 决定每个像素是否实心。
func spawn_from_grid(pos: Vector2, w: int, h: int, solid: Callable, material: int = 1) -> PBody:
	var s := PixelShape.new()
	for y in h:
		for x in w:
			if solid.call(x, y):
				s.set_pixel(x, y, material)
	return spawn_shape(pos, s)


## 从一张图片烘焙出实体（**每个像素可以有不同的材质**）。
##
## material_of(x, y, color) -> int：返回 **0 表示这个像素是空的**。
##
## ⚠️ 关键设计：**规则由游戏层给**。引擎只负责「按你返回的材质把像素铺进形状」这一件事，
##    至于什么颜色算什么材质、透明算不算空、笔刷边缘怎么处理 —— 全是游戏层的事。
##    这就是「引擎提供机制、规则在游戏层」那一刀。
##
## 和 spawn_from_grid 的区别：那个只有**一个**材质、只有实心/空两种结果；
## 这个能逐像素决定材质。于是「游戏层画好一张画布 -> 引擎变成实体」这条路才成立：
##
##     # 游戏层随便怎么画（TileMap、SubViewport、手搓 Image……），只要最后是一张 Image
##     var body := px.bake_image(canvas, Vector2(0, 0), func(x, y, c):
##         if c.a < 0.5:
##             return 0                                  # 透明 = 空
##         return MAT_OF_COLOR[c.to_rgba32()]            # 颜色 -> 材质
##     )
##
## 图片的尺寸就是形状的尺寸；像素 (0,0) 落在形状局部的 (0,0)（左上角），
## 和刚体 position 的约定一致（见 PixelShape 的原点约定）。
func bake_image(image: Image, pos: Vector2, material_of: Callable) -> PBody:
	var s := PixelShape.new()
	var w := image.get_width()
	var h := image.get_height()
	for y in h:
		for x in w:
			var m: int = material_of.call(x, y, image.get_pixel(x, y))
			if m != 0:
				s.set_pixel(x, y, m)
	return spawn_shape(pos, s)


## 把蓝图**固化**成实体。
##
## 蓝图（renderer.sync_blueprint）**只是画面**：不在 world.bodies 里，
## 宽相扫不到、不受重力、不被破坏。这一步才让它变成真的刚体。
##
## 「画完一笔先不固化」的循环：
##
##     var r := px.renderer()
##     r.sync_blueprint(uid, shape, xform)      # 画的时候：看得见，但没物理
##     ...                                      # （可以反复改 shape 再 sync）
##     var body := px.solidify(uid, shape, pos) # 画完了：进物理，蓝图消失
##
## 固化之后的形状和 spawn_shape 出来的完全一样 —— 同样的物理、同样的破坏、同样的渲染。
func solidify(id: int, shape: PixelShape, pos: Vector2) -> PBody:
	var r := renderer()
	if r != null and r.has_method("forget_blueprint"):
		r.forget_blueprint(id)
	return spawn_shape(pos, shape)


## 造一个圆盘形状（不建刚体）。spawn_circle 和自定义组合都用它。
func make_circle(radius: float, material: int = 1) -> PixelShape:
	var s := PixelShape.new()
	var r2 := radius * radius
	var n := int(ceil(radius))
	for y in range(-n, n + 1):
		for x in range(-n, n + 1):
			var dx := float(x) + 0.5
			var dy := float(y) + 0.5
			if dx * dx + dy * dy <= r2:
				s.set_pixel(x, y, material)
	return s


func despawn(body: PBody) -> void:
	world.remove_body(body)
	if _renderer != null:
		_renderer.forget(body.id)


# ============================================================ 查询

## 世界里的刚体（**只读**：要增删请用 spawn_*/despawn）。
func bodies() -> Array:
	return world.bodies


func body_count() -> int:
	return world.bodies.size()


## 世界坐标处是什么材质（0 = 空）。
func material_at(world_point: Vector2) -> int:
	for b: PBody in world.bodies:
		if b.rects.is_empty() or not b.aabb.has_point(world_point):
			continue
		var l := b.to_local(world_point)
		var ip := Vector2i(int(floor(l.x)), int(floor(l.y)))
		for s in b.shapes:
			var m: int = (s as PixelShape).get_pixel(ip.x, ip.y)
			if m != 0:
				return m
	return 0


func bodies_in(bounds: Rect2) -> Array:
	var out: Array = []
	for b: PBody in world.bodies:
		if bounds.intersects(b.aabb):
			out.append(b)
	return out


# ============================================================ 力

## 过质心的持续力（每帧调一次；不产生力矩）。会唤醒物体。
func push(body: PBody, force: Vector2) -> void:
	body.add_force(force)


## 在世界坐标点施加持续力 —— 该点不在质心就会同时产生力矩。
func push_at(body: PBody, force: Vector2, world_point: Vector2) -> void:
	body.add_force_at(force, world_point)


## 持续力矩（纯转动）。
func spin(body: PBody, torque: float) -> void:
	body.add_torque(torque)


## 清空某个刚体的外力累加器（不打算继续施力时调一次）。
func clear_forces(body: PBody) -> void:
	body.clear_forces()


## 瞬时冲量。world_point 省略时按过质心处理。
func impulse(body: PBody, j: Vector2, world_point: Vector2 = Vector2.INF) -> void:
	if world_point == Vector2.INF:
		body.apply_central_impulse(j)
	else:
		body.apply_impulse(j, world_point)


# ============================================================ 程序化破坏（全部世界坐标）

## 挖一个圆洞。material_delta > 0 时把破坏边缘换成该材质（烧焦/结冰）。
## 返回新产生的碎片刚体。
func carve_circle(center: Vector2, radius: float,
		material_delta: int = 0, burst_speed: float = 40.0) -> Array:
	return _after_damage(world.damage_circle(center, radius, material_delta, burst_speed))


func carve_rect(center: Vector2, half_size: Vector2,
		material_delta: int = 0, burst_speed: float = 40.0) -> Array:
	return _after_damage(world.damage_rect(center, half_size, material_delta, burst_speed))


## 沿世界坐标线段切一条沟（激光切割）。
func cut(from: Vector2, to: Vector2, radius: float,
		material_delta: int = 0, burst_speed: float = 40.0) -> Array:
	return _after_damage(world.damage_segment(from, to, radius, material_delta, burst_speed))


## 爆炸：半径内按距离衰减推开 + 圆形破坏。
## power 是**速度增量**语义（紧贴爆心的物体大约获得 power 的速度）。
func explode(center: Vector2, radius: float, power: float,
		material_delta: int = 0, burst_speed: float = 40.0) -> Array:
	return _after_damage(world.explode(center, radius, power, material_delta, burst_speed))


## 只改颜色不破坏（世界坐标圆）。返回改动的像素数。
func paint_circle(center: Vector2, radius: float, material: int) -> int:
	var n: int = world.paint_circle(center, radius, material)
	if n > 0:
		resync()
	return n


# ============================================================ 抓取

## 抓住世界坐标点附近的刚体。返回是否抓住。
func grab_at(world_point: Vector2, accel: float = 2500.0) -> bool:
	var best: PBody = null
	var best_d := 1.0e18
	for b: PBody in world.bodies:
		if b.is_static or b.rects.is_empty() or not b.aabb.grow(2.0).has_point(world_point):
			continue
		var d := b.com_world().distance_squared_to(world_point)
		if d < best_d:
			best_d = d
			best = b
	if best == null:
		return false
	world.grab(best, world_point, accel)
	return true


func drag_to(world_point: Vector2) -> void:
	if world.is_grabbing():
		world.set_grab_target(world_point)


func release() -> void:
	world.release_grab()


func has_grab() -> bool:
	return world.is_grabbing()


# ============================================================ 关节

## 铰链：两个刚体绕一个世界坐标点相对转动（门、轮子、摆）。
## b 传 null = 接静态世界（比如把吊桥挂在"墙"上）。anchor 省略取两端质心中点。
func add_hinge(a, b, world_anchor := Vector2.INF):
	return world.add_hinge(a, b, world_anchor)


## 滑轨：沿 axis（**世界方向**）相对平移（活塞、抽屉）。
func add_slider(a, b, world_anchor := Vector2.INF, axis := Vector2.RIGHT):
	return world.add_slider(a, b, world_anchor, axis)


## 焊接：完全锁死（把两块拼成一块）。
func add_weld(a, b, world_anchor := Vector2.INF):
	return world.add_weld(a, b, world_anchor)


## 绳：两点距离不超过 max_length（不可伸长）。
func add_rope(a, b, world_anchor_a: Vector2, world_anchor_b: Vector2, max_length: float):
	return world.add_rope(a, b, world_anchor_a, world_anchor_b, max_length)


## 弹簧：拉向 rest_length（力 = 刚度 × 误差 + 阻尼 × 速度误差，绝对力语义）。
func add_spring(a, b, world_anchor_a: Vector2, world_anchor_b: Vector2,
		rest_length: float, stiffness := 100.0, damping := 10.0):
	return world.add_spring(a, b, world_anchor_a, world_anchor_b, rest_length, stiffness, damping)


## ---------- 冻结 / 恢复（可逆）----------
##
## ⚠️ 和 despawn() / cull_outside() 的区别：那些是**移除**（刚体没了，回来也回不来）；
##    冻结是**暂停** —— 位置、速度、材质、关节全留着，解冻后接着跑。
##    "相机外扩两个区块、超出冻结、回来恢复"要的是这一组。
##
## ⚠️ **隐藏节点不会停物理**（Visible=false / 移出视口都只是不画），要停就得冻。

## 冻结一个刚体（位置/速度/材质/关节都留着，解冻后接着跑）。
## ⚠️ 单冻一个是有意的能力（"把这块石头钉在空中"），但它会把关节另一头拽住；
##    要连关节组一起冻用 freeze_component()，相机剔除用 cull_freeze()。
func freeze(body) -> bool:
	return world.freeze(body)


## 解冻：恢复成动态并唤醒。
func unfreeze(body) -> void:
	world.unfreeze(body)


func is_frozen(body) -> bool:
	return world.is_frozen(body)


## 冻结整个关节组件（铰链/滑轨/绳都算连通），返回冻住的数量。
func freeze_component(body) -> int:
	return world.freeze_component(body)


## 相机剔除（**可逆**）：范围外冻结、范围内恢复。
## keep 传"必须保持计算的刚体"（玩家、手上的东西）—— 它们所在的**整个关节组件**都不会被冻。
## 返回 {"frozen": 本次冻住数, "unfrozen": 本次恢复数, "kept": 保持计算数}。
##
## 用法（区块外扩 2 格由游戏层算，引擎只认世界矩形）：
##     var r := Rect2(cam_topleft - Vector2.ONE * 2 * chunk, cam_size + Vector2.ONE * 4 * chunk)
##     px.cull_freeze(r, [player_body])
func cull_freeze(rect: Rect2, keep: Array = []) -> Dictionary:
	return world.cull_freeze(rect, keep)


## 断开一个关节。
func remove_joint(j) -> void:
	world.remove_joint(j)


## 连在这个刚体上的所有关节。
func joints_of(body) -> Array:
	return world.joints_of(body)


## 这个刚体是否（直接或间接）被关节连到静态世界。
func is_jointed_to_static(body) -> bool:
	return world.is_jointed_to_static(body)


# ============================================================ 查询

## 像素级精确的射线检测 —— 直接走体素网格，所以能穿过像素画的空洞。
## 返回 Query.Hit（hit / distance / point / normal / material / body / shape）。
## radius > 0 时是"加粗射线"（扫掠一个半径 radius 的圆）。
func raycast(origin: Vector2, direction: Vector2, max_dist: float,
		radius: float = 0.0) -> Query.Hit:
	return Query.raycast(origin, direction, max_dist, radius)


## 离 origin 最近的实心像素。
func closest_point(origin: Vector2, max_dist: float) -> Query.Hit:
	return Query.closest_point(origin, max_dist)


## 查询时排除某些刚体（一直生效到 query_clear_filters）。
func query_reject_body(body: PBody) -> void:
	Query.reject_body(body)


## 只查询这些碰撞层（位掩码，一直生效到 query_clear_filters）。
## 判据是单向的：刚体的 collision_layer 与它有交集才被看见。
func query_require(mask: int) -> void:
	Query.require(mask)


## 在已有要求上追加可命中的层。
func query_include(mask: int) -> void:
	Query.include(mask)


func query_clear_filters() -> void:
	Query.clear_filters()


## 设置刚体的碰撞层与掩码（位掩码，语义同 Godot 的 collision_layer / collision_mask）。
##
## layer = 0 表示"不在任何层"：它碰不到任何东西，任何东西也碰不到它 ——
## 这是"临时关掉一个刚体"的正当做法（不重建碰撞体、不丢状态）。
func set_collision_filter(body, layer: int, mask: int) -> void:
	body.collision_layer = layer
	body.collision_mask = mask


# ============================================================ 标签

## 给刚体打标签，之后用 find_body / find_bodies 按名字找它。
func set_tag(body: PBody, tag: String, value = null) -> void:
	body.tags[tag] = value


func has_tag(body: PBody, tag: String) -> bool:
	return body.tags.has(tag)


func tag_value(body: PBody, tag: String):
	return body.tags.get(tag)


func remove_tag(body: PBody, tag: String) -> void:
	body.tags.erase(tag)


func list_tags(body: PBody) -> Array:
	return body.tags.keys()


func find_body(tag: String) -> PBody:
	return world.find_body(tag)


func find_bodies(tag: String) -> Array:
	return world.find_bodies(tag)


func find_shapes(tag: String) -> Array:
	return world.find_shapes(tag)


# ============================================================ 刚体辅助

## 重力缩放：0 = 不受重力，负数 = 反重力。
func set_gravity_scale(body: PBody, scale: float) -> void:
	body.gravity_scale = scale


func set_velocity(body: PBody, v: Vector2) -> void:
	body.linear_velocity = v
	body.awake = true
	body.sleep_timer = 0.0


func set_angular_velocity(body: PBody, w: float) -> void:
	body.angular_velocity = w
	body.awake = true
	body.sleep_timer = 0.0


func set_active(body: PBody, active: bool) -> void:
	body.awake = active
	body.sleep_timer = 0.0


func is_active(body: PBody) -> bool:
	return body.awake


## 刚体上某一点的世界速度（含转动贡献）。
func velocity_at(body: PBody, world_point: Vector2) -> Vector2:
	return body.velocity_at(world_point)


func center_of_mass(body: PBody) -> Vector2:
	return body.com_world()


## ---- 动力学量 ----
##
## ⚠️ 符号约定（2D，Godot 的 y 轴向下）：
##   角速度为正 = 屏幕上**顺时针**转；角动量的符号与它一致。


func mass_of(body: PBody) -> float:
	return body.mass


func inertia_of(body: PBody) -> float:
	return body.inertia


## 角速度，弧度/秒（正 = 屏幕上顺时针）。
func angular_velocity_of(body: PBody) -> float:
	return body.angular_velocity


## 线动量 p = m·v。
func momentum(body: PBody) -> Vector2:
	return body.linear_momentum()


## 角动量 L = I·ω，关于**质心**。
func angular_momentum(body: PBody) -> float:
	return body.angular_momentum()


## 关于世界某点的角动量：L = I·ω + r × m·v。
## 判断"绕某个轴转不转"要用这个（比如绕钉子摆动的木板）。
func angular_momentum_about(body: PBody, world_point: Vector2) -> float:
	return body.angular_momentum_about(world_point)


## 动能 ½m|v|² + ½Iω²。
func kinetic_energy(body: PBody) -> float:
	return body.kinetic_energy()


## 力矩**冲量**（角冲量），一次性改变角速度。
## 持续力矩用 spin()（每帧调）。
func torque_impulse(body: PBody, t: float) -> void:
	body.apply_torque_impulse(t)


## 给整个系统做守恒检查用：总动量 / 关于质心的总角动量 / 总动能 / 整体质心。
##
## ⚠️ 只有**没有外力**（重力、摩擦、阻尼）时总量才守恒。本引擎有线性阻尼
##    （每步 ×1/(1+0.35·dt)），所以长时间会缓慢衰减 —— 短窗口内检查才准。
func total_momentum() -> Vector2:
	return world.total_momentum()


func total_angular_momentum(about: Vector2 = Vector2.INF) -> float:
	var p: Vector2 = world.center_of_mass_world() if about == Vector2.INF else about
	return world.total_angular_momentum(p)


func total_kinetic_energy() -> float:
	return world.total_kinetic_energy()


func system_center_of_mass() -> Vector2:
	return world.center_of_mass_world()


func bounds(body: PBody) -> Rect2:
	return body.aabb


## 刚体的**世界坐标凸包**（多边形碰撞箱拟合）—— **与 bounds() 并列**的另一种包围体。
##
## 比 bounds() 紧：AABB 是轴对齐的，刚体一转就按外接半径膨胀（100x8 的板转 45 度
## 就是 76x76 的空盒子）；凸包跟着刚体一起转。判定贵一点（O(顶点数) vs O(1)），
## 所以"能粗筛就粗筛"的地方仍然该先用 bounds()。
##
## 返回：世界坐标顶点，**不含首点**（不开环）。空刚体返回空数组。
##
## ⚠️ 它是**包围体，不是碰撞形状**：凹形状（L 形墙、楼梯）的凹角会被填平，
##    拿它去碰撞会多出看不见的体积。物理真正用的是碰撞矩形（`body.rects`）。
func hull(body: PBody) -> PackedVector2Array:
	return body.world_hull()


## 世界坐标点是否落在刚体的凸包内（**保守**：凸包比像素集大，
## 返回 true **不代表**那个点上有像素 —— 要精确判定用 material_at()）。
func hull_contains(body: PBody, world_point: Vector2) -> bool:
	return body.hull_contains(world_point)


## 刚体**真的在用**的碰撞体形状（世界坐标的凸多边形数组）。
##
## 引擎默认把像素拟合成的**凸多边形**交给 Rapier（斜边是直的：楼梯的锯齿会被拉成
## 一条斜线），所以这里的多边形就是物理实际用的形状 —— 不是另算一份近似。
## 走矩形那条路（`world.poly_colliders = false` 或矩形数超预算）时，返回的是
## 每个碰撞矩形（4 个角）。
##
## ⚠️ 它是**惰性**读回（形状不变就复用缓存），可以每帧调；但**别在编辑器里调** ——
##    编辑器不跑物理，刚体还没有 Rapier 身份，会返回空数组。
func colliders(body: PBody) -> Array:
	return world.fetch_polys(body)


## 是否已经被打碎（形状全空）。
func is_broken(body: PBody) -> bool:
	for s in body.shapes:
		if not (s as PixelShape).is_empty():
			return false
	return true


# ============================================================ 形状辅助

func shape_body(shape: PixelShape) -> PBody:
	return shape.owner_body


func shape_bounds(shape: PixelShape) -> Rect2i:
	return shape.local_aabb()


## 形状的凸包（**形状局部像素坐标**）—— 与 shape_bounds() 并列的另一种包围体。
##
## ⚠️ 与 shape_bounds() 的缓存口径不同：那个跟着"内容版本"走，**每帧都问也便宜**；
##    这个按 revision 作废，第一次调用要扫一遍块（768x100 地面约 1 万次行扫描），
##    所以**别在每帧的热循环里对同一个没改过的形状反复调** —— 缓存会兜住，
##    但形状一改就要重算。要世界坐标请用 hull(body)。
func shape_hull(shape: PixelShape) -> PackedVector2Array:
	return shape.local_hull()


func shape_voxels(shape: PixelShape) -> int:
	return shape.pixel_count()


## **世界坐标**处的材质 id（0 = 空）。
func shape_material_at(shape: PixelShape, world_point: Vector2) -> int:
	return ShapeOps.material_at_position(shape, world_point)


## 形状局部像素坐标处的材质 id。
func shape_material_at_index(shape: PixelShape, x: int, y: int) -> int:
	return shape.get_pixel(x, y)


func set_shape_density(shape: PixelShape, d: float) -> void:
	ShapeOps.set_density(shape, d)


## 按连通性切分：最大的那块留在原形状，其余挂到同一刚体上并返回。
func split_shape(shape: PixelShape) -> Array:
	return ShapeOps.split(shape)


## 把同一刚体里与本形状相邻的形状并进来。
func merge_shape(shape: PixelShape) -> PixelShape:
	return ShapeOps.merge(shape)


func is_shape_touching(a: PixelShape, b: PixelShape) -> bool:
	return ShapeOps.is_touching(a, b)


func is_shape_disconnected(shape: PixelShape) -> bool:
	return ShapeOps.is_disconnected(shape)


func shape_closest_point(shape: PixelShape, world_point: Vector2) -> Query.Hit:
	return ShapeOps.closest_point(shape, world_point)


func create_shape(body: PBody, ref: PixelShape = null) -> PixelShape:
	return ShapeOps.create(body, ref)


func clear_shape(shape: PixelShape) -> void:
	ShapeOps.clear(shape)


func copy_shape_content(src: PixelShape, dst: PixelShape) -> void:
	ShapeOps.copy_content(src, dst)


## 用矩形填一段像素（material = 0 等价于擦除）。
func draw_shape_box(shape: PixelShape, rect: Rect2i, material: int = 1) -> void:
	ShapeOps.draw_box(shape, rect, material)


# ============================================================ 推进与渲染

## 推进。内部用固定步长累加器，所以外部帧率波动不会改变物理结果。
## 推进。内部用固定步长累加器，所以外部帧率波动不会改变物理结果。
##
## **外力语义**：底层 PWorld 是持久的 ClearForces 模型（add_force 会一直累积到
## 显式清空）。门面把它改成更贴合游戏循环的语义 —— **力只作用于本帧**，
## 下一帧不 push 就没有力。这样既不用记得清空，也不会出现"忘了清空导致力越滚越大"。
## 需要持续力就每帧 push 一次。
## ---- 接触数据（只读，轮询）----
##
## ⚠️ 为什么门面要包一层：门面的规矩是"调用方只需要认识这一个类"，
##    而接触数据原本只能从 world 逃生口拿（`.world` 的注释写着"想直接调底层接口时用它，
##    但优先用门面的方法"）。加在这里，调用方就不用碰底层。
##
## ⚠️ 两条使用约定：
##   · **不需要开事件**：下面三个查询直接读求解器，每帧都能查。
##     （`Contact` 事件那条路要 `world.contact_events_enabled = true` —— 每步构造对象有开销。）
##   · **在步进之后查**：接触是 step 的产物 —— 在 `_process` 或靠后的 `_physics_process` 里查。
##
## ⚠️ 项目一贯用**轮询**而不是 signal（节点层一个 signal 都没有，`broken_joints` 也是这样），
##    所以这里给的是方法，不是信号。
func contact_pair_count() -> int:
	if world == null:
		return 0
	return world.contact_pair_count()


## 第 idx 个接触对的**全部**接触点：{normal, position, dist, impulse, fid1, fid2}
##   position 世界坐标；normal 世界系法向（由 a 指向 b）
##   dist < 0 才是真穿透；> 0 是推测接触（还没碰上，只是被拦住）
##   impulse 是**该点自己的**冲量 —— 面-面接触通常 2 个点，而不是"一个点背着整个面的冲量"
func contact_points(idx: int) -> Array:
	if world == null:
		return []
	return world.contact_points(idx)


## 第 idx 个接触对的配对级信息：{points, total_impulse, id_a, id_b}
## ⚠️ `total_impulse` 是这次碰撞的**预算**：多个损伤入口要**共同分配**它。
func contact_info(idx: int) -> Dictionary:
	if world == null:
		return {}
	return world.contact_info(idx)


## 把第 idx 个接触对变成**多个损伤入口**，并按各点冲量分配这次碰撞的预算。
## 返回 [{point, impulse, share, radius, penetrating}, ...]（半径按 sqrt(份额) 分配）。
##
## ⚠️ 这是**游戏规则**的原料，不是规则本身：引擎只给"各点冲量 + 整对总冲量"，
##    "多猛算高速""要不要打洞"由调用方决定。
func contact_entries(idx: int, base_radius: float, min_share: float = 0.05) -> Array:
	if world == null:
		return []
	var info: Dictionary = world.contact_info(idx)
	return Destruction.contact_entries(info["points"], info["total_impulse"], base_radius, min_share)


func step(delta: float) -> void:
	_accum += delta
	var steps := 0
	while _accum >= world.fixed_dt and steps < world.max_substeps:
		world.step(world.fixed_dt)
		_accum -= world.fixed_dt
		steps += 1
	if steps == world.max_substeps:
		_accum = 0.0
	_clear_all_forces()
	if auto_render:
		_sync_renderer()


func _clear_all_forces() -> void:
	for b: PBody in world.bodies:
		if not b.is_static:
			b.clear_forces()


## 手动步进一次（无累加器）。
func step_once(dt: float = -1.0) -> void:
	world.step(world.fixed_dt if dt <= 0.0 else dt)
	if auto_render:
		_sync_renderer()


## 渲染层（第一次访问时惰性创建；不想要渲染就永远别访问它）。
func renderer() -> Node2D:
	if _renderer == null:
		_renderer = PixelRenderer.new()
		_renderer.name = "PixelRenderer"
		add_child(_renderer)
		_renderer.palette = _palette
	return _renderer


## 强制重建所有贴图（改了调色板之后调用）。
func resync() -> void:
	if _renderer == null:
		return
	for b: PBody in world.bodies:
		if not _wants_internal_render(b):
			_renderer.forget(b.id)
			continue
		_renderer.sync(b)


## 这个刚体要不要进**内部渲染器**（画贴图）。
##
## ⚠️⚠️ 判据必须和节点层（PixelWorld.uses_internal_render）**一致**，否则"只物理不渲染"
##    在门面这条路（代码驱动的项目，比如 ink-2）上会**静默失效** —— 症状就是
##    "明明配了不渲染，破坏之后还是冒出一张停在旧位置的矩形贴图"。
##    ⚠️ 门面这条路没有节点，所以只能看 **PBody 上的 internal_render**；
##    节点层还额外看"这个节点有没有自带视觉（PixelSprite2D）"。
func _wants_internal_render(b: PBody) -> bool:
	return b.internal_render


func _sync_body(b: PBody) -> void:
	if auto_render and _renderer != null:
		if not _wants_internal_render(b):
			_renderer.forget(b.id)      # 关掉渲染之后要把旧贴图**回收**，不是留着
			return
		_renderer.sync(b)


## 每帧维护渲染层。include_static=false 时**跳过静态体**（与节点层同一条判据）：
## 静态体的几何只在破坏时变，而那时调用方会走 _after_damage(true)。
##
## ⚠️ 实测（tests/_bench_syncpath.gd，1 个 768x100 地面 + 200 个动态方块）：
##    每帧 1.558 ms（全部）vs 1.530 ms（跳过静态）—— 差值只有 0.028 ms（2%），
##    因为内容没变的静态体一次 sync 只要 6 us。所以这条**不是**为了省那 2%，
##    而是为了让门面与节点层**语义一致**（不然"静态体不用每帧同步"这条经验在两条路上不一致，
##    以后谁改都会改错一边）。
func _sync_renderer(include_static := false) -> void:
	if _renderer == null:
		return
	var live := {}
	for b: PBody in world.bodies:
		live[b.id] = true
		if b.is_static and not include_static:
			continue
		if not _wants_internal_render(b):
			_renderer.forget(b.id)
			continue
		_renderer.sync(b)
	_renderer.prune(live)


## 破坏会让引擎增删刚体 —— 门面负责让渲染层跟上，调用方什么都不用做。
##
## ⚠️ 这里必须 include_static=true：**静态地形也会被打坏**，跳过它就等于
##    "地面被挖了洞，画面上还是完整的"（而且不报任何错）。
func _after_damage(fragments: Array) -> Array:
	if auto_render:
		_sync_renderer(true)
	return fragments
