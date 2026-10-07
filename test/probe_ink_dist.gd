extends SceneTree
## 诊断：粒子在容器里到底怎么分布的 —— 以及"初始 90%、沉降后 75%"是从哪来的。
##
## ⚠️⚠️ 读 pos/vel 之前**必须** f.sync_from_native()。
##    走原生时权威状态在**原生那边**，每步只回吐 ink 掩码（见 fluid_pbf.gd 的 _native_dirty）。
##    不同步的话：ink 掩码是**当前**的，而 pos/vel 是**灌进去的那一份**（初始密排），
##    于是"每格粒子数 / 平均速度 / 分带"量的全是初始状态，而覆盖数是对的 ——
##    两个数对不上时，人会先怀疑覆盖统计，不会怀疑探针。上一版就是这个病。
##
## ⚠️ 判据要用**被测对象自己的代码**：密度场直接调流体的
##    _particles_to_grid() + _density_update()，不在这里重写一遍公式
##    （重写 = 两套实现，探针和被测对象一分叉，量的就不是它了）。
##
## ⚠️ 等待按**物理帧**算，不按 idle 帧：headless 的 idle 帧快得离谱，
##    "等 40 帧"可能一个物理步都没走完，量到的是沉降**途中**。

const STAGES := [240, 600, 1200]     # 物理帧（60Hz -> 4 秒 / 10 秒 / 20 秒）

var _scene = null
var _start := 0
var _stage := 0


func _initialize() -> void:
	_scene = load("res://map/main.tscn").instantiate()
	root.add_child(_scene)
	_start = Engine.get_physics_frames()


func _process(_d: float) -> bool:
	var elapsed: int = Engine.get_physics_frames() - _start
	if _stage >= STAGES.size():
		quit(0)
		return true
	if elapsed < STAGES[_stage]:
		return false
	print("\n========== 物理帧 %d（%.1f 秒） ==========" % [elapsed, float(elapsed) / 60.0])
	_dump(_stage == STAGES.size() - 1)
	_stage += 1
	return false


