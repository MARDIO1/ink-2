// FastPhys —— GDExtension 入口。
//
// 两个类，各自一条命令流（编号互不干扰）：
//   · @@RapierPhys@@  —— 物理全部交给 Rapier（rapier_bridge.dll），op 0..42。
//   · @@PixelRaster@@ —— 形状 -> RGBA8 图的栅格化，**纯 CPU、不依赖 Rapier**。
//     为什么单独一个类：渲染不该被"Rapier 桥接没加载"拖下水；两套命令流混在
//     一起还会让"下一个空 op 号是多少"变成两个模块的共享状态。
//
// ⚠️ 手写的那套内核（collide_kernel.h / bp_kernel.h / solver_kernel.h）已经删除。
//    它们曾经把宽相 / 窄相 / 求解逐位移植到 C++，是"GDScript 与 C++ 逐字节等价"
//    那个验证机制的产物 —— 一旦物理换成 Rapier，这套东西就没有存在理由了。
//
// 关于数据传递（纯 C API 下的坑，RapierPhys 仍然受用）：
//   往"传进来的" PackedByteArray 里写是**不安全**的 —— ptrcall 的实参指向调用现场的
//   Variant 副本，_copy_on_write 会把写入落到副本上，调用方看不到。
//   所以输出走**返回值**：先用拷贝构造函数按模板复制出一个等长数组，再写它。

#include "gdextension_interface.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
// windows.h 只用来做运行时动态加载；宏要收窄，否则 min/max 会污染其它头
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

static GDExtensionInterfaceGetProcAddress g_get_proc_address = nullptr;
static GDExtensionClassLibraryPtr g_library = nullptr;

static GDExtensionInterfaceClassdbRegisterExtensionClass6 g_register_class6 = nullptr;
static GDExtensionInterfaceClassdbRegisterExtensionClassMethod g_register_method = nullptr;
static GDExtensionInterfaceClassdbConstructObject g_construct_object = nullptr;
static GDExtensionInterfaceObjectSetInstance g_object_set_instance = nullptr;
static GDExtensionInterfaceStringNameNewWithUtf8Chars g_sn_new = nullptr;
static GDExtensionInterfaceStringNewWithUtf8Chars g_str_new = nullptr;
static GDExtensionInterfaceVariantGetPtrConstructor g_get_ctor = nullptr;
static GDExtensionInterfacePackedByteArrayOperatorIndex g_pba_index = nullptr;
static GDExtensionInterfacePackedByteArrayOperatorIndexConst g_pba_index_const = nullptr;
static GDExtensionPtrConstructor g_pba_copy_ctor = nullptr;
static GDExtensionPtrConstructor g_pba_default_ctor = nullptr;
static GDExtensionInterfaceVariantGetPtrBuiltinMethod g_get_builtin = nullptr;
static GDExtensionPtrBuiltInMethod g_pba_resize = nullptr;

// ---- Variant <-> 内置类型 的官方转换接口 ----
// 这是纯 C API 里最关键的一组：没有它就得自己去猜 Variant 的内存布局。
//   to_type  : 把 Variant 拆成内置类型值（读实参）
//   from_type: 把内置类型值装进 Variant（写返回值）
// 两者都是**拷贝语义**，所以源/目标用完都要各自析构。
static GDExtensionInterfaceGetVariantToTypeConstructor g_get_to_type = nullptr;
static GDExtensionInterfaceGetVariantFromTypeConstructor g_get_from_type = nullptr;
static GDExtensionInterfaceVariantGetPtrDestructor g_get_destructor = nullptr;
static GDExtensionTypeFromVariantConstructorFunc g_pba_from_variant = nullptr;
static GDExtensionVariantFromTypeConstructorFunc g_pba_to_variant = nullptr;
static GDExtensionPtrDestructor g_pba_destructor = nullptr;
static GDExtensionTypeFromVariantConstructorFunc g_int_from_variant = nullptr;
static GDExtensionPtrDestructor g_int_destructor = nullptr;

// 内置类型值的暂存空间（PackedByteArray 实际只有 8 字节，给足余量）
struct TypeStorage { alignas(16) unsigned char buf[64]; };

struct SN { alignas(16) unsigned char buf[64]; };
static SN g_sn_class, g_sn_parent, g_sn_method;
static SN g_sn_ret, g_sn_a0, g_sn_a1, g_sn_a2, g_sn_a3;
static SN g_sn_bp;          // 方法名 broadphase
static SN g_sn_sv, g_sn_sv0, g_sn_sv1, g_sn_sv2, g_sn_svret, g_sn_cw;
static SN g_sn_bp0, g_sn_bp1, g_sn_bp2, g_sn_bp3;
static SN g_sn_bpret;
static SN g_sn_resize;      // PackedByteArray.resize 的 StringName
// PackedByteArray.resize 的 hash —— 从 extension_api.json 里取，不能瞎猜
static const int64_t PBA_RESIZE_HASH = 848867239;
// ⚠️ PropertyInfo 里的 class_name / hint_string **不能给 nullptr** ——
// Godot 会根据它们构造 PropertyInfo，空指针会直接段错误。
// 之前那次 signal 11 就是这里：注册方法时没有任何输出就崩了。
static SN g_sn_empty_class;
alignas(16) static unsigned char g_str_empty_hint[64];


