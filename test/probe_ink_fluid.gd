extends SceneTree
## 探针：墨水流体层接上之后，容器多大、长什么样、单步多贵。

const FluidPBF := preload("res://addons/pixel_destruction/fluid/fluid_pbf.gd")

var _scene = null
var _frames := 0

func _initialize() -> void:
	_scene = load("res://map/main.tscn").instantiate()
	root.add_child(_scene)

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 40:
		return false
	_dump()
	quit(0)
	return true

func _dump() -> void:
	var ink = _scene.get_node_or_null("Player/BottledInk")
	if ink == null:
		print("** 找不到 Player/BottledInk **")
		return
	print("visible=%s  texture=%s  z_index=%d  offset=%s" % [
		str(ink.visible), str(ink.texture.get_size()) if ink.texture != null else "<null>",
		ink.z_index, str(ink.offset)])
	var f = ink._fluid
	if f == null:
		print("** 流体没建起来（容器为空？）**")
		return
	print("容器 %dx%d  origin=%s  可通行 %d 格  粒子 %d / max %d" % [
		f.num_x, f.num_y, str(ink._grid_origin), _nz(f.solid_mask),
		f.particle_count(), f.max_particles])
	print("rest_density=%.6f  fill_ratio=%.3f  越界粒子=%d" % [
		f.rest_density, f.fill_ratio, _out(f)])
	print("")
	# ⚠️ 必须先落成有类型的局部：f 是 Object，f.num_x 是 Variant，
	#    直接 var i := x * f.num_y + y 会 "Cannot infer the type of i"。
	var gw: int = f.num_x
	var gh: int = f.num_y
	var wet := 0
	for y in gh:
		var line := ""
		for x in gw:
			# ⚠️⚠️ **两套索引**，别用一个 i 查两边：
			#    f.ink 是 **x 主序**（x*ny + y，见 fluid_pbf.gd 文件头）
			#    _container 是 **行主序**（y*gw + x，见 bottled_ink.gd 的构建循环）
			#    用同一个 i 查会把它转置 —— 计数会从 3150 掉到 1915，
			#    而画面看着像"液体只装了 55%"。我在 bottled_ink.gd 里修过一次，
			#    然后在**这个探针里**又原样犯了一遍。
			var fi: int = x * gh + y
			var ci: int = y * gw + x
			if ink._container[ci] == 0:
				line += " "
			elif f.ink[fi] != 0:
				line += "#"
				wet += 1
			else:
				line += "."
		print(line)
	print("")
	print("有墨的格 = %d / %d" % [wet, _nz(ink._container)])
	# ⚠️⚠️ 重力必须是**域单位**，和 bottled_ink.gd 里那条一模一样：
	#        gravity_px * spacing
	#    第一版这里传的是裸的 900 —— 而真实值是 600 * 0.041 = 24.6，**36 倍**。
	#    粒子被暴力加速、压成一团，测出来的数一直不可信，
	#    而"慢了/快了"的判断全建立在它上面（三次里错了两次）。
	var gm: float = ink.gravity_px * f.spacing
	print("重力 = %.3f 域单位/秒²（= gravity_px %.0f x spacing %.4f）" % [gm, ink.gravity_px, f.spacing])
	var t0 := Time.get_ticks_usec()
	for i in 60:
		f.step(0.0, gm)
	var t1 := Time.get_ticks_usec()
	print("流体单步 %.3f ms（原生可用=%s）" % [
		(t1 - t0) / 1000.0 / 60.0, str(ClassDB.class_exists("PixelFluid"))])
	# 同时量一下 GDScript 参照实现，看原生到底快多少（同一份数据）
	var gd = FluidPBF.new()
	gd.resize_grid(f.num_x, f.num_y)
	gd.solid_mask = f.solid_mask.duplicate()
	gd.spacing = f.spacing
	gd.radius = f.radius
	gd.init_particles(f.particle_count())
	gd._native_checked = true
	gd._native = null
	var t2 := Time.get_ticks_usec()
	for i in 5:
		gd.step(0.0, gm)
	var t3 := Time.get_ticks_usec()
	print("参照实现单步 %.3f ms（%d 粒子）" % [(t3 - t2) / 1000.0 / 5.0, gd.particle_count()])

func _nz(a: PackedByteArray) -> int:
	var c := 0
	for v in a:
		if v != 0:
			c += 1
	return c

func _out(f) -> int:
	var h: float = f.spacing
	var bad := 0
	for i in f.particle_count():
		var cx := clampi(int(f.pos[i * 2] / h), 0, f.num_x - 1)
		var cy := clampi(int(f.pos[i * 2 + 1] / h), 0, f.num_y - 1)
		if f.solid_mask[cx * f.num_y + cy] == 0:
			bad += 1
	return bad
