@tool
extends Node2D
## 物理调试叠加层：把引擎内部状态画出来，**运行时和编辑器里都能看**。
##
## 甲方要求「能在场景编辑器中可视化」。这里的做法是 @tool + _draw()：
##   · 编辑器里画的是**当前场景里已有的刚体**（静态摆好的那些），不推进物理；
##   · 运行时每帧重画。
##
## ⚠️ 绝对不要在这个脚本里推进物理。@tool 的 _process 在编辑器里也会跑，
##    一旦 step 就会污染场景、还会让编辑器卡死（而且存盘时把结果写进去）。
##
## 用法：把本节点加到场景里，把 world_source 指到 PixelPhysics 节点即可。
## 什么都不指的话会自动往上找兄弟节点里的 PixelPhysics。

@export var world_source: NodePath

## ---- 画什么（Inspector 里勾）----
@export_group("显示内容")
@export var show_obbs := true              ## 碰撞矩形（贪心分解的结果，物理实际用的形状）
@export var show_aabbs := false            ## 刚体 AABB（宽相用的粗包围盒）
@export var show_swept_aabbs := false      ## 扫掠 AABB（含本步位移，CCD 用）
@export var show_contacts := true          ## 接触点 + 法向
@export var show_velocity := false         ## 线速度矢量
@export var show_angular := false          ## 角速度弧线
@export var show_com := true               ## 质心
@export var show_awake := true             ## 用颜色区分清醒/休眠
@export var show_ids := false              ## 刚体 id
@export var show_stats := true             ## 左上角统计文字

@export_group("外观")
@export var obb_color := Color(0.3, 0.9, 1.0, 0.9)
@export var aabb_color := Color(0.5, 0.5, 0.5, 0.5)
@export var swept_color := Color(1.0, 0.6, 0.2, 0.4)
@export var contact_color := Color(1.0, 0.25, 0.25, 1.0)
@export var velocity_color := Color(0.4, 1.0, 0.4, 0.9)
@export var angular_color := Color(1.0, 0.9, 0.3, 0.9)
@export var com_color := Color(1.0, 1.0, 1.0, 0.9)
@export var asleep_color := Color(0.4, 0.4, 0.45, 0.8)
@export var awake_color := Color(0.3, 0.9, 1.0, 0.9)
@export var stats_color := Color(1, 1, 1, 0.85)

@export_group("比例")
## 速度矢量的长度 = 速度 × 这个系数（像素/（像素·秒⁻¹））
@export var velocity_scale := 0.25
@export var contact_normal_len := 12.0
@export var font_size := 12

## 被叠加的世界（PWorld）。编辑器里由 PixelWorld 通过 set_world() 注入。
var world = null


## 注入世界并重绘一次。
##
## ⚠️ 用显式方法而不是直接赋 c.world —— 直接赋在某些情况下会报
##    "Invalid assignment of property or key 'world'"，而且报错信息不指向真因。
##    方法调用没有这个歧义，也顺便把"赋值 + 重绘"绑成一件事。
func set_world(w) -> void:
	world = w
	refresh()
## 统计文字的字号要按相机 zoom 反算，否则拉近之后字会占满整个屏幕
var font_size_draw := 12.0


func _ready() -> void:
	# ⚠️ 必须画在**像素精灵之上**。
	#    PixelRenderer 的 Sprite2D 是 PixelWorld.rebuild() 时**追加**进去的 ——
	#    排在 DebugOverlay 后面，于是精灵把线盖住：1 px 宽的框有一半落在精灵里，
	#    露在外面的只剩半个像素，实测**完全看不见**（第一版就踩了这个：
	#    线宽从 6 px 改成 1 px 之后，截图里叠加层整个"消失"了）。
	if z_index == 0:
		z_index = 10
	_resolve_world()
	set_process(true)


