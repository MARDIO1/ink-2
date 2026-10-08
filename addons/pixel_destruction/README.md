# pixel_destruction — 2D 像素破坏物理引擎

Teardown 风格的 **2D 像素破坏 + 刚体物理**，纯 GDScript 实现，可选 GDExtension 原生加速。
可以直接拖进任何 Godot 4.x 项目。

核心特点：

- **任意像素团就是碰撞体** —— 不要求凸形或矩形。像素数据会被贪心分解成 OBB，物理层只看见 OBB。
- **破坏即物理** —— 挖掉像素后按连通性分裂，切下来的部分自动变成新的刚体。
- **确定性 + 逐位可复现** —— 同输入必然同输出（`tests/test_determinism.gd`）
  （正是靠这一点，原生加速才敢默认打开）。
- **精度纪律写在代码里** —— float32/float64 的每一条边界都有注释和测试钉住，
  见 [docs/PRECISION.md](docs/PRECISION.md)。**这是本项目最值钱的部分**：
  物理引擎的"差不多对"和"逐位对"之间隔着十几条反直觉的规则。

---

## 环境要求

- **Godot 4.x**（标准版，无需 .NET）。开发基线 4.7.2。
- 只用引擎核心类型：`WorkerThreadPool` / `ClassDB` / `OS` / `Image` / `Sprite2D`。没有第三方依赖。
- 原生加速（可选）额外需要：g++ 或 MSVC（C++17）。

---

## 获取

从 [Releases](../../releases) 下载 `pixel_destruction.zip`，解开即是完整的 addon。

> 仓库里**没有** `addons/pixel_destruction/` —— 它是构建产物，由 CI 生成。
> 要在本地构建：先跑 `python tools/build_addon.py`，
> 再用 `python tools/check_addon.py` 校验自洽。

## 安装

1. 把整个 `addons/pixel_destruction/` 目录拷进你的项目。
2. （可选）构建并启用原生加速，见下面「原生加速」一节。
3. 跑一遍自检确认可移植：

```
godot --headless --path <你的项目> --script res://addons/pixel_destruction/examples/minimal.gd
```

八个断言全过就说明引擎在你的项目里可用（像素团分解、重力、接触、破坏分裂、抓取、休眠）。

---

## 快速上手

**只需要认识一个类：`PixelPhysics`**（注册了 `class_name`，连 preload 都不用写）。

```gdscript
var px := PixelPhysics.new()
add_child(px)                                   # 加进树里就自动 _physics_process

px.define_material(1, Color.SLATE_GRAY, 2.5)    # 石头：颜色 + 密度一次设好
px.define_material(2, Color.SANDY_BROWN, 0.6)   # 木头
px.add_ground(Rect2(-400, 300, 800, 40), 1)

var ball := px.spawn_circle(Vector2(0, 0), 14, 2)
```

### 体素颜色 / 材质

颜色**按材质**表达，不逐像素存颜色 —— 像素数据只存 1 字节材质 id：

```gdscript
px.define_material(3, Color.CRIMSON, 7.8)        # 定义（或改）一种材质
px.material_color(3)                             # -> Color
px.material_at(Vector2(100, 320))                # -> 世界坐标处是什么材质（0 = 空）

px.paint_circle(Vector2(0, 0), 20, 3)            # 世界坐标涂色（不破坏、不分裂）
px.set_body_material(ball, 2, 3)                 # 整个刚体换材质，并自动重算质量

# 想逐像素读写就下到 PixelShape 层：
var s: PixelShape = ball.shapes[0]
s.get_pixel(4, 4)                                # -> 材质 id
s.fill_rect(Rect2i(0, 0, 4, 4), 3)               # material 0 == 清空
s.count_by_material()                            # -> {1: 84, 3: 16}
```

### 质量

质量 = 像素数 x 材质密度。密度在 `define_material` 里一起设定：

