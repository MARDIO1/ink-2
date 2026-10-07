extends RefCounted
## 破坏内核的 GPU 后端（RenderingDevice 计算着色器）。
##
## 一次 dispatch 完成：破坏掩码应用 -> chunk 内 4 邻域连通分量 -> 输出分量掩码。
## 一个 invocation 处理一个 chunk，chunk 之间零依赖；chunk 内部复用 CPU 那套
## uint64 位运算泛洪，所以结果与 CPU **逐位一致**（test_gpu.gd 会逐 chunk 比对）。
##
## 【实测结论：默认关闭】
##   内核本身是对的、且与 CPU 逐位一致，但在当前架构下**跑不过 CPU**：
##   576 chunks 的一次破坏，GPU 侧只花 0.75 ms（提交 0.51 + 回读 0.23），
##   而整个函数耗时 15.5 ms —— 剩下 14.7 ms 全在 GDScript 的字典/数组记账上
##   （occ_pairs 组装、材质同步、comp_masks/node_of 的 Dictionary 写入、
##   接缝 union-find）。GPU 加不到这些地方去。
##   所以真正的出路是把整条管线搬进 GDExtension，而不是只把泛洪搬上 GPU。
##   想自己验证就把 ENABLED 打开，用 tests/test_gpu.gd 跑对比。
##
## 限制：
##   - 需要 Forward+ / Vulkan（gl_compatibility 没有 RenderingDevice）。
##   - headless（dummy 驱动）下拿不到设备，自动退回 CPU。
##   - 一个 chunk 内分量数 > 16 时该 chunk 由 CPU 兜底（棋盘格这类病态输入）。

## 打开后 destruct.gd 才会走 GPU 路径；默认 false（原因见上）。
const ENABLED := false
const SHADER_PATH := "res://addons/pixel_destruction/gpu/destruction.glsl"
const MAX_COMP := 16
const OVERFLOW_FLAG := 0x80000000
## 低于这个 chunk 数，dispatch + 回读的固定开销盖过收益。
## 实测：64 chunks 时 GPU 更慢，256 chunks 起步有数倍收益。
const MIN_CHUNKS_FOR_GPU := 128

var available := false
var last_error := ""
var last_dispatch_chunks := 0
var last_gpu_usec := 0
var last_submit_usec := 0
var last_readback_usec := 0
var last_unpack_usec := 0

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _buf_in_occ: RID
var _buf_in_anchor: RID
var _buf_in_damage: RID
var _buf_out: RID
var _uniform_set: RID
var _cap_occ := 0
var _cap_anchor := 0
var _cap_damage := 0


func setup() -> bool:
	if available:
		return true
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		last_error = "no RenderingDevice (headless / gl_compatibility?)"
		return false
	var sf = load(SHADER_PATH)
	if sf == null:
		last_error = "shader not imported: " + SHADER_PATH
		return false
	var spirv: RDShaderSPIRV = sf.get_spirv()
	if spirv == null:
		last_error = "no spirv"
		return false
	if spirv.compile_error_compute != "":
		last_error = spirv.compile_error_compute
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		last_error = "shader_create failed"
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	available = true
	return true


func shutdown() -> void:
	if _rd == null:
		return
	for rid in [_buf_in_occ, _buf_in_anchor, _buf_in_damage, _buf_out, _uniform_set]:
		if rid.is_valid():
			_rd.free_rid(rid)
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_rd.free()
	_rd = null
	available = false


static func should_use_gpu(chunk_count: int) -> bool:
	if not ENABLED:
		return false
	return chunk_count >= MIN_CHUNKS_FOR_GPU


