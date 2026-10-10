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
#include <algorithm>
// PixelFluid 的 push_apart 要用 std::sqrt（与 GDScript 的 sqrt() 同为 IEEE 正确舍入，
// 这是两条路径能逐位对拍的前提之一）。
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <unordered_map>
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

// 内置类型值的暂存空间（PackedByteArray 实际只有 8 字节，给足余量）
struct TypeStorage { alignas(16) unsigned char buf[64]; };

struct SN { alignas(16) unsigned char buf[64]; };
static SN g_sn_parent;
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
//  43  body_fit_polys(u32 id, i32 n_rects, f32[n*4] rects, f64 friction, f64 mass, f32 dev_tol)
//                                                  -> i32 n_polys
//      **凸多边形碰撞体**（Noita 式拟合）：原生侧把精确覆盖的矩形拟合成凸多边形
//      （斜边拉直、锯齿拉平），建碰撞体，并按 mass/多边形面积 反算密度。
//      拟合算法与浮点纪律见 rapier_bridge/src/lib.rs 的"像素形状 -> 凸多边形碰撞体"一节。
//      ⚠️ 与 op 5（body_set_rects）是**互斥**的两条路：谁最后被调用谁生效
//         （两者都会先清空旧碰撞体）。PWorld 按矩形数预算二选一。
//  44  body_get_polys(u32 id, i32 cap)            -> cap 够时：[i32 n_polys][每个 i32 count + 顶点 f32 对]
//                                                    cap 不够时：只写 [i32 需要的字节数]
//      **读回真的在用的碰撞体形状**（可视化 / 闸门用）。问物理要真相，不另算一份。
//  46  body_get_inertia(u32 id)                   -> f64（Rapier 侧角惯量，诊断用）
//  45  body_get_mass(u32 id)                      -> f64（Rapier 侧质量）
//      判据用：拟合后的碰撞体面积 >= 像素面积，密度按质量反算 —— 两边质量不许分叉。
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
	// 凸多边形碰撞体（Noita 式的像素拟合结果）。签名与 rapier_bridge 的 rb_body_set_polys 一一对应。
	// 凸多边形碰撞体（Noita 式拟合）：给矩形集合，原生侧拟合成多边形再建碰撞体。
	int32_t (*body_fit_polys)(RPWorld, uint32_t, const float *, int32_t, double, double, float) = nullptr;
	// 读回当前碰撞体形状（可视化/闸门用）。返回写入或需要的字节数。
	int32_t (*body_get_polys)(RPWorld, uint32_t, uint8_t *, int32_t) = nullptr;
	// Rapier 侧的质量（密度补偿的判据）
	double (*body_get_mass)(RPWorld, uint32_t) = nullptr;
	double (*body_get_inertia)(RPWorld, uint32_t) = nullptr;
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
	RP_GET(body_fit_polys, "rb_body_fit_polys")
	RP_GET(body_get_polys, "rb_body_get_polys")
	RP_GET(body_get_mass, "rb_body_get_mass")
	RP_GET(body_get_inertia, "rb_body_get_inertia")
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
	float f32() { float v = 0; if (i + 4 > n) { ok = false; return 0; } std::memcpy(&v, p + i, 4); i += 4; return v; }
	int64_t i64() { int64_t v = 0; if (i + 8 > n) { ok = false; return 0; } std::memcpy(&v, p + i, 8); i += 8; return v; }
	// 定长裸字节段。失败返回 nullptr 且 ok = false —— 调用方**必须**查 ok 再解引用。
	const uint8_t *bytes(size_t count) {
		if (i + count > n) { ok = false; return nullptr; }
		const uint8_t *q = p + i;
		i += count;
		return q;
	}
	// i32 批量段（op 43 的多边形顶点数数组）。与 f32s 同一个理由：一次 memcpy。
	bool i32s(size_t count, std::vector<int32_t> &dst) {
		dst.resize(count);
		if (i + count * 4 > n) { ok = false; return false; }
		if (count > 0) std::memcpy(dst.data(), p + i, count * 4);
		i += count * 4;
		return true;
	}
	bool f32s(size_t count, std::vector<float> &dst) {
		dst.resize(count);
		if (i + count * 4 > n) { ok = false; return false; }
		if (count > 0) std::memcpy(dst.data(), p + i, count * 4);
		i += count * 4;
		return true;
	}
	// f64 批量段。PixelFluid 要读 2N 个 double 的粒子状态 —— 逐元素 f64() 要 N 次
	// 调用，而这里一次 memcpy 就够（与 GDScript 侧的 to_byte_array 同一个理由）。
	bool f64s(size_t count, double *dst) {
		if (i + count * 8 > n) { ok = false; return false; }
		if (count > 0) std::memcpy(dst, p + i, count * 8);
		i += count * 8;
		return true;
	}
};