```gdscript
px.define_material(1, Color.SLATE_GRAY, 2.5)     # 石头：1 像素 = 2.5 单位质量
var rock := px.spawn_rect(Vector2(0, 0), Vector2(10, 10), 1)
rock.mass                                        # -> 250
rock.inertia                                     # -> 自动算好
rock.local_com                                   # -> 质心（局部像素坐标）

# 改了**材质**（或绕过引擎直接改像素）之后重算质量：
px.world.refresh_mass(rock)
# ⚠️ 破坏（fracture / detach / fracture_pixels）之后**不需要**再调一次 ——
#    引擎在破坏里就把密度/摩擦/恢复系数一起重算好了。
```

### 对某一点施加力

```gdscript
px.push(rock, Vector2(0, -50000))                        # 过质心的持续力
px.push_at(rock, Vector2(0, -50000), rock.com_world())   # 在指定世界坐标点施加
px.spin(rock, 8000.0)                                    # 纯力矩
px.impulse(rock, Vector2(500, 0))                        # 瞬时冲量（过质心）
px.impulse(rock, Vector2(500, 0), some_world_point)      # 瞬时冲量（在点上）
```

**力只作用于本帧**：门面在每步结束时自动清空累加器，所以"每帧 push 一次"就是持续力，
不 push 就没有力 —— 不需要记得 `clear_forces()`。

> 叉积的常识在这里依然是常识：力和力臂**平行**时力矩为 0。
> 想在质心右侧推就让 `point - com` 垂直于 `force`。

### 程序化破坏（全部世界坐标）

```gdscript
px.carve_circle(Vector2(100, 100), 12.0)                 # 挖圆洞
px.carve_rect(Vector2(100, 100), Vector2(10, 4))         # 挖矩形
px.cut(Vector2(0, 0), Vector2(200, 0), 2.0)              # 沿线段切一条沟

px.explode(Vector2(100, 100), 120.0, 400.0)              # 爆炸：推开 + 破坏
#   参数：爆心、半径、power（速度增量语义）、material_delta、burst_speed

# material_delta > 0 会把破坏边缘换成该材质（烧焦 / 结冰 / 腐蚀）：
px.explode(center, 80.0, 300.0, 4)                       # 边缘烧成材质 4
```

全部返回**新产生的碎片刚体**数组，并且会自动让渲染层跟上（不用手动 prune）。

### 抓取拖动

```gdscript
if px.grab_at(mouse_world):        # 抓住鼠标下的刚体
	...
px.drag_to(mouse_world)            # 每帧拖
px.release()
```

### 关节

```gdscript
var j = px.add_hinge(plank, null, Vector2(100, 100))   # 铰链（b 传 null 即接静态世界）
px.add_slider(piston, cylinder, Vector2(0, 0), Vector2.RIGHT)
px.add_weld(armor, hull, anchor)
px.add_rope(a, b, anchor_a, anchor_b, 60.0)            # 最大距离 60
px.add_spring(a, b, anchor_a, anchor_b, 30.0, 200.0, 20.0)

j.set_limits(-PI / 2, PI / 2)      # 限位（铰链是角度，滑轨是距离）
j.set_motor_velocity(3.0, 1.0e7)   # 马达：目标速度 + 最大力（0 = 关掉）
j.set_motor_target(0.0, 1.0e7)     # 角度/位置伺服
j.movement()                       # 当前角度 / 距离
j.break_impulse = 5000.0           # 约束冲量（力 × dt）超阈值就断
px.is_jointed_to_static(debris)    # 这一堆碎块是否还（间接）挂在静态世界上
```

### 碰撞层与掩码

```gdscript
px.set_collision_filter(frag, 2, 1)   # 我在第 2 层，只碰第 1 层（碎块之间不互撞）
px.query_require(1)                   # 查询只打第 1 层（地形）
px.query_include(2)                   # 再追加一层
```

语义与 Godot 的 `collision_layer` / `collision_mask` 一致：两个刚体要碰，**双方都得同意**。
默认掩码是全 1（谁都碰），所以要「只碰某几层」必须显式写掩码。

