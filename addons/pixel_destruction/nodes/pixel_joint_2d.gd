@tool
extends Node2D
## **可放置的场景节点**：在 Godot 场景编辑器里摆一个关节，而不是用代码建。
##
## ## 为什么关节也要节点化
##
## 关卡（地面/墙/箱子）已经是节点了 —— 编辑器里能选中、能拖、能改尺寸。
## 关节如果只能在代码里建，那"吊桥挂在哪个点、限位多少度、马达多快"就得
## 改一次代码、跑一次游戏才知道对不对。节点化之后：
##
##   · 关节节点的 **position 就是锚点 A**（拖它 = 拖支点）；
##   · 参数全在 Inspector 里，改完编辑器里立刻能看到连线变化；
##   · 和 @@PixelBody2D@@ 一样，**烘焙只发生一次**，之后热循环里不碰 Node。
##
## ## 用法
##
## 放在 @@PixelWorld@@ 下面（和 PixelBody2D 同级），把 body_a / body_b 指向
## 两个 PixelBody2D 节点。**留空 = 接静态世界**（例如把吊桥挂在墙上）。
##
## 参数含义见 @@src/physics/joint.gd@@（PJoint）—— 这一层只做翻译。
##
## ⚠️ 关节没有可见的物理形状，所以本节点**自己把锚点连线画出来**：
##    不画的话，编辑器里"有关节"和"没关节"看起来一模一样。
##    运行时也画（可关：debug_draw），因为绳/弹簧/铰链在物理里本来就是隐形的。

const _PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")

enum Kind { HINGE, SLIDER, WELD, ROPE, SPRING }
enum Motor { OFF, VELOCITY, POSITION }

@export_group("连接")
@export var kind: Kind = Kind.HINGE
## 两端的 PixelBody2D。**留空 = 静态世界**（另一端挂在"世界"上）。
@export var body_a: NodePath
@export var body_b: NodePath
## 锚点 B 相对本节点位置的偏移。**只有绳/弹簧用得到**（两端锚点不同）；
## 铰链/滑轨/焊接只有一个锚点（就是本节点的位置）。
@export var anchor_b_offset := Vector2.ZERO
## 滑轨的轴（**世界方向**）。两端朝向不同也能对上（见 rb_joint_new 的说明）。
@export var axis := Vector2.RIGHT

@export_group("限位")
## 只有铰链（角度）与滑轨（距离）有限位。绳/弹簧的"长度"是 rest_length。
@export var limits_enabled := false
@export var min_limit := -1.0
@export var max_limit := 1.0

@export_group("马达")
@export var motor: Motor = Motor.OFF
## 速度模式 = 目标速度（rad/s 或 px/s）；位置模式 = 目标角度/距离。
@export var motor_target := 0.0
## 0 = 禁用（对应参考 API 里 "strength 0 = 关闭" 的语义）。
@export var motor_max_force := 1.0e7
@export var motor_stiffness := 100.0
@export var motor_damping := 100.0

@export_group("绳 / 弹簧")
## 绳 = 最大长度；弹簧 = 静止长度。
@export var rest_length := 50.0
## 弹簧刚度（Rapier 的 ForceBased：力 = 刚度 x 误差 + 阻尼 x 速度误差）。
## ⚠️ 平衡点在静止长度下方 m*g/刚度 处 —— 要按**重量**选，见 demo 场景里的注释。
@export var stiffness := 10000.0
@export var damping := 800.0

@export_group("接触")
## 两个被本关节连着的刚体之间**要不要生成接触**。默认 **关**。
##
## ⚠️ 打开它 = 让接触求解器和关节对着干："焊住但体素重合"的两个刚体会一直抽搐。
## 只有确实需要"连在一起还互相挡"时才开。
@export var contacts_enabled := false

@export_group("断裂")
## 约束冲量（力 x 时间步）超过它就断。**0 = 不断**。
@export var break_impulse := 0.0

@export_group("调试")
## 是否画锚点连线。
##
## ⚠️ **运行时只在 DebugOverlay 可见时才画**（甲方要求：约束的调试画法不能出现在
##    游戏画面里）。编辑器里**始终**画 —— 不然摆关节时"有约束"和"没约束"一模一样。
@export var debug_draw := true

## 烘焙出来的 PJoint（RefCounted）。编辑器里是 null，运行时才有值。
##
## ⚠️ 和 PixelBody2D.body 一样**不加 @export**：@export 只允许内置类型 /
##    Resource / Node / enum，PJoint 是 RefCounted。
var joint = null


