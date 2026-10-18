// Thin GDExtension C API binding, following the existing project native ABI convention.
#include "gdextension_interface.h"
#include "energy_kernel.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>
// Windows 导出入口；限制系统头的宏，避免污染标准库。
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



typedef void (*CmdDispatch)(void *,const uint8_t *,size_t,uint8_t *,size_t,size_t &);
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
		// 长度由受控 GDScript 调用方写入头部，
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
static SN g_sn_pf_class, g_sn_pf_step, g_sn_pf_a0, g_sn_pf_a1, g_sn_pf_ret;

static GDExtensionObjectPtr create_energy_instance(void *p_userdata, GDExtensionBool p_notify_postinitialize) {
	GDExtensionObjectPtr obj = g_construct_object((GDExtensionConstStringNamePtr)g_sn_parent.buf);
	if (obj == nullptr) return nullptr;
	blue::Kernel *d = new blue::Kernel();
	g_object_set_instance(obj, (GDExtensionConstStringNamePtr)g_sn_pf_class.buf, (GDExtensionClassInstancePtr)d);
	return obj;
}

static void free_energy_instance(void *p_userdata, GDExtensionClassInstancePtr p_instance) {
	if (p_instance != nullptr) delete (blue::Kernel *)p_instance;
}

static void energy_dispatch(void *ctx, const uint8_t *in, size_t in_n,
		uint8_t *out, size_t out_cap, size_t &written) {
	((blue::Kernel *)ctx)->command(in, in_n, out, out_cap, written);
}

static void call_energy_step(void *method_userdata, GDExtensionClassInstancePtr p_instance,
		const GDExtensionConstVariantPtr *p_args, GDExtensionInt p_argument_count,
		GDExtensionVariantPtr r_return, GDExtensionCallError *r_error) {
	call_cmd_glue(energy_dispatch, p_instance, p_args, p_argument_count, r_return, r_error);
}

static void register_energy_grid() {
	GDExtensionClassCreationInfo6 info = {};
	info.is_virtual = false;
	info.is_abstract = false;
	info.is_exposed = true;
	info.is_runtime = false;
	info.create_instance_func = create_energy_instance;
	info.free_instance_func = free_energy_instance;
	g_register_class6(g_library, (GDExtensionConstStringNamePtr)g_sn_pf_class.buf,
		(GDExtensionConstStringNamePtr)g_sn_parent.buf, &info);
	printf("[InkEnergyGrid2] 类已注册\n");

	GDExtensionClassMethodInfo mi = {};
	mi.name = (GDExtensionStringNamePtr)g_sn_pf_step.buf;
	mi.call_func = call_energy_step;
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
	printf("[InkEnergyGrid2] 已注册方法 step\n");
}


static void initialize(void *, GDExtensionInitializationLevel level) {
    if(level==GDEXTENSION_INITIALIZATION_SCENE)register_energy_grid();
}
static void deinitialize(void *, GDExtensionInitializationLevel) {}
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
		printf("[InkEnergyGrid2] 关键接口缺失\n");
		return 0;
	}
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_parent.buf, "Object");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_class.buf, "InkEnergyGrid2");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_step.buf, "step");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_a0.buf, "input");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_a1.buf, "out_template");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_pf_ret.buf, "result");
	g_sn_new((GDExtensionUninitializedStringNamePtr)g_sn_empty_class.buf, "");
	g_str_new((GDExtensionUninitializedStringPtr)g_str_empty_hint, "");
	// PackedByteArray 的构造索引 1 = 拷贝构造
	g_pba_copy_ctor = g_get_ctor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 1);
	if (!g_pba_copy_ctor) { printf("[InkEnergyGrid2] 拿不到 PackedByteArray 构造函数\n"); return 0; }
	if (!g_get_to_type || !g_get_from_type || !g_get_destructor) {
		printf("[InkEnergyGrid2] 缺少 Variant 转换接口\n");
		return 0;
	}
	g_pba_from_variant = g_get_to_type(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
	g_pba_to_variant = g_get_from_type(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
	g_pba_destructor = g_get_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
	// ⚠️ variant_get_ptr_destructor 对 POD 类型（int/float…）返回 **null** —— 它们没有析构函数。
	// 所以可空项要分开判断，不能一起当"必需"。
	if (!g_pba_from_variant || !g_pba_to_variant || !g_pba_destructor) {
		printf("[InkEnergyGrid2] Variant 转换函数解析失败: from=%p to=%p dtor=%p\n",
			(void *)g_pba_from_variant, (void *)g_pba_to_variant,
			(void *)g_pba_destructor);
		return 0;
	}
	r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;
	r_initialization->userdata = nullptr;
	r_initialization->initialize = initialize;
	r_initialization->deinitialize = deinitialize;
	printf("[InkEnergyGrid2] 入口被调用，接口全部拿到\n");
	return 1;
}
