# 精度纪律

**这份文档是迁移这个引擎时最不能跳过的东西。**

物理引擎"看起来对"和"逐位可复现"之间，隔着一串完全反直觉的规则。
下面每一条都对应一个真实修过的 bug —— 症状、根因、判据都写清楚，
因为**同样的坑会以完全不同的面貌再出现一次**。

核心事实：Godot 的 `Vector2` / `Rect2` 是 `real_t`（标准版 = **float32**），
而 **GDScript 的算术是 float64**。所有坑都源于这两者交界处的隐式转换。

---

## 一、类型转换规则（背下来）

### 1.1 向量运算是 float32，标量运算是 float64

```gdscript
var v := Vector2(1.1, 1.1)        # 存进去时就已经截成 float32
var a := v.x                       # 读出来是 double（值仍是 float32 能表示的那个）
var b := a * 3.0                   # 这是 double 运算
```

**判据**：看这一行**实际参与运算的是什么类型**，不是看值的来源。

### 1.2 `Vector2 * real_t` —— 标量**先截成 float32 再乘** ★

```gdscript
var dx := 1234.5678901234          # double，全精度
var imp := n * dx                  # 等价于 n * (float)dx —— 先截、再在 float32 里乘
```

C++ 里对应的错法：

```cpp
// ✗ 错：先 double 乘、最后才舍入
V2 imp = V2{ (float)((double)n.x * dx), (float)((double)n.y * dx) };
// ✓ 对：先把标量截成 float32，再在 float32 里相乘
static inline V2 vmul(V2 a, float s) { return V2{ a.x * s, a.y * s }; }
V2 imp = vmul(n, (float)dx);
```

**症状**：差 1 个 float32 ULP，单看不致命，但在病态的 2x2 LCP 里会被放大成
0.02 的速度差、让物体该睡不睡。**这个 bug 让求解器移植卡了整整两轮。**

### 1.3 `Vector2` **分量相减**是 double ★

```gdscript
var rhs_x := bias.x - v.x          # bias、v 都是 Vector2（分量 float32）
```

看起来是"两个 float32 相减"，但 GDScript 会把分量提升成 double 再减 ——
**结果是精确的 double 差值**，不是 float32。

```cpp
// ✗ 错：多了一次 float32 舍入
float rhs_x = bias.x - v.x;
// ✓ 对
double rhs_x = (double)bias.x - (double)v.x;
```

**症状**：同样 1 ULP，但这次踩在"限力阈值"上 —— 该抓取的 `next.length()`
恰好卡在 `max_impulse` 附近，1 ULP 直接让"要不要限力"翻面，delta 差 2.44e-4。

**1.2 和 1.3 是同一个陷阱的两个方向**：一个是不该截断的地方截断了，
一个是该在 float32 里算的地方用了 double。判据只有一条 ——
**这一行在 GDScript 里到底是什么类型在运算**。

### 1.4 `Vector2.rotated()` 会把**角度**先截成 float32

```gdscript
o.u = Vector2(cos(rot), sin(rot))   # obb_from_local_rect 的写法：全精度 double 三角函数
o2 = o.rotated(rot)                 # 等价于 rot_used = (float)rot，两者会分叉
```

移植时一律用 `Vector2(cos(a), sin(a))` 构造基向量。

### 1.5 `Rect2.grow(amount)` 同样截断 amount

扫掠 AABB 是 `aabb.grow(motion)`，其中 `motion` 是 `v * dt`（float32）
—— 保证两边一致即可，但**不要**在一边用 double 的 motion。

### 1.6 `absf` / `maxf` / `clampf` 返回 double

```gdscript
absf(u.dot(axis)) * h.x             # dot 是 float32，absf 之后是 double，乘出来是 double
```

`clampf` 的语义是 `v < lo ? lo : (v > hi ? hi : v)`（**不是** `min(max(v,lo),hi)`）——
NaN 行为不同。C++ 侧照抄这个嵌套写法。

### 1.7 存进 `Vector2` 就是一次舍入 ★

```gdscript
_warm[m.key] = {feat: Vector2(p.normal_impulse, p.tangent_impulse)}
```

累积冲量本来是 double，**存进 Vector2 时被舍入了一次**。
C++ 侧如果存成 double，两边从第 2 步起就会分叉（第 1 步缓存是空的，看不出来）。

---

## 二、编译器

### 2.1 `-ffp-contract=off` 是**必需**的

没有它，编译器会把 `a*b+c` 融合成 FMA（一次舍入而不是两次），
C++ 路径立刻与 GDScript 分叉。**这不是优化开关，是正确性开关。**

---

## 三、算法层面的陷阱

### 3.1 病态的 2x2 LCP 会放大 1 ULP ★★

接触的 `det = k11*k22 - k12^2` 在力臂很大时只有 ~1e-7 量级。
两次几乎相等的量相减，相对误差被放大若干数量级。

**结论**：在接触/求解路径上，**1 ULP 不是噪声**。
判断"这个差异是不是可以忽略"时，必须先看 `det` 的尺度。