// ================= RapierPhys：把物理交给 Rapier =================
//
// 只做**薄包装**，两个理由：
//   · 桥接层 rapier_bridge.dll 是 MSVC Rust 编的，本 DLL 是 MinGW g++ 编的 ——
//     链接期混用导入库容易出问题，所以用 LoadLibrary **运行时**取函数指针。
//   · GDScript 侧只有**一个**方法 cmd(in, out)：in 是命令流，out 是结果流。
//     手写 GDExtension 的注册样板很重，注册面越小越好；而且这层胶水迟早会被
//     真正的 PWorld 集成取代（那时命令流会变成批量位姿/矩形同步）。
//
// 命令流（小端；全部 memcpy 读写，不要求对齐）：
//   in  = [i32 out_cap][命令...]
//   out = [i32 written][结果...]        written 是结果段的字节数
//
//   0  reset()                                    -> i32 ok(0 成功)
//   1  set_gravity(f64 x, f64 y)
//   2  step(f64 dt)
//   3  body_new(i32 is_static, f64 x, y, rot)     -> i32 id
//   4  body_remove(u32 id)
//   5  body_set_rects(u32 id, i32 count, f32[count*4], f64 friction)
//   6  body_set_pose(u32 id, f64 x, y, rot)
//   7  body_set_vel(u32 id, f64 vx, vy, w)
//   8  body_get_state(u32 id)                     -> f64 x, y, rot, vx, vy, w
//   9  body_is_sleeping(u32 id)                   -> i32
//  10  body_wake(u32 id)
//  11  contact_count()                            -> i32
//  ⚠️ op 12（contact_get）**已删除**：它只给"一个代表点 + 整对总冲量"，
//     宽面撞击会被压成一次尖刺；而且实测静默返回全 0。替代品是 op 35。
//  35  contact_get_points(u32 idx, i32 cap)       -> i32 n_points，然后（cap 够时）
//                                                    f64 id_a, id_b, n_points, total_impulse,
//                                                    每个点 nx, ny, px, py, dist, impulse,
//                                                    tangent_impulse, fid1, fid2
//                                                    （impulse 是**法向**分量；tangent_impulse 是
//                                                      **切向（摩擦）**分量，世界向量 = perp(n) * 它；
//                                                      fid1/fid2 = 接触特征 id，跨帧稳定）
//                                                    ⚠️ 一次物理更新里整个面可以同时有多个接触点
//                                                    （60 Hz 是更新时间，不是接触数量限制）
//  13  body_count()                               -> i32
//  14  body_add_force(u32 id, f64 fx, fy, torque)
//  15  body_set_type(u32 id, i32 is_static)
//  16  body_set_damping(u32 id, f64 linear, f64 angular)
//  17  body_set_gravity_scale(u32 id, f64 scale)
//  18  body_reset_forces(u32 id)
//  19  body_set_ccd(u32 id, i32 enabled, f64 soft_ccd_prediction)
//  20  world_set_length_unit(f64 unit)
//  21  world_set_max_linear_velocity(f64 normalized)
//  22  world_set_pixel_params(f64 pred_dist, f64 corr_vel, f64 allowed_err)
//  23  world_set_ccd_substeps(u32 n)
//
// ---- 关节（见 rapier_bridge/src/lib.rs 的"关节"一节）----
//  24  joint_new(i32 kind, u32 id_a, u32 id_b, f64 a1x,a1y,a2x,a2y,
//                f64 axis_x,axis_y, f64 p1,p2,p3)     -> i32 joint_id
//  25  joint_remove(u32 jid)
//  26  joint_set_limits(u32 jid, f64 min, f64 max)     （min > max = 不限制）
//  27  joint_motor_velocity(u32 jid, f64 target_vel, f64 damping, f64 max_force)
//  28  joint_motor_position(u32 jid, f64 target, f64 stiffness, f64 damping, f64 max_force)
//  29  joint_motor_off(u32 jid)
//  30  joint_impulse(u32 jid)                          -> f64 线性模长, 角冲量
//  31  joint_count()                                   -> i32
//
// ---- 碰撞层 / 掩码 ----
//  32  body_set_groups(u32 id, u32 layer, u32 mask)     （Rapier InteractionGroups）
//  33  joint_set_contacts(u32 jid, i32 enabled)         0 = 两个被关节连着的刚体之间不生成接触
//  34  body_set_density(u32 id, f64 density)             材质密度 -> Rapier 质量（不推就是两边质量分叉）
//  38  body_set_friction(u32 id, f64 friction)           材质摩擦系数 -> Rapier 碰撞体
//  39  body_set_restitution(u32 id, f64 restitution)     材质恢复系数 -> Rapier 碰撞体
//  40  joint_set_softness(u32 jid, f64 freq, f64 damping)  关节求解软度（Hz + 阻尼比）
//  41  world_set_joint_solver(i32 iters, i32 warmstart, f64 coeff)  世界级关节求解参数
//  42  body_set_solver_iterations(u32 id, u32 n)       局部约束岛追加迭代
//  （35~37 曾用于"鼠标关节"抓取，已删除 —— 见 rapier_bridge/src/lib.rs 的墓碑注释）

typedef void *RPWorld;

struct RapierApi {
	HMODULE dll = nullptr;
	RPWorld (*world_new)() = nullptr;
	void (*world_free)(RPWorld) = nullptr;
	void (*world_set_gravity)(RPWorld, double, double) = nullptr;
	void (*world_step)(RPWorld, double) = nullptr;
	uint32_t (*body_new)(RPWorld, int32_t, double, double, double) = nullptr;
	void (*body_remove)(RPWorld, uint32_t) = nullptr;
	void (*body_set_rects)(RPWorld, uint32_t, const float *, int32_t, double) = nullptr;
	void (*body_set_pose)(RPWorld, uint32_t, double, double, double) = nullptr;
	void (*body_set_vel)(RPWorld, uint32_t, double, double, double) = nullptr;
	int32_t (*body_get_state)(RPWorld, uint32_t, double *) = nullptr;
	int32_t (*body_is_sleeping)(RPWorld, uint32_t) = nullptr;
	void (*body_wake)(RPWorld, uint32_t) = nullptr;
	int32_t (*contact_count)(RPWorld) = nullptr;
	// ⚠️ contact_get / op 12 已删除（静默返回全 0，替代品是 op 35）
	// ⚠️ 与 contact_get 的区别：导出**全部**接触点及**各自的**冲量（见 op 35 的说明）
	int32_t (*contact_get_points)(RPWorld, int32_t, double *, int32_t) = nullptr;
	int32_t (*body_count)(RPWorld) = nullptr;
	void (*body_add_force)(RPWorld, uint32_t, double, double, double) = nullptr;
	void (*body_set_type)(RPWorld, uint32_t, int32_t) = nullptr;
	void (*body_set_damping)(RPWorld, uint32_t, double, double) = nullptr;
	void (*body_set_gravity_scale)(RPWorld, uint32_t, double) = nullptr;
	void (*body_reset_forces)(RPWorld, uint32_t) = nullptr;
	void (*body_set_ccd)(RPWorld, uint32_t, int32_t, double) = nullptr;
	void (*world_set_ccd_substeps)(RPWorld, uint32_t) = nullptr;
	void (*world_set_length_unit)(RPWorld, double) = nullptr;
	void (*world_set_max_linear_velocity)(RPWorld, double) = nullptr;
	void (*world_set_pixel_params)(RPWorld, double, double, double) = nullptr;
	// 关节：签名与 rapier_bridge/src/lib.rs 里的 rb_joint_* 一一对应
	uint32_t (*joint_new)(RPWorld, int32_t, uint32_t, uint32_t, double, double, double, double,
		double, double, double, double, double) = nullptr;
	void (*joint_remove)(RPWorld, uint32_t) = nullptr;
	void (*joint_set_limits)(RPWorld, uint32_t, double, double) = nullptr;
	void (*joint_motor_velocity)(RPWorld, uint32_t, double, double, double) = nullptr;
	void (*joint_motor_position)(RPWorld, uint32_t, double, double, double, double) = nullptr;
	void (*joint_motor_off)(RPWorld, uint32_t) = nullptr;
	int32_t (*joint_impulse)(RPWorld, uint32_t, double *) = nullptr;
	int32_t (*joint_count)(RPWorld) = nullptr;
	void (*body_set_groups)(RPWorld, uint32_t, uint32_t, uint32_t) = nullptr;
	void (*joint_set_contacts)(RPWorld, uint32_t, int32_t) = nullptr;
	void (*body_set_density)(RPWorld, uint32_t, double) = nullptr;
	void (*body_set_solver_iterations)(RPWorld, uint32_t, uint32_t) = nullptr;
void (*body_set_friction)(RPWorld, uint32_t, double) = nullptr;
void (*body_set_restitution)(RPWorld, uint32_t, double) = nullptr;
	int32_t (*joint_set_softness)(RPWorld, uint32_t, double, double) = nullptr;
	void (*world_set_joint_solver)(RPWorld, int32_t, int32_t, double) = nullptr;

