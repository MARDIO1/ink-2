extends RefCounted
## PBF 粒子流体（Position Based Fluids）—— 纯视觉的液体，不参与物理像素、不做碰撞。
##
## ## 本文件是**语义真源**
##
## 原生实现（gdext/fastphys.cpp 的 PixelFluid）必须与它**逐位相同**，
## 闸门 tests/validation_fluid.gd。所以这里的运算顺序、除法方向、舍入方式都是**契约**，
## 不是风格问题 —— 改任何一处都要同时改 C++ 那侧，否则闸门会打脸。
##
## ## 算法出处
##
## Matthias Müller "Ten Minute Physics" 的 PBF；参数取自 PinkiePie1/CH32V203Dev
## 的 Apps/fluid_vb/SandSim.c —— 同一套参数（130 粒子 / 17x18 格 / overRelaxation 1.9 /
## stiffness 1.0 / flipRatio 0.9 / bouncyness -0.9）在 144MHz、**无 FPU** 的 RISC-V
## 上跑过。所以这些值不重新标定。
##
## 那边是 Q24 定点（qmul(a,b) = (int64)a*b >> 24），这里用 float64。
## **为什么敢用浮点**：引擎的构建带 -ffp-contract=off，README 写明
## 「少了它编译器会把浮点乘加融合成 FMA，与 GDScript 路径立刻分叉」——
## 也就是说"C++ 与 GDScript 浮点逐位一致"本来就是本仓库的既定前提。
##
## ## 为什么是粒子而不是格子流体
##
## 本用途是"玩家转动时液面跟着变"。PBF 里**没有"下"这个概念** —— 重力只是一个
## 加速度向量，加到粒子速度上；转动 = 换一个向量，没了。
## 而格子流体每一步都要判断"哪个邻居算下坡"，45 度时液面变平变慢、斜对角流的
## 权重惩罚、perp 用 1-|cos| 近似……所有角度相关的怪味都是从那个判断里长出来的。
##
## ## 网格索引约定（与参照实现一致，别改成行主序）
##
##     INDEX(x, y) = x * ny + y
##
## 于是**同一列的相邻单元在数组里连续** —— push_apart 靠这条把"同列 3 格"
## 合并成一次遍历（见那里的说明）。四邻域：left = i - ny，right = i + ny，
## bottom = i - 1，top = i + 1。
##
## ## 坐标与单位
##
## 粒子活在**自己的**域里（[0, nx*h] x [0, ny*h]），不是世界像素。调用方负责把域
## 映射到目标区域；重力也在这个域的单位里，按"域有多高"换算。
## 这条隔离让"瓶子 51x27 像素"和"LED 矩阵 17x18"能用同一个内核。
##
## ## 缓冲为什么是"两个分量拼一条"
##
## GDScript 的 Packed*Array 是**值类型**（赋值即拷贝）。所以 `var f := _u_vel`
## 之后再写 f 是**写副本**，一个字符都不会进到 _u_vel —— 而且不报错。
## 把 u/v 两个分量拼进同一条数组、用 base = component*ncells 索引，
## 就既只有一份代码、又不必把数组传来传去。

# ---- 参数（默认值 = 参照实现的值）----

## 网格列数 / 行数。
var num_x := 17
var num_y := 18
## 格子间距（域单位）。
var spacing := 0.041
## 粒子半径（域单位）。与 spacing 的**比值**才是物理量（0.019/0.041 = 0.463）。
var radius := 0.019
## 时间步长（秒）。
var dt := 0.016
## 撞壁时的速度保留率。负数 = 反弹。
var bouncyness := -0.9
## 压力过松弛系数。
var over_relaxation := 1.9
## 密度修正的刚度。
var stiffness := 1.0
## FLIP / PIC 混合比（0 = 全 PIC，1 = 全 FLIP）。
var flip_ratio := 0.9
## "把粒子推开"的迭代次数。
var push_iters := 1
## 压力松弛的迭代次数。
var grid_iters := 8
## 渲染时把粒子泼成多大（格）。
##
##   0 = **只标它所在的那一格**。⚠️ 会有一地透明噪点：粒子按 2r = 0.926 密排，
##       而格子是 1x1，每格平均只有 0.74 个粒子 -> 约 **26% 的格子是空的**。
##   > 0（默认 0.8）= 以该半径泼圆盘。
##
## ⚠️ 半径的**下界是 0.75**，两个理由各自独立：
##    · 粒子离自己格心最远可以到 0.707（格角）—— 半径比它小，粒子会**一格都标不上**
##      （实测 3522 个粒子只标出 692 格，看着像"墨水在漏"）；
##    · 相邻粒子间距 0.926，两个半径 r 的圆盘要盖住中点，需要 r >= 0.463；
##      但要盖住**四格交汇处**（离最近粒子最远 0.926/sqrt(3) = 0.535）才不留洞，
##      再加上格心对齐的余量，0.8 是实测不漏的取值。
## 溢出容器的那部分由 _raster_ink 与掩码取交裁掉，所以半径大一点不会糊出瓶壁。
var splat_radius := 0.8

# ---- 权威状态 ----
## 粒子位置，[x0, y0, x1, y1, ...]，长度 2N。
var pos := PackedFloat64Array()
## 粒子速度，同上。
var vel := PackedFloat64Array()

# ---- 派生状态（每步由 pos/vel 重算，不是第二份真源）----
## 可通行掩码：1 = 可通行，0 = 固体。长度 nx*ny。
var solid_mask := PackedByteArray()
## 单元类型。AIR_CELL / FLUID_CELL / SOLID_CELL。
var cell_type := PackedByteArray()
## 静止密度。首帧由密度场平均得到，之后固定。
var rest_density := 0.0
## 渲染输出：1 = 有墨水。长度 nx*ny。
var ink := PackedByteArray()

const AIR_CELL := 1
const FLUID_CELL := 0
const SOLID_CELL := 2

# 网格临时缓冲。[0, ncells) = u 分量，[ncells, 2*ncells) = v 分量
var _f := PackedFloat64Array()
var _w := PackedFloat64Array()
var _f_prev := PackedFloat64Array()
var _density := PackedFloat64Array()
var _pressure_scale := PackedFloat64Array()
var _density_corr := PackedFloat64Array()
var _fluid_cells := PackedInt32Array()
# 粒子分格（计数排序）
var _cell_prefix := PackedInt32Array()
var _particle_ids := PackedInt32Array()
var _particle_cell := PackedInt32Array()

