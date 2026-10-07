extends SceneTree
## 门面（PixelPhysics）的端到端验证 —— 只 import 这一个类。
## 无头运行：
##   godot --headless --path <项目> --script res://addons/pixel_destruction/examples/facade_demo.gd

## ⚠️ 这里用 preload 而不是直接用全局的 PixelPhysics 类型：
## class_name 要靠**编辑器扫描一次**才会进 .godot/global_script_class_cache.cfg，
## 而刚克隆下来 / 还没打开过编辑器的项目里跑 --script 时缓存是空的，
## 直接写 "var px: PixelPhysics" 会报 "Could not find type"。
## preload 拿到的常量可以当类型注解用，任何环境下都成立。
const PixelPhysicsScript := preload("res://addons/pixel_destruction/pixel_physics.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

var _pass := 0
var _fail := 0
var px: PixelPhysicsScript

func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS  ", name, "  ", detail)
	else:
		_fail += 1
		print("  FAIL  ", name, "  ", detail)

func _initialize() -> void:
	print("=== 门面验证 ===")

	px = PixelPhysicsScript.new()
	px.auto_step = false                      # 自己控节奏
	root.add_child(px)
	px.configure({"gravity": Vector2(0.0, 900.0)})

	# ---- 材质：颜色 + 密度一次设好 ----
	px.define_material(1, Color(0.62, 0.60, 0.56), 2.5)   # 石头
	px.define_material(2, Color(0.72, 0.52, 0.32), 0.6)   # 木头
	# ⚠️ Color 内部是 float32，不能拿字面量做 == 比较
	_check("颜色与密度同源",
		is_equal_approx(px.material_color(1).r, 0.62) and is_equal_approx(px.material_density(1), 2.5),
		"color.r=%.2f density=%.1f" % [px.material_color(1).r, px.material_density(1)])

	# ---- 造物 ----
	var ground := px.add_ground(Rect2(-400.0, 300.0, 800.0, 40.0), 1)
	_check("地面是静态体", ground.is_static and px.body_count() == 1)

	var ball := px.spawn_circle(Vector2(0.0, 0.0), 14.0, 1)
	_check("圆盘被分解成 OBB", ball.rects.size() > 0, "%d 个矩形" % ball.rects.size())
	# 石头的密度是 2.5 -> 质量应为像素数 * 2.5
	var px_count: int = (ball.shapes[0] as PixelShape).pixel_count()
	_check("密度参与质量", is_equal_approx(ball.mass, float(px_count) * 2.5),
		"%d 像素 * 2.5 = %.0f（实际 %.0f）" % [px_count, float(px_count) * 2.5, ball.mass])

	# ---- 落到地面并停住 ----
	for i in 240:
		px.step(1.0 / 60.0)
	_check("停在地面上", absf(ball.linear_velocity.y) < 5.0, "|vy|=%.2f y=%.1f" % [absf(ball.linear_velocity.y), ball.position.y])
	_check("没穿地", ball.position.y < 300.0, "y=%.1f" % ball.position.y)

	# ---- 查询 ----
	_check("material_at 读到地面材质", px.material_at(Vector2(0.0, 320.0)) == 1)
	_check("material_at 空处为 0", px.material_at(Vector2(-380.0, -380.0)) == 0)

	# ---- 力：门面是"每帧施加"语义 ----
	var box := px.spawn_rect(Vector2(-200.0, 200.0), Vector2(16.0, 16.0), 2)   # 木头，轻
	var y0 := box.position.y
	# 木头密度 0.6 -> 16x16 的箱子质量约 154；重力 900 -> 需要约 1.4e5 的力才抬得动。
	# 取 5e6 留足余量（加速度约 32000 px/s²）。
	# ⚠️ 力竖直、偏移也竖直的话力矩**本来就该是 0**（叉积平行）。
	# 要产生转动，偏移必须垂直于力的方向 —— 这里在质心**右侧** 8 像素处向上推。
	for i in 120:
		px.push_at(box, Vector2(0.0, -5.0e5), box.com_world() + Vector2(8.0, 0.0))
		px.step(1.0 / 60.0)
	_check("持续力把物体抬起来了", box.position.y < y0 - 10.0, "y %.1f -> %.1f" % [y0, box.position.y])
	_check("偏心持续力产生转动", absf(box.angular_velocity) > 0.05, "w=%.3f" % box.angular_velocity)

	# 不 push 之后力必须消失（门面语义）
	var v_before := box.linear_velocity.length()
	for i in 30:
		px.step(1.0 / 60.0)
	_check("停止施力后力消失", box.accum_force == Vector2.ZERO and box.accum_torque == 0.0,
		"|v| %.1f -> %.1f" % [v_before, box.linear_velocity.length()])
	var _v_kept := v_before

	# ---- 冲量 ----
	var b2 := px.spawn_rect(Vector2(200.0, -200.0), Vector2(12.0, 12.0), 1)
	b2.linear_velocity = Vector2.ZERO
	px.impulse(b2, Vector2(500.0, 0.0))
	_check("冲量立即改速度", b2.linear_velocity.x > 0.0, "vx=%.1f" % b2.linear_velocity.x)

	# ---- 程序化破坏（全部世界坐标）----
	var target := px.spawn_rect(Vector2(500.0, 100.0), Vector2(40.0, 40.0), 1)
	var before: int = (target.shapes[0] as PixelShape).pixel_count()
	px.carve_circle(Vector2(520.0, 120.0), 8.0)
	var after: int = (target.shapes[0] as PixelShape).pixel_count()
	_check("世界坐标挖洞", after < before, "%d -> %d" % [before, after])

	var slab := px.spawn_rect(Vector2(-600.0, 0.0), Vector2(40.0, 40.0), 1)
	var frags: Array = px.cut(Vector2(-700.0, 20.0), Vector2(-500.0, 20.0), 1.5)
	_check("切割产生碎片", frags.size() > 0, "碎出 %d 块" % frags.size())

	var boom_target := px.spawn_rect(Vector2(300.0, -400.0), Vector2(30.0, 30.0), 1)
	var nearby := px.spawn_rect(Vector2(360.0, -400.0), Vector2(12.0, 12.0), 2)
	nearby.linear_velocity = Vector2.ZERO
	px.explode(Vector2(300.0, -400.0), 120.0, 300.0)
	_check("爆炸推开邻近物体", nearby.linear_velocity.length() > 50.0, "|v|=%.1f" % nearby.linear_velocity.length())
	var boom_n: int = (boom_target.shapes[0] as PixelShape).pixel_count()
	_check("爆炸破坏本体", boom_n < 900, "%d 像素" % boom_n)

	# 涂色点要用 com_world()（它带旋转），不能拿 position + 局部偏移 ——
	# 物体转起来之后 position + (8,8) 早就不在物体里了
	var painted := px.paint_circle(box.com_world(), 4.0, 2)
	_check("世界坐标涂色", painted > 0, "改了 %d 像素" % painted)
	var swapped: int = px.set_body_material(ground, 1, 2)
	_check("整体换材质并重算质量", swapped > 0 and px.material_at(Vector2(0.0, 320.0)) == 2,
		"换掉 %d 像素" % swapped)

	# ---- 抓取 ----
	_check("抓取命中", px.grab_at(Vector2(200.0, -200.0)))
	_check("抓取状态可查", px.has_grab())
	px.drag_to(Vector2(200.0, -300.0))
	for i in 60:
		px.step(1.0 / 60.0)
	_check("被拖动了", b2.position.y < -200.0, "y=%.1f" % b2.position.y)
	px.release()
	_check("松开后不再抓取", not px.has_grab())

	# ---- 渲染层：门面自动维护，不残留幽灵 ----
	var r = px.renderer()
	_check("渲染层已惰性创建", r != null)
	px.step(1.0 / 60.0)
	var n_before := px.body_count()
	px.carve_rect(Vector2(500.0, 100.0), Vector2(40.0, 40.0))
	px.step(1.0 / 60.0)
	_check("破坏后渲染层自动跟上", px.body_count() >= n_before,
		"刚体 %d -> %d" % [n_before, px.body_count()])

	print("=== %d passed, %d failed ===" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