	bool tried = false;
	bool ok = false;
};

static RapierApi g_rap;
static SN g_sn_rp_class, g_sn_rp_cmd, g_sn_rp_a0, g_sn_rp_a1, g_sn_rp_ret;

// 只用来取"本 DLL 自己的模块句柄"——静态函数的地址一定落在本模块里
static void rapier_anchor() {}

static bool load_rapier() {
	if (g_rap.tried) return g_rap.ok;
	g_rap.tried = true;
	// 先找本 DLL 所在目录，再退回默认搜索路径（exe 目录 / cwd / PATH）
	char self[MAX_PATH] = { 0 };
	HMODULE mod = nullptr;
	if (::GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
			(LPCSTR)&rapier_anchor, &mod) && mod != nullptr) {
		::GetModuleFileNameA(mod, self, MAX_PATH);
	}
	std::string dir;
	for (int i = (int)std::strlen(self) - 1; i >= 0; --i) {
		if (self[i] == '\\' || self[i] == '/') { dir.assign(self, (size_t)i + 1); break; }
	}
	std::string local = dir + "rapier_bridge.dll";
	g_rap.dll = ::LoadLibraryA(local.c_str());
	if (g_rap.dll == nullptr) g_rap.dll = ::LoadLibraryA("rapier_bridge.dll");
	if (g_rap.dll == nullptr) {
		printf("[RapierPhys] 加载 rapier_bridge.dll 失败（GetLastError=%lu）\n", (unsigned long)::GetLastError());
		return false;
	}
#define RP_GET(field, name) \
	g_rap.field = (decltype(g_rap.field))::GetProcAddress(g_rap.dll, name); \
	if (g_rap.field == nullptr) { printf("[RapierPhys] 缺少符号 %s\n", name); return false; }
	RP_GET(world_new, "rb_world_new")
	RP_GET(world_free, "rb_world_free")
	RP_GET(world_set_gravity, "rb_world_set_gravity")
	RP_GET(world_step, "rb_world_step")
	RP_GET(body_new, "rb_body_new")
	RP_GET(body_remove, "rb_body_remove")
	RP_GET(body_set_rects, "rb_body_set_rects")
	RP_GET(body_set_pose, "rb_body_set_pose")
	RP_GET(body_set_vel, "rb_body_set_vel")
	RP_GET(body_get_state, "rb_body_get_state")
	RP_GET(body_is_sleeping, "rb_body_is_sleeping")
	RP_GET(body_wake, "rb_body_wake")
	RP_GET(contact_count, "rb_contact_count")
	// ⚠️ RP_GET(contact_get, "rb_contact_get") 已删除 —— 符号在 Rust 侧也删了，留着会加载失败
	RP_GET(body_count, "rb_body_count")
	RP_GET(body_add_force, "rb_body_add_force")
	RP_GET(body_set_type, "rb_body_set_type")
	RP_GET(body_set_damping, "rb_body_set_damping")
	RP_GET(body_set_gravity_scale, "rb_body_set_gravity_scale")
	RP_GET(body_reset_forces, "rb_body_reset_forces")
	RP_GET(body_set_ccd, "rb_body_set_ccd")
	RP_GET(world_set_ccd_substeps, "rb_world_set_ccd_substeps")
	RP_GET(world_set_length_unit, "rb_world_set_length_unit")
	RP_GET(world_set_max_linear_velocity, "rb_world_set_max_linear_velocity")
	RP_GET(world_set_pixel_params, "rb_world_set_pixel_params")
	RP_GET(joint_new, "rb_joint_new")
	RP_GET(joint_remove, "rb_joint_remove")
	RP_GET(joint_set_limits, "rb_joint_set_limits")
	RP_GET(joint_motor_velocity, "rb_joint_motor_velocity")
	RP_GET(joint_motor_position, "rb_joint_motor_position")
	RP_GET(joint_motor_off, "rb_joint_motor_off")
	RP_GET(joint_impulse, "rb_joint_impulse")
	RP_GET(joint_count, "rb_joint_count")
	RP_GET(body_set_groups, "rb_body_set_groups")
	RP_GET(joint_set_contacts, "rb_joint_set_contacts")
	RP_GET(contact_get_points, "rb_contact_get_points")
	RP_GET(body_set_density, "rb_body_set_density")
	RP_GET(body_set_solver_iterations, "rb_body_set_solver_iterations")
RP_GET(body_set_friction, "rb_body_set_friction")
RP_GET(body_set_restitution, "rb_body_set_restitution")
	RP_GET(joint_set_softness, "rb_joint_set_softness")
	RP_GET(world_set_joint_solver, "rb_world_set_joint_solver")

#undef RP_GET
	g_rap.ok = true;
	printf("[RapierPhys] rapier_bridge.dll 已加载: %s\n", local.c_str());
	return true;
}

struct RapierInstance {
	RPWorld world = nullptr;
	RapierInstance() { if (load_rapier()) world = g_rap.world_new(); }
	~RapierInstance() { if (world != nullptr && g_rap.world_free != nullptr) g_rap.world_free(world); }
};