### 查询与生命周期

```gdscript
px.bodies()                        # 只读列表
px.body_count()
px.bodies_in(Rect2(...))           # 范围内的刚体
px.despawn(body)
```

可运行版本：[examples/facade_demo.gd](examples/facade_demo.gd)（24 项断言）。

## 模块结构

```
physics/            物理核心（与渲染/应用层完全解耦）
  pworld.gd         ★ 世界：把刚体/关节同步给 Rapier，破坏/抓取/关节的入口
  pbody.gd          刚体：位姿/速度/质量属性/像素形状/矩形分解结果/碰撞层掩码
  joint.gd          ★ 关节：铰链/滑轨/焊接/绳/弹簧 + 限位 + 马达 + 断裂阈值
  query.gd          ★ 像素级射线 / 最近点 / AABB 查询 + 过滤器（含碰撞层）
  grab.gd           鼠标拖动（**策略层**：每子步算一个限力，不是求解器约束）
  sweep.gd          精确 OBB 扫掠（保守推进），连续碰撞
  collide.gd        OBB-OBB 的 SAT（几何工具，sweep 在用）
  solver.gd         求解参数与流形结构（求解本身在 Rapier 里）

core/               像素与破坏
  pixel_bits.gd     位运算工具
  pixel_chunk.gd    8x8 像素块 + 占用位掩码
  pixel_shape.gd    ★ 稀疏像素集合（chunk 表），碰撞形状的源头
  greedy_rects.gd   像素团 -> 矩形分解
  mass_props.gd     质量/惯量/质心
  destruction.gd    ★ 破坏：Damage 描述 + 连通性分裂（CPU/GPU 双路径）
  brush.gd          画笔/擦除的像素级操作
  pixel_editor.gd   应用层编辑（笔画 -> 多个 Body）
  pixel_scale.gd    "一个体素在屏幕上多大"

nodes/              节点层（像用 Godot 内置引擎一样用本引擎）
  pixel_world.gd    ★ 世界容器：烘焙子节点、每帧推进一次物理
  pixel_body_2d.gd  刚体（对标 RigidBody2D）：可拖动、可继承、带编辑器抓手
  pixel_shape_2d.gd 形状子节点（对标 CollisionShape2D）：一个刚体可挂多个
  pixel_joint_2d.gd 关节（节点位置 = 锚点 A；body_a/body_b 留空 = 静态世界）
  pixel_sprite_2d.gd 渲染子节点（对标 Sprite2D）
  pixel_material.gd 材质资源（颜色 + 密度 + 强度一份数据）

render/             可选
  pixel_renderer.gd 每个 Body 一张 ImageTexture 的 Sprite2D

gpu/                可选
  gpu_destruction.gd  用 RenderingDevice 做破坏 + 分量标注

native/             可选（GDExtension 源码 + .gdextension 模板）
examples/           最小可运行示例
docs/               架构与精度纪律
```

---

## 门面 API 速查（PixelPhysics）

日常开发只用这张表就够了。**全部坐标都是世界坐标。**