## 原生后端（懒加载）。null = 用本文件的参照实现。
var _native: Object = null
var _native_checked := false
## 原生那份状态是否已经过期 —— 粒子集 / 掩码 / 尺寸变了就要重新灌一次。
##
## ⚠️ 走原生时，**权威状态在原生那边**：每步只回吐 ink 掩码（10 KB），
##    pos/vel（4320 粒子时 138 KB）不再每步往返。代价是本文件的 pos/vel
##    在原生推进之后是**旧的** —— 要读它们必须先 sync_from_native()。
##    本文件里唯一需要真坐标的地方是增删粒子的选择（_select_extreme），
##    它在 _apply_fill 里已经先 sync 了。
var _native_dirty := true
## 原生路径**真的被走到过**几次。
##
## ⚠️ 为什么需要它：原生调用失败时本文件会**静默退回参照实现**（只 push_error）。
##    于是"原生 == 参照"那类逐位断言会退化成"GDScript 跟自己比"，**必然通过** ——
##    闸门变假绿。判据必须是"这条路真的走过了"，不是"结果一样"。
var native_calls := 0


## 把原生那份 pos/vel 拉回来。读 pos/vel 之前必须调。
## 不走原生时是空操作。
func sync_from_native() -> void:
	var nat := _ensure_native()
	if nat == null:
		return
	# ⚠️⚠️ 原生**还没灌过状态**（或刚改过）时不能拉：它那份是空的/旧的，
	#    拉回来会把本文件正确的状态覆盖成垃圾。
	#    症状是 "dump 返回长度不对"（S->n = 0 时只回吐 8 字节），
	#    而它发生在 snap_fill -> _apply_fill 这条**初始化**路径上 ——
	#    离"同步"这个语义看起来十万八千里。
	#    判据：_native_dirty 为真时，**本文件才是权威**，没什么可拉的。
	if _native_dirty:
		return
	var n := particle_count()
	var need := n * 16 * 2 + 8          # pos + vel + rest_density
	var inp := PackedByteArray()
	inp.resize(8 + 1)
	inp.encode_s32(0, need)
	inp.encode_s32(4, 1)
	inp.encode_u8(8, 3)                       # op 3 = dump
	var tmpl := PackedByteArray()
	tmpl.resize(4 + need)
	var res: PackedByteArray = nat.step(inp, tmpl)
	# ⚠️ 只比 **written**。res.size() 是模板长度，恒等于 4 + need ——
	#    把它一起打出来会让人以为"长度不符"，而真正不符的是 written。
	if res.decode_s32(0) != need:
		push_error("PixelFluid.dump 回吐长度不对（written=%d 期望=%d，res.size=%d）"
				% [res.decode_s32(0), need, res.size()])
		return
	var body := res.slice(4, 4 + need)
	pos = body.slice(0, n * 16).to_float64_array()
	vel = body.slice(n * 16, n * 16 * 2).to_float64_array()
	rest_density = body.decode_double(n * 16 * 2)


## 声明"原生那份状态过期了"。改过 solid_mask / 尺寸之后要调。
func mark_dirty() -> void:
	_native_dirty = true

var _min_x := 0.0
var _min_y := 0.0
var _max_x := 0.0
var _max_y := 0.0


#region 生命周期

func _init() -> void:
	resize_grid(num_x, num_y)


## 改网格尺寸。会重建全部缓冲并**清空粒子**（尺寸变了，旧坐标没有意义）。
func resize_grid(nx: int, ny: int) -> void:
	num_x = maxi(nx, 3)
	num_y = maxi(ny, 3)
	var n := num_x * num_y
	# ⚠️⚠️ **必须逐个写，不能写成 for a in [_f, _w, ...]**。
	#    Array 字面量会把 Packed*Array **按值拷进去**（见文件头「缓冲为什么是两个分量
	#    拼一条」），于是 a.resize(n) 改的是副本 —— 成员数组仍然是**空的**。
	#    症状不是报错，而是接下来每一步都 "Out of bounds set index 0"：
	#    报错点在 _setup_solid_mask / _particles_to_grid，指向的却是这里。
	_f.resize(n * 2)
	_w.resize(n * 2)
	_f_prev.resize(n * 2)
	_density.resize(n)
	_pressure_scale.resize(n)
	_density_corr.resize(n)
	cell_type.resize(n)
	solid_mask.resize(n)
	ink.resize(n)
	_cell_prefix.resize(n + 1)
	pos.resize(0)
	vel.resize(0)
	rest_density = 0.0
	_native_dirty = true
	_setup_solid_mask()
	_update_bounds()


func _setup_solid_mask() -> void:
	# 边界一圈是固体，内部可通行。与参照实现 setup_solid_mask 同判据。
	for x in num_x:
		for y in num_y:
			var edge := x == 0 or x == num_x - 1 or y == 0 or y == num_y - 1
			solid_mask[x * num_y + y] = 0 if edge else 1


## 域钳位（撞壁判据）。
##
## ⚠️⚠️ 是 **r .. num*h - r**，不是参照实现的 **h + r .. (num-1)*h - r**。
##
##    参照实现多缩进一格，是因为**它的容器就是那个矩形网格、外圈一格是实心边界** ——
##    墙在内缩一格的位置。照抄到掩码容器上，第 0 行/列就永远够不着，
##    四周各留一格空 —— 那正是"粒子和线稿之间有一条缝"。
##
##    掩码容器的墙**就是域的边**：可通行格在哪，粒子就该能到哪。
##    外圈若真是实心的，_contain_particles 会把粒子推回来，不需要钳位替它操心。
func _update_bounds() -> void:
	_min_x = radius
	_min_y = radius
	_max_x = float(num_x) * spacing - radius
	_max_y = float(num_y) * spacing - radius