// ---- 命令流的读写（不要求对齐，全部 memcpy）----
struct CmdRd {
	const uint8_t *p = nullptr;
	size_t n = 0;
	size_t i = 0;
	bool ok = true;
	uint8_t u8() { if (i + 1 > n) { ok = false; return 0; } return p[i++]; }
	int32_t i32() { int32_t v = 0; if (i + 4 > n) { ok = false; return 0; } std::memcpy(&v, p + i, 4); i += 4; return v; }
	uint32_t u32() { return (uint32_t)i32(); }
	double f64() { double v = 0; if (i + 8 > n) { ok = false; return 0; } std::memcpy(&v, p + i, 8); i += 8; return v; }
	int64_t i64() { int64_t v = 0; if (i + 8 > n) { ok = false; return 0; } std::memcpy(&v, p + i, 8); i += 8; return v; }
	// 定长裸字节段。失败返回 nullptr 且 ok = false —— 调用方**必须**查 ok 再解引用。
	const uint8_t *bytes(size_t count) {
		if (i + count > n) { ok = false; return nullptr; }
		const uint8_t *q = p + i;
		i += count;
		return q;
	}
	bool f32s(size_t count, std::vector<float> &dst) {
		dst.resize(count);
		if (i + count * 4 > n) { ok = false; return false; }
		if (count > 0) std::memcpy(dst.data(), p + i, count * 4);
		i += count * 4;
		return true;
	}
};

struct CmdWr {
	uint8_t *p = nullptr;
	size_t cap = 0;
	size_t i = 0;
	void i32(int32_t v) { if (i + 4 <= cap) std::memcpy(p + i, &v, 4); i += 4; }
	void f64(double v) { if (i + 8 <= cap) std::memcpy(p + i, &v, 8); i += 8; }
};

static void run_rapier_cmd(RapierInstance *inst, const uint8_t *in, size_t in_n,
		uint8_t *out, size_t out_cap, size_t &written) {
	CmdWr w; w.p = out; w.cap = out_cap; w.i = 0;
	if (inst == nullptr || inst->world == nullptr) { w.i32(-1); written = w.i; return; }
	RPWorld W = inst->world;
	CmdRd r; r.p = in; r.n = in_n; r.i = 0;
	static std::vector<float> rect_scratch;
	double buf[8];
	while (r.ok && r.i < r.n) {
		uint8_t op = r.u8();
		if (!r.ok) break;
		switch (op) {
			case 0: {
				g_rap.world_free(W);
				inst->world = g_rap.world_new();
				W = inst->world;
				w.i32(W != nullptr ? 0 : -1);
				break;
			}
			case 1: { double x = r.f64(), y = r.f64(); g_rap.world_set_gravity(W, x, y); break; }
			case 2: { double dt = r.f64(); g_rap.world_step(W, dt); break; }
			case 3: {
				int32_t st = r.i32(); double x = r.f64(), y = r.f64(), rot = r.f64();
				w.i32((int32_t)g_rap.body_new(W, st, x, y, rot));
				break;
			}
			case 4: { uint32_t id = r.u32(); g_rap.body_remove(W, id); break; }
			case 5: {
				uint32_t id = r.u32(); int32_t cnt = r.i32();
				if (cnt < 0) cnt = 0;
				bool got = r.f32s((size_t)cnt * 4, rect_scratch);
				double fr = r.f64();
				if (got) g_rap.body_set_rects(W, id, rect_scratch.data(), cnt, fr);
				break;
			}
			case 6: { uint32_t id = r.u32(); double x = r.f64(), y = r.f64(), rot = r.f64();
				g_rap.body_set_pose(W, id, x, y, rot); break; }
			case 7: { uint32_t id = r.u32(); double vx = r.f64(), vy = r.f64(), av = r.f64();
				g_rap.body_set_vel(W, id, vx, vy, av); break; }
			case 8: {
				uint32_t id = r.u32();
				for (int k = 0; k < 6; ++k) buf[k] = 0.0;
				int32_t rc = g_rap.body_get_state(W, id, buf);
				if (rc == 0) for (int k = 0; k < 6; ++k) buf[k] = 0.0;
				for (int k = 0; k < 6; ++k) w.f64(buf[k]);
				break;
			}
			case 9: { uint32_t id = r.u32(); w.i32(g_rap.body_is_sleeping(W, id)); break; }
			case 10: { uint32_t id = r.u32(); g_rap.body_wake(W, id); break; }
			case 11: { w.i32(g_rap.contact_count(W)); break; }
			// ⚠️⚠️ **op 12 已删除**（连同 rb_contact_get / contact_get 指针 / RP_GET 绑定）。
			//    原因：它只取"第一个流形的第一个点"作位置，却给整对的**总冲量**
			//    —— 整个面的冲量被附在一个代表点上，宽面撞击照着它打洞就是一次尖刺。
			//    而且它在我的探针里静默返回全 0（tests/diag_contact_points4.gd 记录），
			//    留着只会让下一个人以为它可用。替代品是 op 35。
			case 13: { w.i32(g_rap.body_count(W)); break; }
			case 14: { uint32_t id = r.u32(); double fx = r.f64(), fy = r.f64(), tq = r.f64();
				g_rap.body_add_force(W, id, fx, fy, tq); break; }
			case 15: { uint32_t id = r.u32(); int32_t st = r.i32();
				g_rap.body_set_type(W, id, st); break; }
			case 16: { uint32_t id = r.u32(); double lin = r.f64(), ang = r.f64();
				g_rap.body_set_damping(W, id, lin, ang); break; }
			case 17: { uint32_t id = r.u32(); double sc = r.f64();
				g_rap.body_set_gravity_scale(W, id, sc); break; }
			case 18: { uint32_t id = r.u32(); g_rap.body_reset_forces(W, id); break; }
			case 19: { uint32_t id = r.u32(); int32_t en = r.i32(); double sp = r.f64();
				g_rap.body_set_ccd(W, id, en, sp); break; }
			case 20: { double u = r.f64(); g_rap.world_set_length_unit(W, u); break; }
			case 21: { double v = r.f64(); g_rap.world_set_max_linear_velocity(W, v); break; }
			case 22: { double pd = r.f64(), cv = r.f64(), ae = r.f64();
				g_rap.world_set_pixel_params(W, pd, cv, ae); break; }
			case 23: { uint32_t n = r.u32(); g_rap.world_set_ccd_substeps(W, n); break; }
			case 42: { uint32_t id = r.u32(); uint32_t n = r.u32(); g_rap.body_set_solver_iterations(W, id, n); break; }
			case 24: {
				int32_t kind = r.i32();
				uint32_t ia = r.u32(), ib = r.u32();
				double a1x = r.f64(), a1y = r.f64(), a2x = r.f64(), a2y = r.f64();
				double ax = r.f64(), ay = r.f64();
				double p1 = r.f64(), p2 = r.f64(), p3 = r.f64();
				w.i32((int32_t)g_rap.joint_new(W, kind, ia, ib, a1x, a1y, a2x, a2y, ax, ay, p1, p2, p3));
				break;
			}
			case 25: { uint32_t jid = r.u32(); g_rap.joint_remove(W, jid); break; }
			case 26: { uint32_t jid = r.u32(); double lo = r.f64(), hi = r.f64();
				g_rap.joint_set_limits(W, jid, lo, hi); break; }
			case 27: { uint32_t jid = r.u32(); double tv = r.f64(), dp = r.f64(), mf = r.f64();
				g_rap.joint_motor_velocity(W, jid, tv, dp, mf); break; }
			case 28: { uint32_t jid = r.u32(); double tg = r.f64(), st = r.f64(), dp = r.f64(), mf = r.f64();
				g_rap.joint_motor_position(W, jid, tg, st, dp, mf); break; }
			case 29: { uint32_t jid = r.u32(); g_rap.joint_motor_off(W, jid); break; }
			case 30: {
				uint32_t jid = r.u32();
				buf[0] = 0.0; buf[1] = 0.0;
				g_rap.joint_impulse(W, jid, buf);
				w.f64(buf[0]);
				w.f64(buf[1]);
				break;
			}
			case 31: { w.i32(g_rap.joint_count(W)); break; }
			case 32: {
				uint32_t id = r.u32();
				uint32_t layer = r.u32();
				uint32_t mask = r.u32();
				g_rap.body_set_groups(W, id, layer, mask);
				break;
			}
			case 33: {
				uint32_t jid = r.u32();
				int32_t en = r.i32();
				g_rap.joint_set_contacts(W, jid, en);
				break;
			}
			case 34: {
				uint32_t id = r.u32();
				double dens = r.f64();
				g_rap.body_set_density(W, id, dens);
				break;
			}
			case 35: {
				// 导出第 idx 个接触对的**全部**接触点及各自的冲量。
				// ⚠️ 两步式：点数事先不知道，cap 不够时只回点数（i32），调用方扩容后重来。
				//    输出 = i32 n_points，然后（cap 够时）f64 id_a, id_b, n_points, total_impulse,
				//    以及每个点 nx, ny, px, py, dist, impulse。
				uint32_t idx = r.u32();
				int32_t cap = r.i32();
				static std::vector<double> pt_scratch;
				pt_scratch.resize((size_t)(cap > 0 ? cap : 1));
				int32_t n = 0;
				if (g_rap.contact_get_points != nullptr)
					n = g_rap.contact_get_points(W, (int32_t)idx, pt_scratch.data(), cap);
				w.i32(n);
				size_t need = (size_t)(4 + n * 9);
				if (cap > 0 && (size_t)cap >= need) {
					for (size_t q = 0; q < need; ++q) w.f64(pt_scratch[q]);
				}
				break;
			}
			case 38: {
				uint32_t id = r.u32();
				double fric = r.f64();
				g_rap.body_set_friction(W, id, fric);
				break;
			}
			case 39: {
				uint32_t id = r.u32();
				double rest = r.f64();
				g_rap.body_set_restitution(W, id, rest);
				break;
			}
			// 40  关节求解软度（自然频率 Hz + 阻尼比）—— 不推就是 Rapier 默认
			case 40: {
				uint32_t id = r.u32();
				double freq = r.f64(), damping = r.f64();
				g_rap.joint_set_softness(W, id, freq, damping);
				break;
			}
			// 41  世界级关节求解参数（迭代次数 / warmstart 开关 / warmstart 系数）——
			//     三个都是"显式设过才推"，没设的保持 Rapier 默认（没调过的场景逐位不变）
			case 41: {
				int32_t it = r.i32(), ws = r.i32();
				double coeff = r.f64();
				g_rap.world_set_joint_solver(W, it, ws, coeff);
				break;
			}
			default:
				// ⚠️ 未知操作码**必须立刻停**：它的载荷长度未知，继续读下去会把
				//    后面的字节当成操作码，整条流错位 —— 而错位往往表现为"写出了
				//    超出容量的字节"（实测 written=28 而 out_cap=4），静默损坏内存。
				//    这个坑真的发生过：加了新 op 却只重建了本 DLL、忘了重建 Rust 桥接，
				//    于是 load_rapier 失败，一路错位到"所有物体停在原点"。
				printf("[RapierPhys] 未知操作码 %d（命令流错位），就此中止\n", (int)op);
				r.ok = false;
				break;
		}
	}
	written = w.i;
	if (written > out_cap) {
		// CmdWr 只在容量内 memcpy，但 w.i 会照常前进 —— 所以 written > out_cap
		// 是"命令流错位"的可靠指纹，必须喊出来。
		printf("[RapierPhys] 结果段越界：written=%zu > out_cap=%zu（命令流很可能错位）\n", written, out_cap);
	}
}

