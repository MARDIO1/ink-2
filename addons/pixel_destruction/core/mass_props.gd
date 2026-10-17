extends RefCounted
## 从像素分布推导质量属性 —— 这是 Teardown 的核心机制：
##   mass    = Σ density(material)
##   com     = Σ density * p / mass
##   inertia = Σ density * (|p - com|^2 + 1/6)     （1x1 方块绕自身中心的极惯性矩 = 1/6）
##
## 因此"炸掉半面墙，质量自动减半"是免费的，不需要任何脚本干预。

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

class Props:
	var mass := 0.0
	var com := Vector2.ZERO
	var inertia := 0.0
	var pixel_count := 0
	## 摩擦/恢复系数的**逐像素累加**（除以 pixel_count 就是加权平均）。
	## 和密度同一个口径：材质是逐像素存的，混合材质的刚体取加权平均。
	var fric_sum := 0.0
	var rest_sum := 0.0

	func inv_mass() -> float:
		return 0.0 if mass <= 0.0 else 1.0 / mass

	func inv_inertia() -> float:
		return 0.0 if inertia <= 0.0 else 1.0 / inertia


## density_of: Callable(material:int) -> float，默认全部为 1.0
## `changed_keys`：调用方**声明**"这一步只改了这些块"（键 = PixelShape.make_key）。
## 传了就复用其余块的几何缓存（见 PixelShape._mp_cache），没传就全量重算并清缓存。
##
## ⚠️ 为什么这样设计（实测）：本函数逐块扫描，32000 像素的形状**删 1 个像素也要 2.95 ms**，
##    而 fracture_pixels 每次破坏都要调它 —— 于是"擦一下大刚体"就是几毫秒。
##    逐块缓存后，删 1 个像素只重算 1 块（其余 500 块直接复用）。
## ⚠️ 逐位精确：每块的加法**顺序与原来完全一致**（整块同材质那一路的 5 项加法原样保留），
##    所以结果与全量重算逐位相同（tests/validation_mass_cache.gd 钉这条）。
static func compute(shape: PixelShape, density_of: Callable = Callable(),
		friction_of: Callable = Callable(), restitution_of: Callable = Callable(),
		changed_keys: Variant = null) -> Props:
	## 单趟扫描：同时累加质量、一阶矩与"绕原点的极惯性矩"，
	## 再用平行轴定理换算到质心：I_com = I_origin - m * |com|^2。
	## （逐像素循环是 GDScript 里最贵的部分，能少扫一趟就少一趟。）
	var p := Props.new()
	var m := 0.0
	var sx := 0.0
	var sy := 0.0
	var i_origin := 0.0
	var n := 0
	# ⚠️⚠️ **密度按材质记忆化**：density_of 的契约是 Callable(material) -> float，
	#    也就是**只依赖材质**。但旧代码逐像素调一次 —— 3 万像素的碎片就是 3 万次
	#    Callable 调用，实测占这个函数三分之一以上，而材质种类通常只有一两种。
	#
	#    ⚠️ 这个缓存**只在本次 compute 内有效**（不跨调用、不存在 shape 上），
	#    所以密度表之后被改了也不会读到旧值 —— 不需要任何失效逻辑。
	#    （跨调用缓存密度才会引入"缓存判错不报错"的风险，这里刻意不做。）
	var has_density := density_of.is_valid()
	var dens := {}
	# 摩擦/恢复系数：**和密度同一趟扫描**（逐像素再扫一遍是白烧；材质种类通常一两种，
	# 同样按材质记忆化）。没给 Callable 就整趟不算，零开销。
	var has_fric := friction_of.is_valid()
	var has_rest := restitution_of.is_valid()
	var fric := {}
	var rest := {}
	var f_sum := 0.0
	var r_sum := 0.0
	var dscale := shape.density_scale
	# 逐块几何缓存：传了 changed_keys 才复用；没传 = "不知道改了哪些块" -> 清掉（sound）。
	var cache: Dictionary = shape._mp_cache
	var hinted: bool = changed_keys != null
	if not hinted:
		cache.clear()
	var changed: Dictionary = changed_keys if hinted else {}
	for k: int in shape.chunks:
		var c: PixelChunk = shape.chunks[k]
		var bx := PixelShape.key_x(k) << 3
		var by := PixelShape.key_y(k) << 3
		var occ := c.occ
		if occ == 0:
			continue
		var n_c := Bits.popcount(occ)
		# ---- 复用：本块没被改过，直接拿缓存的几何量（只可能是"整块同材质"那一路）----
		if hinted and not changed.has(k):
			var e: Variant = cache.get(k)
			if e != null:
				var v0: int = e["v"]
				var n0: int = e["n"]
				var d0r := 1.0
				if has_density:
					var cd0 = dens.get(v0)
					if cd0 == null:
						cd0 = density_of.call(v0)
						dens[v0] = cd0
					d0r = cd0
				d0r *= dscale
				var fv0r := 0.0
				if has_fric:
					var cf0 = fric.get(v0)
					if cf0 == null:
						cf0 = friction_of.call(v0)
						fric[v0] = cf0
					fv0r = cf0
				var rv0r := 0.0
				if has_rest:
					var cr0 = rest.get(v0)
					if cr0 == null:
						cr0 = restitution_of.call(v0)
						rest[v0] = cr0
					rv0r = cr0
				# ⚠️ 这 5 行与下面快路径的加法**逐字对应**（顺序、括号都一样）-> 逐位精确
				m += d0r * float(n0)
				sx += d0r * e["sx"]
				sy += d0r * e["sy"]
				i_origin += d0r * e["ii"]
				f_sum += fv0r * float(n0)
				r_sum += rv0r * float(n0)
				n += n0
				continue
		# ⚠️⚠️ **整块同材质时的边际量快路径**。逐像素要付位扫描 + 三次查表 + 12 次浮点，
		#    实测 **0.61 us/像素**：768x100 一刀切开后两片共 6.6 万像素 = **40 ms**，
		#    是"生成新实体"里最大的一项（比 apply_damage 9.4 + split 17.3 加起来还大）。
		#
		#    整块同材质时，质量/一阶矩/极惯性矩都能从**行、列 popcount** 一次算完：
		#      m = n*d          sx = d*Σ_j (bx+j+0.5)*colcnt[j]
		#      sy = d*Σ_j (by+j+0.5)*rowcnt[j]
		#      I_origin = d*(Σ_j (bx+j+0.5)^2*colcnt[j] + Σ_j (by+j+0.5)^2*rowcnt[j] + n/6)
		#    ⚠️ 极惯性矩只要 Σx² 与 Σy²，**不需要 x·y 交叉项** —— 所以边际量就够，
		#      不必知道行列的联合分布。
		#    ⚠️ 摩擦/恢复系数同理（同材质 -> n 倍同一个值），**必须一起聚合**，
		#      否则快路径会静默漏掉它们（那条路是别人刚加的功能）。
		#
		#    "整块同材质"的判据：空像素的 mat 恒为 0（PixelChunk 的约定），
		#    所以 mat.count(v) == popcount(occ) 等价于"所有占用像素的材质都是 v"。
		#    这是一次**原生**扫描（PackedByteArray.count），比逐像素便宜得多。
		#    不满足就走下面的逐像素慢路径 —— 累加顺序与旧实现完全相同。
		var v: int = c.mat[Bits.first_bit_index(occ)]
		if v != 0 and c.mat.count(v) == n_c:
			var d0 := 1.0
			if has_density:
				var cd = dens.get(v)
				if cd == null:
					cd = density_of.call(v)
					dens[v] = cd
				d0 = cd
			d0 *= dscale
			var fv0 := 0.0
			if has_fric:
				var cf = fric.get(v)
				if cf == null:
					cf = friction_of.call(v)
					fric[v] = cf
				fv0 = cf
			var rv0 := 0.0
			if has_rest:
				var cr = rest.get(v)
				if cr == null:
					cr = restitution_of.call(v)
					rest[v] = cr
				rv0 = cr
			var sx_c := 0.0
			var sy_c := 0.0
			var sxx := 0.0
			var syy := 0.0
			for j in 8:
				var cj := Bits.popcount(occ & (0x0101010101010101 << j))
				var rj := Bits.popcount(occ & (0xFF << (j << 3)))
				var fx := float(bx + j) + 0.5
				var fy := float(by + j) + 0.5
				sx_c += fx * float(cj)
				sxx += fx * fx * float(cj)
				sy_c += fy * float(rj)
				syy += fy * fy * float(rj)
			var ii_c := sxx + syy + float(n_c) / 6.0
			# 存几何量（与密度无关，所以密度表改了不用失效）
			cache[k] = {"n": n_c, "sx": sx_c, "sy": sy_c, "ii": ii_c, "v": v}
			m += d0 * float(n_c)
			sx += d0 * sx_c
			sy += d0 * sy_c
			i_origin += d0 * ii_c
			f_sum += fv0 * float(n_c)
			r_sum += rv0 * float(n_c)
			n += n_c
			continue
		cache.erase(k)          # 混合材质的块不进缓存（复用分支只认快路径的条目）
		var bits := occ
		while bits != 0:
			var i := Bits.first_bit_index(bits)
			bits &= bits - 1
			var px := float(bx + (i & 7)) + 0.5
			var py := float(by + (i >> 3)) + 0.5
			var d := 1.0
			if has_density:
				var mi: int = c.mat[i]
				var cached = dens.get(mi)
				if cached == null:
					cached = density_of.call(mi)
					dens[mi] = cached
				d = cached
			# 形状级的密度倍率（Teardown 的 SetShapeDensity）。默认 1.0，不影响既有行为。
			d *= dscale
			if has_fric or has_rest:
				var mi2: int = c.mat[i]
				if has_fric:
					var fv = fric.get(mi2)
					if fv == null:
						fv = friction_of.call(mi2)
						fric[mi2] = fv
					f_sum += fv
				if has_rest:
					var rv = rest.get(mi2)
					if rv == null:
						rv = restitution_of.call(mi2)
						rest[mi2] = rv
					r_sum += rv
			m += d
			sx += d * px
			sy += d * py
			i_origin += d * (px * px + py * py + 1.0 / 6.0)
			n += 1
	p.pixel_count = n
	p.fric_sum = f_sum
	p.rest_sum = r_sum
	if m <= 0.0 or n == 0:
		return p
	p.mass = m
	p.com = Vector2(sx / m, sy / m)
	p.inertia = maxf(0.0, i_origin - m * p.com.length_squared())
	return p
