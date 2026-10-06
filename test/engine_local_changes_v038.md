# ink2 本地引擎修改说明（2026-10-06）

## 1. 当前状态与责任边界

**修改过引擎，也扩展过接口。当前运行的是官方 v0.3.8 加本地未提交补丁，不是原封不动的官方发布包。**

- 官方基线：`91dc1ec1f6f78f41c96469cdf576707794f12236`，源码分支 `main`。
- 引擎真源：`T:/GODOT/bag/Godot_2DVoxel_Addons`。
- 游戏安装目录：`T:/GODOT/ink-2/addons/pixel_destruction`；这是生成后的副本，不是源码目录的链接。
- 游戏与测试：`T:/GODOT/ink-2`。
- 本文由当前 `git diff HEAD`、源码、已有测试日志核对。此次只写文档，没有修改物理算法、重新安装或重新运行物理测试。
- Request 草稿：`T:/GODOT/ink-2/test/engine_performance_request.md`。尚未向引擎作者发送、提交或推送。

早期记录中的“没有修改 addon”只描述当时的只读排查阶段，不能用于描述现在的安装状态。前面性能优化已经修改源码、编译两个 DLL 并安装。本次把依赖和兼容性补齐。

以下功能是官方 v0.3.8 已有能力，不计入本地新增：冻结/恢复、碎片 chunk 接管、形状独立脏区、关节软度与世界求解参数、拥有自绘视觉的节点不再重复绘制。

## 2. 修改文件清单

以下路径均相对引擎真源；脚本运行副本保持同模块路径，但前缀变为游戏 `addons/pixel_destruction/`。

| 文件 | 函数/位置 | 本地修改 | 性质 |
|---|---|---|---|
| `src/physics/pbody.gd` | 字段约 152 行、`clear_forces()` | 持续执行器力/力矩、追加求解迭代字段 | 新接口与清除语义扩展 |
| `src/physics/pworld.gd` | `_substep_rapier()` | 合并执行器输出、发送局部迭代设置 | 行为修改与原生协议扩展 |
| `src/physics/pworld.gd` | `fracture_pixels()` | 第四参数、局部连通证明、碎片属性继承 | 公开签名扩展与优化 |
| `gdext/fastphys.cpp` | `RapierApi`、`load_rapier()`、`run_rapier_cmd()` | 加载新导出、opcode 42 | ABI/协议扩展 |
| `gdext/rapier_bridge/src/lib.rs` | `rb_body_set_solver_iterations()` | 调用 Rapier 追加求解迭代 | 新 C ABI 导出 |
| 同上 | `World::index_contacts()`、`rb_contact_count()`、`rb_contact_get_points()` | 每物理步建立一次接触对索引 | 内部优化，查询签名不变 |
| `tools/build_native.py` | `main()` 的 g++ 参数 | `-static` 替代两项局部静态链接选项 | 部署依赖修复 |
| `tests/validation_fracture_pixels.gd` | 断裂验证与 teardown | 增加静态地面掉落碎片与属性继承检查 | 验证代码 |
| `gdext/fastphys.dll`、`gdext/rapier_bridge.dll` | 编译产物 | 对应上述源码 | 必须配套安装 |

相对官方基线共有 6 个文本文件和 2 个 DLL 改动；当前文本差异统计为 93 行新增、21 行删除。这里只列引擎差异，游戏此前的控制、HUD、伤害、冻结接入另有修改。

## 3. 执行器力：接口、原因、生命周期

新增 `PBody` 字段：

```gdscript
var control_force := Vector2.ZERO
var control_torque := 0.0
```

二者都是**持续输出**：每个控制帧覆盖写入；`PWorld._substep_rapier()` 每子步使用相同输出积分。停用控制器、释放节点或结束控制时必须归零。它们不会在 `world.step()` 后自动归零。

最终推给 Rapier 的力是 `accum_force + grab_force + control_force`，力矩同理。沿用原有“输出变化时先 reset，再 add”路径，避免 Rapier 的持久力被每子步重复累加。`clear_forces()` 现在同时清除 `accum_*` 和 `control_*`；调用顺序需要让控制器在清除之后写入。