### 3.2 `support()` 返回的是**角点**，不是"最近点" ★★★

OBB 的支撑点是**顶点**：面贴面时，切向那一轴的重叠是任意的
（由 `dot >= 0` 决定正负）。所以：

- 两个支撑点的**中点**当接触点是错的 ——
  小箱子 vs 半宽 2000 的地面时中点偏出**上千单位**，力臂随之暴增，
  `kn` 巨大 → `normal_mass ≈ 0` → **接触实际上失效**；
- 正确写法：法向取**两个支撑面的中点**，切向取**两盒切向重叠区间的中心**。
  面贴面时它正好是接触面中心，力臂为 0。

**这类"看起来对但其实没有约束力"的接触最危险** —— 它不会报错，
只会让另一套机制（穿透修正）意外地承担起全部工作。

### 3.3 `sort_custom` 是**不稳定排序**

它只看比较器的返回值。所以：**只要比较器返回的布尔序列不变，
排序结果的排列就不变**。

推论：把比较器里的属性访问换成 packed 数组读取是**安全的**
（省 0.9 ms/子步），但**换一个排序算法是不安全的**（并列元素的相对次序会变，
进而改变求解顺序，物理结果随之改变）。

### 3.4 `awake` 标志的读取时机

`prepare()`` 读**实时**的 `a.awake` 并缓存进 `m.wa`；
迭代里一律用缓存的 `m.wa`。移植时必须保持这个顺序 ——
否则"抓取约束把物体唤醒"这件事会在中途改变别的约束的行为。

### 3.5 数值约束：推测接触的边际必须**小于**子步位移上限 ★★★

`margin = min((rel+spin)*dt + 0.5, max_speculative_margin)`，
而 `bias = -sep/dt` 决定"这一子步允许多快接近"。

- 边际 ≈ 子步位移（2.0 对 2.0）→ `bias` 恰好允许物体**全速**撞上去、
  一点不刹车 → 高速撞击翻成陀螺并反弹；
- 边际太小（< 1.5）→ 缓冲不够，落地轻微抖动 → **睡不着**。

默认 1.5 对 2.0 是扫出来的甜点。**改任何一个都要重扫另一个。**

---

## 四、GDExtension 的坑（如果要用原生加速）

- **不要从 C++ 里 resize 一个 `PackedByteArray`** —— 直接段错误。
  输出一律走"调用方给模板 → 按模板拷贝 → 写 → 转回 Variant"。
- 输出缓冲被写满时，用"返回条数 == 容量"当溢出信号，让调用方扩容重试。
- `GDExtensionPropertyInfo` 的 `class_name` / `hint_string` **不能是 nullptr**，
  否则注册方法时段错误；要指向有效的空 `StringName` / `String`。
- `ptrcall` 在 GDScript 里**不会被调用**（GDScript 走 `call_func` / Variant），
  写 ptrcall 分支是死代码。
- 用 `variant_get_ptr_destructor` 时注意它**对 POD 类型返回 null**，
  不能当成必需检查。
- `alignas` 要写在 `static` **前面**。
- 输出 DLL 被残留的 Godot 进程占用时，链接会报 "Permission denied" —— 先杀进程。

---

## 五、GDScript 自身的坑

- `% ` 格式化**不支持 `%g` / `%e`** —— 用 `%.17f` / `%s` / `%d`。
- 从无类型 `Array` 取值做 `:=` 推断会触发
  "inferred from a Variant value" —— 项目把该警告当成**错误**，必须显式标注类型。
- `for x: T in untyped_array` 里 `T` 只是标注，不改变实际类型。
- 手工把 `_substep()` 拆成几个阶段来调试时，**千万别漏掉 `update_aabb()`** ——
  AABB 陈旧会让宽相完全不产生接触，"物体穿过墙壁"其实只是你的调试脚本错了。

---

## 六、怎么验证"我改对了"

这个引擎的所有移植工作都靠同一个套路：

1. **逐位状态摘要**：跑固定场景 N 步，把全体物体的位置/速度/角速度按
   高精度格式求和打印。任何一位变化都能看出来。
2. **逐帧定位首次分歧**：两个实现各跑一遍，逐帧比较，找**第一次**出现差异的帧
   和**第一次**出现差异的物体/字段。
3. **分层探针**：先比缓存内容 → 再比 prepare 的中间量 → 最后比迭代每一次的内部量。
   每次只加粗一层，**并且必须按 key/下标对齐**（曾经因为"前 N 次调用"错位对比，
   看着像分叉其实是在比不同的流形）。
4. **行为 vs 算术分开**：先判定"是逻辑差异还是舍入差异"——
   把某个机制整个关掉看差异是否消失，比自己推演快得多。

> 那条"去掉 warm start 假设"就是这么被**证伪**的：改完隧穿表毫无变化，
> 说明假设不成立，立刻回滚。**记录被证伪的假设和记录成功的修复一样重要。**
