extends SceneTree
## 诊断：容器掩码 vs 剪影 alpha，看"外面"的泛洪有没有漏。

var _scene = null
var _frames := 0

func _initialize() -> void:
	_scene = load("res://map/main.tscn").instantiate()
	root.add_child(_scene)

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 20:
		return false
	var ink = _scene.get_node_or_null("Player/BottledInk")
	var vis = _scene.get_node_or_null("Player/Visual")
	var img: Image = vis.texture.get_image()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var rgba := img.get_data()
	print("Visual 贴图 %dx%d" % [w, h])
	# alpha 图（每 2x2 取一格）
	print("--- 剪影 alpha（# = 不透明，. = 透明）---")
	for y in range(0, h, 2):
		var line := ""
		for x in range(0, w, 2):
			line += "#" if rgba[(y * w + x) * 4 + 3] != 0 else "."
		print("%3d %s" % [y, line])
	# 容器
	print("--- 容器掩码（# = 容器内）---")
	var f = ink._fluid
	var gw: int = f.num_x
	var gh: int = f.num_y
	print("容器 %dx%d  origin=%s" % [gw, gh, str(ink._grid_origin)])
	for gy in gh:
		var line := ""
		for gx in gw:
			line += "#" if ink._container[gy * gw + gx] != 0 else "."
		print("%3d %s" % [gy, line])
	quit(0)
	return true