原因：旧手部把整帧冲量提前施加到很轻的手上，关节尚未求解时就产生很大的瞬时速度，世界 CCD 据此选择大量全局子步。新路径让关节与驱动力在每子步一起求解，减少该速度峰值触发的全世界碰撞重复计算。没有通过全局限速或关闭 CCD 来提速。

游戏接入：`T:/GODOT/ink-2/actor/player/src/hand.gd` 的控制输出处分别覆盖手与身体的等大反向力；`_exit_tree()` 清零双方输出。力/功率限幅仍由游戏控制器负责，引擎字段不自动限幅。

限制：多个控制器同时写同一字段会互相覆盖，当前不是多执行器自动合成接口。上游需要明确所有权，或提供合成规则。不要把它误当成调用一次后只生效一帧的 `add_force()`。

## 4. 局部求解迭代：新增协议与兼容性

公开字段：`PBody.additional_solver_iterations`，默认 `0`。内部缓存：`_rp_solver_iterations`，初值 `-1`；值变化时发送一次设置。发送前只限制不小于 0，目前没有上界。

调用链：

```text
PBody.additional_solver_iterations
→ PWorld._substep_rapier(): opcode 42 + u32 body_id + u32 iterations
→ fastphys.cpp: case 42
→ rb_body_set_solver_iterations(World*, u32, u32)
→ Rapier RigidBody::set_additional_solver_iterations(usize)
```

这增加的是该刚体所在连接约束岛的求解精度；接触和关节连接的其他动态刚体可能一起承担开销。它不是“只多算手上的一个关节”，也不是增加全世界碰撞检测子步。当前游戏手设置 `32`；世界基础迭代为 `4`。降低全局子步后仍需要验证 Weld 的角度误差。

**版本配套要求：**

- 官方 v0.3.8 使用 opcode 40 表示关节软度、41 表示世界关节求解参数；本地新增使用 42。更早本地补丁曾占用 40，升级时已调整，不能混装旧协议。
- 新 `fastphys.dll` 要求桥接 DLL 导出 `rb_body_set_solver_iterations`；官方桥接 DLL 缺该导出。
- 新脚本会发送 opcode 42；官方旧入口 DLL 不支持该命令。
- 当前没有 ABI 版本协商、能力查询或安全降级，两个 DLL 和生成脚本必须同批替换。
- 42 是本地选择，未取得上游协议保留；正式合入时应由维护者确认编号。

本次代码审查还发现一个未覆盖的生命周期风险：同一个 `PBody` 被移除后重新加入，创建原生 body 时会重置矩形与分组缓存，但没有重置 `_rp_solver_iterations`。若字段值未变化，新原生 body 可能漏收追加迭代设置。这不是已验证通过的场景，已列入 Request；此次文档审查没有顺带修改引擎。

## 5. 精确像素破坏：第四参数与连通优化

当前位置：`src/physics/pworld.gd:2863`。

```gdscript
func fracture_pixels(body: PBody, removals: Dictionary,
        burst_speed: float = 0.0, dynamic_fragments: bool = false) -> Dictionary
```

`removals`、返回 `{removed, body_alive, fragments}` 保持原定义。前三参数调用仍可用；第四参数默认 `false` 保持原碎片静态性行为。

当第四参数为 `true`，从静态体分离出来的新碎片转为动态；留在原 body 上的部分不因此变为动态。新碎片在 `add_body()` 前继承原体的 `collision_layer`、`collision_mask`、`gravity_scale`，避免重建时使用默认值。

游戏 `T:/GODOT/ink-2/map/src/collision_damage.gd:314` 使用第四参数 `true`，使地面的断落块能掉落。因此仅换回官方三参数引擎会令该调用参数数量不匹配，需要同步调整游戏接入。

优化步骤：未受损 shape 不再重新做分裂；受损 shape 调用现有 `Destruction.local_connectivity()`。只有返回 `LOCAL_CONNECTED` 才复用原对象，否则，包括未知和低于像素阈值的结果，都回退 `Destruction.split(..., true)`。不是在局部看见没有裂缝就猜测整块连通。