## 按六角形密排初始化粒子，返回粒子数。
##
## 排布间距 dx = 2r、dy = 0.866*2r，奇偶行错开 r —— 最密六角堆，
## 也是 restDensity 有意义的来源：粒子均匀铺满时密度场是常数。
func init_particles(max_count: int = -1) -> int:
	pos.resize(0)
	vel.resize(0)
	rest_density = 0.0
	_native_dirty = true
	var h := spacing
	var r := radius
	var dx := 2.0 * r
	var dy := 0.86602540378 * dx
	# ⚠️⚠️ 晶格的行列数要按**域**算，不能按 num_x / num_y 算。
	#    dy = 0.866*2r = 0.802 格，而 num_y = 59 只给出 59*0.802 ≈ 47 格的覆盖 ——
	#    照 num_y 循环，密排只铺满域的八成，于是"填满容器需要多少粒子"被系统性低估：
	#    fill_ratio = 1.0 时瓶子只装了七成，而且**看着像流体没灌满**，
	#    根本不会往"排布循环写错了"这个方向想。
	var nx_lat := int(ceil(float(num_x) * h / dx)) + 2
	var ny_lat := int(ceil(float(num_y) * h / dy)) + 2
	# ⚠️ 默认上限是**晶格能放下的总数**，不是 num_x * num_y。
	#    num_x*num_y 是"格子数"，而粒子按 0.743 格²/个 密排 —— 每格平均放得下
	#    1.34 个。用格子数当上限会**少排 26%**，于是 fill_ratio = 1.0 时
	#    瓶子只装了七成，看着像"液体没灌满"，而所有断言都还是绿的。
	var limit := max_count
	if limit < 0:
		limit = nx_lat * ny_lat
	var count := 0
	# ⚠️⚠️ **从下往上排**（j 递减）。
	#
	#    晶格的 j=0 是最上面一行，而调用方给的 limit 是"装多少" —— 从上往下排的话，
	#    截断时留下的是**上面那一半**：液体一开始悬在半空，要落一阵子才像样
	#    （实测第 40 帧只盖住 56%，而终态是 90%）。
	#    从下往上排，截断留下的是底下那一块 —— **一开始就是终态**。
	#    这也顺带让"初始状态"和"静止状态"一致，省掉一整段没意义的沉降动画。
	for jj in ny_lat:
		var j := ny_lat - 1 - jj
		for i in nx_lat:
			if count >= limit:
				break
			# ⚠️⚠️ 起点是 **r**，不是 h + r；终点是 **num*h - r**，不是 (num-1)*h - r。
			#
			#    参照实现用的是 h + r .. (num-1)*h - r —— 那是**因为它的容器就是那个矩形
			#    网格、外圈本来就是实心边界**，粒子该从第 1 格开始。
			#    而我们的容器是剪影掩码，边界就是瓶壁：照抄会在**四周各留一格空**
			#    （第 0 行/列永远分不到粒子），看着就是"粒子和线稿之间有一条缝"。
			var px := r + dx * float(i) + (r if (j % 2) == 0 else 0.0)
			var py := r + dy * float(j)
			if px > float(num_x) * h - r or py > float(num_y) * h - r:
				continue
			# 只放在**可通行**的格子里。
			#
			# ⚠️ 参照实现没有这一条 —— 它的 solidMask 只有最外圈边界，容器永远是矩形，
			#    所以"排满整个域"就等于"排满容器"。容器一旦有形状（瓶子剪影），
			#    照排就会把粒子放进容器外的死格子里：压力求解跳过固体格，
			#    grid_to_particles 也不把它们推出来 —— 那批粒子**永久卡住**，
			#    而且它们还占着 fill_ratio 的份额，液面会比应有的低。
			var cx := clampi(int(px / h), 0, num_x - 1)
			var cy := clampi(int(py / h), 0, num_y - 1)
			if solid_mask[cx * num_y + cy] == 0:
				continue
			pos.append(px)
			pos.append(py)
			vel.append(0.0)
			vel.append(0.0)
			count += 1
	# ⚠️ 参照实现会把排不满的粒子**全部堆在左上角**（p_num 用完之后那段 for）。
	#    这里刻意不堆：那会在角落里造出一个密度高得离谱的点，而 restDensity 是
	#    **首帧**由密度场平均出来的 —— 基准被那几个粒子带偏之后**永远不会再修正**。
	#    宁可少几个粒子，也不能让整局的静止密度从一开始就是错的。
	return count


func particle_count() -> int:
	return pos.size() / 2

#endregion

#region 液体量（连续）

## 目标液量比例 0..1。**负数 = 不控制**（粒子数完全由 init_particles / 增删决定）。
##
## 设成非负之后，每次 step() 先朝它挪一小步（见 fill_rate），再跑模拟。
var fill_ratio := -1.0

## 每步最多增删几个粒子。0 = 不限（一步到位）。
##
## ## 为什么是"每步几个"而不是"一次删够"
##
## 一次删掉 200 个 = 液面**瞬间**塌掉一大块，那是跳变，不是液面下降。
## 每次删几个、让模拟自己重新沉下去，液面就是**一格一格**往下走的 ——
## 在 51x27 的瓶子上，一格就是一像素，看上去就是连续的。
##
## 代价是显示**滞后**于真值：掉 200 点血、每步删 2 个，要 100 步（约 1.7 秒）追上。
## 对血条来说这个滞后是**要的**（挨打要有过程），但它必须最终收敛 ——
## 闸门里有一条断言就钉这个（见 tests/validation_fluid.gd）。
var fill_rate := 2

## 每步最多消掉**剩余差额**的百分之几（比例逼近）。
##
## ⚠️ 只有固定下限是不够的：fill_rate = 2 时掉一半血要 1158 步（约 19 秒）才追得上，
##    而调大下限又会让小变化变成跳变。两者要一起用 ——
##    小差额由下限兜住（平滑），大差额由比例项加速（收敛）。
##    0.06 时约 60 步（1 秒）追平任意大的差额，而 10 个粒子的变化仍是逐颗走。
var fill_gain := 0.06

## 满瓶时的粒子数上限。0 = 用 num_x*num_y。
var max_particles := 0


## 设目标液量比例。**只设目标，不立刻改粒子数** —— 下一次 step() 才朝它挪一步。
##
## ⚠️ 刻意**不**在这里应用。这个 API 会被每帧调用（血量一变就调），
##    如果它顺手把粒子删到位，那就是"一下全部删完" —— 正是要避免的那个跳变。
##    要一步到位请显式调 snap_fill()：让"错的那条路"必须多打一个字。
func set_fill_ratio(ratio: float) -> void:
	fill_ratio = clampf(ratio, 0.0, 1.0)


## 立刻把粒子数对齐到 fill_ratio（一步到位）。**只在初始化 / 测试里用。**
func snap_fill(gx: float = 0.0, gy: float = 1.0) -> void:
	if fill_ratio < 0.0:
		return
	_apply_fill(gx, gy, 0)


## 本步增删的粒子数（诊断用）。step() 里填。
var last_fill_delta := 0


