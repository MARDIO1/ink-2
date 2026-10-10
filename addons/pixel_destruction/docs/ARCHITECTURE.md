# 架构 —— 一个时间步里发生了什么

## 数据流

```
PBody                        world.bodies[]
  ├─ shapes:  PixelShape[]   像素数据（chunk 稀疏表）
  ├─ rects:   Rect2[]        贪心分解出的碰撞矩形（局部空间，**精确覆盖**：面积和 == 像素数）
│                           —— 这是**输入**，不是最终碰撞形状
├─ polys:   Vector2[][]    **Rapier 里真的在用的**碰撞体形状（惰性读回，见下）
  ├─ aabb:    Rect2          世界 AABB（每子步维护，宽相/粗筛用）
  ├─ world_hull()            世界凸包（**与 AABB 并列的包围体**，惰性：谁问谁付）
  ├─ local_com / mass / inertia
  └─ position / rotation / velocity
        │
        ▼
PWorld.step(dt)
  ├─ _compute_substeps(dt)   按"最快物体一步走多远"决定切几个子步
  └─ for each substep:
       ├─ clear_pseudo()            清空位置修正通道
       ├─ _integrate_forces()       重力 + 阻尼 + 终端速度
       ├─ _broadphase()             ① 扫掠 AABB → SAP 排序 → 配对 → 窄相 → 流形
       ├─ _wake_pass()              ② 醒着的运动体碰到睡眠体就唤醒它
       ├─ _solve()                  ③ 顺序冲量迭代（warm start + 分块 + 分裂冲量）
       ├─ _integrate_transforms()   ④ 真实速度 + 伪速度一起积分位置（绕质心）
       ├─ update_aabb()             ⑤
       └─ _update_sleep()           ⑥ 由流形构成的约束图做并查集分岛 → 整岛入睡
```

## 三个"消费者"约定（踩过的坑）

`manifolds` 有**三个**读者：`_solve`、`_wake_pass`、`_update_sleep`。
移植或优化时**漏掉任何一个**都会出问题，而且症状各不相同：

| 漏掉谁 | 症状 |
|---|---|
| `_solve` | 物体之间不再碰撞（最明显） |
| `_wake_pass` | **睡得太好**：睡眠体永远不被靠近的运动体唤醒 |
| `_update_sleep` | 岛划分失效，休眠行为错乱 |

> 实战教训：走原生路径时 `manifolds` 会被置空，此时三个消费者必须
> **读同一份打包数据**。所以"走不走打包路径"这件事**只在一个地方判断一次**
> （`_packed_manifolds`），不能各判各的 —— 曾经因为两处判断条件不一致，
> 导致"拖动一个方块，其它方块全部掉穿地面"。

## 只有一条求解路径：Rapier

```
PWorld.step()
  -> 把"引擎侧改过的"推给 Rapier（位姿 / 速度 / 矩形 / 力，逐字段比对镜像，没改的不推）
  -> Rapier 走一步（宽相 / 窄相 / 求解 / 休眠 / CCD 全是它的）
  -> 把结果读回来（位姿 / 速度 / 睡眠），再采集接触事件
```

每个子步只有**一次** @@RapierPhys.cmd()@@ 调用。

> 历史：这里曾经有 _Packed 路径与对象路径两条，加上 GDScript 宽相/求解器共三套实现。
> 它们都已删除 —— 物理换成 Rapier 后没有存在理由了。
> 详见 @@docs/development_log.md@@ 的「把物理交给 Rapier」一节。

⚠️ **这一段已作废**：对象路径（以及它的 GDScript 宽相/求解器）已经**全部删除**，
float32/float64 边界换来的，见 [PRECISION.md](PRECISION.md)。

## 休眠

`_update_sleep` 用**流形构成的约束图**做并查集：

- 动态体之间通过接触相连 → 同一个岛；
- **静态体不参与并查集**（否则一整块地面会把所有东西并成一个岛，岛并行名存实亡）；
- 一个岛里所有物体都"慢"够久，整岛一起睡。

## 连续碰撞（CCD）

三层，从便宜到贵：

1. **子步细分**（默认第一道防线）：按最快物体切时间步，
   让每子步位移 <= `ccd_max_motion`。
2. **推测接触**：在边际内提前生成接触，把接近速度限制到"刚好接触"。
   ⚠️ 边际必须**小于**子步位移上限，否则它不刹车（见 PRECISION.md 3.5）。
3. **精确 OBB 扫掠**（`sweep.gd`）：保守推进求最早接触时刻。
   能处理纯转动、质心偏离、双方都在动 —— 这些是 AABB 扫掠**结构上做不到**的。
   默认只在子步饱和时接管。

## 破坏

```
world.fracture(body, damage, burst_speed)
  ├─ 连通性：Destruction.split()（原生 PixelRaster op 3，缺扩展时退回 GDScript 参照实现）
  ├─ 破坏：apply_damage()（keep 掩码按 chunk 合并）
  ├─ 最大的那块留在原 Body（保持引用与 id 稳定）
  └─ 其余每块 spawn 成新 Body（带上 burst_speed 的初速度）
```

⚠️ **Damage 的坐标是"目标 Shape 的本地像素空间"**，不是世界坐标。
⚠️ **破坏不等于碎片**：连通性分裂才产生新刚体；中心挖洞得到环，仍然是一块。

## 扩展点

- 想换碰撞形状：`greedy_rects.gd` 换成别的分解方式即可，物理层只吃 `rects`。
- **默认的碰撞形状是"拟合出来的凸多边形"，不是 `rects` 本身**：`rects` 是精确覆盖的输入，
  原生侧（`rb_body_fit_polys`）把它拟合成凸多边形（斜边拉直、锯齿拉平、块数更少）再交给 Rapier。
  `world.poly_colliders = false` 可以关掉（回到精确矩形）。
  ⚠️ 要**可视化/判定**就用 `px.colliders(body)`（读回 Rapier 的真相），
  别照 `rects` 画 —— 那是两份会分叉的真相。
- 想要"紧的包围体"：`hull_fit.gd`（凸包，与 AABB 并列）。
  ⚠️ 它是**包围体**，不是碰撞形状 —— 凹形状的凹角会被填平，别拿它去替换 `rects`。
- 想换渲染：`PixelRenderer` 是唯一与渲染相关的模块，替换它不影响物理。
- 想换求解器：求解**整体在 Rapier 里**（`native/rapier_bridge`），GDScript 侧没有求解代码。
  要换就把桥接层换掉（`gdext/fastphys.cpp` 的命令流协议是唯一的接口）。