func _dump(with_map: bool) -> void:
	var ink = _scene.get_node_or_null("Player/BottledInk")
	if ink == null:
		print("** 找不到 Player/BottledInk **")
		return
	var f = ink._fluid
	if f == null:
		print("** 流体没建起来（容器为空？）**")
		return
	# ⚠️⚠️ 本次测量的全部意义就在这一行。别删。
	f.sync_from_native()
	# ⚠️ f 是 Object，属性全是 Variant，`var x := f.num_x` 会
	#    "Cannot infer the type"。一律先落成有类型的局部。
	var gw: int = f.num_x
	var gh: int = f.num_y
	var h: float = f.spacing
	var r: float = f.radius
	var n: int = f.particle_count()
	var cap: int = f.max_particles
	var target: int = int(round(f.fill_ratio * float(cap)))
	print("粒子 %d   目标 %d（fill_ratio %.3f x max_particles %d）   native_calls %d" % [
		n, target, f.fill_ratio, cap, f.native_calls])
	print("rest_density %.6f   spacing %.4f   radius %.4f   splat_radius %.2f" % [
		f.rest_density, h, r, f.splat_radius])

	# ---- 每格粒子数 ----
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
	print("被占用的格 %d / %d（容器可通行 %d）  单格最多 %d 个   平均 %.3f 个/占用格" % [
		used, gw * gh, _nz(ink._container), mx, float(n) / float(maxi(used, 1))])

	# ---- 密度场 vs rest_density（"压力追不上"这个假设的判据）----
	f._particles_to_grid()
	f._density_update()
	var dsum := 0.0
	var dcnt := 0
	var dmax := 0.0
	var dsum_all := 0.0
	for i in gw * gh:
		var d: float = f._density[i]
		dsum_all += d
		if f.cell_type[i] == f.FLUID_CELL:
			dsum += d
			dcnt += 1
			dmax = maxf(dmax, d)
	var dmean := dsum / float(maxi(dcnt, 1))
	print("密度场：流体格 %d   均值 %.6f   峰值 %.6f   全网格和 %.1f（应 = 粒子数 %d）" % [
		dcnt, dmean, dmax, dsum_all, n])
	print("        rest_density %.6f   当前/基准 = %.4f（>1 = 比初始密排更密）" % [
		f.rest_density, dmean / maxf(f.rest_density, 1e-9)])

	# ---- 覆盖 ----
	var wet := 0
	for v in f.ink:
		if v != 0:
			wet += 1
	var cont := _nz(ink._container)
	# 六角密排每个粒子占多少格² —— 从**被测对象自己的** radius/spacing 算，不写魔法数
	var cell_per_p := (2.0 * r / h) * (0.86602540378 * 2.0 * r / h)
	print("墨水覆盖 %d / %d 格 = %.1f%%   按密排 %.3f 格²/个 折算：%d 个粒子该覆盖 %.0f 格" % [
		wet, cont, 100.0 * float(wet) / float(maxi(cont, 1)), cell_per_p, n, float(n) * cell_per_p])
	print("        每个粒子的实际覆盖 = %.3f 格²（低于密排值 = 粒子挤在一起了）" % [
		float(wet) / float(maxi(n, 1))])
	# ---- 越界 / 速度 ----
	print("落在固体格里的粒子 %d（>0 就是 _contain_particles 没兜住）" % _out(f))
	var sp := 0.0
	for i in n:
		sp += sqrt(f.vel[i * 2] * f.vel[i * 2] + f.vel[i * 2 + 1] * f.vel[i * 2 + 1])
	print("平均速度 %.5f 域单位/步   域高 %.1f 格" % [sp / float(maxi(n, 1)), float(gh)])

	# ---- 按 y 分带（粒子 + 墨水）----
	var bands := ""
	var inkbands := ""
	for b in range(0, gh, 6):
		var pc := 0
		var ic := 0
		for y in range(b, mini(b + 6, gh)):
			for x in gw:
				pc += per[x * gh + y]
				if f.ink[x * gh + y] != 0:
					ic += 1
		bands += "%d " % pc
		inkbands += "%d " % ic
	print("每 6 行一带 粒子（y 上->下）： " + bands)
	print("每 6 行一带 墨水：              " + inkbands)

	# ---- 被 _contain_particles "搬"过多少个（判据：位置**正好**在格心）----
	# ⚠️ 为什么这个判据成立：_contain_particles 把位置写成 (tx+0.5)*h —— 正好格心，
	#    而它是 _push_apart 的**最后一步**，之后没人再动它。所以"正好在格心"
	#    就等于"这一步被搬过"。搬一次 = 一次**瞬移**（速度不变），压力场于是
	#    突然看见一个密度尖峰 —— 这是"永远静不下来"的嫌疑机制。
	var snapped := 0
	for i in n:
		# ⚠️ f.pos[...] 是 Variant，`:=` 推不出类型（Cannot infer the type of "fx"）—— 必须显式标 float。
		var fx: float = f.pos[i * 2] / h
		var fy: float = f.pos[i * 2 + 1] / h
		if absf((fx - floor(fx)) - 0.5) < 1e-9 and absf((fy - floor(fy)) - 0.5) < 1e-9:
			snapped += 1
	print("位置正好在格心的粒子 %d / %d = %.1f%%（= 上一步被 _contain_particles 搬过）" % [
		snapped, n, 100.0 * float(snapped) / float(maxi(n, 1))])

	# ---- 最近邻距离：是"挤"还是"成团"，这个量分得清 ----
	# ⚠️ 密度场均值分不清这两件事：成团会让流体格变少、每格密度变高，
	#    看上去和"整体被压缩"一模一样（这次两个数就都指向 1.4~1.5 倍）。
	#    最近邻距离只跟局部间距有关，不会被"有多少空格"带偏。
	var buckets := {}
	for i in n:
		var bx := clampi(int(f.pos[i * 2] / h), 0, gw - 1)
		var by := clampi(int(f.pos[i * 2 + 1] / h), 0, gh - 1)
		var key := bx * gh + by
		var arr: PackedInt32Array = buckets.get(key, PackedInt32Array())
		arr.append(i)
		buckets[key] = arr
	var nn_sum := 0.0
	var nn_cnt := 0
	var overlap := 0
	var min_dist_cells := 2.0 * r / h
	for i in n:
		var bx := clampi(int(f.pos[i * 2] / h), 0, gw - 1)
		var by := clampi(int(f.pos[i * 2 + 1] / h), 0, gh - 1)
		var best := 1e30
		for ox in range(-1, 2):
			for oy in range(-1, 2):
				var tx := bx + ox
				var ty := by + oy
				if tx < 0 or tx >= gw or ty < 0 or ty >= gh:
					continue
				var arr2: PackedInt32Array = buckets.get(tx * gh + ty, PackedInt32Array())
				for j in arr2:
					if j == i:
						continue
					var dx: float = f.pos[j * 2] - f.pos[i * 2]
					var dy: float = f.pos[j * 2 + 1] - f.pos[i * 2 + 1]
					var d2: float = dx * dx + dy * dy
					if d2 < best:
						best = d2
		if best < 1e29:
			var d := sqrt(best) / h
			nn_sum += d
			nn_cnt += 1
			if d < min_dist_cells:
				overlap += 1
	print("最近邻距离 均值 %.3f 格（密排该是 %.3f）  比 min_dist 还近的粒子 %d / %d = %.1f%%" % [
		nn_sum / float(maxi(nn_cnt, 1)), min_dist_cells, overlap, n,
		100.0 * float(overlap) / float(maxi(n, 1))])

	if with_map:
		print("--- 墨水图（# = 有墨，. = 容器内空，空格 = 容器外；已转成行主序）---")
		for y in gh:
			var line := ""
			for x in gw:
				var ci: int = y * gw + x
				if ink._container[ci] == 0:
					line += " "
				elif f.ink[x * gh + y] != 0:
					line += "#"
				else:
					line += "."
			print(line)


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
