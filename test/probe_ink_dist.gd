extends SceneTree
## 诊断：粒子在容器里到底怎么分布的。

var _scene = null
var _frames := 0

func _initialize() -> void:
	_scene = load("res://map/main.tscn").instantiate()
	root.add_child(_scene)

func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 40:
		return false
	var ink = _scene.get_node_or_null("Player/BottledInk")
	var f = ink._fluid
	var gw: int = f.num_x
	var gh: int = f.num_y
	var h: float = f.spacing
	var n: int = f.particle_count()
	print("粒子 %d  网格 %dx%d  spacing=%.3f  radius=%.3f  push_iters=%d  grid_iters=%d" % [
		n, gw, gh, h, f.radius, f.push_iters, f.grid_iters])
	print("rest_density=%.6f  dt=%.4f" % [f.rest_density, f.dt])
	# 每格粒子数
	var per := PackedInt32Array()
	per.resize(gw * gh)
	for i in n:
		var cx := clampi(int(f.pos[i * 2] / h), 0, gw - 1)
		var cy := clampi(int(f.pos[i * 2 + 1] / h), 0, gh - 1)
		per[cx * gh + cy] += 1
	var mx := 0
	var used := 0
	for v in per:
		mx = maxi(mx, v)
		if v > 0:
			used += 1
	print("被占用的格 = %d / %d   单格最多 %d 个粒子" % [used, _nz(ink._container), mx])
	# 按 y 分带统计
	print("每 6 行一带的粒子数（y 从上到下）：")
	var bands := ""
	for b in range(0, gh, 6):
		var c := 0
		for y in range(b, mini(b + 6, gh)):
			for x in gw:
				c += per[x * gh + y]
		bands += "%d " % c
	print("  " + bands)
	# 平均速度
	var sp := 0.0
	for i in n:
		sp += sqrt(f.vel[i * 2] * f.vel[i * 2] + f.vel[i * 2 + 1] * f.vel[i * 2 + 1])
	print("平均速度 %.4f   域高 %.1f 格" % [sp / float(maxi(n, 1)), float(gh)])
	quit(0)
	return true

func _nz(a: PackedByteArray) -> int:
	var c := 0
	for v in a:
		if v != 0:
			c += 1
	return c
