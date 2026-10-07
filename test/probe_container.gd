extends SceneTree
## 诊断：容器 / 可画掩码 / 剪影 alpha / **烘出来的贴图** 四张图对齐着看。
##
## ⚠️ 为什么必须把"烘出来的贴图"也 dump 出来：_draw 对**不等于**画面对。
##    真正决定像素的是 _render() 走完之后 _tex 里那份。只看掩码会把
##    "掩码对、渲染路径错"整个漏掉 —— 而这次的症状恰恰是"看着还在画"。
##    所以这里的判据是**贴图**：_draw = 0 的格子上贴图必须全透明。
##
## ⚠️ 剪影那张贴图是**调色板烘出来的**：材质 1/2/3 都是纯黑，材质 0 和材质 5
##    都是**全透明**（见 player.tscn 的 Visual.palette）。所以从这张贴图上
##    **分不出**"这里没有像素"和"这里是瓶身填充" —— 两者 alpha 都是 0。

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
	if ink == null or vis == null or vis.texture == null:
		print("** 找不到 Player/BottledInk 或 Visual **")
		return
	var img: Image = vis.texture.get_image()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var rgba := img.get_data()
	var gw: int = ink._gw
	var gh: int = ink._gh
	var lo: Vector2i = ink._grid_origin
	print("Visual 贴图 %dx%d   容器 %dx%d @ %s   offset=%s scale=%s" % [
		w, h, gw, gh, str(lo), str(ink.offset), str(ink.scale)])
	var lit: Image = null
	if ink.texture != null:
		lit = ink.texture.get_image()
		if lit.get_format() != Image.FORMAT_RGBA8:
			lit.convert(Image.FORMAT_RGBA8)
	var lp := lit.get_data() if lit != null else PackedByteArray()
	var cont := 0
	var draw := 0
	var opaque := 0
	var leak_draw := 0
	var leak_cont := 0
	var wet_draw0 := 0
	for gy in gh:
		for gx in gw:
			var i := gy * gw + gx
			var sx := lo.x + gx
			var sy := lo.y + gy
			var a: int = rgba[(sy * w + sx) * 4 + 3] if (sx < w and sy < h) else 0
			if ink._container[i] != 0:
				cont += 1
			if ink._draw[i] != 0:
				draw += 1
			if a != 0:
				opaque += 1
			var la: int = lp[i * 4 + 3] if lp.size() > i * 4 + 3 else 0
			if ink._draw[i] == 0 and la != 0:
				leak_draw += 1
			if ink._container[i] == 0 and la != 0:
				leak_cont += 1
			if ink._draw[i] == 0 and ink._fluid.ink[gx * gh + gy] != 0:
				wet_draw0 += 1
	print("容器 %d 格   可画 %d 格   剪影不透明 %d 格" % [cont, draw, opaque])
	print("**_draw=0 但贴图非透明 = %d **   **_container=0 但贴图非透明 = %d **" % [leak_draw, leak_cont])
	print("_draw=0 但流体有墨的格 = %d（这些格**不该**出现在贴图上）" % wet_draw0)
	print("")
	print("--- 剪影alpha / 容器 / 可画_draw / 贴图(@墨 o玻璃) ---")
	for gy in gh:
		var l1 := ""
		var l2 := ""
		var l3 := ""
		var l4 := ""
		for gx in gw:
			var i := gy * gw + gx
			var sx := lo.x + gx
			var sy := lo.y + gy
			var a: int = rgba[(sy * w + sx) * 4 + 3] if (sx < w and sy < h) else 0
			l1 += "#" if a != 0 else "."
			l2 += "#" if ink._container[i] != 0 else "."
			l3 += "#" if ink._draw[i] != 0 else "."
			var la: int = lp[i * 4 + 3] if lp.size() > i * 4 + 3 else 0
			if la == 0:
				l4 += " "
			elif lp[i * 4] < 128:
				l4 += "@"
			else:
				l4 += "o"
		print("%3d %s | %s | %s | %s" % [gy, l1, l2, l3, l4])