局部判据依赖破坏前 shape 本来连通；正常 `add_body()` 的 `ensure_connected` 与分裂输出满足前提。绕过检查或错误使用 `connected_known=true` 的调用不在该证明前提内。最坏情况仍需要全量 split；矩形分解、质量重算、原生碰撞体重建和节点同步成本仍然存在。

本地没有增加像素血量贴图，也没有修改白色裂缝何时贯穿的游戏规则。材质摩擦与恢复系数重建支持属于当前官方代码，不应重复归为本地新增。

## 6. 接触查询复杂度优化

旧 `rb_contact_get_points(i)` 从接触迭代器起点寻找第 i 对。游戏遍历 N 对时，累计重复扫描约 `1 + 2 + ... + N`，产生 O(N²) 枚举开销。

新增 `World.contact_pairs` 只保存当前活跃接触对的 ColliderHandle；`index_contacts()` 在需要时建立一次。`rb_contact_count()` 和 `rb_contact_get_points()` 共用索引；随后通过对应句柄查询 NarrowPhase 的接触对。

- 每物理步、删除刚体、重建矩形碰撞体时标记失效。
- 不跨步缓存接触点、冲量或裸指针，保留带代数的句柄。
- 对所有接触的遍历变为 O(N) 建表，加逐对查询及总接触点处理开销；没有声称原生碰撞识别本身变为 O(N)。
- 查询参数、点数据布局、容量不足时返回需求数量的协议未改。
- 增加 O(N) 句柄内存；需要上游补充删除/重建/冻结恢复/容量不足时的对照测试。

## 7. 构建、安装、核验和回退

`tools/build_native.py` 的链接参数改为 `-static`，解决只静态链接 gcc/stdcpp 时仍依赖未随包部署的 `libwinpthread`、导致 Windows 加载错误 126 的问题。没有升级 Rapier 依赖版本，仍使用 `rapier2d = "0.36"`。

复现构建在源码根执行，先保存并关闭占用 DLL 的 Godot：

```powershell
python tools/build_native.py
python tools/build_addon.py --verify
```

不带 `--verify` 时生成目录为源码根 `addons/pixel_destruction/`；上面带 `--verify` 的命令成功后会将产物移到 `T:/GODOT/bag/_addon_build`。安装到游戏时必须排除生成目录根 `.gdignore`，否则 Godot 会忽略整个插件；保留游戏已有 `.uid`，按生成包处理脚本路径，不手抄一份源码。需要成套安装两 DLL 与生成脚本，并重启后重新导入核验。

本次重新读取 SHA256，源码与游戏安装副本两两一致：

| DLL | SHA256 |
|---|---|
| fastphys.dll | `CE542B027AE96D859DDBA32BA7BED7FCB7D39A33B7FEFD0C57BF561CAE06EE83` |
| rapier_bridge.dll | `88A86C933DE19E2196FD744171DB9338B6EFED3315CF553DAC3CEB24C786D93F` |

升级前备份：`T:/GODOT/bag/ink2_pre_v038_20261006`，其中 `runtime/` 是当时完整安装副本。这个备份是升级前的本地优化版本，**不是官方 v0.3.8 原版**。回退官方版本需要重新生成官方包，并同步回退游戏的新增字段与第四参数调用；不能只替换某一个 DLL。不在本次执行回退。

## 8. 已有验证与证据边界

以下均为先前运行产生、本次读回的日志；本次未重跑，未执行全套发布门禁。

| 日志（游戏 test/ 下） | 结果 |
|---|---|
| `v038_hand.log` | 50 通过、0 失败；Weld 相对角度最大 0.026048°；支撑物块后期位置峰峰值 0.037750 px |
| `v038_control.log` | 28 检查、0 失败，包含游戏冻结接入 |
| `v038_damage.log` | 39 检查、0 失败 |
| `v038_climb.log` | 8 检查、0 失败 |
| `v038_validation_freeze.log` | 冻结断言通过；退出仍有 resources in use 报错，不能称日志全干净 |
| `v038_slam.log` | 真实 F5 样本，180 帧；CPU 测量段均值 0.795439 ms、P95 1.197 ms、最大 12.978 ms，最多 4 子步 |
| `v038_cut.log` | 同样本切除 37 像素、产生 3 新碎片；fracture API 6.216 ms、同步 3.153 ms；180 帧均值 1.47835 ms、P95 2.231 ms、最大 14.764 ms |

