# rapier_bridge —— Godot ↔ Rapier 的桥接层

**纯 C ABI 的 Rust cdylib**，把物理交给 [Rapier](https://github.com/dimforge/rapier)（Apache-2.0）。

## 为什么是这个形态

- Godot 侧的 GDExtension 是 **MinGW g++** 编的，Rust 是 **MSVC** 编的 ——
  跨 C++ ABI 不现实，跨 C ABI 是标准做法。
- 只传基本类型与裸指针；**内存一律由 Rust 分配/释放**，调用方不 free 任何东西。
- Rapier 静态链进 DLL，所以产物自包含（依赖只有系统库 + MSVC 运行时）。
- 外部 id 用 u32，存在 Rapier 的 `RigidBody::user_data` 里，遍历时能直接映射回来。

## 构建

```bash
cd gdext/rapier_bridge
cargo build --release          # -> target/release/rapier_bridge.dll
cargo run --release --bin smoke  # 冒烟：拼接地面滑行 + 角接触 + 睡眠
```

⚠️ **不要用 rapier 仓库自带的 `bindings/c/rapier2d-ffi`**：那个 workspace 里有一个
`puffin_egui` 的 **git 依赖**，而本机 git 连不上 github.com（curl 能连，
见开发日志的"网络"一节）—— cargo 会在依赖解析阶段直接失败。
这里只依赖 **crates.io 上的 `rapier2d`**，干净。

## 实测（smoke + 对照探针）

同一批场景，本引擎 vs Rapier（像素当单位，y 向下，重力 600）：

| 场景 | 本引擎 | Rapier |
|---|---|---|
| **幽灵碰撞**：滑过 60 段拼接地面 | 偏离 **16.16 px**、倒退 1 次、ω=4.91 打转 | 偏离 **0.0027 px**、0 倒退、转角 0.025° |
| **角接触**：40° 的 24x24 方块 | 修好后 0.806° | **−0.000°**（完全倒平） |
| **规模**：240 碎块 | **1.79 ms/步** | **0.067 ms/步**（≈27×） |
| 休眠 | 0/120 入睡 | **0/240 入睡** |

幽灵碰撞被彻底解决，而且**不是靠调参** —— 是 Rapier/parry 的
`compound_pseudo_normals`：把被兄弟块盖住的"切割边"从边界里去掉，
接触法向投影不进法向锥就丢弃该接触。本项目的地面正是"一个刚体 + N 个相邻矩形"，
恰好命中这条路。

⚠️ 性能对比要诚实：Rapier 的 0.067 ms 是**纯物理**，
而 GDScript 侧的胶水（同步位姿、接触事件、破坏重建碰撞体）仍然存在，
换过去之后这部分不会消失。

## ⚠️ 两个实测踩到的坑

1. **`rb_body_set_rects` 是替换语义** —— 它先清空该刚体的**全部**碰撞体，再加新的。
   一个 body 有 N 个矩形时必须**一次调用发完**；分 N 次调用只会留下最后一段。
   （第一版就这么错的：60 段地面变成 1 段，方块直接掉出世界 3822 px。）
2. `rb_body_get_state` 的 `out` 需要 **6 个 f64**：`x, y, rot, vx, vy, angvel`。
   （旧接口 `rb_contact_get` 要 7 个 f64 —— 它**已删除**，替代品是
   `rb_contact_get_points`，见 `src/lib.rs` 里的墓碑说明。）

## Godot 侧怎么调

`fastphys.dll` 里注册了一个 `RapierPhys` 类（**一个方法** `cmd`）：

```gdscript
var inst = ClassDB.instantiate("RapierPhys")
var out: PackedByteArray = inst.cmd(input, out_template)   # 命令流 in / 结果流 out
```

- `fastphys.dll` 用 **LoadLibrary 动态加载**本 DLL（运行时取函数指针）——
  不做链接期耦合，避开 MinGW g++ ↔ MSVC Rust 的导入库问题。
- 命令流格式见 `gdext/fastphys.cpp` 里 `RapierPhys` 那一节的注释；
  `tests/diag_rapier.gd` 是可直接运行的样例（含编码器）。

## 状态：已完成，是唯一路径

1. ~~GDExtension 包装~~ ✅ `RapierPhys` 类，用 `LoadLibrary` 动态加载本 DLL。
2. ~~`PWorld` 接 Rapier~~ ✅ 位姿/矩形同步逐字段比对镜像；接触事件映射回 `Contact`。
3. ~~测试套件判定~~ ✅ **293 项全绿**；8 条基准已重设。
4. ~~删除手写内核~~ ✅ `bp_kernel.h` / `collide_kernel.h` / `solver_kernel.h` 已删除。

⚠️ **两个 DLL 必须一起重建。** 只重建其中一个的后果不是报错，而是
`load_rapier()` 找不到新符号 → 世界指针为 null → **物理完全不动**。
实测踩过一次：加了 op 19 只重建了 fastphys.dll，于是所有物体停在原点。

## 两个标志性 bug 已消失

| 幽灵碰撞诊断（Rapier #669 判据） | 手写引擎 | Rapier |
|---|---|---|
| A 一整块 | 0.0000 px | 0.0026 px |
| B 同一 body 两段 | **16.1619 px** + 打转 | **0.0044 px** |
| C 60 个独立静态体 | **14.9131 px** + 打转 | **0.0047 px** |

角接触：四个场景全部倒到 −0.000°（手写路径 0.806°）。