// ================= PixelRaster：形状 -> RGBA8 图（渲染用） =================
//
// 为什么值得搬进原生：逐像素在 GDScript 里填 RGBA8 是**实测 0.65 us/像素**
// （参照实现 = src/render/pixel_renderer.gd 的 _build_region_image_gd）——
// 一块 64x64 要 2.5 ms，768x100 的地面首次建图 **50 ms**。而"大物体被切开"
// 那一帧里，渲染重建比破坏本身还贵（实测 53 ms vs 23.7 ms，
// 见 tests/diag_bigfrag_hitch.gd）。
//
// ⚠️ GDScript 那条路**必须留着**：它是参照实现，逐位对拍靠它
//    （tests/validation_raster_native.gd）；shading 打开时也只能走它
//    （逐像素着色是 GDScript 的规则）。
//
// 命令流（头部协议与 RapierPhys.cmd 相同：in = [i32 out_cap][i32 cmd_len][ops...]）：
//   1  fill_region(i32 w, i32 h, i32 rx, i32 ry, i32 ox, i32 oy, i32 n_chunks,
//                  u32 palette[256], { i32 cx, i32 cy, i64 occ, u8 mat[64] } * n_chunks)
//        -> w*h*4 字节 RGBA8（先清零），written = w*h*4
//      w,h     = 区域尺寸（像素）
//      rx,ry   = 区域原点（shape 局部像素坐标）
//      ox,oy   = shape 的 aabb 原点（局部像素坐标）—— 块坐标 (cx,cy) 靠它换算
//      palette = 256 项 u32（小端 = r,g,b,255）。**由 GDScript 侧按与参照实现
//                逐位一致的规则算好**（int(c*255) 截断 / alpha 强制 255 /
//                材质 id 越界 clamp 到最后一格）—— 原生只做拷贝，
//                浮点语义只留一处真源（"同一规则写两处"在本仓库栽过太多次）。
//
// 每个块的 (occ, mat) 与 PixelChunk 一一对应：occ 的 bit i = 局部像素
// (i & 7, i >> 3)，mat[i] = 材质 id。区域外的像素直接跳过（与参照实现同判据）。