## 每步朝 fill_ratio 挪一步。返回本步增删的粒子数。
func _advance_fill(gx: float, gy: float) -> int:
	if fill_ratio < 0.0:
		return 0
	return _apply_fill(gx, gy, fill_rate)


func _apply_fill(gx: float, gy: float, rate: int) -> int:
	var cap := max_particles
	if cap <= 0:
		cap = num_x * num_y
	var target := int(round(clampf(fill_ratio, 0.0, 1.0) * float(cap)))
	var cur := particle_count()
	var delta := target - cur
	if delta == 0:
		return 0
	if rate > 0:
		# 限幅 = max(下限, 误差的比例) —— 见 fill_gain 的说明。
		var limit := maxi(rate, int(ceil(float(absi(delta)) * fill_gain)))
		delta = clampi(delta, -limit, limit)
	# ⚠️ 增删要**真坐标**（_select_extreme 按高度挑），而走原生时本文件的 pos/vel
	#    在原生推进之后是旧的 —— 先拉回来。稳态（delta == 0）不会走到这里，
	#    所以这趟往返只在掉血/回墨时发生。
	sync_from_native()
	if delta > 0:
		_add_particles(delta, gx, gy)
	else:
		_remove_particles(-delta, gx, gy)
	return delta


## 32 位整数混合（xorshift 风格），把粒子下标打散成伪随机序。
##
## ⚠️ **必须与 C++ 侧逐位相同** —— 它决定"平局时先删谁"，而删谁是可观测行为。
##    每一步都 & 0x7FFFFFFF 是为了避开 int64 溢出：不截断的话
##    x * 1274126177 会到 2.7e18 以上，两个语言一旦在溢出行为上分叉就完了。
static func _index_hash(i: int) -> int:
	var x := (i + 1) * 73856093
	x = x & 0x7FFFFFFF
	x = x ^ (x >> 13)
	x = (x * 1274126177) & 0x7FFFFFFF
	x = x ^ (x >> 16)
	return x


## 选 k 个"沿重力方向最靠上（want_top=true）或最靠下"的粒子下标。
##
## ## 为什么不用 sort_custom
##
## 排序的**结果顺序**会成为可观测行为（删掉哪些粒子），而闸门是 C++ 与 GDScript
## **逐位对拍**。要在 C++ 里复刻 Godot 的排序算法才能保证一致 —— 那是在赌两个
## 库的内部实现，不值得。
##
## 这里用 k 轮线性扫描选极值：O(k*n)，k 是 fill_rate（默认 2），n 是粒子数。
## 平局判据写死成"下标小的优先"，所以**同一份输入永远选出同一批**。
func _select_extreme(k: int, gx: float, gy: float, want_top: bool) -> PackedInt32Array:
	var n := particle_count()
	var out := PackedInt32Array()
	if n == 0 or k <= 0:
		return out
	var gl := sqrt(gx * gx + gy * gy)
	var ux := 0.0
	var uy := 1.0
	if gl > 0.0:
		ux = gx / gl
		uy = gy / gl
	var h := PackedFloat64Array()
	h.resize(n)
	for i in n:
		h[i] = pos[i * 2] * ux + pos[i * 2 + 1] * uy
	var taken := PackedByteArray()
	taken.resize(n)
	k = mini(k, n)
	for _pass in k:
		var best := -1
		for i in n:
			if taken[i] != 0:
				continue
			if best < 0:
				best = i
				continue
			if h[i] == h[best]:
				# 平局用下标哈希打散。
				#
				# ⚠️⚠️ **必须打散**：初始六角密排里同一行的粒子高度**完全相同**，
				#    按"下标小的优先"会一次选中一串**相邻**粒子 —— 液面上出现一个
				#    缺口，而不是液面整体下沉。而"删哪些"是可观测行为，
				#    所以哈希必须是确定性的（两边逐位相同）。
				if _index_hash(i) < _index_hash(best):
					best = i
				elif _index_hash(i) == _index_hash(best) and i < best:
					best = i
			else:
				var better := (h[i] > h[best]) if want_top else (h[i] < h[best])
				if better:
					best = i
		if best < 0:
			break
		taken[best] = 1
		out.append(best)
	return out


## 删掉最靠上（逆着重力）的 k 个粒子。
##
## 为什么是"最上面"：液体是从表面流走/蒸发掉的，不是从底部凭空少一块。
## 而液面近似水平，"最上面"那批天然散布在整条液面上 —— 不会在一处挖出一个洞。
func _remove_particles(k: int, gx: float, gy: float) -> void:
	var n := particle_count()
	k = mini(k, n)
	if k <= 0:
		return
	var drop := _select_extreme(k, gx, gy, false)
	var marked := PackedByteArray()
	marked.resize(n)
	for i in drop:
		marked[i] = 1
	var np := PackedFloat64Array()
	var nv := PackedFloat64Array()
	np.resize((n - k) * 2)
	nv.resize((n - k) * 2)
	var w := 0
	for i in n:
		if marked[i] != 0:
			continue
		np[w * 2] = pos[i * 2]
		np[w * 2 + 1] = pos[i * 2 + 1]
		nv[w * 2] = vel[i * 2]
		nv[w * 2 + 1] = vel[i * 2 + 1]
		w += 1
	pos = np
	vel = nv
	_native_dirty = true


## 在**液面上方**补 k 个粒子。
##
## 位置取"最靠上的那批粒子各自再往上挪一个粒子直径"。新粒子落在液面上，
## 由 push_apart 自己把它们摊开。刻意不随机 —— 闸门要逐位对拍。
func _add_particles(k: int, gx: float, gy: float) -> void:
	var n := particle_count()
	var gl := sqrt(gx * gx + gy * gy)
	var ux := 0.0
	var uy := 1.0
	if gl > 0.0:
		ux = gx / gl
		uy = gy / gl
	var seeds := _select_extreme(k, gx, gy, false) if n > 0 else PackedInt32Array()
	for t in k:
		var px := spacing * 0.5 * float(num_x)
		var py := spacing * 0.5 * float(num_y)
		if seeds.size() > 0:
			var s: int = seeds[t % seeds.size()]
			px = pos[s * 2] - ux * (2.0 * radius)
			py = pos[s * 2 + 1] - uy * (2.0 * radius)
		pos.append(clampf(px, _min_x, _max_x))
		pos.append(clampf(py, _min_y, _max_y))
		vel.append(0.0)
		vel.append(0.0)
	_native_dirty = true

#endregion

#region 仿真