| 分类 | 方法 |
|---|---|
| 配置 | `configure(opts)` · `set_gravity(g)` |
| 材质 | `define_material(id, color, density)` · `material_color(id)` · `material_density(id)` · `set_body_material(body, from, to)` |
| 造物 | `add_ground(rect, mat)` · `spawn_rect(pos, size, mat)` · `spawn_circle(pos, r, mat)` · `spawn_shape(pos, shape)` · `spawn_from_grid(pos, w, h, solid, mat)` · `make_circle(r, mat)` · `despawn(body)` |
| 查询 | `bodies()` · `body_count()` · `material_at(world_point)` · `bodies_in(bounds)` |
| 施力 | `push(body, f)` · `push_at(body, f, world_point)` · `spin(body, t)` · `impulse(body, j, at?)` · `clear_forces(body)` |
| 破坏 | `carve_circle(c, r, mat_delta?, burst?)` · `carve_rect(c, half, ...)` · `cut(from, to, r, ...)` · `explode(c, r, power, ...)` · `paint_circle(c, r, mat)` |
| 抓取 | `grab_at(world_point, accel?)` · `drag_to(world_point)` · `release()` · `has_grab()` |
| **关节** | `add_hinge(a, b, anchor?)` · `add_slider(a, b, anchor?, axis?)` · `add_weld(a, b, anchor?)` · `add_rope(a, b, anchor_a, anchor_b, max_len)` · `add_spring(a, b, anchor_a, anchor_b, rest, k, c)` · `remove_joint(j)` · `joints_of(body)` · `is_jointed_to_static(body)` |
| **碰撞过滤** | `set_collision_filter(body, layer, mask)` |
| 运行 | `step(delta)`（固定步长累加器）· `step_once(dt)` · `renderer()` · `resync()` |
| **查询** | `raycast(origin, dir, max_dist, radius?)` **像素级精确** · `closest_point(origin, max_dist)` · `query_reject_body(body)` · `query_require(mask)` · `query_include(mask)` · `query_clear_filters()` |
| **标签** | `set_tag(body, tag, value?)` · `has_tag` · `tag_value` · `remove_tag` · `list_tags` · `find_body(tag)` · `find_bodies(tag)` · `find_shapes(tag)` |
| **刚体辅助** | `set_gravity_scale` · `set_velocity` · `set_angular_velocity` · `set_active` · `is_active` · `velocity_at` · `center_of_mass` · `bounds` · `is_broken` |
| **形状辅助** | `shape_body` · `shape_bounds/size/voxels` · `shape_material_at(shape, world_point)` · `shape_material_at_index` · `set_shape_density` · `split_shape` · `merge_shape` · `is_shape_touching` · `is_shape_disconnected` · `shape_closest_point` · `create_shape` · `clear_shape` · `copy_shape_content` · `draw_shape_box` |

字段：`world`（底层 `PWorld`，想直接调底层接口时用）、
`auto_step`、`auto_render`。

### 门面替你保证的事

不封装时要自己盯住的一致性，现在都在这一层里：

1. **材质只有一张表** —— 颜色和密度在 `define_material` 里一次设好，
   不再需要同时维护 `PixelRenderer.palette` 和 `PWorld.material_density`。
2. **坐标系只有一套** —— 破坏/查询/施力/抓取全是世界坐标，内部自动换算。
3. **刚体增删与渲染同步** —— 破坏会让引擎增删刚体，门面负责 sync + prune，
   不会留下幽灵贴图；`resync()` 在改调色板后重建全部贴图。
4. **外力不跨帧累积** —— 门面在每步末清空累加器，"每帧 push 一次"就是持续力。
5. **帧率无关** —— `step` 内部是固定步长累加器，外部帧率波动不改变物理结果。

### 底层 API（需要精细控制时才用）

| 类 | 用途 |
|---|---|
| `PWorld` | `add_body` / `step` / `fracture` / `grab` / `cull_outside` / `enforce_body_budget`，以及全部 CCD / 原生开关 |
| `PBody` | 位姿、速度、质量属性、`rects`、`com_world()`、`to_world/to_local`、`apply_impulse`、`add_force/clear_forces` |
| `PixelShape` | `get_pixel` / `set_pixel` / `fill_rect` / `count_by_material` / `remap_material` |
| `Destruction` | `Damage.circle/segment/rect`、`apply_damage`、`split`（**Shape 局部坐标**，无分裂语义需要自己处理） |
| `Brush` | `stamp_circle` / `stroke_circle` / `erase_at` / `erase_stroke` |

---

## API 速查（底层）

### PWorld —— 世界