func _process(_dt: float) -> void:
	# ⚠️⚠️ 编辑器里**绝对不要每帧 queue_redraw()**。
	#    那会让编辑器的 2D 画布永不停歇地重画，而 _draw() 要遍历所有刚体、
	#    画 OBB 四边形和接触点 —— 实测这是编辑器卡顿的主因之一。
	#    编辑器里改成**按需重绘**：由 PixelWorld.rebuild() 调 refresh()。
	if Engine.is_editor_hint():
		return
	if world == null:
		_resolve_world()
	queue_redraw()


## 请求重绘一次（编辑器里由 PixelWorld.rebuild() 调用）
func refresh() -> void:
	if world == null:
		_resolve_world()
	queue_redraw()


func _resolve_world() -> void:
	var src: Node = null
	if not world_source.is_empty():
		src = get_node_or_null(world_source)
	if src == null:
		# 没指定就自动找。⚠️ 必须**先看父节点自己**再看它的子节点 ——
		#    Demo 场景里 world 就在父节点 Demo 身上，只遍历 children 会找不到，
		#    表现是"叠加层在场景里但什么都不画"，很难查。
		var parent := get_parent()
		if parent != null:
			if "world" in parent:
				src = parent
			else:
				for c in parent.get_children():
					if c != self and "world" in c:
						src = c
						break
	if src != null and "world" in src:
		world = src.world
	else:
		world = null



## 屏幕 1 像素 = 多少**世界单位**。
##
## ⚠️ 叠加层画的是世界坐标，所以线宽/点半径不反算就会随取景缩放变粗：
##    体素 3 px + 相机 zoom 6 时，1.0 世界单位的线宽 = **6 屏幕像素**。
##    而 draw_rect/draw_polyline 的线是**以边界为中心**画的 —— 于是碰撞框
##    看起来比像素图大一圈。实测（demo_shot.png）：墙的像素在 x=948..1667，
##    叠加层外沿在 x=945..1670，正好各多 3 px = 半个线宽。
##    结论：不是坐标错了，是**线太粗**。所有线宽都乘这个系数。
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


## 世界里的刚体（没有世界就返回空，编辑器里没摆 PixelPhysics 时不该报错）
func _bodies() -> Array:
	if world == null:
		return []
	return world.bodies


func _draw() -> void:
	if world == null:
		if show_stats:
			draw_string(ThemeDB.fallback_font, Vector2(8, 18),
				"调试叠加层：找不到 world_source（把 world_source 指到 PixelPhysics 节点）",
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 0.5, 0.5, 0.9))
		return

	var bodies: Array = _bodies()
	var font := ThemeDB.fallback_font
	var u := _screen_unit()      # 线宽/点半径的换算（见 _screen_unit 的说明）

	for b in bodies:
		var col := obb_color
		if show_awake:
			col = awake_color if b.awake else asleep_color

		# ---- AABB / 扫掠 AABB ----
		if show_aabbs:
			draw_rect(b.aabb, aabb_color, false, u)
		if show_swept_aabbs:
			draw_rect(b.swept_aabb, swept_color, false, u)

		# ---- 碰撞矩形（物理真正用的形状）----
		if show_obbs:
			for r: Rect2 in b.rects:
				_draw_obb(b, r, col, u)

		# ---- 质心 ----
		if show_com and not b.is_static:
			var c: Vector2 = b.com_world()
			draw_line(c - Vector2(5, 0) * u, c + Vector2(5, 0) * u, com_color, u)
			draw_line(c - Vector2(0, 5) * u, c + Vector2(0, 5) * u, com_color, u)

		# ---- 速度矢量 ----
		if show_velocity and not b.is_static:
			var v: Vector2 = b.linear_velocity * velocity_scale
			if v.length_squared() > 1.0:
				var o: Vector2 = b.com_world()
				draw_line(o, o + v, velocity_color, 2.0 * u)
				_draw_arrow_head(o + v, v.normalized(), velocity_color, u)

		# ---- 角速度弧线（半径按角速度大小，正负用方向区分）----
		if show_angular and not b.is_static and absf(b.angular_velocity) > 0.01:
			var o2: Vector2 = b.com_world()
			var r2: float = clampf(8.0 + absf(b.angular_velocity) * 4.0, 8.0, 40.0)
			var a0 := 0.0
			var a1: float = clampf(b.angular_velocity * 0.5, -PI, PI)
			draw_arc(o2, r2, a0, a1, 16, angular_color, 2.0 * u)

		# ---- id ----
		if show_ids:
			draw_string(font, b.position + Vector2(2, -2), str(b.id),
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size - 2, col)

	# ---- 接触点 + 法向 ----
	if show_contacts:
		for m in world.manifolds:
			for p in m.points:
				draw_circle(p.position, 2.5 * u, contact_color)
				draw_line(p.position, p.position + m.normal * contact_normal_len,
					contact_color, 1.5 * u)

	# ---- 统计（贴在屏幕左上角，跟着相机走）----
	var frame := _screen_frame()
	var y: float = frame["origin"].y
	if show_stats:
		_draw_stats(bodies, font, frame, y)


