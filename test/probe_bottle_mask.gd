extends SceneTree
## 探针：把玩家瓶内遮罩 dump 成文本。
##
## 为什么要它：接流体之前必须知道**遮罩到底长什么样** —— 网格尺寸、solid_mask、
## 以及"瓶子内部是不是单一连通的一坨"全由它决定。
## player_body.png 里瓶身内部是**白色实心**的，而 BottledInk._build_interior() 找的是
## "被围住的透明像素"，两者对不上，所以不能靠看图猜。

var _scene = null
var _frames := 0

func _initialize() -> void:
	_scene = load("res://map/main.tscn").instantiate()
	root.add_child(_scene)

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 12:
		return false
	_dump()
	quit(0)
	return true

func _dump() -> void:
	var ink = _scene.get_node_or_null("Player/BottledInk")
	if ink == null:
		print("** 找不到 Player/BottledInk **")
		return
	var vis = _scene.get_node_or_null("Player/Visual")
	print("=== 节点 ===")
	print("Visual.texture      = ", vis.texture.get_size() if vis != null and vis.texture != null else "<null>")
	print("BottledInk.texture  = ", ink.texture.get_size() if ink.texture != null else "<null>")
	print("BottledInk.visible  = ", ink.visible, "   offset = ", ink.offset)
	print("Liquid.texture      = ", ink.get_node("Liquid").texture.get_size())

	var tex: Texture2D = ink.texture
	if tex == null:
		print("** 遮罩还没算出来 **")
		return
	var img := tex.get_image()
	if img == null:
		print("** 拿不到 Image **")
		return
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	print("")
	print("=== 瓶内遮罩 %dx%d ===" % [w, h])

	# 连通分量：4 邻域，看"瓶子内部"是几坨
	var comp := PackedInt32Array()
	comp.resize(w * h)
	comp.fill(-1)
	var ncomp := 0
	var sizes: Array[int] = []
	var stack := PackedInt32Array()
	for i in w * h:
		if data[i * 4 + 3] == 0 or comp[i] >= 0:
			continue
		comp[i] = ncomp
		stack.clear()
		stack.append(i)
		var n := 0
		while not stack.is_empty():
			var p: int = stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			n += 1
			var px := p % w
			var py := p / w
			for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: int = px + off.x
				var ny: int = py + off.y
				if nx < 0 or nx >= w or ny < 0 or ny >= h:
					continue
				var q := ny * w + nx
				if data[q * 4 + 3] == 0 or comp[q] >= 0:
					continue
				comp[q] = ncomp
				stack.append(q)
		sizes.append(n)
		ncomp += 1
	print("连通分量数 = %d   各分量格数 = %s" % [ncomp, str(sizes)])

	# 最大分量的 bbox
	var big := 0
	for i in ncomp:
		if sizes[i] > sizes[big]:
			big = i
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := Vector2i(-(1 << 30), -(1 << 30))
	for i in w * h:
		if comp[i] != big:
			continue
		var px := i % w
		var py := i / w
		lo.x = mini(lo.x, px); lo.y = mini(lo.y, py)
		hi.x = maxi(hi.x, px); hi.y = maxi(hi.y, py)
	print("最大分量 bbox = x %d..%d  y %d..%d  (w=%d h=%d)" % [
		lo.x, hi.x, lo.y, hi.y, hi.x - lo.x + 1, hi.y - lo.y + 1])

	# ASCII：'#' = 最大分量，'.' = 空，'o' = 其它分量
	print("")
	print("=== ASCII（# = 最大分量，+ = 其它分量，. = 空）===")
	for y in h:
		var line := ""
		for x in w:
			var i := y * w + x
			if data[i * 4 + 3] == 0:
				line += "."
			elif comp[i] == big:
				line += "#"
			else:
				line += "+"
		print("%3d %s" % [y, line])
