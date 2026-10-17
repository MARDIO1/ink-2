extends SceneTree

const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")

func _initialize() -> void:
	# 256 个连续实心块：结果含一个分组计数，恰好比旧初始缓冲多 4 字节。
	var shape := Shape.new()
	for x in 2048:
		for y in 8:
			shape.set_pixel(x, y, 1)
	var before := Destruction.native_fallbacks
	var result := Destruction.components(shape)
	var okay: bool = result.size() == 1 and result[0].size() == 256 and Destruction.native_fallbacks == before
	print("[NativeCapacity] %s full buffer retries with group header without fallback" % ("PASS" if okay else "FAIL"))
	quit(0 if okay else 1)