## 推进一步。
##
## [param gx] [param gy] 是**域单位**下的重力加速度 —— 不是像素/秒²。
## 调用方按"域有多高"换算（见文件头「坐标与单位」）。
##
## 顺序是契约，与参照实现一致：
##   integrate -> push_apart -> particles_to_grid -> density_update
##             -> grid_forces -> grid_to_particles
func step(gx: float, gy: float) -> void:
	last_fill_delta = _advance_fill(gx, gy)
	var nat := _ensure_native()
	if nat != null and _step_native(nat, gx, gy):
		return
	_step_gd(gx, gy)


## 纯 GDScript 参照实现。原生不可用 / 闸门对拍时走这条。
func _step_gd(gx: float, gy: float) -> void:
	_integrate(gx, gy)
	_push_apart(push_iters)
	_particles_to_grid()
	_density_update()
	_grid_forces(grid_iters)
	_grid_to_particles()
	_raster_ink()


func _integrate(gx: float, gy: float) -> void:
	var dvx := gx * dt
	var dvy := gy * dt
	var n := particle_count()
	for i in n:
		var k := i * 2
		vel[k] += dvx
		vel[k + 1] += dvy
		pos[k] += vel[k] * dt
		pos[k + 1] += vel[k + 1] * dt
		var x := pos[k]
		var y := pos[k + 1]
		if x < _min_x:
			x = _min_x
			vel[k] = vel[k] * bouncyness
		if x > _max_x:
			x = _max_x
			vel[k] = vel[k] * bouncyness
		if y < _min_y:
			y = _min_y
			vel[k + 1] = vel[k + 1] * bouncyness
		if y > _max_y:
			y = _max_y
			vel[k + 1] = vel[k + 1] * bouncyness
		pos[k] = x
		pos[k + 1] = y


## 把挨得太近的粒子互相推开（位置层面的不可压缩）。
##
## 分格只做**一次**，nIters 轮复用同一份桶 —— 这是参照实现的行为，nIters 默认 1
## 时无所谓；改大 push_iters 要知道桶会过期（粒子的 3x3 邻域是每轮现算的）。
func _push_apart(iters: int) -> void:
	var n := particle_count()
	if n == 0:
		return
	var h := spacing
	var ncells := num_x * num_y
	if _particle_ids.size() != n:
		_particle_ids.resize(n)
		_particle_cell.resize(n)
	for i in ncells:
		_cell_prefix[i] = 0
	for i in n:
		var xi := clampi(int(pos[i * 2] / h), 0, num_x - 1)
		var yi := clampi(int(pos[i * 2 + 1] / h), 0, num_y - 1)
		var c := xi * num_y + yi
		_particle_cell[i] = c
		_cell_prefix[c] += 1
	var prefix := 0
	for i in ncells:
		prefix += _cell_prefix[i]
		_cell_prefix[i] = prefix
	_cell_prefix[ncells] = prefix
	for i in n:
		var c := _particle_cell[i]
		_cell_prefix[c] -= 1
		_particle_ids[_cell_prefix[c]] = i
	var min_dist := 2.0 * radius
	var min_dist2 := min_dist * min_dist
	for _iter in iters:
		for i in n:
			var px := pos[i * 2]
			var py := pos[i * 2 + 1]
			var pxi := clampi(int(px / h), 0, num_x - 1)
			var pyi := clampi(int(py / h), 0, num_y - 1)
			var x0 := maxi(pxi - 1, 0)
			var y0 := maxi(pyi - 1, 0)
			var x1 := mini(pxi + 1, num_x - 1)
			var y1 := mini(pyi + 1, num_y - 1)
			for xi in range(x0, x1 + 1):
				# 同一列的相邻单元在 _particle_ids 里**连续**（INDEX 是 x 主序），
				# 所以"整列 3 格"可以合并成一次区间遍历 —— 这是参照实现的关键优化。
				var first := _cell_prefix[xi * num_y + y0]
				var last := _cell_prefix[xi * num_y + y1 + 1]
				for j in range(first, last):
					var id := _particle_ids[j]
					if id == i:
						continue
					var dx := pos[id * 2] - px
					var dy := pos[id * 2 + 1] - py
					var d2 := dx * dx + dy * dy
					if d2 > min_dist2 or d2 == 0.0:
						continue
					var d := sqrt(d2)
					var s := 0.5 * (min_dist - d) / d
					dx *= s
					dy *= s
					px -= dx
					py -= dy
					pos[id * 2] += dx
					pos[id * 2 + 1] += dy
			pos[i * 2] = px
			pos[i * 2 + 1] = py
	# 撞壁（参照实现把 HandleParticleCollisions 并进了这里，且 integrate 里也做了一次）
	for i in n:
		var x := pos[i * 2]
		var y := pos[i * 2 + 1]
		if x < _min_x:
			x = _min_x
			vel[i * 2] = vel[i * 2] * bouncyness
		if x > _max_x:
			x = _max_x
			vel[i * 2] = vel[i * 2] * bouncyness
		if y < _min_y:
			y = _min_y
			vel[i * 2 + 1] = vel[i * 2 + 1] * bouncyness
		if y > _max_y:
			y = _max_y
			vel[i * 2 + 1] = vel[i * 2 + 1] * bouncyness
		pos[i * 2] = x
		pos[i * 2 + 1] = y
	_contain_particles()


## 把落在**固体格**里的粒子搬回最近的可通行格心。
##
## 为什么需要它：参照实现的 solidMask 只有最外圈边界，容器是个矩形，粒子不可能
## 跑到"容器外"（域边界就是容器边界）。容器一旦有形状，粒子就会漂进不该有液体的
## 格子 —— 而压力求解跳过固体格、grid_to_particles 也不把它们推出来，于是它们
## **永久卡在那里**，还继续占着 fill_ratio 的份额。
##
## 判据刻意写得笨：固定搜 9x9 的方窗，取距离最小的可通行格心，**平局取格号小的**。
## 笨才可复现 —— 闸门是 C++ 与 GDScript 逐位对拍，用"就近的某个格子"这种
## 说法是不行的。
##
## ⚠️ 半径 4 是够用的：粒子每步位移远小于一格，最多陷进去一两格。
##    真的一步跨进固体深处（比如容器被破坏出一个尖角），它会在几帧内被逐步搬出来
##    —— 每帧搬一次，不是一次搬到底。
func _contain_particles() -> void:
	var n := particle_count()
	var h := spacing
	for i in n:
		var px := pos[i * 2]
		var py := pos[i * 2 + 1]
		var cx := clampi(int(px / h), 0, num_x - 1)
		var cy := clampi(int(py / h), 0, num_y - 1)
		if solid_mask[cx * num_y + cy] != 0:
			continue
		var best := -1
		var best_d2 := 0.0
		for dy in range(-4, 5):
			var ty := cy + dy
			if ty < 0 or ty >= num_y:
				continue
			for dx in range(-4, 5):
				var tx := cx + dx
				if tx < 0 or tx >= num_x:
					continue
				var tc := tx * num_y + ty
				if solid_mask[tc] == 0:
					continue
				var gx := (float(tx) + 0.5) * h
				var gy := (float(ty) + 0.5) * h
				var d2 := (gx - px) * (gx - px) + (gy - py) * (gy - py)
				# 严格小于 -> 平局时**先扫到的赢**；扫描顺序固定，所以可复现
				if best < 0 or d2 < best_d2:
					best = tc
					best_d2 = d2
		if best >= 0:
			pos[i * 2] = (float(best / num_y) + 0.5) * h
			pos[i * 2 + 1] = (float(best % num_y) + 0.5) * h


