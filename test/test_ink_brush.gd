extends SceneTree
## 笔刷几何与墨水桶搜索的单元测试：不建画布、不跑物理。
##
## 这两个模块被抽出来的目的就是"能脱离场景验证"，所以这里只喂数据。

const InkBrush := preload("res://actor/canvas/src/ink_brush.gd")
const InkBucket := preload("res://actor/canvas/src/ink_bucket.gd")

var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[InkBrush] %s %s" % ["PASS" if ok else "FAIL", label])


func _empty_data(size: Vector2i) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(size.x * size.y * 4)
	return data


## 把 rect 的四条边涂成不透明（alpha = 255），模拟一圈封闭墨线。
func _stroke_ring(data: PackedByteArray, size: Vector2i, rect: Rect2i) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var inside: bool = x > rect.position.x and x < rect.end.x - 1 \
				and y > rect.position.y and y < rect.end.y - 1
			if inside:
				continue
			data[(y * size.x + x) * 4 + 3] = 255


func _run() -> void:
	var size := Vector2i(32, 32)

	# ---- 笔刷几何 ----
	var line := {}
	InkBrush.line(line, Vector2(4.5, 10.5), Vector2(24.5, 10.5), 1, size)
	check("1px 水平线连续无缺格", line.size() == 21
		and line.keys().all(func(at): return at.y == 10))

	var stamp := {}
	InkBrush.collect_stamp(stamp, Vector2(10.5, 10.5), 1, size)
	check("1px 笔刷只落一格", stamp.size() == 1 and stamp.has(Vector2i(10, 10)))

	var clamps := {}
	InkBrush.collect_stamp(clamps, Vector2(-5.0, -5.0), 9, size)
	check("笔刷不越出画布", clamps.keys().all(
		func(at): return at.x >= 0 and at.y >= 0 and at.x < size.x and at.y < size.y))

	var frame := {}
	InkBrush.rect(frame, Vector2(4.0, 4.0), Vector2(20.0, 20.0), 3, size)
	# 外包围盒是半开区间：拖到 20 时最右一列是 19。
	check("矩形是空心边框", frame.has(Vector2i(4, 4)) and frame.has(Vector2i(19, 19))
		and not frame.has(Vector2i(12, 12)))

	var ring := {}
	InkBrush.circle(ring, Vector2(16.0, 16.0), 8.0, 1, size)
	check("圆环不含圆心", not ring.has(Vector2i(15, 15)) and not ring.has(Vector2i(16, 16))
		and ring.size() > 20)

	# ---- 墨水桶搜索 ----
	var data := _empty_data(size)
	_stroke_ring(data, size, Rect2i(4, 4, 12, 12))       # 内部 10x10 = 100 格空区
	var rod := _empty_data(size)

	var closed := InkBucket.find_region(data, rod, size, Vector2i(9, 9), 1000)
	check("封闭区域整片找到", bool(closed.get("ok", false)) and closed.cells.size() == 100)

	var budget := InkBucket.find_region(data, rod, size, Vector2i(9, 9), 10)
	check("预算不足时报告 room 并带回计数", str(budget.get("reason", "")) == "room"
		and int(budget.get("count", 0)) > 10)

	var solid := InkBucket.find_region(data, rod, size, Vector2i(4, 4), 1000)
	check("点在实心像素上返回 solid", str(solid.get("reason", "")) == "solid")

	var open := InkBucket.find_region(data, rod, size, Vector2i(1, 1), 100000)
	check("连到画布边缘返回 open", str(open.get("reason", "")) == "open")

	print("[InkBrush] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
