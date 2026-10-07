extends RefCounted
## 8x8 像素 chunk 的位运算工具集（Teardown 位平面在 2D 的最小形态）。
##
## 位布局：bit = x + (y << 3)，x/y 均属于 [0, 7]
## Godot 的 int 是 int64（有符号），一个 chunk 恰好 64 bit，无需数组。
##
## 注意：0x8080808080808080 这类字面量超过 int64 上限，不能直接写，
## 一律通过 ((x << 3) | 7) 逐位构造或对掩码取反得到。

const SIZE := 8
const PIXELS := 64
const ROW_BITS := 0xFF
const MASK_LOW56 := 0x00FFFFFFFFFFFFFF

static var _col_masks: PackedInt64Array = PackedInt64Array()
static var _row_masks: PackedInt64Array = PackedInt64Array()
static var _not_col0 := 0
static var _not_col7 := 0
static var _ready := false

static func ensure() -> void:
	if _ready:
		return
	_col_masks.resize(SIZE)
	_row_masks.resize(SIZE)
	for x in SIZE:
		var m := 0
		for y in SIZE:
			m |= 1 << (x + (y << 3))
		_col_masks[x] = m
	for y in SIZE:
		_row_masks[y] = ROW_BITS << (y << 3)
	_not_col0 = ~_col_masks[0]
	_not_col7 = ~_col_masks[SIZE - 1]
	_ready = true

static func col_mask(x: int) -> int:
	ensure()
	return _col_masks[x]

static func row_mask(y: int) -> int:
	ensure()
	return _row_masks[y]

static func bit(x: int, y: int) -> int:
	return 1 << (x + (y << 3))

static func inside(x: int, y: int) -> bool:
	return x >= 0 and x < SIZE and y >= 0 and y < SIZE

static func popcount(v: int) -> int:
	## SWAR popcount。中间乘法会溢出，但按位结果仍然正确；
	## 最后的算术右移需要用 & 0x7F 截断符号位。
	v = v - ((v >> 1) & 0x5555555555555555)
	v = (v & 0x3333333333333333) + ((v >> 2) & 0x3333333333333333)
	v = (v + (v >> 4)) & 0x0F0F0F0F0F0F0F0F
	return ((v * 0x0101010101010101) >> 56) & 0x7F

static func dilate4(m: int) -> int:
	## 4 邻域膨胀一步（上下左右）。跨行/跨 chunk 的溢出已处理。
	ensure()
	return m \
		| ((m & _not_col7) << 1) \
		| ((m & _not_col0) >> 1) \
		| (m << 8) \
		| ((m >> 8) & MASK_LOW56)

static func flood(seed: int, occupancy: int) -> int:
	## 在 occupancy 内从 seed 出发做 4 邻域连通泛洪，返回连通分量掩码。
	## 位运算迭代，无分支、无队列；8x8 chunk 最多 64 次迭代，实际 3~8 次收敛。
	var f := seed & occupancy
	if f == 0:
		return 0
	while true:
		var n := dilate4(f) & occupancy
		if n == f:
			break
		f = n
	return f

static func col_bits(m: int, x: int) -> int:
	## 把第 x 列的 8 个 bit 压缩成一个 byte（bit y = 该列第 y 行是否实心）。
	var out := 0
	for y in SIZE:
		if (m & (1 << (x + (y << 3)))) != 0:
			out |= 1 << y
	return out

static func row_bits(m: int, y: int) -> int:
	return (m >> (y << 3)) & ROW_BITS

static func first_bit_index(v: int) -> int:
	## 返回最低置位下标，v == 0 时返回 -1。
	## GDScript 的 int 没有 bit_length()，这里按字节再按位两段逼近。
	if v == 0:
		return -1
	var i := 0
	while (v & 0xFF) == 0:
		v = (v >> 8) & MASK_LOW56
		i += 8
	while (v & 1) == 0:
		v >>= 1
		i += 1
	return i