## 屏幕 1 像素 = 多少**世界单位**。
##
## ⚠️⚠️ 用**画布到视口的变换**（get_viewport_transform），**不要**用相机 zoom。
##    相机 zoom 只描述"游戏里"的缩放：在编辑器里它可能是任意值 —— 我一度把
##    render_scale 改成"取相机所在视口"，编辑器视口很小时 zoom 会掉到 0.5 左右，
##    于是点按 2/zoom 算就变成十几个像素（甲方："joint的点变得巨大无比"）。
##    get_viewport_transform() 在编辑器、游戏、SubViewport 里都是"世界 -> 屏幕"的
##    真实变换，取它的 scale 永远是对的：编辑器里 = 2 个编辑器像素，游戏里 = 2 个屏幕像素。
func _screen_unit() -> float:
	var sc := get_viewport_transform().get_scale()
	if absf(sc.x) <= 0.0001:
		return 1.0
	return 1.0 / sc.x


## 现在该不该画：编辑器里始终画；运行时看 DebugOverlay 的可见性。
func debug_visible_now() -> bool:
	if Engine.is_editor_hint():
		return true
	if not debug_draw:
		return false
	var ov := _debug_overlay()
	return ov != null and (ov as CanvasItem).visible


## 同级（PixelWorld 下）的 DebugOverlay。没有就当作"调试视图没开"。
func _debug_overlay() -> Node:
	var p := get_parent()
	return p.get_node_or_null("DebugOverlay") if p != null else null


func _init() -> void:
	set_notify_transform(true)


func _enter_tree() -> void:
	# ⚠️ 必须显式打开，否则 NOTIFICATION_TRANSFORM_CHANGED 不会发（同 PixelBody2D）。
	set_notify_transform(true)
	# ⚠️ 必须画在**像素精灵之上**：PixelRenderer 的 Sprite2D 是 PixelWorld.rebuild()
	#    时追加进去的，排在关节节点后面 —— 锚点上的圆点会被刚体精灵整个盖住
	#    （实测：滑轨的锚点在箱子内部，屏幕上**一个像素都看不到**）。
	if z_index == 0:
		z_index = 5
	# ⚠️ DebugOverlay 的显示/隐藏要能立刻反映到约束画法上（甲方按 D 切视图）。
	#    不连这个信号的话，切了视图关节还停在上一帧画出来的样子。
	var ov := _debug_overlay()
	if ov is CanvasItem:
		var ci := ov as CanvasItem
		if not ci.visibility_changed.is_connected(queue_redraw):
			ci.visibility_changed.connect(queue_redraw)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		queue_redraw()
		# ⚠️ 只 queue_redraw 是不够的：**烘焙过之后画的是物理锚点**（anchor_a_world()
		#    优先返回 joint.anchor_a_world()），而那个锚点是上次 bake() 时的位置 ——
		#    于是编辑器里拖关节节点，线不跟手、物理锚点也停在原地，
		#    直到下一次 rebuild()（而 rebuild 会丢掉所有破坏状态，不能拿它兜底）。
		#    所以拖动必须请求**重烘焙这一个关节**。
		if Engine.is_editor_hint():
			var p := get_parent()
			if p != null and p.has_method("on_joint_transformed"):
				p.on_joint_transformed(self)


## 运行时锚点会跟着刚体跑 —— 每帧重画一次连线。
## ⚠️ 编辑器里不跑（关节不动，画一次就够）；但**这个守卫必须写在函数体里**：
##    定义 _process 本身就会启用它，_enter_tree 里的判断挡不住。
func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if debug_visible_now():
		queue_redraw()


## 把一个 PixelBody2D 的 NodePath 解析成已经烘焙好的 PBody。
## 留空 -> null（= 静态世界）。
func _resolve_body(path: NodePath, which: String):
	if path.is_empty():
		return null
	var n := get_node_or_null(path)
	if n == null:
		push_warning("[PixelJoint2D] %s 的 %s 指向不存在的节点：%s" % [name, which, path])
		return null
	if not (n is _PixelBody2D):
		push_warning("[PixelJoint2D] %s 的 %s 不是 PixelBody2D：%s" % [name, which, path])
		return null
	return n.body