| 方法 | 说明 |
|---|---|
| `add_body(body, shape_list, density_of?) -> PBody` | 加入刚体。`shape_list` 是 `PixelShape` 数组；`density_of` 可给逐材质密度 |
| `remove_body(body)` | 移除 |
| `step(dt)` | 推进一个时间步（内部按需切子步） |
| `pre_step(dt) -> int` | **自己驱动子步时用它**：清接触事件 + 刷新质心 + 灰尘清理 + 子步估计，返回该切几个子步 |
| `advance(delta) -> int` | 固定步长累加器版本，返回执行了几步 |
| `fracture(body, damage, burst_speed?) -> Array` | **破坏**：返回新产生的碎片 Body |
| `grab(body, world_point, accel?) -> Grab` | 建立鼠标拖动（策略层，不是求解器约束） |
| `set_grab_target(p)` / `release_grab()` / `is_grabbing()` | 拖动 |
| `add_hinge / add_slider / add_weld / add_rope / add_spring(...) -> PJoint` | 建关节（`b` 传 `null` = 接静态世界） |
| `remove_joint(j)` / `joints_of(body)` / `is_jointed_to_static(body)` | 关节的移除与查询 |
| `cull_outside(bounds) -> int` | 清掉跑出边界的动态体 |
| `enforce_body_budget() -> int` | 按预算淘汰（最远的先死） |

关键字段：`gravity`、`terminal_speed`、`max_angular_velocity`（角速度上限，
Rapier 没有这个旋钮）、`rp_max_linear_velocity`、`min_fragment_pixels`、
`ccd_ignore_mass` / `debris_max_mass` / `debris_min_speed`（灰尘策略，默认关）、`sleeping_enabled`、
`sleep_linear`/`sleep_surface`/`sleep_delay`、`max_speculative_margin`、
`ccd_enabled`/`ccd_auto`/`ccd_max_motion`/`ccd_max_substeps`、
`ccd_substep_cost_budget_us` / `ccd_min_driver_thickness` / `ccd_per_body` / `max_surface_speed`
（小碎片 x CCD 的四道闸门，默认全关 —— 见 `docs/manual/performance.md` 的「小碎片」一节）、
`min_fragment_thickness`（太薄的碎片不生成刚体，随 `fracture_pixels` 的 `downgraded` 交回调用方）、
`bodies`、`joints`（活动关节）、`broken_joints`（断掉/移除掉的，供游戏层轮询）。

### PBody —— 刚体

状态：`position` / `rotation`（绕**质心**转）/ `linear_velocity` /
`angular_velocity` / `mass` / `inertia` / `inv_mass` / `inv_inertia` /
`local_com` / `awake` / `sleep_timer`。

几何：`shapes`（PixelShape 数组）/ `rects`（贪心分解出的 Rect2 数组）/
`aabb` / `swept_aabb` / `bounding_radius()`。

碰撞过滤：`collision_layer`（默认 1）/ `collision_mask`（默认全 1）——
语义同 Godot，**双方都得同意**才碰；`layer = 0` 表示不在任何层（幽灵）。

操作：`make_static()` / `make_dynamic()` /
`rebuild(shapes, density_of?, max_rects?)` / `update_aabb()` /
`com_world()` / `to_world(p)` / `to_local(p)` /
`velocity_at(p)` / `apply_impulse(impulse, at)` / `is_slow(lin, ang)`。

### Destruction —— 破坏

```gdscript
var d := Destruction.Damage.circle(center, radius)   # center 是本地像素坐标
var d := Destruction.Damage.segment(from, to, radius)
var d := Destruction.Damage.rect(center, half_size)

Destruction.apply_damage(shape, d) -> int            # 返回挖掉的像素数
Destruction.split(shape, min_pixels) -> Array        # 按连通性切块
```

⚠️ **破坏不等于碎片**：在圆盘正中心挖洞得到的是**环**——仍然连通，
所以正确地**不会**产生新刚体。要看到碎片，得让破坏真的把形状切断。

### Grab —— 抓取

`body` / `local_anchor` / `target` / `max_accel` /
`max_speed` / `max_omega`。
它和接触约束在**同一层迭代**，所以拖着物体撞墙时会自然互相制衡。