// PixelRaster 自己的一组 StringName。
// ⚠️ 不复用 RapierPhys 那几个缓冲区：复用会让两个类的方法名/参数名互相覆盖，
//    注册出来的签名静默错位（而症状是"调用时参数对不上"）。
static SN g_sn_pxr_class, g_sn_pxr_fill, g_sn_pxr_a0, g_sn_pxr_a1, g_sn_pxr_ret;

static void run_raster_cmd(const uint8_t *in, size_t in_n, uint8_t *out, size_t out_cap, size_t &written) {
	written = 0;
	CmdRd r; r.p = in; r.n = in_n; r.i = 0;
	while (r.ok && r.i < r.n) {
		uint8_t op = r.u8();
		if (!r.ok) break;
		switch (op) {
			case 1: {
				int32_t w = r.i32(), h = r.i32();
				int32_t rx = r.i32(), ry = r.i32();
				int32_t ox = r.i32(), oy = r.i32();
				int32_t n_chunks = r.i32();
				if (w < 0) w = 0;
				if (h < 0) h = 0;
				if (n_chunks < 0) n_chunks = 0;
				size_t need = (size_t)w * (size_t)h * 4u;
				const uint8_t *pal = r.bytes(1024);
				if (!r.ok) break;
				// ⚠️ 容量不够必须**停**，不能"能写多少写多少"：written 会被当成结果段
				//    长度，写超容量是静默内存损坏（本仓库在命令流错位上栽过 ——
				//    见 RapierPhys 的 default 分支墓碑）。
				if (need > out_cap) {
					printf("[PixelRaster] 结果段容量不够：need=%zu out_cap=%zu\n", need, out_cap);
					r.ok = false;
					break;
				}
				// 空像素必须是**全 0**（RGBA8 透明）—— 参照实现靠 resize 的零初始化
				std::memset(out, 0, need);
				for (int32_t k = 0; k < n_chunks; ++k) {
					int32_t cx = r.i32(), cy = r.i32();
					int64_t occ = r.i64();
					const uint8_t *mat = r.bytes(64);
					if (!r.ok) break;
					// cx * 8 而不是 cx << 3：左移负数在 C++ 里是 UB（虽然实际不会错）
					int32_t bx = cx * 8 - ox;
					int32_t by = cy * 8 - oy;
					uint64_t bits = (uint64_t)occ;
					while (bits != 0) {
						int i = __builtin_ctzll(bits);   // 与 PixelBits.first_bit_index 同义
						bits &= bits - 1;
						int32_t lx = bx + (i & 7) - rx;
						int32_t ly = by + (i >> 3) - ry;
						if (lx < 0 || lx >= w || ly < 0 || ly >= h) continue;
						uint32_t col;
						std::memcpy(&col, pal + ((size_t)mat[i] << 2), 4);
						std::memcpy(out + (((size_t)ly * (size_t)w + (size_t)lx) << 2), &col, 4);
					}
				}
				written = need;
				break;
			}
			default:
				// 与 RapierPhys 同一条规矩：未知操作码**立刻停**（它的载荷长度未知，
				// 继续读会把后面的字节当操作码，整条流错位）
				printf("[PixelRaster] 未知操作码 %d（命令流错位），就此中止\n", (int)op);
				r.ok = false;
				break;
		}
	}
}

static GDExtensionObjectPtr create_rapier_instance(void *p_userdata, GDExtensionBool p_notify_postinitialize) {
	GDExtensionObjectPtr obj = g_construct_object((GDExtensionConstStringNamePtr)g_sn_parent.buf);
	if (obj == nullptr) return nullptr;
	RapierInstance *d = new RapierInstance();
	g_object_set_instance(obj, (GDExtensionConstStringNamePtr)g_sn_rp_class.buf, (GDExtensionClassInstancePtr)d);
	return obj;
}

static void free_rapier_instance(void *p_userdata, GDExtensionClassInstancePtr p_instance) {
	if (p_instance != nullptr) delete (RapierInstance *)p_instance;
}

// ---- cmd(in, out_template) 的**公共胶水** ----
//
// RapierPhys.cmd 与 PixelRaster.fill_region 只有 dispatch 不同：协议头、
// 模板拷贝、返回值装填完全一样 —— 所以只写这一份实现。
// （"同一规则写两处"在本仓库栽过太多次：GDScript 侧改了 C++ 侧没改，接触点差 3.88 个单位。）
typedef void (*CmdDispatch)(void *ctx, const uint8_t *in, size_t in_n,
		uint8_t *out, size_t out_cap, size_t &written);

static void rapier_dispatch(void *ctx, const uint8_t *in, size_t in_n,
		uint8_t *out, size_t out_cap, size_t &written) {
	run_rapier_cmd((RapierInstance *)ctx, in, in_n, out, out_cap, written);
}

static void raster_dispatch(void *ctx, const uint8_t *in, size_t in_n,
		uint8_t *out, size_t out_cap, size_t &written) {
	(void)ctx;   // 栅格化没有实例状态
	run_raster_cmd(in, in_n, out, out_cap, written);
}

static void call_cmd_glue(CmdDispatch fn, void *ctx,
		const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count,
		GDExtensionVariantPtr r_return, GDExtensionCallError *r_error) {
	if (r_error) r_error->error = GDEXTENSION_CALL_OK;
	if (p_argument_count < 2) {
		if (r_error) r_error->error = GDEXTENSION_CALL_ERROR_TOO_FEW_ARGUMENTS;
		return;
	}
	TypeStorage in_s, tmpl_s, out_s;
	g_pba_from_variant(in_s.buf, (GDExtensionVariantPtr)p_args[0]);
	g_pba_from_variant(tmpl_s.buf, (GDExtensionVariantPtr)p_args[1]);
	const uint8_t *in = g_pba_index_const(in_s.buf, 0);
	// 输出走"按模板拷贝"这条已验证过的路（C++ 侧 resize PackedByteArray 会段错误）
	GDExtensionConstTypePtr ctor_args[1] = { tmpl_s.buf };
	g_pba_copy_ctor(out_s.buf, ctor_args);
	uint8_t *out = g_pba_index(out_s.buf, 0);
	size_t written = 0;
	if (in != nullptr && out != nullptr) {
		// 头部 8 字节：out_cap = 结果段容量，cmd_len = 命令段长度。
		// ⚠️ 拿不到 PackedByteArray 的 size（见 broadphase 那处的说明），
		//    所以长度必须由调用方写在头里，不能靠"读到越界为止"。
		int32_t out_cap = 0, cmd_len = 0;
		std::memcpy(&out_cap, in, 4);
		std::memcpy(&cmd_len, in + 4, 4);
		if (out_cap < 0) out_cap = 0;
		if (cmd_len < 0) cmd_len = 0;
		fn(ctx, in + 8, (size_t)cmd_len, out + 4, (size_t)out_cap, written);
		int32_t w32 = (int32_t)written;
		std::memcpy(out, &w32, 4);
	}
	g_pba_to_variant(r_return, out_s.buf);
	g_pba_destructor(out_s.buf);
	g_pba_destructor(tmpl_s.buf);
	g_pba_destructor(in_s.buf);
}