## 把一个局部矩形按刚体变换画成四边形（**不是**画轴对齐矩形 ——
## 刚体可以旋转，画 AABB 会骗人）。
func _draw_obb(b, r: Rect2, col: Color, width := 1.0) -> void:
	var pts := PackedVector2Array([
		b.to_world(r.position),
		b.to_world(r.position + Vector2(r.size.x, 0)),
		b.to_world(r.position + r.size),
		b.to_world(r.position + Vector2(0, r.size.y)),
	])
	draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]), col, width)


func _draw_arrow_head(tip: Vector2, dir: Vector2, col: Color, width := 1.5) -> void:
	var n := Vector2(-dir.y, dir.x)
	var s := width / 1.5      # 箭头大小跟着线宽一起缩放（屏幕尺度恒定）
	draw_line(tip, tip - dir * 6.0 * s + n * 3.0 * s, col, width)
	draw_line(tip, tip - dir * 6.0 * s - n * 3.0 * s, col, width)


## 屏幕左上角的锚点（**世界坐标**）与"屏幕 1 像素 = 多少世界单位"。
##
## ⚠️ _draw() 画的是世界坐标，直接写 (8,18) 会跑到镜头外面去
##    （表现是"叠加层在画但看不到字"）。所以要跟着相机走：
##    视口尺寸 ÷ 相机 zoom = 可视区大小，取它的左上角再加一点边距。
func _screen_frame() -> Dictionary:
	var u := _screen_unit()
	var origin := Vector2(8, 18) * u
	var cam := get_viewport().get_camera_2d()
	if cam != null:
		var z := cam.zoom
		if z.x > 0.0 and z.y > 0.0:
			origin = cam.get_screen_center_position() - get_viewport_rect().size * 0.5 / z \
				+ Vector2(8, 18) * u
	return {"origin": origin, "u": u}


## 左上角统计。返回**画完之后**的 y（图例接着往下排）。
func _draw_stats(bodies: Array, font: Font, frame: Dictionary, y0: float) -> float:
	var awake := 0
	var dyn := 0
	for b in bodies:
		if b.is_static:
			continue
		dyn += 1
		if b.awake:
			awake += 1
	var lines := PackedStringArray([
		"刚体 %d（动态 %d，清醒 %d，休眠 %d）" % [bodies.size(), dyn, awake, dyn - awake],
		"流形 %d  接触点 %d  子步 %d" % [
			world.manifolds.size(), world.last_contacts, world.last_substeps],
		"总动量 (%.1f, %.1f)  总角动量 %.1f  总动能 %.1f" % [
			world.total_momentum().x, world.total_momentum().y,
			world.total_angular_momentum(world.center_of_mass_world()),
			world.total_kinetic_energy()],
	])
	var u: float = frame["u"]
	var origin: Vector2 = frame["origin"]
	var size := maxf(1.0, font_size * u)
	var y := y0
	for s in lines:
		draw_string(font, Vector2(origin.x, y), s, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(size), stats_color)
		y += size + 3.0 * u
	return y
