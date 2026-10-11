extends SceneTree
## 诊断：**脸到底是哪种材质** —— 决定 _draw 能不能把脸整块排除掉。
##
## 背景：_draw 现在的判据是"这一格有透明像素就画"，而脸**内部**也是透明的。
## 材质 0（没画）和材质 5（瓶身填充）在**烘出来的贴图上都是 alpha 0**，分不出来，
## 所以只能回到**形状的 mat 数组**里找信息。这个探针把 mat 摊成一张图。

const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

var _scene = null
var _start := 0
var _done := false


func _initialize() -> void:
	_scene = load("res://map/main.tscn").instantiate()
	root.add_child(_scene)
	_start = Engine.get_physics_frames()


func _process(_d: float) -> bool:
	if _done:
		quit(0)
		return true
	if Engine.get_physics_frames() - _start < 20:
		return false
	_done = true
	_dump()
	quit(0)
	return true


func _dump() -> void:
	var ink = _scene.get_node_or_null("Player/BottledInk")
	var vis = _scene.get_node_or_null("Player/Visual")
	if ink == null or vis == null:
		print("** 找不到节点 **")
		return
	var shapes: Array = vis._collect()
	if shapes.is_empty():
		print("** 没有形状 **")
		return
	var box := Rect2i()
	var first := true
	for s in shapes:
		var b: Rect2i = s.local_aabb()
		box = b if first else box.merge(b)
		first = false
	var w := box.size.x
	var h := box.size.y
	var mat := PackedByteArray()
	mat.resize(w * h)
	for s in shapes:
		for k: int in s.chunks:
			var c = s.chunks[k]
			var bx := (PixelShape.key_x(k) << 3) - box.position.x
			var by := (PixelShape.key_y(k) << 3) - box.position.y
			var bits: int = c.occ
			while bits != 0:
				# ⚠️ 不用 Bits.first_bit_index —— 那个单例不在本工程的全局作用域里
				#    （"Identifier Bits not declared"）。自己数最低位更省事。
				var i := 0
				var probe := bits
				while (probe & 1) == 0:
					probe >>= 1
					i += 1
				bits &= bits - 1
				var gx := bx + (i & 7)
				var gy := by + (i >> 3)
				if gx >= 0 and gx < w and gy >= 0 and gy < h:
					mat[gy * w + gx] = int(c.mat[i])
	print("贴图空间 %dx%d @ %s   形状 %d 个" % [w, h, str(box.position), shapes.size()])
	var hist := PackedInt32Array()
	hist.resize(16)
	for v in mat:
		hist[v] += 1
	var hs := ""
	for i in 16:
		if hist[i] > 0:
			hs += "%d:%d " % [i, hist[i]]
	print("材质直方图（0 = 没画）： " + hs)
	var lo: Vector2i = ink._grid_origin
	var gw: int = ink._gw
	var gh: int = ink._gh
	print("--- 材质图（. = 0 没画，数字 = 材质号；左列是格号）---")
	for gy in gh:
		var line := ""
		for gx in gw:
			var sx := lo.x + gx
			var sy := lo.y + gy
			var m: int = mat[sy * w + sx] if (sx < w and sy < h) else 0
			line += "." if m == 0 else str(m)
		print("%3d %s" % [gy, line])