### PixelRenderer —— 渲染

`sync(body)` 同步一个 Body 的贴图；`prune(live_dict)` 回收已消失的；
`palette` 是材质 id -> Color。基于 Sprite2D + ImageTexture，每个 Body 一张图。

⚠️ 建贴图那一步（形状 -> RGBA8）走**原生**（`PixelRaster.fill_region`，
**0.028 us/像素**；GDScript 参照实现是 0.654 us/像素）。`shading = true`
或扩展缺失时退回 GDScript —— 两条路**逐字节一致**，闸门是
`tests/validation_raster_native.gd`。

---

## 原生加速（可选）

`native/` 里是宽相 + 窄相 + 求解器的 C++ 实现。**这是唯一实现** ——
GDScript 那一份已经删除，缺扩展时引擎会响亮地报错（不再静默回退）。

构建：

```bash
cd addons/pixel_destruction/native
g++ -O2 -std=c++17 -ffp-contract=off -shared -static-libgcc -static-libstdc++ \
    -I<gdextension_interface.h 所在目录> -o fastphys.dll fastphys.cpp
```

⚠️ **`-ffp-contract=off` 不能省** —— 少了它编译器会把浮点乘加融合成 FMA，
与 GDScript 路径立刻分叉（见 [docs/PRECISION.md](docs/PRECISION.md)）。

这个 DLL 里有两个类：`RapierPhys`（物理）与 `PixelRaster`（栅格化 + 矩形分解）。
后者**不依赖 Rapier 桥接**，所以 `rapier_bridge.dll` 没加载时它照样能用。

`PixelRaster` 有两个方法（同一个命令流，靠 op 字节分派）：`fill_region`（形状 -> RGBA8，
渲染用）与 `decompose`（像素团 -> 碰撞矩形集合，破坏用）。两个都有 GDScript 参照实现
（`shading = true` / 扩展缺失 / DLL 太旧时自动退回），判据是**逐位相同**：
`tests/validation_raster_native.gd` 与 `tests/validation_greedy_native.gd`。

启用：Godot **不会**自动扫描 `.gdextension`，必须在项目的
`.godot/extension_list.cfg` 里列出它的路径（一行一个，例如
`res://addons/pixel_destruction/native/fastphys.gdextension`）。

实测收益（503 物体 / 1120 流形）：

| 环节 | 收益 |
|---|---|
| 宽相（含数据搬运） | 1.9 ~ 2.5x |
| 求解器（含数据搬运） | 16 ~ 28x |
| 拖动时的 step | 慢 8.00x -> 1.06x（原生支持抓取后） |

---

## 设计取舍与已知限制

- **只用 OBB**：像素团被分解成矩形，所以窄相最多 2 点流形。好处是快且确定；
  代价是曲面/斜面会有轻微"阶梯感"（像素美术里通常看不出来）。
- **推测接触的边际不能大于子步位移上限**（默认 1.5 对 2.0）。这条是量出来的，
  越过它高速撞击会翻成陀螺。理由写在 `pworld.gd` 的字段注释里。
- **超高速仍然有限**：约 6000 px/s（每帧 100 px）以上，子步预算顶满后行为会退化。
  精确 sweep 已实现并验证（14/14），但触发判据还在收紧中。
- **`solve_batch.gd`（SoA 求解）默认关闭**：在本项目的 VM 上不如对象路径，
  留着作为"用内存布局换性能"的实验记录。
- **多线程默认关闭**：岛并行/着色并行都已实现且结果确定，
  但实测在这个 VM 上并发收益为负（GDScript 对象访问在多线程下膨胀）。
  C++ 侧没有这个问题，是未来最值得做的一块。

---

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 一个时间步里发生了什么
- [docs/PRECISION.md](docs/PRECISION.md) —— **精度纪律**：float32/float64 的全部边界，
  以及用真实 bug 换来的规则

## 许可

MIT，见包内的 `LICENSE`。