## 粒子速度 -> MAC 网格。两个分量是**交错半格**采样的：
##   u 在 (x, y - h/2)，v 在 (x - h/2, y)
## 这是压力求解能只靠"四个面"做散度的前提。
func _particles_to_grid() -> void:
	var ncells := num_x * num_y
	for i in ncells:
		_f[i] = 0.0
		_f[ncells + i] = 0.0
		_w[i] = 0.0
		_w[ncells + i] = 0.0
		cell_type[i] = SOLID_CELL if solid_mask[i] == 0 else AIR_CELL
	var n := particle_count()
	var h := spacing
	for i in n:
		var xi := clampi(int(pos[i * 2] / h), 0, num_x - 1)
		var yi := clampi(int(pos[i * 2 + 1] / h), 0, num_y - 1)
		cell_type[xi * num_y + yi] = FLUID_CELL
	for component in 2:
		var base := component * ncells
		var off_x := 0.0 if component == 0 else h * 0.5
		var off_y := h * 0.5 if component == 0 else 0.0
		for i in n:
			var x := clampf(pos[i * 2], h, float(num_x - 1) * h)
			var y := clampf(pos[i * 2 + 1], h, float(num_y - 1) * h)
			var x0 := clampi(int((x - off_x) / h), 0, num_x - 2)
			var y0 := clampi(int((y - off_y) / h), 0, num_y - 2)
			var tx := ((x - off_x) - float(x0) * h) / h
			var ty := ((y - off_y) - float(y0) * h) / h
			var sx := 1.0 - tx
			var sy := 1.0 - ty
			var w0 := sx * sy
			var w1 := tx * sy
			var w2 := tx * ty
			var w3 := sx * ty
			var pv := vel[i * 2 + component]
			var nr0 := x0 * num_y + y0
			var nr1 := (x0 + 1) * num_y + y0
			var nr2 := (x0 + 1) * num_y + (y0 + 1)
			var nr3 := x0 * num_y + (y0 + 1)
			_f[base + nr0] += pv * w0
			_w[base + nr0] += w0
			_f[base + nr1] += pv * w1
			_w[base + nr1] += w1
			_f[base + nr2] += pv * w2
			_w[base + nr2] += w2
			_f[base + nr3] += pv * w3
			_w[base + nr3] += w3
		for i in ncells:
			if _w[base + i] > 0.0:
				_f[base + i] = _f[base + i] / _w[base + i]
		# 固体面：速度取上一帧的网格值（无滑移的近似）。参照实现就是取 uPrev。
		for x in num_x:
			for y in num_y:
				var idx := x * num_y + y
				if component == 0:
					var is_solid := cell_type[idx] == SOLID_CELL
					var left_solid := x > 0 and cell_type[(x - 1) * num_y + y] == SOLID_CELL
					if is_solid or left_solid:
						_f[idx] = _f_prev[idx]
				else:
					var is_solid2 := cell_type[idx] == SOLID_CELL
					var bottom_solid := y > 0 and cell_type[x * num_y + (y - 1)] == SOLID_CELL
					if is_solid2 or bottom_solid:
						_f[ncells + idx] = _f_prev[ncells + idx]
	# 流体单元列表。**扫描顺序 x 外 y 内** —— 与参照实现同序：松弛是 Gauss-Seidel，
	# 迭代顺序会进结果，所以这个顺序也是逐位对拍的一部分。
	_fluid_cells.resize(0)
	for x in range(1, num_x - 1):
		for y in range(1, num_y - 1):
			var idx := x * num_y + y
			if cell_type[idx] == FLUID_CELL:
				_fluid_cells.append(idx)


## 粒子质量 -> 格心密度。首帧顺便定出 restDensity。
##
## ⚠️ restDensity **只算一次**（rest_density == 0 是判据）。它是压力的基准，
##    之后粒子数怎么变都不重算 —— 否则"掉血"会同时改掉物理的基准，
##    液体的手感会跟着血量漂。
func _density_update() -> void:
	var ncells := num_x * num_y
	for i in ncells:
		_density[i] = 0.0
	var n := particle_count()
	var h := spacing
	var off := h * 0.5
	for i in n:
		var x := clampf(pos[i * 2], h, float(num_x - 1) * h)
		var y := clampf(pos[i * 2 + 1], h, float(num_y - 1) * h)
		var x0 := clampi(int((x - off) / h), 0, num_x - 2)
		var y0 := clampi(int((y - off) / h), 0, num_y - 2)
		var tx := ((x - off) - float(x0) * h) / h
		var ty := ((y - off) - float(y0) * h) / h
		var sx := 1.0 - tx
		var sy := 1.0 - ty
		_density[x0 * num_y + y0] += sx * sy
		_density[(x0 + 1) * num_y + y0] += tx * sy
		_density[(x0 + 1) * num_y + (y0 + 1)] += tx * ty
		_density[x0 * num_y + (y0 + 1)] += sx * ty
	if rest_density == 0.0:
		var sum := 0.0
		var num_fluid := 0
		for i in ncells:
			if cell_type[i] == FLUID_CELL:
				sum += _density[i]
				num_fluid += 1
		if num_fluid > 0:
			rest_density = sum / float(num_fluid)


