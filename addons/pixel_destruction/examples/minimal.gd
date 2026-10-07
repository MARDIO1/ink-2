extends SceneTree
## 最小示例：不依赖任何 demo 代码，只用 addon 跑起一个可破坏的 2D 像素物理世界。
##
## 无头运行：
##   godot --headless --path <你的项目> --script res://addons/pixel_destruction/examples/minimal.gd
##
## 这个文件同时充当"引擎是否可用"的自检 —— 每一步都带断言。

const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PWorld := preload("res://addons/pixel_destruction/physics/pworld.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")

var _pass := 0
var _fail := 0

func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS  ", name, "  ", detail)
	else:
		_fail += 1
		print("  FAIL  ", name, "  ", detail)

func _block(w: int, h: int) -> PixelShape:
	var s := PixelShape.new()
	for y in h:
		for x in w:
			s.set_pixel(x, y, 1)
	return s

func _initialize() -> void:
	print("=== pixel_destruction 最小示例 ===")

	# --- 1. 建世界 ---
	var world := PWorld.new()
	world.gravity = Vector2(0.0, 900.0)   # 注意：这里用的是底层类，示例默认走原生路径

	var ground := PBody.new()
	ground.position = Vector2(-400.0, 300.0)
	ground.make_static()
	world.add_body(ground, [_block(800, 40)])

	# --- 2. 像素图形状不只是矩形：任意像素团会自动分解成 OBB ---
	var blob := PixelShape.new()
	for y in 24:
		for x in 24:
			if (x - 12) * (x - 12) + (y - 12) * (y - 12) <= 144:
				blob.set_pixel(x, y, 1)
	var ball := PBody.new()
	ball.position = Vector2(-100.0, 100.0)
	world.add_body(ball, [blob])
	_check("像素团被分解成矩形", ball.rects.size() > 0, "%d 个矩形" % ball.rects.size())

	# --- 3. 自由落体 1 秒 ---
	for i in 60:
		world.step(1.0 / 60.0)
	_check("确实在下落", ball.position.y > 150.0, "y=%.1f" % ball.position.y)

	# --- 4. 落到地面后停下 ---
	for i in 240:
		world.step(1.0 / 60.0)
	_check("停在地面上", absf(ball.linear_velocity.y) < 5.0,
		"|vy|=%.3f  y=%.1f" % [absf(ball.linear_velocity.y), ball.position.y])
	_check("没有穿地", ball.position.y < 300.0, "y=%.1f" % ball.position.y)

	# --- 5. 破坏：把球从中间切开 ---
	#
	# ⚠️ 两个容易踩的点：
	#   1. Damage 的坐标是**目标 Shape 的本地像素空间**，不是世界坐标；
	#   2. 破坏**不等于**碎片：在圆盘正中心挖一个洞得到的是**环**——
	#      它仍然是连通的一整块，所以正确地**不会**产生新刚体。
	#      要看到碎片，得让破坏真的把形状切断。
	var before := world.bodies.size()
	var dmg := Destruction.Damage.rect(Vector2(12.0, 12.0), Vector2(1.5, 12.0))
	var parts: Array = world.fracture(ball, dmg, 40.0)
	_check("切开后产生了碎片", parts.size() > 0,
		"碎出 %d 块，刚体 %d -> %d" % [parts.size(), before, world.bodies.size()])

	# --- 6. 抓取（鼠标关节）：拖动一个刚体 ---
	var box := PBody.new()
	box.position = Vector2(-300.0, 200.0)
	world.add_body(box, [_block(16, 16)])
	world.grab(box, box.com_world(), 2500.0)
	_check("抓取已建立", world.is_grabbing())
	world.set_grab_target(Vector2(-300.0, 120.0))
	for i in 60:
		world.step(1.0 / 60.0)
	_check("被拖起来了", box.position.y < 199.0, "y=%.1f" % box.position.y)
	world.release_grab()

	# --- 7. 堆积与休眠 ---
	var world2 := PWorld.new()
	world2.gravity = Vector2(0.0, 900.0)
	var g2 := PBody.new()
	g2.position = Vector2(-200.0, 300.0)
	g2.make_static()
	world2.add_body(g2, [_block(400, 40)])
	for i in 5:
		var b := PBody.new()
		b.position = Vector2(-20.0 + float(i) * 4.0, 280.0 - float(i) * 14.0)
		world2.add_body(b, [_block(12, 12)])
	for i in 600:
		world2.step(1.0 / 60.0)
	var awake := 0
	for b in world2.bodies:
		if not b.is_static and b.awake:
			awake += 1
	_check("堆叠会自己睡着", awake == 0, "仍清醒 %d/%d" % [awake, world2.bodies.size() - 1])

	print("=== %d passed, %d failed ===" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
