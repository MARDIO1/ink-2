extends RefCounted
## 一个 8x8 像素 chunk。
##
##   occ : int64 位掩码，bit(x + 8y) == 1 表示该像素是实心的
##   mat : PackedByteArray(64)，下标 y*8+x，0 表示空（与 occ 保持一致）
##
## 材质 id 从 1 开始；occ 是权威数据，mat 是随行的材质表。

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")

var occ := 0
var mat: PackedByteArray = PackedByteArray()
## 逐体素的**辅助表**，引擎不解释它的语义。
##
## 游戏层拿它放损伤、引信计时、信号强度、温度…… 引擎只保证它跟 occ/mat
## 一起被复制、切分、保留。
##
## ⚠️ 为什么不把损伤编码进材质 id 的高位：那会污染材质表，
##    而且在切分/复制/blit 时极容易丢。独立一张表就没有这个问题。
##
## 约定：set_pixel **不动** aux（改材质时通常想保留损伤）；
##       clear_pixel 会把 aux 归零（像素没了，它的历史也没意义了）。
var aux: PackedByteArray = PackedByteArray()

## ⚠️ skip_tables：整块拷贝（split 的绝大多数 chunk）走**零拷贝共享** ——
##    PackedByteArray 是写时复制，直接赋值只是共享缓冲区，任何一方之后写入才会真的复制。
##    所以那种情况下不必先分配两张 64 字节的表再被覆盖掉（每块省 2 次分配）。
##    部分掩码的拷贝仍然需要这两张表（逐像素写入会触发 COW 复制）。
func _init(skip_tables := false) -> void:
	if skip_tables:
		return
	mat.resize(Bits.PIXELS)
	aux.resize(Bits.PIXELS)

func clone():
	# 不能在本脚本内用自身类名做类型（没有 class_name），用脚本反射构造。
	var c = get_script().new()
	c.occ = occ
	c.mat = mat.duplicate()
	c.aux = aux.duplicate()
	return c

func is_empty() -> bool:
	return occ == 0

func count() -> int:
	return Bits.popcount(occ)

func get_material(x: int, y: int) -> int:
	if (occ & Bits.bit(x, y)) == 0:
		return 0
	return mat[y * Bits.SIZE + x]

func set_pixel(x: int, y: int, material: int) -> void:
	var b := Bits.bit(x, y)
	occ |= b
	mat[y * Bits.SIZE + x] = material

func clear_pixel(x: int, y: int) -> void:
	occ &= ~Bits.bit(x, y)
	mat[y * Bits.SIZE + x] = 0
	aux[y * Bits.SIZE + x] = 0

func apply_keep_mask(keep: int) -> void:
	## keep 掩码语义与 Teardown 的 remove mask 一致：bit 1 = 保留，0 = 删除。
	## 破坏管线里这就是一次位与 + 一次材质清理。
	var removed := occ & ~keep
	if removed == 0:
		return
	occ &= keep
	while removed != 0:
		var i := Bits.first_bit_index(removed)
		mat[i] = 0
		aux[i] = 0
		removed &= removed - 1

func blit_into(target, mask: int) -> void:
	## 把 mask 内的像素复制到 target（split 阶段用）。
	var m := occ & mask
	if m == 0:
		return
	# ⚠️⚠️ **整块拷贝的快路径**：split 时绝大多数 chunk 是"整块属于同一个分量"
	#    （mask == -1），逐像素拷要跑 64 次迭代（实测 **~26 us/块**），
	#    768x100 的 1238 块就是 **30+ ms** —— 而整块拷贝只要 3 次赋值
	#    （mat/aux 是 PackedByteArray，duplicate 是原生 memcpy）。
	#    实测把 split 的组装段从 ~37 ms 降到 ~2 ms。
	#
	#    两个前提都必要：mask 必须覆盖整块（否则会拷进不该拷的像素），
	#    且 target 必须是空的（否则整体赋值会覆盖它已有的内容）。
	#    不满足就退回逐像素 —— 宁可慢，不能错。
	if mask == -1 and target.occ == 0:
		target.occ = occ
		target.mat = mat.duplicate()
		target.aux = aux.duplicate()
		return
	while m != 0:
		var i := Bits.first_bit_index(m)
		target.occ |= 1 << i
		target.mat[i] = mat[i]
		target.aux[i] = aux[i]
		m &= m - 1