## 压力松弛：把密度超出静止值的部分变成对四个面的速度修正。
func _grid_forces(iters: int) -> void:
	var ncells := num_x * num_y
	for i in ncells:
		_f_prev[i] = _f[i]
		_f_prev[ncells + i] = _f[ncells + i]
	var m := _fluid_cells.size()
	for k in m:
		var center := _fluid_cells[k]
		var s := solid_mask[center - num_y] + solid_mask[center + num_y] \
				+ solid_mask[center - 1] + solid_mask[center + 1]
		_pressure_scale[center] = -over_relaxation / float(s)
		var compression := (_density[center] - rest_density) if rest_density > 0.0 else 0.0
		_density_corr[center] = compression * stiffness if compression > 0.0 else 0.0
	for _iter in iters:
		for k in m:
			var center := _fluid_cells[k]
			var ps := _pressure_scale[center]
			if ps == 0.0:
				continue
			var left := center - num_y
			var right := center + num_y
			var bottom := center - 1
			var top := center + 1
			var div := _f[right] - _f[center] + _f[ncells + top] - _f[ncells + center]
			div -= _density_corr[center]
			var p := div * ps
			if solid_mask[left] != 0:
				_f[center] -= p
			if solid_mask[right] != 0:
				_f[right] += p
			if solid_mask[bottom] != 0:
				_f[ncells + center] -= p
			if solid_mask[top] != 0:
				_f[ncells + top] += p


## 网格速度 -> 粒子，按 flip_ratio 混合 PIC 与 FLIP。
##
## 全 PIC 会把液体抹得像糖浆（每次采样都丢一次动量）；全 FLIP 会保留噪声。
## 0.9 是参照实现/教程的取值。
func _grid_to_particles() -> void:
	var n := particle_count()
	var h := spacing
	var ncells := num_x * num_y
	for component in 2:
		var base := component * ncells
		var offset := num_y if component == 0 else 1
		var off_x := 0.0 if component == 0 else h * 0.5
		var off_y := h * 0.5 if component == 0 else 0.0
		for i in n:
			var x := clampf(pos[i * 2], h, float(num_x - 1) * h)
			var y := clampf(pos[i * 2 + 1], h, float(num_y - 1) * h)
			var x0 := clampi(int((x - off_x) / h), 0, num_x - 2)
			var y0 := clampi(int((y - off_y) / h), 0, num_y - 2)
			var tx := ((x - off_x) - float(x0) * h) / h
			var ty := ((y - off_y) - float(y0) * h) / h
			var sx := 1.0 - tx
			var sy := 1.0 - ty
			var d0 := sx * sy
			var d1 := tx * sy
			var d2 := tx * ty
			var d3 := sx * ty
			var nr0 := x0 * num_y + y0
			var nr1 := (x0 + 1) * num_y + y0
			var nr2 := (x0 + 1) * num_y + (y0 + 1)
			var nr3 := x0 * num_y + (y0 + 1)
			var d := 0.0
			var pic_num := 0.0
			var corr_num := 0.0
			if cell_type[nr0] != AIR_CELL or (nr0 - offset >= 0 and cell_type[nr0 - offset] != AIR_CELL):
				d += d0
				pic_num += d0 * _f[base + nr0]
				corr_num += d0 * (_f[base + nr0] - _f_prev[base + nr0])
			if cell_type[nr1] != AIR_CELL or (nr1 - offset >= 0 and cell_type[nr1 - offset] != AIR_CELL):
				d += d1
				pic_num += d1 * _f[base + nr1]
				corr_num += d1 * (_f[base + nr1] - _f_prev[base + nr1])
			if cell_type[nr2] != AIR_CELL or (nr2 - offset >= 0 and cell_type[nr2 - offset] != AIR_CELL):
				d += d2
				pic_num += d2 * _f[base + nr2]
				corr_num += d2 * (_f[base + nr2] - _f_prev[base + nr2])
			if cell_type[nr3] != AIR_CELL or (nr3 - offset >= 0 and cell_type[nr3 - offset] != AIR_CELL):
				d += d3
				pic_num += d3 * _f[base + nr3]
				corr_num += d3 * (_f[base + nr3] - _f_prev[base + nr3])
			if d <= 0.0:
				continue
			var inv_d := 1.0 / d
			var pic_v := pic_num * inv_d
			var corr := corr_num * inv_d
			var old_v := vel[i * 2 + component]
			vel[i * 2 + component] = (1.0 - flip_ratio) * pic_v + flip_ratio * (old_v + corr)


## 粒子 -> 覆盖率掩码（1 = 有墨水）。这一步是**渲染**，不影响物理。
##
## 半径默认取 radius/spacing（0.463 格）—— 粒子静止时按 2r 间距密排，
## 所以每个粒子刚好覆盖约一格，泼出来是一整片而不是一串点。
func _raster_ink() -> void:
	var ncells := num_x * num_y
	for i in ncells:
		ink[i] = 0
	var n := particle_count()
	var h := spacing
	var rc := splat_radius
	if rc <= 0.0:
		# 只标所在格。粒子离格心最远 0.707，所以这里**不能用半径判据** ——
		# 直接用"它在哪一格"。
		for i in n:
			var cx := clampi(int(pos[i * 2] / h), 0, num_x - 1)
			var cy := clampi(int(pos[i * 2 + 1] / h), 0, num_y - 1)
			var c := cx * num_y + cy
			if solid_mask[c] != 0:
				ink[c] = 1
		return
	var rc2 := rc * rc
	for i in n:
		var px := pos[i * 2] / h
		var py := pos[i * 2 + 1] / h
		var x0 := maxi(int(px - rc), 0)
		var x1 := mini(int(px + rc) + 1, num_x - 1)
		var y0 := maxi(int(py - rc), 0)
		var y1 := mini(int(py + rc) + 1, num_y - 1)
		for x in range(x0, x1 + 1):
			for y in range(y0, y1 + 1):
				var dx := (float(x) + 0.5) - px
				var dy := (float(y) + 0.5) - py
				# 与掩码取交：粒子贴近容器边缘时，它的泼溅半径会溢出到容器外 ——
				# 那会让液体看起来"糊出瓶壁"。
				if dx * dx + dy * dy <= rc2 and solid_mask[x * num_y + y] != 0:
					ink[x * num_y + y] = 1
	_close_ink()