static void call_rapier_cmd(void *method_userdata, GDExtensionClassInstancePtr p_instance,
		const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count,
		GDExtensionVariantPtr r_return, GDExtensionCallError *r_error) {
	call_cmd_glue(rapier_dispatch, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void call_raster_fill(void *method_userdata, GDExtensionClassInstancePtr p_instance,
		const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count,
		GDExtensionVariantPtr r_return, GDExtensionCallError *r_error) {
	(void)p_instance;
	call_cmd_glue(raster_dispatch, nullptr, p_args, p_argument_count, r_return, r_error);
}

static void register_rapier_phys() {
	GDExtensionClassCreationInfo6 info = {};
	info.is_virtual = false;
	info.is_abstract = false;
	info.is_exposed = true;
	info.is_runtime = false;
	info.create_instance_func = create_rapier_instance;
	info.free_instance_func = free_rapier_instance;
	g_register_class6(g_library, (GDExtensionConstStringNamePtr)g_sn_rp_class.buf,
		(GDExtensionConstStringNamePtr)g_sn_parent.buf, &info);
	printf("[RapierPhys] 类已注册\n");

	GDExtensionClassMethodInfo mi = {};
	mi.name = (GDExtensionStringNamePtr)g_sn_rp_cmd.buf;
	mi.call_func = call_rapier_cmd;
	mi.ptrcall_func = nullptr;
	mi.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
	mi.has_return_value = true;
	static GDExtensionPropertyInfo ret_info = {};
	ret_info.type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	ret_info.name = (GDExtensionStringNamePtr)g_sn_rp_ret.buf;
	ret_info.class_name = (GDExtensionStringNamePtr)g_sn_empty_class.buf;
	ret_info.hint_string = (GDExtensionStringPtr)g_str_empty_hint;
	mi.return_value_info = &ret_info;
	mi.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	static GDExtensionPropertyInfo args[2] = {};
	args[0].type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	args[0].name = (GDExtensionStringNamePtr)g_sn_rp_a0.buf;
	args[1].type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	args[1].name = (GDExtensionStringNamePtr)g_sn_rp_a1.buf;
	for (int i = 0; i < 2; ++i) {
		args[i].class_name = (GDExtensionStringNamePtr)g_sn_empty_class.buf;
		args[i].hint_string = (GDExtensionStringPtr)g_str_empty_hint;
	}
	static GDExtensionClassMethodArgumentMetadata meta[2] = {
		GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE, GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE };
	mi.argument_count = 2;
	mi.arguments_info = args;
	mi.arguments_metadata = meta;
	mi.default_argument_count = 0;
	mi.default_arguments = nullptr;
	g_register_method(g_library, (GDExtensionConstStringNamePtr)g_sn_rp_class.buf, &mi);
	printf("[RapierPhys] 已注册方法 cmd\n");
}

// ---- PixelRaster 的类与实例 ----
//
// ⚠️ 它**不需要 Rapier**：实例只是个占位（GDExtension 要求一个 class instance
//    指针），所以桥接层没加载时它照样能用 —— 渲染不该被物理扩展拖下水。
struct RasterInstance { int unused = 0; };

static GDExtensionObjectPtr create_raster_instance(void *p_userdata, GDExtensionBool p_notify_postinitialize) {
	GDExtensionObjectPtr obj = g_construct_object((GDExtensionConstStringNamePtr)g_sn_parent.buf);
	if (obj == nullptr) return nullptr;
	RasterInstance *d = new RasterInstance();
	g_object_set_instance(obj, (GDExtensionConstStringNamePtr)g_sn_pxr_class.buf, (GDExtensionClassInstancePtr)d);
	return obj;
}

static void free_raster_instance(void *p_userdata, GDExtensionClassInstancePtr p_instance) {
	if (p_instance != nullptr) delete (RasterInstance *)p_instance;
}

static void register_pixel_raster() {
	GDExtensionClassCreationInfo6 info = {};
	info.is_virtual = false;
	info.is_abstract = false;
	info.is_exposed = true;
	info.is_runtime = false;
	info.create_instance_func = create_raster_instance;
	info.free_instance_func = free_raster_instance;
	g_register_class6(g_library, (GDExtensionConstStringNamePtr)g_sn_pxr_class.buf,
		(GDExtensionConstStringNamePtr)g_sn_parent.buf, &info);
	printf("[PixelRaster] 类已注册\n");

	GDExtensionClassMethodInfo mi = {};
	mi.name = (GDExtensionStringNamePtr)g_sn_pxr_fill.buf;
	mi.call_func = call_raster_fill;
	mi.ptrcall_func = nullptr;
	mi.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
	mi.has_return_value = true;
	static GDExtensionPropertyInfo ret_info = {};
	ret_info.type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	ret_info.name = (GDExtensionStringNamePtr)g_sn_pxr_ret.buf;
	ret_info.class_name = (GDExtensionStringNamePtr)g_sn_empty_class.buf;
	ret_info.hint_string = (GDExtensionStringPtr)g_str_empty_hint;
	mi.return_value_info = &ret_info;
	mi.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	static GDExtensionPropertyInfo args[2] = {};
	args[0].type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	args[0].name = (GDExtensionStringNamePtr)g_sn_pxr_a0.buf;
	args[1].type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	args[1].name = (GDExtensionStringNamePtr)g_sn_pxr_a1.buf;
	for (int i = 0; i < 2; ++i) {
		args[i].class_name = (GDExtensionStringNamePtr)g_sn_empty_class.buf;
		args[i].hint_string = (GDExtensionStringPtr)g_str_empty_hint;
	}
	static GDExtensionClassMethodArgumentMetadata meta[2] = {
		GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE, GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE };
	mi.argument_count = 2;
	mi.arguments_info = args;
	mi.arguments_metadata = meta;
	mi.default_argument_count = 0;
	mi.default_arguments = nullptr;
	g_register_method(g_library, (GDExtensionConstStringNamePtr)g_sn_pxr_class.buf, &mi);
	printf("[PixelRaster] 已注册方法 fill_region\n");
}


static void initialize(void *p_userdata, GDExtensionInitializationLevel p_level) {
	if (p_level != GDEXTENSION_INITIALIZATION_SCENE) return;
	GDExtensionClassCreationInfo6 info = {};
	info.is_virtual = false;
	info.is_abstract = false;
	info.is_exposed = true;
	info.is_runtime = false;
	// 两个类各自注册自己的类与实例（都继承 RefCounted）：
	//   RapierPhys  —— 物理
	//   PixelRaster —— 渲染栅格化（不依赖 Rapier）
	register_rapier_phys();
	register_pixel_raster();
}

static void deinitialize(void *p_userdata, GDExtensionInitializationLevel p_level) {
	if (p_level == GDEXTENSION_INITIALIZATION_SCENE) printf("[FastPhys] 反初始化\n");
}

extern "C" __declspec(dllexport) GDExtensionBool gdextension_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	// 无缓冲输出：崩溃时块缓冲会把日志全部吞掉，什么都看不到
	setvbuf(stdout, nullptr, _IONBF, 0);
	g_get_proc_address = p_get_proc_address;
	g_library = p_library;
	g_sn_new = (GDExtensionInterfaceStringNameNewWithUtf8Chars)p_get_proc_address("string_name_new_with_utf8_chars");
	g_register_class6 = (GDExtensionInterfaceClassdbRegisterExtensionClass6)p_get_proc_address("classdb_register_extension_class6");
	g_register_method = (GDExtensionInterfaceClassdbRegisterExtensionClassMethod)p_get_proc_address("classdb_register_extension_class_method");
	g_construct_object = (GDExtensionInterfaceClassdbConstructObject)p_get_proc_address("classdb_construct_object");
	g_object_set_instance = (GDExtensionInterfaceObjectSetInstance)p_get_proc_address("object_set_instance");
	g_str_new = (GDExtensionInterfaceStringNewWithUtf8Chars)p_get_proc_address("string_new_with_utf8_chars");
	g_get_ctor = (GDExtensionInterfaceVariantGetPtrConstructor)p_get_proc_address("variant_get_ptr_constructor");
	g_get_builtin = (GDExtensionInterfaceVariantGetPtrBuiltinMethod)p_get_proc_address("variant_get_ptr_builtin_method");
	g_get_to_type = (GDExtensionInterfaceGetVariantToTypeConstructor)p_get_proc_address("get_variant_to_type_constructor");
	g_get_from_type = (GDExtensionInterfaceGetVariantFromTypeConstructor)p_get_proc_address("get_variant_from_type_constructor");
	g_get_destructor = (GDExtensionInterfaceVariantGetPtrDestructor)p_get_proc_address("variant_get_ptr_destructor");
	g_pba_index = (GDExtensionInterfacePackedByteArrayOperatorIndex)p_get_proc_address("packed_byte_array_operator_index");
	g_pba_index_const = (GDExtensionInterfacePackedByteArrayOperatorIndexConst)p_get_proc_address("packed_byte_array_operator_index_const");
	if (!g_sn_new || !g_str_new || !g_register_class6 || !g_register_method || !g_construct_object
			|| !g_object_set_instance || !g_get_ctor || !g_pba_index || !g_pba_index_const) {
		printf("[FastPhys] 关键接口缺失\n");
		return 0;
	}
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_parent.buf, "RefCounted");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_rp_class.buf, "RapierPhys");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_rp_cmd.buf, "cmd");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_rp_a0.buf, "input");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_rp_a1.buf, "out_template");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_rp_ret.buf, "result");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_class.buf, "PixelRaster");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_fill.buf, "fill_region");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_a0.buf, "input");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_a1.buf, "out_template");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_ret.buf, "result");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_empty_class.buf, "");
	g_str_new((GDExtensionUninitializedStringPtr)g_str_empty_hint, "");
	// PackedByteArray 的构造索引 1 = 拷贝构造
	g_pba_copy_ctor = g_get_ctor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 1);
	g_pba_default_ctor = g_get_ctor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 0);
	if (!g_pba_copy_ctor || !g_pba_default_ctor) { printf("[FastPhys] 拿不到 PackedByteArray 构造函数\n"); return 0; }
	// ⚠️ 这里曾经解析并检查 PackedByteArray.resize —— 那是手写后端用来"现造输出数组"的。
	//    RapierPhys 的输出走"按模板拷贝"（C++ 侧 resize 一个 PackedByteArray 实测段错误），
	//    不需要它。删掉内核后这段检查还在，导致扩展**整个加载失败** ——
	//    而症状是 GDScript 侧 "Nonexistent function 'cmd' in base 'Nil'"，完全指不到这里。
	//    教训：删掉一个子系统时，它的**启动期自检**要一起删。
	if (!g_get_to_type || !g_get_from_type || !g_get_destructor) {
		printf("[FastPhys] 缺少 Variant 转换接口\n");
		return 0;
	}
	g_pba_from_variant = g_get_to_type(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
	g_pba_to_variant = g_get_from_type(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
	g_pba_destructor = g_get_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
	g_int_from_variant = g_get_to_type(GDEXTENSION_VARIANT_TYPE_INT);
	g_int_destructor = g_get_destructor(GDEXTENSION_VARIANT_TYPE_INT);
	// ⚠️ variant_get_ptr_destructor 对 POD 类型（int/float…）返回 **null** —— 它们没有析构函数。
	// 所以可空项要分开判断，不能一起当"必需"。
	if (!g_pba_from_variant || !g_pba_to_variant || !g_pba_destructor || !g_int_from_variant) {
		printf("[FastPhys] Variant 转换函数解析失败: from=%p to=%p dtor=%p int_from=%p\n",
			(void *)g_pba_from_variant, (void *)g_pba_to_variant,
			(void *)g_pba_destructor, (void *)g_int_from_variant);
		return 0;
	}
	r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_initialization->userdata = nullptr;
	r_initialization->initialize = initialize;
	r_initialization->deinitialize = deinitialize;
	printf("[FastPhys] 入口被调用，接口全部拿到\n");
	return 1;
}