样本 `test/canvas_capture.tres`：3770 实体像素，275 个矩形，一块连通物体。上表是 CPU 测量段，不是显卡整帧耗时或玩家运行的 FPS 保证。破坏瞬间仍有重建尖峰；更早测试还记录过约 202 ms 冷启动尖峰，尚未定位，不能宣称全部卡顿解决。

## 9. 当前碰撞架构与多边形改造边界

```text
PixelShape / PixelChunk：实体像素、材料
→ PBody.rebuild()：像素质量/质心/惯量 + GreedyRects 精确矩形覆盖
→ PWorld._substep_rapier()：矩形、力、Joint、子步命令
→ fastphys.cpp：Godot GDExtension + 二进制协议
→ rapier_bridge/src/lib.rs：Rapier RigidBody / Collider / 碰撞与约束求解
→ 回读状态；Godot 节点与像素画面同步
```

Godot 节点不是这条路径的原生求解器；`PBody` 也不是 Godot `RigidBody2D`。实际动力学在 Rapier 中。

`rb_body_set_rects():173` 每个矩形单独调用 `ColliderBuilder::cuboid()`、插入同一 RigidBody。因此样本一块 body 对应 275 个独立 Collider，而非一个含 275 子形状的 compound Collider。斜边的像素阶梯可能制造很多矩形；总成本还乘上全局子步数。实际候选对数量取决于空间重叠，不能直接断言每帧做 275² 次碰撞。

确认的旧实现是 `T:/GODOT/ink-fffight/ink/solid/ink_solid.gd:278` 的 `polygon_create()`：BitMap 提取轮廓，epsilon 从 2 增到 8 px，并挑最大轮廓。`ink/runtime/ink_body.tscn:13` 使用 `CollisionPolygon2D`；`ink/runtime/ink_body.gd:514` 另为预测查询做凸分解。这不能证明用户记忆中的每个旧版像素引擎都用了相同后端。

Godot `BUILD_SOLIDS` 会将凹多边形分为若干凸形状，保留凹槽，不是直接做一个凸包。旧程序的轮廓简化确实减少几何复杂度，但可能改变 1 px 结构，并且只选最大轮廓不能作为完整多组件/孔洞方案。旧穿模的原因还可能包含 CCD 与旋转预测，不能仅由轮廓算法推断。

### 建议的两阶段引擎实验（尚未实现）

1. **先测一个 body 一个 compound Collider，内部仍放原矩形。** 核心修改集中在 Rust `rb_body_set_rects()`，先保持 opcode 5 的矩形载荷；核验质量/质心/惯量、材质、mask、CCD、接触流形与破坏重建。预计减少宽相代理数，但内部子形状检测仍存在，必须 A/B 证明收益，不能承诺一定更快。
2. **再测像素边界 → 凸多边形分解 → compound。** 涉及轮廓生成与孔洞、简化、顶点协议、Rust Collider 建立、重建与缓存，属于跨层改造。外轮廓简化须保护细杆、凹槽、1 px 连接、孔洞；不能直接采用 epsilon 2～8。碰撞形状面积若变化，还要解决 Rapier 根据几何密度算出的质量与游戏像素质量不一致的问题。

总体判断：能改，优先保留 Rapier、Joint 和像素破坏规则，只替换碰撞几何的组织方式。compound 矩形实验范围较小；完整多边形路线明显更大，性能收益受实际轮廓复杂度影响。本次没有实施任一路线。

参考：[Godot CollisionPolygon2D 的 BUILD_SOLIDS](https://docs.godotengine.org/en/stable/classes/class_collisionpolygon2d.html)、[Rapier Collider 与形状、质量说明](https://rapier.rs/docs/user_guides/javascript/colliders/)。Rapier 网页为概念参考，具体 Rust 0.36 API 以当前依赖源码为准。