## 闭运算：空的格子若**四邻里至少三个是墨**，补上。
##
## 为什么需要它：粒子按 2r 密排，局部稀疏处（表面附近、正在沉降时）会留下
## **单格空洞** —— 圆盘半径解决的是"覆盖不足"，解决不了这个。
## 继续放大半径只会让液体整体变胖，而闭运算只补凹口。
##
## ⚠️ 判据必须在**原始的那一份**上算：边写边判会按扫描顺序传播，
##    结果依赖遍历方向，C++ 与 GDScript 立刻分叉。
##
## ⚠️ 只补不删。删孤立墨点（开口运算）会把液面削薄 ——
##    表面本来就有单层粒子的地方。
##
## ⚠️ 判据是 **>= 3 / 4**，不是"全部"：平液面上方那一格只有下面一个邻居是墨，
##    不会被补 —— 用 2/4 就会让液面**整体抬高一行**。
func _close_ink() -> void:
	var ncells := num_x * num_y
	var src := ink.duplicate()
	var seen := PackedByteArray()
	seen.resize(ncells)
	var stack := PackedInt32Array()

	# 种子：**贴着容器外沿的空格**。
	# ⚠️ 不是"整张图的四边" —— 容器外的格子本来就该是空的，拿它们当种子等于把
	#    "容器内的封闭空腔"也一并判成有气，那样一格都填不上。
	for x in num_x:
		for y in num_y:
			var c := x * num_y + y
			if src[c] != 0 or seen[c] != 0:
				continue
			if not _is_edge_cell(x, y):
				continue
			seen[c] = 1
			stack.append(c)

	# 泛洪：只有**可通行的空格**能传气 —— 墨水格子不是气。
	while not stack.is_empty():
		var sp := stack.size() - 1
		var c := stack[sp]
		stack.resize(sp)
		var x := c / num_y
		var y := c % num_y
		if x > 0:
			_try_air(src, seen, stack, c - num_y)
		if x + 1 < num_x:
			_try_air(src, seen, stack, c + num_y)
		if y > 0:
			_try_air(src, seen, stack, c - 1)
		if y + 1 < num_y:
			_try_air(src, seen, stack, c + 1)

	# 没气就填
	for c in ncells:
		if src[c] == 0 and seen[c] == 0 and solid_mask[c] != 0:
			ink[c] = 1


## 该格是不是"贴着容器外沿"—— 四邻里有越界或不可通行的，就算贴边。
func _is_edge_cell(x: int, y: int) -> bool:
	if x == 0 or x + 1 == num_x or y == 0 or y + 1 == num_y:
		return true
	var c := x * num_y + y
	return solid_mask[c - num_y] == 0 or solid_mask[c + num_y] == 0 			or solid_mask[c - 1] == 0 or solid_mask[c + 1] == 0


func _try_air(src: PackedByteArray, seen: PackedByteArray,
		stack: PackedInt32Array, c: int) -> void:
	if seen[c] != 0 or src[c] != 0 or solid_mask[c] == 0:
		return
	seen[c] = 1
	stack.append(c)

#endregion


#region 原生分发

## 懒加载原生后端（PixelFluid）。返回 null = 用本文件的参照实现。
##
## ⚠️ 与 PixelRenderer._ensure_raster 同一套：
##    · GDExtension 实例化的 RefCounted 引用计数是 2，多出来的那份没人还 ——
##      Godot issue #111075，判 > 1 再 unreference；
##    · 扩展不可用时**吵闹地**退回参照实现，不静默。
##      和物理（缺扩展就没法跑）不同：流体只是表现，慢一点也必须是**对的**。
func _ensure_native() -> Object:
	if not _native_checked:
		_native_checked = true
		if ClassDB.class_exists("PixelFluid"):
			var o: Object = ClassDB.instantiate("PixelFluid")
			if o != null and o.get_reference_count() > 1:
				o.unreference()
			# 老 DLL 里可能没有这个方法 —— has_method 是判"扩展是不是太旧"的正式手段
			# （PixelRaster.decompose 就是为此留的第二个方法）。
			if o != null and o.has_method("step"):
				_native = o
		if _native == null:
			push_warning("PixelFluid 扩展不可用 —— 流体退回 GDScript 参照实现（慢很多）。" +
					"跑 python tools/build_native.py 重编 fastphys.dll。")
	return _native


## 把状态打包成命令流交给原生，再解包回来。
##
## 返回 false 表示这次调用没成（长度不对 / 原生拒绝）—— 调用方退回参照实现。
##
## 打包走 PackedFloat64Array.to_byte_array()：**原生**的整块转换，
## 不是逐元素 encode_f64（那要 2N 次调用，实测是这个函数里最大的一项）。
func _step_native(nat: Object, gx: float, gy: float) -> bool:
	var n := particle_count()
	var ncells := num_x * num_y
	var cmd := PackedByteArray()

	if _native_dirty:
		# op 1 = load：把权威状态灌进去。只在粒子集 / 掩码 / 参数变了时发。
		var head := PackedByteArray()
		head.resize(1 + 4 * 5 + 8 * 6)
		head.encode_u8(0, 1)
		head.encode_s32(1, n)
		head.encode_s32(5, num_x)
		head.encode_s32(9, num_y)
		head.encode_s32(13, push_iters)
		head.encode_s32(17, grid_iters)
		head.encode_double(21, spacing)
		head.encode_double(29, radius)
		head.encode_double(37, bouncyness)
		head.encode_double(45, over_relaxation)
		head.encode_double(53, stiffness)
		head.encode_double(61, flip_ratio)
		head.append_array(solid_mask)
		head.append_array(pos.to_byte_array())
		head.append_array(vel.to_byte_array())
		cmd.append_array(head)

	# op 2 = step：每步只发 4 个 f64，只收 ink 掩码
	var tail := PackedByteArray()
	tail.resize(1 + 8 * 4)
	tail.encode_u8(0, 2)
	tail.encode_double(1, dt)
	tail.encode_double(9, gx)
	tail.encode_double(17, gy)
	tail.encode_double(25, splat_radius)
	cmd.append_array(tail)

	var inp := PackedByteArray()
	inp.resize(8)
	inp.encode_s32(0, ncells)
	inp.encode_s32(4, cmd.size())
	inp.append_array(cmd)
	var tmpl := PackedByteArray()
	tmpl.resize(4 + ncells)
	var res: PackedByteArray = nat.step(inp, tmpl)
	if res.size() < 4 + ncells or res.decode_s32(0) != ncells:
		push_error("PixelFluid.step 返回长度不对（res=%d 期望=%d）—— 退回 GDScript 参照实现"
				% [res.size(), 4 + ncells])
		return false
	ink = res.slice(4, 4 + ncells)
	_native_dirty = false
	native_calls += 1
	return true

#endregion