struct CmdWr {
	uint8_t *p = nullptr;
	size_t cap = 0;
	size_t i = 0;
	void i32(int32_t v) { if (i + 4 <= cap) std::memcpy(p + i, &v, 4); i += 4; }
	void f64(double v) { if (i + 8 <= cap) std::memcpy(p + i, &v, 8); i += 8; }
	// 裸字节段（PixelFluid 要回吐 pos/vel/ink 三个批量数组）。
	// ⚠️ 与其它写入器同一条规矩：**只在容量内 memcpy，但 i 照常前进** ——
	//    于是 written > out_cap 是"结果段越界/命令流错位"的可靠指纹。
	void raw(const void *src, size_t bytes) {
		if (i + bytes <= cap && src != nullptr) std::memcpy(p + i, src, bytes);
		i += bytes;
	}
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
			case 43: {
				// body_fit_polys(u32 id, i32 n_rects, f32[n*4] rects, f64 friction, f64 mass, f32 dev_tol)
				//   -> i32 n_polys（拟合出来的多边形个数，诊断用）
				//
				// 原生侧把**精确覆盖的矩形**拟合成凸多边形（Noita 式：斜边是直的），
				// 再建 Rapier 的凸多边形碰撞体，并按 mass/多边形面积 反算密度
				// （见 rb_body_fit_polys 的说明）。GDScript 只给矩形，不自己拟合 ——
				// 碎片路径一次几百个刚体，GDScript 侧拟合会卡（实测 ~35us/矩形）。
				uint32_t id = r.u32();
				int32_t cnt = r.i32();
				if (cnt < 0) cnt = 0;
				bool got = r.f32s((size_t)cnt * 4, rect_scratch);
				double fr = r.f64();
				double ms = r.f64();
				float tol = r.f32();
				// ⚠️⚠️ **不往结果段写任何东西**：子步这条命令流的结果段是按
				//    "每个刚体 48 字节状态"精确开出来的（PWorld 的 n_state*48），
				//    这里多写 4 字节就会让**后面所有状态读回整体偏移 4 字节** ——
				//    症状是"角速度突然变成 1000"这种完全对不上的物理量，
				//    而 written > out_cap 那行警告是唯一的指纹（实测抓到过）。
				//    诊断信息请走 op 44（读回碰撞体形状），别在这条流里塞。
				if (got) g_rap.body_fit_polys(W, id, rect_scratch.data(), cnt, fr, ms, tol);
				break;
			}
			case 46: {
				// body_get_inertia(u32 id) -> f64（Rapier 侧的角惯量，诊断用）
				uint32_t id = r.u32();
				double v = 0.0;
				if (g_rap.body_get_inertia) v = g_rap.body_get_inertia(W, id);
				w.f64(v);
				break;
			}
			case 45: {
				// body_get_mass(u32 id) -> f64（Rapier 侧的质量）
				// 判据用：拟合后的碰撞体面积 >= 像素面积，密度必须按质量反算 ——
				// 两边质量一旦分叉，所有"按 mass 算力"的地方都会错（抓取限力等）。
				uint32_t id = r.u32();
				double m = 0.0;
				if (g_rap.body_get_mass) m = g_rap.body_get_mass(W, id);
				w.f64(m);
				break;
			}
			case 44: {
				// body_get_polys(u32 id, i32 cap) -> 结果段：[i32 n_polys][每个 i32 count + count x (f32 x,y)]
				// cap 不够时原生把**需要的字节数**报回来（与 PixelRaster.decompose 同一条规矩）。
				uint32_t id = r.u32();
				int32_t cap = r.i32();
				if (cap < 0) cap = 0;
				std::vector<uint8_t> tmp((size_t)cap);
				int32_t need = g_rap.body_get_polys(W, id, tmp.empty() ? nullptr : tmp.data(), cap);
				// ⚠️ 协议：cap 不够时**只写**"需要多少字节"（4 字节），调用方按它精确重开一次；
				//    cap 够时写**块本身**（need 字节，不再重复写 need）。
				//    第一版两边都写了 -> 结果段比 cap 多 4 字节，被 written > out_cap 抓住。
				if (need <= cap && need > 0) {
					w.raw(tmp.data(), (size_t)need);
				} else {
					w.i32(need);
				}
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
//   2  decompose(i32 n_chunks, i32 max_rects,
//                { i32 cx, i32 cy, i64 occ } * n_chunks)
//        -> i32 count, i32 budget_exceeded,
//           i32 aabb_x, aabb_y, aabb_w, aabb_h,
//           { i32 x, i32 y, i32 w, i32 h } * count
//      written = 24 + count*16；**结果段放不下矩形时只写头**（written = 24，
//      count 在里面）—— 调用方按 count 精确重开一次。见 run_raster_decompose。
//      n_chunks / max_rects 在头里（与 op 1 同一种"先头后记录"的排布）。
//
//      ⚠️ max_rects **不参与几何**（参照实现里它只决定 budget_exceeded 这个标志位：
//         "decompose 永远精确，超了要告诉我"）。原生顺手把标志一起算了，
//         省得同一条阈值规则在两边各写一份。
//
//      ⚠️ AABB 是**出参**，不是入参：decompose() 在 GDScript 里第一步就是
//         local_aabb()，而那一扫才是每笔破坏 2.0 ms 里的大头（500 个 chunk
//         实测 1.8 ms）。要成入参就得先在 GDScript 里扫一遍 —— 那就白搬了。
//
// 每个块的 (occ, mat) 与 PixelChunk 一一对应：occ 的 bit i = 局部像素
// (i & 7, i >> 3)，mat[i] = 材质 id。区域外的像素直接跳过（与参照实现同判据）。

// PixelRaster 自己的一组 StringName。
// ⚠️ 不复用 RapierPhys 那几个缓冲区：复用会让两个类的方法名/参数名互相覆盖，
//    注册出来的签名静默错位（而症状是"调用时参数对不上"）。
static SN g_sn_pxr_class, g_sn_pxr_fill, g_sn_pxr_decomp, g_sn_pxr_comp, g_sn_pxr_a0, g_sn_pxr_a1, g_sn_pxr_ret;

// ---- op 2 的几何内核：块内贪心 + 极大行程融合 ----
//
// ⚠️⚠️ 这是 src/core/greedy_rects.gd 的**第二份实现**，判据只有一条：
//    **逐位相同**（同样的矩形、同样的顺序）—— 闸门 tests/validation_greedy_native.gd。
//    所以每一步都照着参照实现抄，注释里标出对应的函数名。
//    **顺序不同也是不同**：矩形顺序会原样进入 Rapier 的碰撞体顺序。
//
// 为什么值得搬进原生（800x40 实测，见 tests/bench_decompose_native.gd）：
//    GDScript 冷路径 3.1 ms；每笔破坏的热路径 2.0 ms（其中 local_aabb 重扫
//    占 1.8 ms，真正的分块 + 融合只占 0.2 ms）-> 原生 ~0.15 ms，两笔一起算掉。
//
// ⚠️ 分块锚点在**局部像素坐标的 0/64/128...**，与 AABB 无关（AABB 会随擦到
//    边界而变，锚在 AABB 上的话每笔边缘擦除都要全量重算）。

struct PxRect { int64_t x, y, w, h; };

// 低 bits 位为 1。bits >= 64 时全 1 —— 参照实现里 1 << 64 是 UB，
// 它靠 `if take < 64` 的守卫绕开，这里用同一个判据。
static inline uint64_t px_low_mask(int bits) {
	return bits >= 64 ? ~0ULL : ((1ULL << bits) - 1ULL);
}

// GreedyRects._run_right（块内特化：wq == 1，一行正好一个 word）
static inline int px_run_right(const uint64_t *words, int x, int y) {
	uint64_t inv = ~words[y] & ~px_low_mask(x);
	if (inv == 0) return 64 - x;
	return __builtin_ctzll(inv) - x;
}

// GreedyRects._run_down
static inline int px_run_down(const uint64_t *words, int x, int y) {
	uint64_t bit = 1ULL << x;
	int rh = 1;
	while (y + rh < 64 && (words[y + rh] & bit) != 0) ++rh;
	return rh;
}

// GreedyRects._extend_down_bits
static inline int px_extend_down(const uint64_t *words, int x, int y, int rw) {
	uint64_t m = ~px_low_mask(x) & px_low_mask(x + rw);
	int rh = 1;
	while (y + rh < 64 && (words[y + rh] & m) == m) ++rh;
	return rh;
}

// GreedyRects._extend_right_bits
static inline int px_extend_right(const uint64_t *words, int x, int y, int rh) {
	int best = 64 - x;
	for (int j = 0; j < rh; ++j) {
		int r = px_run_right(words, x, y + j);
		if (r < best) {
			best = r;
			if (best <= 0) break;
		}
	}
	return best;
}

// GreedyRects._clear_rect
static inline void px_clear_rect(uint64_t *words, int x, int y, int rw, int rh) {
	uint64_t m = ~px_low_mask(x) & px_low_mask(x + rw);
	for (int j = 0; j < rh; ++j) words[y + j] &= ~m;
}

// GreedyRects._greedy（64x64、每行一个 word 的特化版）。
// ⚠️ words 会被**就地清零** —— 要跑第二遍必须先复制一份（参照实现靠 duplicate()）。
static void px_greedy_block(uint64_t *words, bool horizontal_first, std::vector<PxRect> &out) {
	for (int wi = 0; wi < 64; ) {
		while (wi < 64 && words[wi] == 0) ++wi;
		if (wi >= 64) break;
		int y = wi;
		int x = __builtin_ctzll(words[wi]);
		if (x >= 64) { ++wi; continue; }     // 参照实现同款防御（64 位字里不会发生）
		int rw, rh;
		if (horizontal_first) {
			rw = px_run_right(words, x, y);
			rh = px_extend_down(words, x, y, rw);
		} else {
			rh = px_run_down(words, x, y);
			rw = px_extend_right(words, x, y, rh);
		}
		px_clear_rect(words, x, y, rw, rh);
		out.push_back({x, y, rw, rh});
	}
}

// GreedyRects._fuse_axis：把"另一轴区间相同、主轴相邻"的矩形并成极大行程。
//
// ⚠️⚠️ 输出顺序 = 分组**首次出现**的顺序（参照实现用的是 Dictionary，
//    Godot 的 Dictionary 保持插入序）。分组内部按主轴升序。
//    ⚠️ 组内不会有两根矩形主轴坐标相同 —— 精确覆盖里那意味着重叠，
//       所以 std::sort（不稳定）在这里与参照实现的 sort_custom 等价。
static void px_fuse_axis(const std::vector<PxRect> &in, bool along_x, std::vector<PxRect> &out) {
	std::vector<std::vector<PxRect>> groups;
	std::unordered_map<uint64_t, size_t> idx;
	idx.reserve(in.size() * 2 + 8);
	for (const PxRect &r : in) {
		int64_t a = along_x ? r.y : r.x;
		int64_t b = along_x ? r.h : r.w;
		uint64_t k = ((uint64_t)(uint32_t)a << 32) | (uint32_t)b;
		size_t gi;
		auto it = idx.find(k);
		if (it == idx.end()) {
			gi = groups.size();
			groups.emplace_back();
			idx.emplace(k, gi);
		} else {
			gi = it->second;
		}
		groups[gi].push_back(r);
	}
	out.clear();
	out.reserve(in.size());
	for (std::vector<PxRect> &g : groups) {
		if (g.size() == 1) { out.push_back(g[0]); continue; }
		if (along_x) {
			std::sort(g.begin(), g.end(), [](const PxRect &p, const PxRect &q) { return p.x < q.x; });
		} else {
			std::sort(g.begin(), g.end(), [](const PxRect &p, const PxRect &q) { return p.y < q.y; });
		}
		PxRect cur = g[0];
		for (size_t i = 1; i < g.size(); ++i) {
			const PxRect &nx = g[i];
			// 参照实现写的是 absf(end - next) < 0.001 —— 全是整数，等价于相等
			if (along_x) {
				if (cur.x + cur.w == nx.x) cur.w = nx.x + nx.w - cur.x;
				else { out.push_back(cur); cur = nx; }
			} else {
				if (cur.y + cur.h == nx.y) cur.h = nx.y + nx.h - cur.y;
				else { out.push_back(cur); cur = nx; }
			}
		}
		out.push_back(cur);
	}
}

// GreedyRects._merge_pass：融合到不动点（两遍都**没有变小**就停）。
static void px_merge_pass(std::vector<PxRect> &rects) {
	std::vector<PxRect> a, b;
	bool changed = true;
	while (changed) {
		changed = false;
		px_fuse_axis(rects, true, a);
		if (a.size() < rects.size()) changed = true;
		px_fuse_axis(a, false, b);
		if (b.size() < a.size()) changed = true;
		rects.swap(b);
	}
}

// 像素坐标 -> i32（协议就是 i32）。|块坐标| < 2^25 是前提（超了 i32 装不下），
// 现实里不可能到 —— 但夹一下比留一个有符号溢出（UB）便宜。
static inline int32_t px_i32(int64_t v) {
	if (v > 2147483647LL) return 2147483647;
	if (v < -2147483648LL) return -2147483648;
	return (int32_t)v;
}

// op 2 主体：块记录 -> (AABB + 矩形集合)。
//
// ⚠️ 结果段容量：调用方**不可能**提前知道矩形数（精确分解的矩形数只有算完才知道），
//    所以这里约定"放不下就只写头"（头 24 字节一定写得下，count 在里面），
//    调用方按 count 精确重开一次。不给"能写多少写多少"—— 那会静默截断。
static void run_raster_decompose(CmdRd &r, uint8_t *out, size_t out_cap, size_t &written) {
	const size_t HEAD = 24;                  // count, budget, aabb_x/y/w/h
	written = 0;
	if (out_cap < HEAD) {
		printf("[PixelRaster] decompose 结果段太小：out_cap=%zu\n", out_cap);
		return;
	}
	int32_t n = r.i32();
	int32_t max_rects = r.i32();
	if (n < 0) n = 0;
	if (!r.ok) return;

	// ① 读块记录，同时算 AABB —— 与 PixelShape.local_aabb() **同一条规则**：
	//    只看 occ，逐行取最低/最高置位；occ == 0 的块整体跳过。
	//    ⚠️ 哨兵值也必须同款（1 << 30 / -(1 << 30)）：参照实现在"所有像素都在
	//       |x| > 2^30"这种荒唐输入下会给出被哨兵夹住的结果，这里要逐位一样。
	const int64_t SENT = 1 << 30;
	int64_t min_x = SENT, min_y = SENT, max_x = -SENT, max_y = -SENT;

	struct PxBlock { int64_t key; int32_t bix, biy; uint64_t words[64]; };
	std::vector<PxBlock> blocks;
	std::unordered_map<uint64_t, size_t> block_idx;
	blocks.reserve((size_t)(n / 8 + 1));

	for (int32_t i = 0; i < n; ++i) {
		int32_t cx = r.i32();
		int32_t cy = r.i32();
		int64_t occ = r.i64();
		if (!r.ok) return;
		uint64_t bits = (uint64_t)occ;
		int64_t bx = (int64_t)cx * 8;
		int64_t by = (int64_t)cy * 8;
		for (int row = 0; row < 8; ++row) {
			uint32_t rb = (uint32_t)((bits >> (row * 8)) & 0xFFu);
			if (rb == 0) continue;
			int lo = __builtin_ctz(rb);
			int hi = 32 - __builtin_clz(rb);      // 最高置位 +1（rb != 0）
			if (bx + lo < min_x) min_x = bx + lo;
			if (bx + hi > max_x) max_x = bx + hi;
			if (by + row < min_y) min_y = by + row;
			if (by + row + 1 > max_y) max_y = by + row + 1;
		}
		// 分块：块坐标 = chunk 坐标 >> 3（算术右移 = 向下取整，负数也对）
		int32_t bix = cx >> 3, biy = cy >> 3;
		int64_t bk = ((int64_t)bix << 32) | (int64_t)(uint32_t)biy;
		size_t gi;
		auto it = block_idx.find((uint64_t)bk);
		if (it == block_idx.end()) {
			gi = blocks.size();
			PxBlock nb;
			nb.key = bk;
			nb.bix = bix;
			nb.biy = biy;
			std::memset(nb.words, 0, sizeof(nb.words));
			blocks.push_back(nb);
			block_idx.emplace((uint64_t)bk, gi);
		} else {
			gi = it->second;
		}
		uint64_t *words = blocks[gi].words;
		int shift = (cx - (bix << 3)) << 3;
		int row0 = (cy - (biy << 3)) << 3;
		for (int row = 0; row < 8; ++row) {
			words[row0 + row] |= (uint64_t)((bits >> (row * 8)) & 0xFFu) << shift;
		}
	}

	// ② 块按 key **升序**（有符号 int64 比较 —— 负块坐标排在前面，
	//    与 GreedyRects._sorted_insert 的 int(keys[mid]) < bk 同义）。
	//    矩形顺序 = 块顺序，所以这一步决定输出顺序。
	std::sort(blocks.begin(), blocks.end(),
			[](const PxBlock &p, const PxBlock &q) { return p.key < q.key; });

	std::vector<PxRect> rects;
	std::vector<PxRect> cand;
	for (PxBlock &bl : blocks) {
		uint64_t w1[64];
		std::memcpy(w1, bl.words, sizeof(w1));
		cand.clear();
		px_greedy_block(w1, true, cand);
		// GreedyRects._decompose_block：两个方向各跑一遍，取**更少**那份
		// （相等时留横优先那份）。只有一个矩形时不必跑第二遍 —— 与参照同款守卫。
		if (cand.size() > 1) {
			uint64_t w2[64];
			std::memcpy(w2, bl.words, sizeof(w2));
			std::vector<PxRect> cand2;
			px_greedy_block(w2, false, cand2);
			if (cand2.size() < cand.size()) cand.swap(cand2);
		}
		int64_t ox = (int64_t)bl.bix * 64;
		int64_t oy = (int64_t)bl.biy * 64;
		for (PxRect &q : cand) {
			q.x += ox;
			q.y += oy;
			rects.push_back(q);
		}
	}

	// ③ 极大行程融合（按块分解会留下 64 的接缝，必须并回去）
	px_merge_pass(rects);

	// ④ 写结果。放不下矩形时只写头（count 在里面），让调用方精确重开。
	CmdWr w;
	w.p = out;
	w.cap = out_cap;
	w.i = 0;
	int32_t count = (int32_t)rects.size();
	// ⚠️⚠️ 空 AABB（有 chunk 但一个像素都没有）必须是**整个** Rect2i()，
	//    不是"位置是哨兵、尺寸为 0"。参照实现是 max_x <= min_x 时整个取 Rect2i()，
	//    而哨兵 1 << 30 会被原样写进 PixelShape 的 AABB 缓存 ——
	//    症状是"形状与碰撞体静默错位"（闸门的"只有空 chunk"用例抓到的）。
	bool aabb_empty = max_x <= min_x;
	w.i32(count);
	w.i32(max_rects > 0 && count > max_rects ? 1 : 0);
	w.i32(aabb_empty ? 0 : px_i32(min_x));
	w.i32(aabb_empty ? 0 : px_i32(min_y));
	w.i32(aabb_empty ? 0 : px_i32(max_x - min_x));
	w.i32(aabb_empty ? 0 : px_i32(max_y - min_y));
	if (HEAD + (size_t)count * 16 <= out_cap) {
		for (const PxRect &q : rects) {
			w.i32(px_i32(q.x));
			w.i32(px_i32(q.y));
			w.i32(px_i32(q.w));
			w.i32(px_i32(q.h));
		}
		written = w.i;
	} else {
		written = HEAD;
	}
}

// ---- op 3 的几何内核：块内泛洪 + 接缝 union-find + 归组 ----
//
// ⚠️⚠️ 这是 src/core/destruction.gd 的 _components_cpu + _group + components 的
//    **第二份实现**，判据只有一条：**逐位相同** —— 同样的分组、同样的顺序、同样的掩码。
//    闸门 tests/validation_components_native.gd。
//    **顺序不同也是不同**：分组顺序 = 节点首次出现的顺序，组内 chunk 顺序 = 首次出现的顺序
//    （参照实现靠 Dictionary 的插入序）。
//
// 为什么值得搬进原生：这条路径是**纯位运算 + 数组**（块内泛洪是 uint64 迭代、
// 接缝是 union-find、归组是拼装），没有 GDScript 特有的语义；
// 而参照实现 768x100（1248 块）要 13.5 ms —— 那还是**已经开了 WorkerThreadPool
// 并行之后**的数字。C++ 这边单线程，赢在每步没有函数调用开销
// （GDScript 一次函数调用 1289 ns、一次 Packed 下标写 23 ns）。

// 与 pixel_bits.gd 的 col_mask / row_mask / MASK_LOW56 同值。
// ⚠️ 0x8080808080808080 这类字面量在 GDScript 里超 int64 上限、只能逐位构造；
//    C++ 的 uint64 能直接写，但**值必须一样**。
static const uint64_t PX_COL0 = 0x0101010101010101ULL;
static const uint64_t PX_COL7 = 0x8080808080808080ULL;
static const uint64_t PX_ROW0 = 0xFFULL;
static const uint64_t PX_ROW7 = 0xFF00000000000000ULL;
static const uint64_t PX_LOW56 = 0x00FFFFFFFFFFFFFFULL;

// Bits.dilate4：4 邻域膨胀一步（跨行/跨块溢出已处理）
static inline uint64_t px_dilate4(uint64_t m) {
	return m | ((m & ~PX_COL7) << 1) | ((m & ~PX_COL0) >> 1) | (m << 8) | ((m >> 8) & PX_LOW56);
}

// Bits.flood：块内 4 邻域连通泛洪。位运算迭代，无分支、无队列。
static inline uint64_t px_flood(uint64_t seed, uint64_t occ) {
	uint64_t f = seed & occ;
	if (f == 0) return 0;
	for (;;) {
		uint64_t nx = px_dilate4(f) & occ;
		if (nx == f) break;
		f = nx;
	}
	return f;
}

// Destruction._find（带路径压缩）
static int32_t px_uf_find(std::vector<int32_t> &parent, int32_t i) {
	int32_t root = i;
	while (parent[(size_t)root] != root) root = parent[(size_t)root];
	while (parent[(size_t)i] != root) {
		int32_t next = parent[(size_t)i];
		parent[(size_t)i] = root;
		i = next;
	}
	return root;
}

// Destruction._union：**小下标当父**。换一种写法分组结果一样，但"逐位相同"
// 是这里的判据 —— 不给自己留解释空间。
static void px_uf_union(std::vector<int32_t> &parent, int32_t a, int32_t b) {
	int32_t ra = px_uf_find(parent, a);
	int32_t rb = px_uf_find(parent, b);
	if (ra == rb) return;
	if (ra < rb) parent[(size_t)rb] = ra;
	else parent[(size_t)ra] = rb;
}

// Destruction._mask_index：第一个包含该 bit 的分量序号，找不到给 0（照抄）
static int32_t px_mask_index(const std::vector<uint64_t> &masks, uint64_t bit) {
	for (size_t i = 0; i < masks.size(); ++i)
		if ((masks[i] & bit) != 0) return (int32_t)i;
	return 0;
}

// op 3：连通分量标注（= Destruction.components()）。
//
//   3  components(i32 n_chunks, { i32 cx, i32 cy, i64 occ } * n_chunks)
//        -> i32 n_groups, i32 total_pairs,
//           { i32 n_pairs, { i32 cx, i32 cy, i64 mask } * n_pairs } * n_groups
//      written = 8 + total_pairs*16；结果段放不下时**只写头**（written = 8，
//      total_pairs 在里面）—— 调用方按它精确重开一次。与 op 2 同一条约定。
//
//      ⚠️ 传 cx/cy 而不是 chunk key：key 的编码（(cx << 32) | (cy & 0xFFFFFFFF)）
//        是 PixelShape 的实现细节，让它只留在 GDScript 一侧（参照实现那边
//        也是 make_key/key_x/key_y 三个函数在管）。
static void run_raster_components(CmdRd &r, uint8_t *out, size_t out_cap, size_t &written) {
	const size_t HEAD = 8;                       // n_groups, total_pairs
	written = 0;
	if (out_cap < HEAD) {
		printf("[PixelRaster] components 结果段太小：out_cap=%zu\n", out_cap);
		return;
	}
	int32_t n = r.i32();
	if (n < 0) n = 0;
	if (!r.ok) return;

	struct CChunk {
		int32_t cx = 0, cy = 0;
		uint64_t occ = 0;
		std::vector<uint64_t> masks;
		std::vector<int32_t> nodes;
	};
	std::vector<CChunk> cs;
	cs.reserve((size_t)n);
	std::unordered_map<uint64_t, int32_t> by_key;
	for (int32_t i = 0; i < n; ++i) {
		int32_t cx = r.i32();
		int32_t cy = r.i32();
		int64_t occ = r.i64();
		if (!r.ok) return;
		CChunk c;
		c.cx = cx;
		c.cy = cy;
		c.occ = (uint64_t)occ;
		// ① 块内分量：反复取**最低置位**当种子 —— 与 _component_slice 同序
		uint64_t remaining = c.occ;
		while (remaining != 0) {
			uint64_t seed = remaining & (~remaining + 1ULL);
			uint64_t comp = px_flood(seed, c.occ);
			c.masks.push_back(comp);
			remaining &= ~comp;
		}
		uint64_t key = (uint64_t)(((int64_t)cx << 32) | (int64_t)(uint32_t)cy);
		by_key.emplace(key, (int32_t)cs.size());
		cs.push_back(std::move(c));
	}
	// ② 节点表：块序 + 块内分量序（= 参照实现的 node_chunk / node_mask）
	std::vector<int32_t> node_chunk;
	std::vector<uint64_t> node_mask;
	for (int32_t i = 0; i < (int32_t)cs.size(); ++i) {
		for (size_t j = 0; j < cs[(size_t)i].masks.size(); ++j) {
			cs[(size_t)i].nodes.push_back((int32_t)node_chunk.size());
			node_chunk.push_back(i);
			node_mask.push_back(cs[(size_t)i].masks[j]);
		}
	}
	int32_t node_count = (int32_t)node_chunk.size();
	std::vector<int32_t> parent((size_t)node_count);
	for (int32_t i = 0; i < node_count; ++i) parent[(size_t)i] = i;
	// ③ 接缝归并：**只查 +X / +Y**（查双向会重复；参照实现就是单向）
	for (int32_t i = 0; i < (int32_t)cs.size(); ++i) {
		CChunk &c = cs[(size_t)i];
		uint64_t rk = (uint64_t)(((int64_t)(c.cx + 1) << 32) | (int64_t)(uint32_t)c.cy);
		auto it = by_key.find(rk);
		if (it != by_key.end()) {
			CChunk &rc = cs[(size_t)it->second];
			uint64_t common = (c.occ & PX_COL7) & ((rc.occ & PX_COL0) << 7);
			// ⚠️ 两边都只有 1 个分量时，连通的 bit 连的都是**同一对节点** ——
			//    逐 bit 跑是纯重复（参照实现里 _group 27.1 ms 九成在这里）。
			if (common != 0) {
				if (c.masks.size() == 1 && rc.masks.size() == 1) {
					px_uf_union(parent, c.nodes[0], rc.nodes[0]);
				} else {
					while (common != 0) {
						int32_t bi = __builtin_ctzll(common);
						px_uf_union(parent,
							c.nodes[(size_t)px_mask_index(c.masks, 1ULL << bi)],
							rc.nodes[(size_t)px_mask_index(rc.masks, 1ULL << (bi - 7))]);
						common &= common - 1;
					}
				}
			}
		}
		uint64_t dk = (uint64_t)(((int64_t)c.cx << 32) | (int64_t)(uint32_t)(c.cy + 1));
		auto it2 = by_key.find(dk);
		if (it2 != by_key.end()) {
			CChunk &dc = cs[(size_t)it2->second];
			uint64_t common = (c.occ & PX_ROW7) & ((dc.occ & PX_ROW0) << 56);
			if (common != 0) {
				if (c.masks.size() == 1 && dc.masks.size() == 1) {
					px_uf_union(parent, c.nodes[0], dc.nodes[0]);
				} else {
					while (common != 0) {
						int32_t bi = __builtin_ctzll(common);
						px_uf_union(parent,
							c.nodes[(size_t)px_mask_index(c.masks, 1ULL << bi)],
							dc.nodes[(size_t)px_mask_index(dc.masks, 1ULL << (bi - 56))]);
						common &= common - 1;
					}
				}
			}
		}
	}
	// ④ 按 root 归组：**顺序 = 节点首次出现的顺序**（参照实现靠 Dictionary 插入序）
	struct CGroup {
		std::vector<int32_t> cix;
		std::vector<uint64_t> mask;
		std::unordered_map<int32_t, size_t> at;
	};
	std::vector<CGroup> groups;
	std::unordered_map<int32_t, int32_t> root_group;
	for (int32_t i = 0; i < node_count; ++i) {
		int32_t root = px_uf_find(parent, i);
		auto it = root_group.find(root);
		int32_t gi;
		if (it == root_group.end()) {
			gi = (int32_t)groups.size();
			root_group.emplace(root, gi);
			groups.push_back(CGroup());
		} else {
			gi = it->second;
		}
		CGroup &g = groups[(size_t)gi];
		int32_t ci = node_chunk[(size_t)i];
		auto it2 = g.at.find(ci);
		if (it2 == g.at.end()) {
			g.at.emplace(ci, g.cix.size());
			g.cix.push_back(ci);
			g.mask.push_back(node_mask[(size_t)i]);
		} else {
			g.mask[it2->second] |= node_mask[(size_t)i];
		}
	}
	// ⑤ 写出
	int32_t n_groups = (int32_t)groups.size();
	int32_t total_pairs = 0;
	for (size_t i = 0; i < groups.size(); ++i) total_pairs += (int32_t)groups[i].cix.size();
	CmdWr w; w.p = out; w.cap = out_cap; w.i = 0;
	w.i32(n_groups);
	w.i32(total_pairs);
	if (HEAD + (size_t)total_pairs * 16 <= out_cap) {
		for (size_t i = 0; i < groups.size(); ++i) {
			const CGroup &g = groups[i];
			w.i32((int32_t)g.cix.size());
			for (size_t j = 0; j < g.cix.size(); ++j) {
				const CChunk &c = cs[(size_t)g.cix[j]];
				w.i32(c.cx);
				w.i32(c.cy);
				int64_t m = (int64_t)g.mask[j];
				w.raw(&m, 8);
			}
		}
		written = w.i;
	} else {
		written = HEAD;
	}
}

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
			case 2: {
				run_raster_decompose(r, out, out_cap, written);
				break;
			}
			case 3: {
				run_raster_components(r, out, out_cap, written);
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

// 与 fill_region **同一个签名**（2 个 PackedByteArray -> PackedByteArray），
// 分派靠命令流里的 op 字节。之所以还是两个方法：GDScript 侧要能
// has_method("decompose") 判断 DLL 是不是太旧（老 DLL 里没有它）。
static void call_raster_decompose(void *method_userdata, GDExtensionClassInstancePtr p_instance,
		const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count,
		GDExtensionVariantPtr r_return, GDExtensionCallError *r_error) {
	(void)p_instance;
	call_cmd_glue(raster_dispatch, nullptr, p_args, p_argument_count, r_return, r_error);
}

// 与 fill_region / decompose 同一个签名，第三个方法名只是为了
// has_method("components") 能判断 DLL 是不是太旧。
static void call_raster_components(void *method_userdata, GDExtensionClassInstancePtr p_instance,
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

	// decompose：签名与 fill_region 相同（参数名/返回名也复用同一组 PropertyInfo）
	GDExtensionClassMethodInfo mi2 = mi;
	mi2.name = (GDExtensionStringNamePtr)g_sn_pxr_decomp.buf;
	mi2.call_func = call_raster_decompose;
	g_register_method(g_library, (GDExtensionConstStringNamePtr)g_sn_pxr_class.buf, &mi2);
	printf("[PixelRaster] 已注册方法 decompose\n");

	GDExtensionClassMethodInfo mi3 = mi;
	mi3.name = (GDExtensionStringNamePtr)g_sn_pxr_comp.buf;
	mi3.call_func = call_raster_components;
	g_register_method(g_library, (GDExtensionConstStringNamePtr)g_sn_pxr_class.buf, &mi3);
	printf("[PixelRaster] 已注册方法 components\n");
}


// ================= PixelFluid：PBF 粒子流体（纯 CPU，不依赖 Rapier） =================
//
// 语义真源是 src/fluid/fluid_pbf.gd —— **判据只有一条：逐位相同**
// （闸门 tests/validation_fluid.gd）。所以这里每一步都照着那份抄，
// 注释里标出对应的函数名。浮点能逐位一致的前提是构建带了 -ffp-contract=off
// （见 tools/build_native.py 与 README 的构建段）：少了它编译器会把乘加融成 FMA，
// 两条路径立刻分叉。
//
// 为什么值得搬进原生：GDScript 参照实现实测 **1.18 ms/步**（130 粒子 / 17x18 格，
// 300 步 354 ms）。瓶子那边要 700+ 粒子、网格也大一倍 —— GDScript 是 10~20 ms/步，
// 每帧都跑不动。
//
// 命令流（头部协议与 RapierPhys.cmd 相同：in = [i32 out_cap][i32 cmd_len][ops...]）：
//   1  step(i32 n, i32 nx, i32 ny, i32 push_iters, i32 grid_iters,
//           f64 spacing, radius, dt, bouncyness, over_relaxation, stiffness,
//           flip_ratio, gx, gy, splat_radius,
//           u8 solid[nx*ny], f64 pos[2n], f64 vel[2n])
//        -> f64 pos[2n], f64 vel[2n], f64 rest_density, u8 ink[nx*ny]
//      written = 32n + 8 + nx*ny
//
// ⚠️ 网格索引是 **INDEX(x,y) = x*ny + y**（x 主序），与参照实现一致 ——
//    push_apart 靠"同一列的相邻单元在数组里连续"把整列 3 格合并成一次遍历。
//    改成行主序会让那个合并失效，而且结果会变。别改。
//
// ⚠️ 实例**持有**网格临时缓冲（它们是每步从 pos/vel 重算的，不是第二份真源），
//    但 pos/vel 的权威副本在 GDScript 侧 —— 每步都传进来、传回去。
//    只有 rest_density 和 uPrev/vPrev 是跨步携带的，两边各自维护、同步更新。

static const uint8_t PBF_AIR = 1;
static const uint8_t PBF_FLUID = 0;
static const uint8_t PBF_SOLID = 2;

static inline int pbf_clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline double pbf_clampd(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

struct FluidInstance {
	int nx = 0, ny = 0;
	// ⚠️ **权威状态在原生这边**（pos/vel/参数/掩码都由 op 1 灌一次）。
	//    每步只回吐 ink 掩码 —— 这是"每步 500 KB 往返"变"10 KB"的关键：
	//    4320 粒子时 pos+vel 是 138 KB，加上 slice/to_float64_array 的拷贝与分配，
	//    GDScript 侧每步要付 ~2.5 ms，而模拟本身只要 ~1 ms。
	int n = 0;
	int push_iters = 1, grid_iters = 8;
	double spacing = 0.041, radius = 0.019;
	double bouncy = -0.9, over_relax = 1.9, stiffness = 1.0, flip_ratio = 0.9;
	std::vector<uint8_t> solid;
	std::vector<uint8_t> ctype;
	std::vector<uint8_t> ink;
	std::vector<uint8_t> ink_src;      // 闭运算要"边写边判"用不了，先存一份原样
	std::vector<uint8_t> seen;         // 围棋闭运算的"有气"标记
	std::vector<int32_t> stack;        // 泛洪栈（复用，别每帧分配）
	std::vector<double> pos, vel;
	std::vector<double> f, w, fprev;      // 2*ncells：前半 u 分量，后半 v 分量
	std::vector<double> density, pscale, dcorr;
	std::vector<int32_t> fluidcells, cellprefix, pids, pcell;
	double rest_density = 0.0;

	void resize(int nx_, int ny_) {
		if (nx == nx_ && ny == ny_) return;
		nx = nx_; ny = ny_;
		const size_t nc = (size_t)nx * (size_t)ny;
		solid.assign(nc, 0);
		ctype.assign(nc, 0);
		ink.assign(nc, 0);
		ink_src.assign(nc, 0);
		seen.assign(nc, 0);
		stack.clear();
		f.assign(nc * 2, 0.0);
		w.assign(nc * 2, 0.0);
		fprev.assign(nc * 2, 0.0);
		density.assign(nc, 0.0);
		pscale.assign(nc, 0.0);
		dcorr.assign(nc, 0.0);
		cellprefix.assign(nc + 1, 0);
		fluidcells.clear();
		// 尺寸变了，旧的静止密度基准就没有意义了。尺寸没变时**不清** ——
		// 它是压力的基准，只应该在真正重建时重置（与参照实现的 resize_grid 同义）。
		rest_density = 0.0;
	}
};

// grid_to_particles 里的四路采样：把一条 if 抽出来，避免写四遍（写四遍就是
// "同一规则写四处"，而这里的判据是逐位对拍）。运算顺序与参照实现一字不差。
static inline void pbf_gather(const uint8_t *ctype, const double *F, const double *FP,
		size_t base, int nrk, int offset, double dk,
		double &d, double &picn, double &corrn) {
	if (ctype[nrk] != PBF_AIR || ((nrk - offset >= 0) && ctype[nrk - offset] != PBF_AIR)) {
		d += dk;
		picn += dk * F[base + (size_t)nrk];
		corrn += dk * (F[base + (size_t)nrk] - FP[base + (size_t)nrk]);
	}
}

// 把落在**固体格**里的粒子搬回最近的可通行格心（与 fluid_pbf.gd 的 _contain_particles 同判据）。
//
// ⚠️ 参照实现没有这一步，因为它的域钳位（minX..maxX）和那一圈边界**正好重合** ——
//    粒子不可能跑到"容器外"。容器一旦有形状（瓶子剪影），两者就不重合了：
//    粒子会漂进不该有液体的格子，而压力求解跳过固体格、grid_to_particles 也不会
//    把它们推出来，于是它们**永久卡在那里**，还继续占着 fill_ratio 的份额。
//
// ⚠️ 这一条**不碰压力求解** —— 那边早就在按 solidMask 判断四个面是不是墙了。
//    所以 overRelaxation / stiffness / flipRatio 那几个标定值继续有效。
//
// 判据刻意写得笨：固定搜 9x9 方窗，取距离最小的可通行格心，平局时**先扫到的赢**。
// 笨才可复现 —— 闸门是 C++ 与 GDScript 逐位对拍。
static void pbf_contain(FluidInstance *S, double *P, int n, double spacing) {
	const int nx = S->nx, ny = S->ny;
	const uint8_t *SM = S->solid.data();
	for (int i = 0; i < n; ++i) {
		const double px = P[(size_t)i * 2];
		const double py = P[(size_t)i * 2 + 1];
		const int cx = pbf_clampi((int)(px / spacing), 0, nx - 1);
		const int cy = pbf_clampi((int)(py / spacing), 0, ny - 1);
		if (SM[cx * ny + cy] != 0) continue;
		int best = -1;
		double best_d2 = 0.0;
		for (int dy = -4; dy <= 4; ++dy) {
			const int ty = cy + dy;
			if (ty < 0 || ty >= ny) continue;
			for (int dx = -4; dx <= 4; ++dx) {
				const int tx = cx + dx;
				if (tx < 0 || tx >= nx) continue;
				const int tc = tx * ny + ty;
				if (SM[tc] == 0) continue;
				const double gx = ((double)tx + 0.5) * spacing;
				const double gy = ((double)ty + 0.5) * spacing;
				const double d2 = (gx - px) * (gx - px) + (gy - py) * (gy - py);
				if (best < 0 || d2 < best_d2) { best = tc; best_d2 = d2; }
			}
		}
		if (best >= 0) {
			P[(size_t)i * 2] = ((double)(best / ny) + 0.5) * spacing;
			P[(size_t)i * 2 + 1] = ((double)(best % ny) + 0.5) * spacing;
		}
	}
}

static void fluid_do_step(FluidInstance *S, int n, double spacing, double radius, double dt,
		double bouncy, double over_relax, double stiffness, double flip_ratio,
		int push_iters, int grid_iters, double gx, double gy, double splat_radius) {
	const int nx = S->nx, ny = S->ny;
	const size_t nc = (size_t)nx * (size_t)ny;
	double *P = S->pos.data();
	double *V = S->vel.data();
	// ⚠️ 域钳位是 r .. num*h - r，与参照实现的 h+r .. (num-1)*h-r **不同**：
	//    参照实现多缩一格是因为它的容器就是那个矩形网格、外圈一格是实心边界。
	//    掩码容器的墙就是域的边 —— 照抄会让第 0 行/列永远够不着（四周一条缝）。
	//    外圈若真是实心的，pbf_contain 会把粒子推回来。
	const double minx = radius, miny = radius;
	const double maxx = (double)nx * spacing - radius;
	const double maxy = (double)ny * spacing - radius;

	// ---- 1. integrate ----
	{
		const double dvx = gx * dt, dvy = gy * dt;
		for (int i = 0; i < n; ++i) {
			const size_t k = (size_t)i * 2;
			V[k] += dvx;
			V[k + 1] += dvy;
			P[k] += V[k] * dt;
			P[k + 1] += V[k + 1] * dt;
			double x = P[k], y = P[k + 1];
			if (x < minx) { x = minx; V[k] = V[k] * bouncy; }
			if (x > maxx) { x = maxx; V[k] = V[k] * bouncy; }
			if (y < miny) { y = miny; V[k + 1] = V[k + 1] * bouncy; }
			if (y > maxy) { y = maxy; V[k + 1] = V[k + 1] * bouncy; }
			P[k] = x;
			P[k + 1] = y;
		}
	}

	// ---- 2. push_apart ----
	if (n > 0) {
		S->pids.resize((size_t)n);
		S->pcell.resize((size_t)n);
		for (size_t i = 0; i < nc; ++i) S->cellprefix[i] = 0;
		for (int i = 0; i < n; ++i) {
			const int xi = pbf_clampi((int)(P[(size_t)i * 2] / spacing), 0, nx - 1);
			const int yi = pbf_clampi((int)(P[(size_t)i * 2 + 1] / spacing), 0, ny - 1);
			const int c = xi * ny + yi;
			S->pcell[(size_t)i] = c;
			S->cellprefix[(size_t)c] += 1;
		}
		int32_t prefix = 0;
		for (size_t i = 0; i < nc; ++i) { prefix += S->cellprefix[i]; S->cellprefix[i] = prefix; }
		S->cellprefix[nc] = prefix;
		for (int i = 0; i < n; ++i) {
			const int c = S->pcell[(size_t)i];
			S->cellprefix[(size_t)c] -= 1;
			S->pids[(size_t)S->cellprefix[(size_t)c]] = i;
		}
		const double min_dist = 2.0 * radius;
		const double min_dist2 = min_dist * min_dist;
		for (int it = 0; it < push_iters; ++it) {
			for (int i = 0; i < n; ++i) {
				double px = P[(size_t)i * 2], py = P[(size_t)i * 2 + 1];
				const int pxi = pbf_clampi((int)(px / spacing), 0, nx - 1);
				const int pyi = pbf_clampi((int)(py / spacing), 0, ny - 1);
				const int x0 = pxi > 0 ? pxi - 1 : 0;
				const int y0 = pyi > 0 ? pyi - 1 : 0;
				const int x1 = (pxi + 1 < nx) ? pxi + 1 : nx - 1;
				const int y1 = (pyi + 1 < ny) ? pyi + 1 : ny - 1;
				for (int xi = x0; xi <= x1; ++xi) {
					// 同一列的相邻单元在 pids 里连续（INDEX 是 x 主序），
					// 所以"整列 3 格"合并成一次区间遍历 —— 参照实现的关键优化。
					const int32_t first = S->cellprefix[(size_t)(xi * ny + y0)];
					const int32_t last = S->cellprefix[(size_t)(xi * ny + y1 + 1)];
					for (int32_t j = first; j < last; ++j) {
						const int id = S->pids[(size_t)j];
						if (id == i) continue;
						double dx = P[(size_t)id * 2] - px;
						double dy = P[(size_t)id * 2 + 1] - py;
						const double d2 = dx * dx + dy * dy;
						if (d2 > min_dist2 || d2 == 0.0) continue;
						const double d = std::sqrt(d2);
						const double s = 0.5 * (min_dist - d) / d;
						dx *= s;
						dy *= s;
						px -= dx;
						py -= dy;
						P[(size_t)id * 2] += dx;
						P[(size_t)id * 2 + 1] += dy;
					}
				}
				P[(size_t)i * 2] = px;
				P[(size_t)i * 2 + 1] = py;
			}
		}
		// 撞壁（参照实现把 HandleParticleCollisions 并进了这里，integrate 里也做了一次）
		for (int i = 0; i < n; ++i) {
			double x = P[(size_t)i * 2], y = P[(size_t)i * 2 + 1];
			if (x < minx) { x = minx; V[(size_t)i * 2] = V[(size_t)i * 2] * bouncy; }
			if (x > maxx) { x = maxx; V[(size_t)i * 2] = V[(size_t)i * 2] * bouncy; }
			if (y < miny) { y = miny; V[(size_t)i * 2 + 1] = V[(size_t)i * 2 + 1] * bouncy; }
			if (y > maxy) { y = maxy; V[(size_t)i * 2 + 1] = V[(size_t)i * 2 + 1] * bouncy; }
			P[(size_t)i * 2] = x;
			P[(size_t)i * 2 + 1] = y;
		}
		pbf_contain(S, P, n, spacing);
	}

	// ---- 3. particles_to_grid（交错半格采样：u 在 (x, y-h/2)，v 在 (x-h/2, y)）----
	{
		double *F = S->f.data();
		double *W = S->w.data();
		uint8_t *CT = S->ctype.data();
		for (size_t i = 0; i < nc; ++i) {
			F[i] = 0.0; F[nc + i] = 0.0;
			W[i] = 0.0; W[nc + i] = 0.0;
			CT[i] = (S->solid[i] == 0) ? PBF_SOLID : PBF_AIR;
		}
		for (int i = 0; i < n; ++i) {
			const int xi = pbf_clampi((int)(P[(size_t)i * 2] / spacing), 0, nx - 1);
			const int yi = pbf_clampi((int)(P[(size_t)i * 2 + 1] / spacing), 0, ny - 1);
			CT[xi * ny + yi] = PBF_FLUID;
		}
		for (int component = 0; component < 2; ++component) {
			const size_t base = (size_t)component * nc;
			const double off_x = (component == 0) ? 0.0 : spacing * 0.5;
			const double off_y = (component == 0) ? spacing * 0.5 : 0.0;
			for (int i = 0; i < n; ++i) {
				const double x = pbf_clampd(P[(size_t)i * 2], spacing, (double)(nx - 1) * spacing);
				const double y = pbf_clampd(P[(size_t)i * 2 + 1], spacing, (double)(ny - 1) * spacing);
				const int x0 = pbf_clampi((int)((x - off_x) / spacing), 0, nx - 2);
				const int y0 = pbf_clampi((int)((y - off_y) / spacing), 0, ny - 2);
				const double tx = ((x - off_x) - (double)x0 * spacing) / spacing;
				const double ty = ((y - off_y) - (double)y0 * spacing) / spacing;
				const double sx = 1.0 - tx, sy = 1.0 - ty;
				const double w0 = sx * sy, w1 = tx * sy, w2 = tx * ty, w3 = sx * ty;
				const double pv = V[(size_t)i * 2 + component];
				const size_t nr0 = (size_t)(x0 * ny + y0);
				const size_t nr1 = (size_t)((x0 + 1) * ny + y0);
				const size_t nr2 = (size_t)((x0 + 1) * ny + (y0 + 1));
				const size_t nr3 = (size_t)(x0 * ny + (y0 + 1));
				F[base + nr0] += pv * w0; W[base + nr0] += w0;
				F[base + nr1] += pv * w1; W[base + nr1] += w1;
				F[base + nr2] += pv * w2; W[base + nr2] += w2;
				F[base + nr3] += pv * w3; W[base + nr3] += w3;
			}
			for (size_t i = 0; i < nc; ++i) {
				if (W[base + i] > 0.0) F[base + i] = F[base + i] / W[base + i];
			}
			// 固体面：速度取上一帧的网格值（无滑移的近似）。参照实现就是取 uPrev。
			for (int x = 0; x < nx; ++x) {
				for (int y = 0; y < ny; ++y) {
					const size_t idx = (size_t)(x * ny + y);
					if (component == 0) {
						const bool is_solid = CT[idx] == PBF_SOLID;
						const bool left_solid = (x > 0) && (CT[(size_t)((x - 1) * ny + y)] == PBF_SOLID);
						if (is_solid || left_solid) F[idx] = S->fprev[idx];
					} else {
						const bool is_solid = CT[idx] == PBF_SOLID;
						const bool bottom_solid = (y > 0) && (CT[(size_t)(x * ny + (y - 1))] == PBF_SOLID);
						if (is_solid || bottom_solid) F[nc + idx] = S->fprev[nc + idx];
					}
				}
			}
		}
		// 流体单元列表。**扫描顺序 x 外 y 内** —— 与参照实现同序：松弛是 Gauss-Seidel，
		// 迭代顺序会进结果，所以这个顺序也是逐位对拍的一部分。
		S->fluidcells.clear();
		for (int x = 1; x < nx - 1; ++x) {
			for (int y = 1; y < ny - 1; ++y) {
				const size_t idx = (size_t)(x * ny + y);
				if (CT[idx] == PBF_FLUID) S->fluidcells.push_back((int32_t)idx);
			}
		}
	}

	// ---- 4. density_update ----
	{
		double *D = S->density.data();
		for (size_t i = 0; i < nc; ++i) D[i] = 0.0;
		const double off = spacing * 0.5;
		for (int i = 0; i < n; ++i) {
			const double x = pbf_clampd(P[(size_t)i * 2], spacing, (double)(nx - 1) * spacing);
			const double y = pbf_clampd(P[(size_t)i * 2 + 1], spacing, (double)(ny - 1) * spacing);
			const int x0 = pbf_clampi((int)((x - off) / spacing), 0, nx - 2);
			const int y0 = pbf_clampi((int)((y - off) / spacing), 0, ny - 2);
			const double tx = ((x - off) - (double)x0 * spacing) / spacing;
			const double ty = ((y - off) - (double)y0 * spacing) / spacing;
			const double sx = 1.0 - tx, sy = 1.0 - ty;
			D[x0 * ny + y0] += sx * sy;
			D[(x0 + 1) * ny + y0] += tx * sy;
			D[(x0 + 1) * ny + (y0 + 1)] += tx * ty;
			D[x0 * ny + (y0 + 1)] += sx * ty;
		}
		if (S->rest_density == 0.0) {
			double sum = 0.0;
			int num_fluid = 0;
			for (size_t i = 0; i < nc; ++i) {
				if (S->ctype[i] == PBF_FLUID) { sum += D[i]; num_fluid += 1; }
			}
			if (num_fluid > 0) S->rest_density = sum / (double)num_fluid;
		}
	}

	// ---- 5. grid_forces ----
	{
		double *F = S->f.data();
		double *FP = S->fprev.data();
		for (size_t i = 0; i < nc * 2; ++i) FP[i] = F[i];
		const size_t m = S->fluidcells.size();
		for (size_t k = 0; k < m; ++k) {
			const size_t center = (size_t)S->fluidcells[k];
			const int s = S->solid[center - (size_t)ny] + S->solid[center + (size_t)ny]
					+ S->solid[center - 1] + S->solid[center + 1];
			S->pscale[center] = -over_relax / (double)s;
			const double compression = (S->rest_density > 0.0)
					? (S->density[center] - S->rest_density) : 0.0;
			S->dcorr[center] = (compression > 0.0) ? compression * stiffness : 0.0;
		}
		for (int it = 0; it < grid_iters; ++it) {
			for (size_t k = 0; k < m; ++k) {
				const size_t center = (size_t)S->fluidcells[k];
				const double ps = S->pscale[center];
				if (ps == 0.0) continue;
				const size_t left = center - (size_t)ny, right = center + (size_t)ny;
				const size_t bottom = center - 1, top = center + 1;
				double div = F[right] - F[center] + F[nc + top] - F[nc + center];
				div -= S->dcorr[center];
				const double p = div * ps;
				if (S->solid[left] != 0) F[center] -= p;
				if (S->solid[right] != 0) F[right] += p;
				if (S->solid[bottom] != 0) F[nc + center] -= p;
				if (S->solid[top] != 0) F[nc + top] += p;
			}
		}
	}

	// ---- 6. grid_to_particles（FLIP/PIC 混合）----
	{
		double *F = S->f.data();
		double *FP = S->fprev.data();
		const uint8_t *CT = S->ctype.data();
		for (int component = 0; component < 2; ++component) {
			const size_t base = (size_t)component * nc;
			const int offset = (component == 0) ? ny : 1;
			const double off_x = (component == 0) ? 0.0 : spacing * 0.5;
			const double off_y = (component == 0) ? spacing * 0.5 : 0.0;
			for (int i = 0; i < n; ++i) {
				const double x = pbf_clampd(P[(size_t)i * 2], spacing, (double)(nx - 1) * spacing);
				const double y = pbf_clampd(P[(size_t)i * 2 + 1], spacing, (double)(ny - 1) * spacing);
				const int x0 = pbf_clampi((int)((x - off_x) / spacing), 0, nx - 2);
				const int y0 = pbf_clampi((int)((y - off_y) / spacing), 0, ny - 2);
				const double tx = ((x - off_x) - (double)x0 * spacing) / spacing;
				const double ty = ((y - off_y) - (double)y0 * spacing) / spacing;
				const double sx = 1.0 - tx, sy = 1.0 - ty;
				const double d0 = sx * sy, d1 = tx * sy, d2 = tx * ty, d3 = sx * ty;
				const int nr0 = x0 * ny + y0;
				const int nr1 = (x0 + 1) * ny + y0;
				const int nr2 = (x0 + 1) * ny + (y0 + 1);
				const int nr3 = x0 * ny + (y0 + 1);
				double d = 0.0, picn = 0.0, corrn = 0.0;
				pbf_gather(CT, F, FP, base, nr0, offset, d0, d, picn, corrn);
				pbf_gather(CT, F, FP, base, nr1, offset, d1, d, picn, corrn);
				pbf_gather(CT, F, FP, base, nr2, offset, d2, d, picn, corrn);
				pbf_gather(CT, F, FP, base, nr3, offset, d3, d, picn, corrn);
				if (d <= 0.0) continue;
				const double inv_d = 1.0 / d;
				const double pic_v = picn * inv_d;
				const double corr = corrn * inv_d;
				const double old_v = V[(size_t)i * 2 + component];
				V[(size_t)i * 2 + component] = (1.0 - flip_ratio) * pic_v + flip_ratio * (old_v + corr);
			}
		}
	}

	// ---- 7. raster_ink（渲染，不影响物理）----
	{
		uint8_t *INK = S->ink.data();
		for (size_t i = 0; i < nc; ++i) INK[i] = 0;
		double rc = splat_radius;
		if (rc <= 0.0) {
			// 只标所在格（与 fluid_pbf.gd 的 _raster_ink 同判据）。
			// ⚠️ 粒子离自己格心最远 0.707（格角），所以这里**不能用半径判据** ——
			//    用 0.463（= radius/spacing）会让大部分粒子一格都标不上。
			for (int i = 0; i < n; ++i) {
				const int cx = pbf_clampi((int)(P[(size_t)i * 2] / spacing), 0, nx - 1);
				const int cy = pbf_clampi((int)(P[(size_t)i * 2 + 1] / spacing), 0, ny - 1);
				const int c = cx * ny + cy;
				if (S->solid[c] != 0) INK[c] = 1;
			}
			return;
		}
		const double rc2 = rc * rc;
		for (int i = 0; i < n; ++i) {
			const double px = P[(size_t)i * 2] / spacing;
			const double py = P[(size_t)i * 2 + 1] / spacing;
			int x0 = (int)(px - rc); if (x0 < 0) x0 = 0;
			int x1 = (int)(px + rc) + 1; if (x1 > nx - 1) x1 = nx - 1;
			int y0 = (int)(py - rc); if (y0 < 0) y0 = 0;
			int y1 = (int)(py + rc) + 1; if (y1 > ny - 1) y1 = ny - 1;
			for (int x = x0; x <= x1; ++x) {
				for (int y = y0; y <= y1; ++y) {
					const double dx = ((double)x + 0.5) - px;
					const double dy = ((double)y + 0.5) - py;
					// 与掩码取交：粒子贴近容器边缘时，它的泼溅半径会溢出到容器外 ——
					// 那会让液体看起来"糊出瓶壁"。
					if (dx * dx + dy * dy <= rc2 && S->solid[x * ny + y] != 0) INK[x * ny + y] = 1;
				}
			}
		}
		// 闭运算（**围棋规则：没气就填**）—— 与 fluid_pbf.gd 的 _close_ink 同判据。
		//
		// 从"贴着容器外沿的空格"泛洪，走不到的空格就是没气 -> 填上。
		// ⚠️ 第一版用的是局部判据"四邻里 >= 3 个是墨" —— 那在凹口、拐角、
		//    两格宽的缝隙上都会给出错的结果（要么漏填要么糊出边界）。
		//    "有没有气"是全局的、定义明确的。
		// ⚠️ 种子不是"整张图的四边"：容器外的格子本来就该是空的，
		//    拿它们当种子等于把容器内的封闭空腔也判成有气，那样一格都填不上。
		uint8_t *SRC = S->ink_src.data();
		std::memcpy(SRC, INK, nc);
		uint8_t *SEEN = S->seen.data();
		std::memset(SEEN, 0, nc);
		std::vector<int32_t> &stk = S->stack;
		stk.clear();
		for (int x = 0; x < nx; ++x) {
			for (int y = 0; y < ny; ++y) {
				const int c = x * ny + y;
				if (SRC[c] != 0 || SEEN[c] != 0) continue;
				bool edge = (x == 0 || x + 1 == nx || y == 0 || y + 1 == ny);
				if (!edge) {
					edge = (S->solid[c - ny] == 0 || S->solid[c + ny] == 0
							|| S->solid[c - 1] == 0 || S->solid[c + 1] == 0);
				}
				if (!edge) continue;
				SEEN[c] = 1;
				stk.push_back(c);
			}
		}
		while (!stk.empty()) {
			const int c = stk.back();
			stk.pop_back();
			const int x = c / ny, y = c % ny;
			const int nb[4] = { (x > 0) ? c - ny : -1, (x + 1 < nx) ? c + ny : -1,
					(y > 0) ? c - 1 : -1, (y + 1 < ny) ? c + 1 : -1 };
			for (int k = 0; k < 4; ++k) {
				const int q = nb[k];
				if (q < 0 || SEEN[q] != 0 || SRC[q] != 0 || S->solid[q] == 0) continue;
				SEEN[q] = 1;
				stk.push_back(q);
			}
		}
		for (size_t c = 0; c < nc; ++c) {
			if (SRC[c] == 0 && SEEN[c] == 0 && S->solid[c] != 0) INK[c] = 1;
		}
	}
}

static void run_fluid_cmd(FluidInstance *S, const uint8_t *in, size_t in_n,
		uint8_t *out, size_t out_cap, size_t &written) {
	written = 0;
	CmdWr w; w.p = out; w.cap = out_cap; w.i = 0;
	CmdRd r; r.p = in; r.n = in_n; r.i = 0;
	while (r.ok && r.i < r.n) {
		const uint8_t op = r.u8();
		if (!r.ok) break;
		switch (op) {
			// 1  load：把权威状态灌进来（粒子集 / 掩码 / 参数变了才发），**不产出**
			case 1: {
				int32_t n = r.i32();
				const int32_t nx = r.i32();
				const int32_t ny = r.i32();
				const int32_t pi = r.i32();
				const int32_t gi = r.i32();
				const double sp = r.f64(), ra = r.f64();
				const double bo = r.f64(), ov = r.f64();
				const double st = r.f64(), fl = r.f64();
				if (!r.ok) break;
				if (n < 0) n = 0;
				if (nx < 3 || ny < 3) {
					printf("[PixelFluid] 网格太小：%dx%d（至少要 3x3）\n", (int)nx, (int)ny);
					r.ok = false;
					break;
				}
				const size_t nc = (size_t)nx * (size_t)ny;
				S->resize(nx, ny);
				S->push_iters = pi;
				S->grid_iters = gi;
				S->spacing = sp;
				S->radius = ra;
				S->bouncy = bo;
				S->over_relax = ov;
				S->stiffness = st;
				S->flip_ratio = fl;
				const uint8_t *solid = r.bytes(nc);
				if (!r.ok) break;
				std::memcpy(S->solid.data(), solid, nc);
				S->pos.resize((size_t)n * 2);
				S->vel.resize((size_t)n * 2);
				if (!r.f64s((size_t)n * 2, S->pos.data())) break;
				if (!r.f64s((size_t)n * 2, S->vel.data())) break;
				S->n = n;
				break;
			}
			// 2  step：每步只收 4 个 f64，**只吐 ink 掩码**
			case 2: {
				const double dt = r.f64(), gx = r.f64(), gy = r.f64(), sr = r.f64();
				if (!r.ok) break;
				const size_t nc = (size_t)S->nx * (size_t)S->ny;
				if (nc > out_cap) {
					printf("[PixelFluid] 结果段容量不够：need=%zu out_cap=%zu\n", nc, out_cap);
					r.ok = false;
					break;
				}
				fluid_do_step(S, S->n, S->spacing, S->radius, dt, S->bouncy, S->over_relax,
						S->stiffness, S->flip_ratio, S->push_iters, S->grid_iters,
						gx, gy, sr);
				w.raw(S->ink.data(), nc);
				written = w.i;
				break;
			}
			// 3  dump：把 pos/vel 回吐给 GDScript（只在它真要读粒子时才发）
			case 3: {
				const size_t bytes = (size_t)S->n * 16;   // 2n 个 f64
				if (bytes * 2 + 8 > out_cap) {
					printf("[PixelFluid] dump 容量不够：need=%zu out_cap=%zu\n", bytes * 2 + 8, out_cap);
					r.ok = false;
					break;
				}
				w.raw(S->pos.data(), bytes);
				w.raw(S->vel.data(), bytes);
				// rest_density 也要带回来：它由原生首帧定出、之后不再变，
				// GDScript 那份不跟着同步就永远是 0（而 0 会被读成"还没定出"）。
				w.f64(S->rest_density);
				written = w.i;
				break;
			}
			default:
				// 与 RapierPhys / PixelRaster 同一条规矩：未知操作码**立刻停**
				// （它的载荷长度未知，继续读会把后面的字节当操作码，整条流错位）
				printf("[PixelFluid] 未知操作码 %d（命令流错位），就此中止\n", (int)op);
				r.ok = false;
				break;
		}
	}
	if (written > out_cap) {
		printf("[PixelFluid] 结果段越界：written=%zu > out_cap=%zu（命令流很可能错位）\n",
				written, out_cap);
	}
}

// PixelFluid 自己的一组 StringName。
// ⚠️ 不复用 RapierPhys / PixelRaster 那几个缓冲区：复用会让类的名字互相覆盖，
//    注册出来的签名静默错位（症状是"调用时参数对不上"）。
static SN g_sn_pf_class, g_sn_pf_step, g_sn_pf_a0, g_sn_pf_a1, g_sn_pf_ret;

static GDExtensionObjectPtr create_fluid_instance(void *p_userdata, GDExtensionBool p_notify_postinitialize) {
	GDExtensionObjectPtr obj = g_construct_object((GDExtensionConstStringNamePtr)g_sn_parent.buf);
	if (obj == nullptr) return nullptr;
	FluidInstance *d = new FluidInstance();
	g_object_set_instance(obj, (GDExtensionConstStringNamePtr)g_sn_pf_class.buf, (GDExtensionClassInstancePtr)d);
	return obj;
}

static void free_fluid_instance(void *p_userdata, GDExtensionClassInstancePtr p_instance) {
	if (p_instance != nullptr) delete (FluidInstance *)p_instance;
}

static void fluid_dispatch(void *ctx, const uint8_t *in, size_t in_n,
		uint8_t *out, size_t out_cap, size_t &written) {
	run_fluid_cmd((FluidInstance *)ctx, in, in_n, out, out_cap, written);
}

static void call_fluid_step(void *method_userdata, GDExtensionClassInstancePtr p_instance,
		const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count,
		GDExtensionVariantPtr r_return, GDExtensionCallError *r_error) {
	call_cmd_glue(fluid_dispatch, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void register_pixel_fluid() {
	GDExtensionClassCreationInfo6 info = {};
	info.is_virtual = false;
	info.is_abstract = false;
	info.is_exposed = true;
	info.is_runtime = false;
	info.create_instance_func = create_fluid_instance;
	info.free_instance_func = free_fluid_instance;
	g_register_class6(g_library, (GDExtensionConstStringNamePtr)g_sn_pf_class.buf,
		(GDExtensionConstStringNamePtr)g_sn_parent.buf, &info);
	printf("[PixelFluid] 类已注册\n");

	GDExtensionClassMethodInfo mi = {};
	mi.name = (GDExtensionStringNamePtr)g_sn_pf_step.buf;
	mi.call_func = call_fluid_step;
	mi.ptrcall_func = nullptr;
	mi.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
	mi.has_return_value = true;
	static GDExtensionPropertyInfo ret_info = {};
	ret_info.type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	ret_info.name = (GDExtensionStringNamePtr)g_sn_pf_ret.buf;
	ret_info.class_name = (GDExtensionStringNamePtr)g_sn_empty_class.buf;
	ret_info.hint_string = (GDExtensionStringPtr)g_str_empty_hint;
	mi.return_value_info = &ret_info;
	mi.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE;
	static GDExtensionPropertyInfo args[2] = {};
	args[0].type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	args[0].name = (GDExtensionStringNamePtr)g_sn_pf_a0.buf;
	args[1].type = GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY;
	args[1].name = (GDExtensionStringNamePtr)g_sn_pf_a1.buf;
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
	g_register_method(g_library, (GDExtensionConstStringNamePtr)g_sn_pf_class.buf, &mi);
	printf("[PixelFluid] 已注册方法 step\n");
}


static void initialize(void *p_userdata, GDExtensionInitializationLevel p_level) {
	if (p_level != GDEXTENSION_INITIALIZATION_SCENE) return;
	GDExtensionClassCreationInfo6 info = {};
	info.is_virtual = false;
	info.is_abstract = false;
	info.is_exposed = true;
	info.is_runtime = false;
	// 三个类各自注册自己的类与实例（都继承 RefCounted）：
	//   RapierPhys  —— 物理
	//   PixelRaster —— 渲染栅格化（不依赖 Rapier）
	//   PixelFluid  —— PBF 粒子流体（不依赖 Rapier）
	register_rapier_phys();
	register_pixel_raster();
	register_pixel_fluid();
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
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_decomp.buf, "decompose");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_comp.buf, "components");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_a0.buf, "input");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_a1.buf, "out_template");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pxr_ret.buf, "result");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_class.buf, "PixelFluid");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_step.buf, "step");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_a0.buf, "input");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_a1.buf, "out_template");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_ret.buf, "result");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_empty_class.buf, "");
	g_str_new((GDExtensionUninitializedStringPtr)g_str_empty_hint, "");
	// PackedByteArray 的构造索引 1 = 拷贝构造
	g_pba_copy_ctor = g_get_ctor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 1);
	if (!g_pba_copy_ctor) { printf("[FastPhys] 拿不到 PackedByteArray 构造函数\n"); return 0; }
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
	// ⚠️ variant_get_ptr_destructor 对 POD 类型（int/float…）返回 **null** —— 它们没有析构函数。
	// 所以可空项要分开判断，不能一起当"必需"。
	if (!g_pba_from_variant || !g_pba_to_variant || !g_pba_destructor) {
		printf("[FastPhys] Variant 转换函数解析失败: from=%p to=%p dtor=%p\n",
			(void *)g_pba_from_variant, (void *)g_pba_to_variant,
			(void *)g_pba_destructor);
		return 0;
	}
	r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_initialization->userdata = nullptr;
	r_initialization->initialize = initialize;
	r_initialization->deinitialize = deinitialize;
	printf("[FastPhys] 入口被调用，接口全部拿到\n");
	return 1;
}