## 烘焙成世界里的一个关节。由 PixelWorld 在**所有刚体之后**调用。
## 失败（两端都空 / 参数非法）返回 null。
func bake(world) -> Variant:
	if world == null:
		return null
	var a = _resolve_body(body_a, "body_a")
	var b = _resolve_body(body_b, "body_b")
	if a == null and b == null:
		push_warning("[PixelJoint2D] %s 两端都空：至少要有一端是刚体" % name)
		return null
	var wa := global_position
	var wb := global_position + anchor_b_offset
	match kind:
		Kind.HINGE:
			joint = world.add_hinge(a, b, wa)
		Kind.SLIDER:
			joint = world.add_slider(a, b, wa, axis)
		Kind.WELD:
			joint = world.add_weld(a, b, wa)
		Kind.ROPE:
			joint = world.add_rope(a, b, wa, wb, rest_length)
		Kind.SPRING:
			joint = world.add_spring(a, b, wa, wb, rest_length, stiffness, damping)
	if joint == null:
		return null
	# ⚠️ 用 bool() 兜一次 null：**编辑器在"脚本新增导出属性"之后重存场景**时，
	#    节点实例上还没有这个属性，get() 拿到 null，于是场景文件里被写成
	#    `contacts_enabled = null`（实测 demo.tscn 里 10 个关节全中）。
	#    直接赋值会报 "Invalid assignment of property or key 'contacts_enabled'
	#    with value of type 'Nil'"，而且**只在运行时炸**。
	joint.contacts_enabled = bool(contacts_enabled)
	if limits_enabled:
		joint.set_limits(min_limit, max_limit)
	match motor:
		Motor.VELOCITY:
			joint.set_motor_velocity(motor_target, motor_max_force, motor_damping)
		Motor.POSITION:
			joint.set_motor_target(motor_target, motor_max_force, motor_stiffness, motor_damping)
	if break_impulse > 0.0:
		joint.break_impulse = break_impulse
	queue_redraw()
	return joint


## 锚点 A 的世界坐标：烘焙过就用**关节的实时锚点**，否则用节点位置。
func anchor_a_world() -> Vector2:
	if joint != null and joint.active:
		return joint.anchor_a_world()
	return global_position


func anchor_b_world() -> Vector2:
	if joint != null and joint.active:
		return joint.anchor_b_world()
	return global_position + anchor_b_offset


func _kind_color() -> Color:
	match kind:
		Kind.HINGE:
			return Color(0.45, 0.85, 1.0, 0.85)
		Kind.SLIDER:
			return Color(1.0, 1.0, 1.0, 0.8)
		Kind.WELD:
			return Color(1.0, 0.5, 0.9, 0.85)
		Kind.ROPE:
			return Color(0.95, 0.8, 0.3, 0.9)
		_:
			return Color(0.4, 1.0, 0.5, 0.9)


func _draw() -> void:
	if not debug_visible_now():
		return
	# 画的是**锚点**，不是形状：关节在物理里没有形状，只有约束。
	# 线宽/点半径按相机 zoom 反算成"屏幕 1~2 像素"（见 _screen_unit）。
	var u := _screen_unit()
	var a := to_local(anchor_a_world())
	var b := to_local(anchor_b_world())
	var col := _kind_color()
	draw_line(a, b, col, 1.0 * u)
	# 滑轨额外画一条**轴线**。
	#
	# ⚠️ 铰链/滑轨/焊接只有**一个**锚点（两端重合），只画点的话整个关节会被
	#    刚体精灵盖住 —— 实测滑轨在屏幕上"一个像素都没有"，看图的人只能猜
	#    "白=滑轨"到底是什么。轴线伸到刚体外面，顺便把"能往哪个方向滑、
	#    能滑多远"也画出来了（有限位时按限位长度画）。
	if kind == Kind.SLIDER:
		var ax := axis
		if joint != null and joint.active:
			ax = joint.world_axis()
		var half := maxf(4.0, absf(max_limit)) if limits_enabled else 8.0
		draw_line(a - ax * half, a + ax * half, col, 1.0 * u)
		draw_line(a - ax * half, a - ax * half + Vector2(-ax.y, ax.x) * 2.0, col, 1.0 * u)
		draw_line(a + ax * half, a + ax * half + Vector2(-ax.y, ax.x) * 2.0, col, 1.0 * u)
	draw_circle(a, 2.0 * u, col)
	draw_circle(b, 2.0 * u, col)