func _ensure_buffers(chunk_count: int, damage_count: int) -> void:
	if chunk_count > _cap_occ:
		if _buf_in_occ.is_valid():
			_rd.free_rid(_buf_in_occ)
		if _buf_out.is_valid():
			_rd.free_rid(_buf_out)
		_cap_occ = chunk_count
		_buf_in_occ = _rd.storage_buffer_create(_cap_occ * 8, PackedByteArray())
		_buf_out = _rd.storage_buffer_create(_cap_occ * 35 * 4, PackedByteArray())
		_uniform_set = RID()
	if chunk_count > _cap_anchor:
		if _buf_in_anchor.is_valid():
			_rd.free_rid(_buf_in_anchor)
		_cap_anchor = chunk_count
		_buf_in_anchor = _rd.storage_buffer_create(_cap_anchor * 8, PackedByteArray())
		_uniform_set = RID()
	if damage_count > _cap_damage:
		if _buf_in_damage.is_valid():
			_rd.free_rid(_buf_in_damage)
		_cap_damage = maxi(damage_count, 4)
		_buf_in_damage = _rd.storage_buffer_create(_cap_damage * 32, PackedByteArray())
		_uniform_set = RID()


func _ensure_uniform_set() -> void:
	if _uniform_set.is_valid():
		return
	var uniforms: Array = []
	var specs := [
		[_buf_in_occ, 0], [_buf_in_anchor, 1], [_buf_in_damage, 2], [_buf_out, 3],
	]
	for spec: Array in specs:
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = spec[1]
		u.add_id(spec[0])
		uniforms.append(u)
	_uniform_set = _rd.uniform_set_create(uniforms, _shader, 0)


## occ_pairs   : 每个 chunk 2 个 int32（u64 占用掩码的 lo/hi）
## anchors     : 每个 chunk 2 个 int32（该 chunk 在 Shape 局部像素空间的左上角）
## damage_data : 每个破坏源 8 个 float32（vec4 type/radius/a.xy + vec4 b.xy/half.xy）
## 返回 { ok: bool, occ: PackedInt32Array(2n), counts: PackedInt32Array(n), comp: PackedInt32Array(2n*MAX_COMP) }
func process(occ_pairs: PackedInt32Array, anchors: PackedInt32Array, damage_data: PackedFloat32Array) -> Dictionary:
	var out := {"ok": false, "occ": PackedInt32Array(), "counts": PackedInt32Array(), "comp": PackedInt32Array()}
	if not available:
		return out
	var chunk_count := occ_pairs.size() / 2
	if chunk_count <= 0:
		return out
	var damage_count := damage_data.size() / 8
	_ensure_buffers(chunk_count, damage_count)
	_ensure_uniform_set()

	_rd.buffer_update(_buf_in_occ, 0, chunk_count * 8, occ_pairs.to_byte_array())
	_rd.buffer_update(_buf_in_anchor, 0, chunk_count * 8, anchors.to_byte_array())
	if damage_count > 0:
		_rd.buffer_update(_buf_in_damage, 0, damage_count * 32, damage_data.to_byte_array())

	var pc := PackedByteArray()
	pc.resize(8)
	pc.encode_u32(0, chunk_count)
	pc.encode_u32(4, damage_count)

	var t0 := Time.get_ticks_usec()
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, _uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, pc, pc.size())
	_rd.compute_list_dispatch(cl, (chunk_count + 63) / 64, 1, 1)   # 一个 invocation 一个 chunk
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	# 一次性回读全部结果，再在 CPU 侧拆包
	last_submit_usec = Time.get_ticks_usec() - t0
	var total_ints := chunk_count * 35
	var raw := _rd.buffer_get_data(_buf_out, 0, total_ints * 4).to_int32_array()
	last_readback_usec = Time.get_ticks_usec() - t0 - last_submit_usec

	var u0 := Time.get_ticks_usec()
	var occ := raw.slice(0, chunk_count * 2)
	var counts := raw.slice(chunk_count * 2, chunk_count * 3)
	var comp := raw.slice(chunk_count * 3, total_ints)
	last_unpack_usec = Time.get_ticks_usec() - u0
	last_gpu_usec = Time.get_ticks_usec() - t0
	last_dispatch_chunks = chunk_count

	return {"ok": true, "occ": occ, "counts": counts, "comp": comp}
