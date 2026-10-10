//! Godot ↔ Rapier 的桥接层：**纯 C ABI**，Rust 侧拥有全部内存。
//!
//! 为什么是 C ABI + cdylib：
//!   · Godot 侧的 GDExtension 是 MinGW g++ 编的，Rust 是 MSVC 编的 ——
//!     跨 C++ ABI 不现实，跨 C ABI 是标准做法；
//!   · 只传基本类型与裸指针，内存一律由 Rust 分配/释放，调用方不 free 任何东西。
//!
//! 外部 id 用 u32，Rapier 侧存在 RigidBody::user_data 里 —— 这样遍历时能直接映射回来。

use rapier2d::prelude::*;
use std::collections::HashMap;

/// 仅提高有精度需求的刚体所在约束岛的求解次数，避免整个世界重复步进。
#[no_mangle]
pub extern "C" fn rb_body_set_solver_iterations(w: *mut World, id: u32, n: u32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        w.bodies[h].set_additional_solver_iterations(n as usize);
    }
}

pub struct World {
    bodies: RigidBodySet,
    colliders: ColliderSet,
    ij: ImpulseJointSet,
    mj: MultibodyJointSet,
    islands: IslandManager,
    bf: BroadPhaseBvh,
    nf: NarrowPhase,
    ccd: CCDSolver,
    soft: SoftBodySet,
    pipe: PhysicsPipeline,
    params: IntegrationParameters,
    gravity: Vector,
    map: HashMap<u32, RigidBodyHandle>,
    next_id: u32,
    /// 世界锚：给"一端接静态世界"的关节当第二个刚体（见 new() 里的说明）。
    anchor: RigidBodyHandle,
    /// 外部关节 id -> 记录。见 rb_joint_new。
    joints: HashMap<u32, JointRec>,
    next_joint_id: u32,
    // 每步只建立一次索引，避免逐对查询从头扫描造成 O(N²)。
    contact_pairs: Vec<(ColliderHandle, ColliderHandle)>,
    contacts_dirty: bool,

}

/// 一个关节在我们这边的记录（Rapier 侧只有句柄，类型得自己记 —— 限位/马达
/// 作用在哪根自由度轴上取决于它）。
struct JointRec {
    handle: ImpulseJointHandle,
    kind: i32,
}

impl World {
    fn new() -> Self {
        let mut bodies = RigidBodySet::new();
        // 世界锚。
        //
        // Rapier 的关节**必须**有两个刚体句柄 —— 没有"这一端接世界"的半边形式。
        // 所以整个世界共用一个位于原点、没有碰撞体的固定刚体：它位姿恒等，
        // 于是"世界坐标锚点"就等于它的局部锚点，调用方不用做任何换算。
        //
        // ⚠️ 它**不进 map**：map 是"外部 id -> 刚体"的表，而 rb_body_count /
        //    rb_body_remove / 状态读回全都按 map 遍历 —— 放进去等于凭空多出一个
        //    调用方没建过的刚体，而且 id 还会和真正的刚体撞号。
        let anchor = bodies.insert(RigidBodyBuilder::fixed());
        World {
            bodies,
            colliders: ColliderSet::new(),
            ij: ImpulseJointSet::new(),
            mj: MultibodyJointSet::new(),
            islands: IslandManager::new(),
            bf: BroadPhaseBvh::new(),
            nf: NarrowPhase::new(),
            ccd: CCDSolver::new(),
            soft: SoftBodySet::new(),
            pipe: PhysicsPipeline::new(),
            params: IntegrationParameters::default(),
            gravity: Vector::new(0.0, 600.0),
            map: HashMap::new(),
            next_id: 1,
            anchor,
            joints: HashMap::new(),
            next_joint_id: 1,
            contact_pairs: Vec::new(),
            contacts_dirty: true,
        }
    }

    /// 本步接触对索引；只存带代数的句柄，不跨步缓存点或冲量。
    fn index_contacts(&mut self) {
        if !self.contacts_dirty { return; }
        self.contact_pairs.clear();
        self.contact_pairs.extend(self.nf.contact_pairs()
            .filter(|p| p.has_any_active_contact())
            .map(|p| (p.collider1, p.collider2)));
        self.contacts_dirty = false;
    }

    /// Rapier 删刚体时连带删除关节；同步清理 id 表，防止句柄槽位复用导致 ABA。
    fn purge_joints(&mut self) {
        let ij = &self.ij;
        self.joints.retain(|_, rec| ij.contains(rec.handle));
    }
}

unsafe fn wref<'a>(w: *mut World) -> Option<&'a mut World> {
    if w.is_null() { None } else { Some(&mut *w) }
}

#[no_mangle]
pub extern "C" fn rb_world_new() -> *mut World {
    Box::into_raw(Box::new(World::new()))
}

#[no_mangle]
pub extern "C" fn rb_world_free(w: *mut World) {
    if !w.is_null() { unsafe { drop(Box::from_raw(w)); } }
}

#[no_mangle]
pub extern "C" fn rb_world_set_gravity(w: *mut World, x: f64, y: f64) {
    if let Some(w) = unsafe { wref(w) } { w.gravity = Vector::new(x as f32, y as f32); }
}

#[no_mangle]
pub extern "C" fn rb_world_step(w: *mut World, dt: f64) {
    if let Some(w) = unsafe { wref(w) } {
        w.params.dt = dt as f32;
        w.contacts_dirty = true;
        w.pipe.step(
            w.gravity, &w.params, &mut w.islands, &mut w.bf, &mut w.nf,
            &mut w.bodies, &mut w.colliders, &mut w.ij, &mut w.mj,
            &mut w.soft, &mut w.ccd, &(), &(),
        );
    }
}

/// 建刚体。is_static != 0 表示静态。返回外部 id（>0）。
#[no_mangle]
pub extern "C" fn rb_body_new(w: *mut World, is_static: i32, x: f64, y: f64, rot: f64) -> u32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    let builder = if is_static != 0 {
        RigidBodyBuilder::fixed()
    } else {
        RigidBodyBuilder::dynamic()
    }
    .translation(Vector::new(x as f32, y as f32))
    .rotation(rot as f32);
    let h = w.bodies.insert(builder);
    let id = w.next_id;
    w.next_id += 1;
    w.bodies[h].user_data = id as u128;
    w.map.insert(id, h);
    id
}

#[no_mangle]
pub extern "C" fn rb_body_remove(w: *mut World, id: u32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(h) = w.map.remove(&id) {
        w.contacts_dirty = true;
        w.bodies.remove(h, &mut w.islands, &mut w.colliders, &mut w.ij, &mut w.mj, &mut w.soft, true);
        // 挂在它上面的关节被 Rapier 一起删了 —— 我们的 id 表要跟着清（见 purge_joints）。
        w.purge_joints();
    }
}

/// 给刚体重建碰撞体：rects 是 4 个 f32 一组（局部 Rect2 的 x,y,w,h），与项目的分解结果一致。
/// 每次都先清空旧碰撞体 —— 像素破坏会让分解结果频繁变化。
#[no_mangle]
pub extern "C" fn rb_body_set_rects(w: *mut World, id: u32, rects: *const f32, count: i32, friction: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(&h) = w.map.get(&id) else { return };
    let old: Vec<ColliderHandle> = w.bodies[h].colliders().iter().copied().collect();
    w.contacts_dirty = true;
    for c in old {
        w.colliders.remove(c, &mut w.islands, &mut w.bodies, &mut w.soft, true);
    }
    if rects.is_null() || count <= 0 { return; }
    let r = unsafe { std::slice::from_raw_parts(rects, (count as usize) * 4) };
    for i in 0..count as usize {
        let (px, py, sx, sy) = (r[i * 4], r[i * 4 + 1], r[i * 4 + 2], r[i * 4 + 3]);
        w.colliders.insert_with_parent(
            ColliderBuilder::cuboid(sx * 0.5, sy * 0.5)
                .translation(Vector::new(px + sx * 0.5, py + sy * 0.5))
                .friction(friction as f32),
            h,
            &mut w.bodies,
        );
    }
}



// ==================== 像素形状 -> 凸多边形碰撞体（Noita 式拟合）====================
//
// 这一节把引擎的**精确覆盖矩形**（GreedyRects / PixelRaster op 2 的输出）拟合成
// **凸多边形**再交给 Rapier：斜边是直的（锯齿被拉平），块数远少于矩形。
//
// 为什么拟合在**这里**而不是 GDScript：碎片路径一次建几百个刚体，每个都要拟合一回。
// GDScript 实测 ~35 us/矩形（300 个碎片 = 40+ ms 卡顿），这里 ~1 us/矩形。
// GDScript 那份（src/core/poly_fit.gd）保留为**参照实现**，
// 闸门 tests/validation_poly_native.gd 逐位对拍（与矩形分解 op 2 同一个规矩）。
//
// ⚠️ 浮点纪律：点用 **f32** 存（对应 GDScript 的 Vector2）、叉积/面积用 **f64** 算
//    （对应 GDScript 的标量表达式）。两边的比较、求和顺序也必须一样 —— 否则
//    "并哪一块"这种离散选择会分叉，逐位对拍就成了同义反复。

#[derive(Clone, Copy)]
struct FitRect {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

impl FitRect {
    fn x1(&self) -> f32 {
        self.x + self.w
    }
    fn y1(&self) -> f32 {
        self.y + self.h
    }
    /// 面积用 f64 累加（GDScript 侧同样是 f64 表达式）。
    fn area(&self) -> f64 {
        self.w as f64 * self.h as f64
    }
}

fn fit_cross(o: (f32, f32), a: (f32, f32), b: (f32, f32)) -> f64 {
    (a.0 as f64 - o.0 as f64) * (b.1 as f64 - o.1 as f64)
        - (a.1 as f64 - o.1 as f64) * (b.0 as f64 - o.0 as f64)
}

/// Andrew 单调链 —— 与 HullFit.of_points 同一条规则：丢掉共线点、不重复首点。
fn fit_hull(points: &[(f32, f32)]) -> Vec<(f32, f32)> {
    let n = points.len();
    if n < 3 {
        return points.to_vec();
    }
    let mut pts = points.to_vec();
    // Vector2 的 operator< ：先 x 后 y（Godot vector2.h）
    pts.sort_by(|a, b| {
        if a.0 != b.0 {
            a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal)
        } else {
            a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal)
        }
    });
    let mut uniq: Vec<(f32, f32)> = Vec::with_capacity(n);
    for p in pts {
        if let Some(last) = uniq.last() {
            if *last == p {
                continue;
            }
        }
        uniq.push(p);
    }
    let n = uniq.len();
    if n < 3 {
        return uniq;
    }
    let mut lower: Vec<(f32, f32)> = Vec::with_capacity(n);
    for &p in uniq.iter() {
        while lower.len() >= 2
            && fit_cross(lower[lower.len() - 2], lower[lower.len() - 1], p) <= 0.0
        {
            lower.pop();
        }
        lower.push(p);
    }
    let mut upper: Vec<(f32, f32)> = Vec::with_capacity(n);
    for &p in uniq.iter().rev() {
        while upper.len() >= 2
            && fit_cross(upper[upper.len() - 2], upper[upper.len() - 1], p) <= 0.0
        {
            upper.pop();
        }
        upper.push(p);
    }
    let mut out: Vec<(f32, f32)> = Vec::with_capacity(lower.len() + upper.len());
    for i in 0..lower.len().saturating_sub(1) {
        out.push(lower[i]);
    }
    for i in 0..upper.len().saturating_sub(1) {
        out.push(upper[i]);
    }
    out
}

/// 有向面积（鞋带）。与 HullFit.signed_area 同序：f64 累加，最后 * 0.5。
fn fit_signed_area(poly: &[(f32, f32)]) -> f64 {
    let n = poly.len();
    if n < 3 {
        return 0.0;
    }
    let mut s = 0.0f64;
    for i in 0..n {
        let a = poly[i];
        let b = poly[(i + 1) % n];
        s += a.0 as f64 * b.1 as f64 - b.0 as f64 * a.1 as f64;
    }
    s * 0.5
}

fn fit_area(poly: &[(f32, f32)]) -> f64 {
    fit_signed_area(poly).abs()
}

/// 包围盒长边 —— 偏离判据的分母（幻影面积 / 长边 ≈ 平均厚度）。
fn fit_long_side(poly: &[(f32, f32)]) -> f64 {
    let mut lo_x = f64::INFINITY;
    let mut lo_y = f64::INFINITY;
    let mut hi_x = f64::NEG_INFINITY;
    let mut hi_y = f64::NEG_INFINITY;
    for p in poly {
        let x = p.0 as f64;
        let y = p.1 as f64;
        if x < lo_x {
            lo_x = x;
        }
        if y < lo_y {
            lo_y = y;
        }
        if x > hi_x {
            hi_x = x;
        }
        if y > hi_y {
            hi_y = y;
        }
    }
    (hi_x - lo_x).max(hi_y - lo_y)
}

struct FitOut {
    polys: Vec<Vec<(f32, f32)>>,
    pixel_area: f64,
    poly_area: f64,
    max_dev: f64,
}

fn fit_rects_to_polys(rects: &[FitRect], dev_tol: f64) -> FitOut {
    const CELL: f64 = 32.0;
    let n = rects.len();
    let mut out = FitOut {
        polys: Vec::new(),
        pixel_area: 0.0,
        poly_area: 0.0,
        max_dev: 0.0,
    };
    for r in rects {
        out.pixel_area += r.area();
    }
    if n == 0 {
        return out;
    }
    // ① 规范顺序：按 (y, x)（结果必须是矩形集合的纯函数）
    let mut order: Vec<usize> = (0..n).collect();
    order.sort_by(|&a, &b| {
        let ra = &rects[a];
        let rb = &rects[b];
        if ra.y != rb.y {
            ra.y.partial_cmp(&rb.y).unwrap_or(std::cmp::Ordering::Equal)
        } else {
            ra.x.partial_cmp(&rb.x).unwrap_or(std::cmp::Ordering::Equal)
        }
    });
    // ② 空间哈希（插入顺序 = 规范顺序，邻居的枚举顺序因此确定）
    let cell_of = |v: f32| -> i32 { (v as f64 / CELL).floor() as i32 };
    let mut buckets: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
    for &i in &order {
        let r = &rects[i];
        let c0x = cell_of(r.x);
        let c0y = cell_of(r.y);
        let c1x = cell_of(r.x1());
        let c1y = cell_of(r.y1());
        for cy in c0y..=c1y {
            for cx in c0x..=c1x {
                buckets.entry((cx, cy)).or_default().push(i);
            }
        }
    }
    let touches = |a: &FitRect, b: &FitRect| -> bool {
        a.x as f64 <= b.x as f64 + b.w as f64
            && b.x as f64 <= a.x as f64 + a.w as f64
            && a.y as f64 <= b.y as f64 + b.h as f64
            && b.y as f64 <= a.y as f64 + a.h as f64
    };
    // 与 box 相接的未分配矩形（顺序 = 桶里数组的顺序 = 规范顺序）
    let neighbors = |buckets: &HashMap<(i32, i32), Vec<usize>>,
                     used: &[bool],
                     box_: &FitRect|
     -> Vec<usize> {
        let mut out: Vec<usize> = Vec::new();
        let c0x = cell_of(box_.x - 1.0);
        let c0y = cell_of(box_.y - 1.0);
        let c1x = cell_of(box_.x1() + 1.0);
        let c1y = cell_of(box_.y1() + 1.0);
        for cy in c0y..=c1y {
            for cx in c0x..=c1x {
                if let Some(arr) = buckets.get(&(cx, cy)) {
                    for &i in arr {
                        if used[i] || out.contains(&i) {
                            continue;
                        }
                        if touches(box_, &rects[i]) {
                            out.push(i);
                        }
                    }
                }
            }
        }
        out
    };
    let mut used = vec![false; n];
    for &start in &order {
        if used[start] {
            continue;
        }
        used[start] = true;
        let r0 = rects[start];
        let mut part_pts: Vec<(f32, f32)> = vec![
            (r0.x, r0.y),
            (r0.x1(), r0.y),
            (r0.x1(), r0.y1()),
            (r0.x, r0.y1()),
        ];
        let mut part_area = r0.area();
        let mut part_box = r0;
        let mut poly: Vec<(f32, f32)> = Vec::new();
        let mut frontier: Vec<usize> = neighbors(&buckets, &used, &part_box);
        loop {
            let mut grew = false;
            for k in 0..frontier.len() {
                let j = frontier[k];
                if used[j] {
                    continue;
                }
                let r2 = rects[j];
                if !touches(&part_box, &r2) {
                    continue;
                }
                let mut mpts = part_pts.clone();
                mpts.push((r2.x, r2.y));
                mpts.push((r2.x1(), r2.y));
                mpts.push((r2.x1(), r2.y1()));
                mpts.push((r2.x, r2.y1()));
                let cand = fit_hull(&mpts);
                if cand.len() < 3 {
                    continue;
                }
                let merged_area = part_area + r2.area();
                let dev = (fit_area(&cand) - merged_area) / fit_long_side(&cand).max(1.0);
                if dev > dev_tol {
                    continue;
                }
                part_pts = cand.clone();
                part_area = merged_area;
                part_box = FitRect {
                    x: part_box.x.min(r2.x),
                    y: part_box.y.min(r2.y),
                    w: part_box.x1().max(r2.x1()) - part_box.x.min(r2.x),
                    h: part_box.y1().max(r2.y1()) - part_box.y.min(r2.y),
                };
                poly = cand;
                used[j] = true;
                frontier.retain(|&v| v != j);
                for k2 in neighbors(&buckets, &used, &r2) {
                    if !frontier.contains(&k2) {
                        frontier.push(k2);
                    }
                }
                grew = true;
                break;
            }
            if !grew {
                break;
            }
        }
        if poly.len() < 3 {
            poly = fit_hull(&part_pts);
        }
        if poly.len() < 3 {
            continue;
        }
        let dev = (fit_area(&poly) - part_area) / fit_long_side(&poly).max(1.0);
        if dev > out.max_dev {
            out.max_dev = dev;
        }
        out.poly_area += fit_area(&poly);
        out.polys.push(poly);
    }
    out
}

/// 把矩形集合拟合成凸多边形碰撞体（Noita 式），并**直接从质量定密度**。
///
/// 返回拟合出来的多边形个数（诊断用）。
///
/// ⚠️ 密度为什么在这里定，而不是让 GDScript 推 op 34：拟合出来的多边形面积
///    >= 像素面积（幻影），推"材质密度"会让 Rapier 的质量比 GDScript 的 mass
///    大出幻影那一份（薄形状能差 2 倍 —— 而所有按 mass 算的力都会跟着错）。
///    这里按 **质量 / 多边形总面积** 反算密度，于是两边的**总质量一致**
///    （惯量分布略有差异：多边形 vs 像素，可接受）。
#[no_mangle]
pub extern "C" fn rb_body_fit_polys(
    w: *mut World,
    id: u32,
    rects: *const f32,
    count: i32,
    friction: f64,
    mass: f64,
    dev_tol: f32,
) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    if rects.is_null() || count <= 0 {
        return 0;
    }
    let Some(&h) = w.map.get(&id) else { return 0 };
    let raw = unsafe { std::slice::from_raw_parts(rects, (count as usize) * 4) };
    let mut rs: Vec<FitRect> = Vec::with_capacity(count as usize);
    for i in 0..count as usize {
        rs.push(FitRect {
            x: raw[i * 4],
            y: raw[i * 4 + 1],
            w: raw[i * 4 + 2],
            h: raw[i * 4 + 3],
        });
    }
    let fit = fit_rects_to_polys(&rs, dev_tol as f64);
    let old: Vec<ColliderHandle> = w.bodies[h].colliders().iter().copied().collect();
    w.contacts_dirty = true;
    for c in old {
        w.colliders.remove(c, &mut w.islands, &mut w.bodies, &mut w.soft, true);
    }
    let mut pts: Vec<Vector> = Vec::new();
    for p in &fit.polys {
        pts.clear();
        pts.reserve(p.len());
        for &(x, y) in p {
            pts.push(Vector::new(x, y));
        }
        if let Some(builder) = ColliderBuilder::convex_hull(&pts) {
            w.colliders
                .insert_with_parent(builder.friction(friction as f32), h, &mut w.bodies);
        }
    }
    if fit.poly_area > 0.0 && mass > 0.0 {
        let d = (mass / fit.poly_area) as Real;
        let cols: Vec<ColliderHandle> = w.bodies[h].colliders().iter().copied().collect();
        for c in cols {
            w.colliders[c].set_density(d);
        }
        if let Some(rb) = w.bodies.get_mut(h) {
            rb.recompute_mass_properties_from_colliders(&w.colliders);
        }
    }
    fit.polys.len() as i32
}

/// Rapier 侧的质量 —— 给"密度补偿"当判据用。
///
/// ⚠️ 为什么要有它：拟合出来的碰撞体面积 >= 像素面积（幻影），所以密度必须按
///    **质量 / 多边形面积** 反算。反算错了不会报错，只会让两边质量静默分叉
///    （所有按 mass 算的力都跟着错）—— 所以闸门要能**量**到 Rapier 的质量。
#[no_mangle]
pub extern "C" fn rb_body_get_mass(w: *mut World, id: u32) -> f64 {
    let Some(w) = (unsafe { wref(w) }) else { return 0.0 };
    match w.map.get(&id) {
        Some(&h) => w.bodies[h].mass() as f64,
        None => 0.0,
    }
}

/// Rapier 侧的角惯量（绕刚体原点）—— 与 rb_body_get_mass 配套的诊断量。
#[no_mangle]
pub extern "C" fn rb_body_get_inertia(w: *mut World, id: u32) -> f64 {
    let Some(w) = (unsafe { wref(w) }) else { return 0.0 };
    match w.map.get(&id) {
        Some(&h) => {
            let mp = w.bodies[h].mass_properties();
            mp.local_mprops.principal_inertia() as f64
        }
        None => 0.0,
    }
}

/// 读回一个刚体**当前**的碰撞体形状（凸多边形 / 矩形都按多边形给）—— 可视化与闸门用。
///
/// out 布局（小端）：[0] i32 n_polys，然后每个多边形 i32 count + count x (f32 x, f32 y)。
/// 返回**写入/需要的字节数**（> out_cap 表示不够，调用方按它重开一次再调）。
///
/// ⚠️ 这是"**问物理要真相**"：读的是 Rapier 里真的在用的形状，而不是 GDScript 侧
///    另算一份 —— 那样可视化会和碰撞体悄悄分叉（本仓库为"调试可视化画错"栽过：
///    它比没有可视化更糟，会把人引到错误方向）。
#[no_mangle]
pub extern "C" fn rb_body_get_polys(w: *mut World, id: u32, out: *mut u8, out_cap: i32) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    let Some(&h) = w.map.get(&id) else { return 0 };
    let cols: Vec<ColliderHandle> = w.bodies[h].colliders().iter().copied().collect();
    let mut counts: Vec<usize> = Vec::with_capacity(cols.len());
    let mut need = 4usize;
    for c in &cols {
        let n = match w.colliders[*c].shape().as_typed_shape() {
            TypedShape::Cuboid(_) => 4,
            TypedShape::ConvexPolygon(p) => p.points().len(),
            _ => 0,
        };
        counts.push(n);
        need += 4 + n * 8;
    }
    if out.is_null() || (out_cap as usize) < need {
        return need as i32;
    }
    unsafe {
        let dst = std::slice::from_raw_parts_mut(out, need);
        let put_i32 = |d: &mut [u8], off: usize, v: i32| {
            d[off..off + 4].copy_from_slice(&v.to_le_bytes());
        };
        let put_f32 = |d: &mut [u8], off: usize, v: f32| {
            d[off..off + 4].copy_from_slice(&v.to_le_bytes());
        };
        put_i32(dst, 0, cols.len() as i32);
        let mut off = 4usize;
        for (i, c) in cols.iter().enumerate() {
            let col = &w.colliders[*c];
            let t = col.translation();
            put_i32(dst, off, counts[i] as i32);
            off += 4;
            match col.shape().as_typed_shape() {
                TypedShape::Cuboid(cu) => {
                    let hx = cu.half_extents.x;
                    let hy = cu.half_extents.y;
                    for (sx, sy) in [(-1.0f32, -1.0f32), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
                        put_f32(dst, off, t.x + hx * sx);
                        put_f32(dst, off + 4, t.y + hy * sy);
                        off += 8;
                    }
                }
                TypedShape::ConvexPolygon(p) => {
                    for v in p.points() {
                        put_f32(dst, off, t.x + v.x);
                        put_f32(dst, off + 4, t.y + v.y);
                        off += 8;
                    }
                }
                _ => {}
            }
        }
    }
    need as i32
}

#[no_mangle]
pub extern "C" fn rb_body_set_pose(w: *mut World, id: u32, x: f64, y: f64, rot: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        w.bodies[h].set_translation(Vector::new(x as f32, y as f32), true);
        w.bodies[h].set_rotation(Rot2::new(rot as f32), true);
    }
}

#[no_mangle]
pub extern "C" fn rb_body_set_vel(w: *mut World, id: u32, vx: f64, vy: f64, ang: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        w.bodies[h].set_linvel(Vector::new(vx as f32, vy as f32), true);
        w.bodies[h].set_angvel(ang as f32, true);
    }
}

/// 读回状态：out 至少 6 个 f64 —— x, y, rot, vx, vy, angvel。返回 1 表示成功。
#[no_mangle]
pub extern "C" fn rb_body_get_state(w: *mut World, id: u32, out: *mut f64) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    let Some(&h) = w.map.get(&id) else { return 0 };
    if out.is_null() { return 0; }
    let b = &w.bodies[h];
    let p = b.translation();
    let v = b.linvel();
    unsafe {
        *out = p.x as f64;
        *out.add(1) = p.y as f64;
        *out.add(2) = b.rotation().angle() as f64;
        *out.add(3) = v.x as f64;
        *out.add(4) = v.y as f64;
        *out.add(5) = b.angvel() as f64;
    }
    1
}

/// 施加**持久**力与力矩（Rapier 每步之后会自己清掉，所以每子步加一次 = 持久）。
/// 项目的 accum_force 是 Box2D 那种"显式 clear_forces 才清"的模型 ——
/// 两者语义在"每子步加一次"下等价。
#[no_mangle]
pub extern "C" fn rb_body_add_force(w: *mut World, id: u32, fx: f64, fy: f64, torque: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        w.bodies[h].add_force(Vector::new(fx as f32, fy as f32), true);
        // ⚠️⚠️ 这里**曾经被我加过一句 add_torque，然后被撤掉了** —— 记下来免得再犯：
        //    我看到"力矩好像没生效"（摆动调不衰减），就补了一句 add_torque；
        //    结果 `validation_dynamics` 的两条**解析解**断言立刻变成 2 倍
        //    （单步 Δω 实测 0.000619 vs 解析 0.000309）—— 力矩本来就在这条路径上
        //    生效，我那一句是**重复施加**。
        //    真相：摆动停不下来不是力矩丢了，是**抓取在泵能量**（见 grab.gd）。
        //    教训："某个量好像没生效"先找**解析解断言**对一下，别急着补代码。
        if torque != 0.0 { w.bodies[h].add_torque(torque as f32, true); }
    }
}

/// 设置长度单位。
///
/// ⚠️ **这是像素世界必须设的一个参数，不设会静默地错一大片。**
/// Rapier 的 IntegrationParameters 默认按"米"调（length_unit = 1.0），
/// 而下面这**一整组**长度相关参数都是乘 length_unit 得到的：
///
///     allowed_linear_error        0.005 * u     （默认 0.005 px —— 紧到几乎为零）
///     max_corrective_velocity     3.0   * u     （默认 3 px/s —— 穿透挤出慢得离谱）
///     prediction_distance         0.02  * u     （默认 0.02 px —— 等于没有推测接触）
///     max_linear_velocity         400.0 * u     （默认 400 px/s —— **钳住所有速度**）
///     contact_recycle_distance    0.05  * u
///
/// 实测症状：自由落体的速度无论重力多大都停在 **397.68 px/s**（正好逼近 400），
/// g=900 和 g=600 给出同一个终速 —— 一眼看去很像阻尼，其实不是
/// （阻尼的终速是 g/d，会随重力变）。
///
/// 100.0 是 Rapier 文档自己给像素游戏的建议值（"100 pixels = 1 meter"）。
#[no_mangle]
pub extern "C" fn rb_world_set_length_unit(w: *mut World, unit: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    w.params.length_unit = unit as f32;
}

/// 单独设置**最大线速度**（归一化值）。
///
/// 为什么不直接用 length_unit 一刀切：length_unit 会同时缩放
/// allowed_linear_error / max_corrective_velocity / prediction_distance /
/// contact_recycle_distance，实测设成 100 会让 validation_dynamics 的
/// "持续力矩 60 步"变成 ω 恒为 0。像素尺度要**逐参数**处理。
///
/// Rapier 默认 normalized_max_linear_velocity = 400.0（按米调的），
/// 在像素世界里表现为"速度无论重力多大都停在 397.68 px/s"。
#[no_mangle]
pub extern "C" fn rb_world_set_max_linear_velocity(w: *mut World, v: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    w.params.normalized_max_linear_velocity = v as f32;
}

/// 一次性设置三个**长度相关**的归一化参数（像素尺度需要逐参数调）。
///
///   pred_dist   normalized_prediction_distance   默认 0.02 —— **推测接触距离**
///   corr_vel    normalized_max_corrective_velocity 默认 3.0 —— 穿透挤出的速度上限
///   allowed_err normalized_allowed_linear_error  默认 0.005 —— 允许的线性误差
///
/// ⚠️ 默认值全是按"米"调的。在像素世界里 prediction_distance = 0.02 px
///    等于**没有推测接触** —— 快物体直接穿过薄几何（穿模）。
///    本引擎原本的 max_speculative_margin 是 1.5 px，就是同一个机制。
#[no_mangle]
pub extern "C" fn rb_world_set_pixel_params(w: *mut World, pred_dist: f64, corr_vel: f64, allowed_err: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    w.params.normalized_prediction_distance = pred_dist as f32;
    w.params.normalized_max_corrective_velocity = corr_vel as f32;
    w.params.normalized_allowed_linear_error = allowed_err as f32;
}

/// 开关 CCD（对应 PWorld.ccd_enabled）。
/// ⚠️ Rapier 的 CCD **默认是关的**（逐刚体），不设的话这个开关等于被静默忽略。
/// 开关 CCD 并设置**软 CCD 预测距离**（对应 PWorld.ccd_enabled / rp_soft_ccd_prediction）。
///
/// ⚠️ Rapier 的 CCD 有四个旋钮，enable_ccd 只是其中最弱的一个：
///   · enable_ccd(bool)                逐刚体，默认 **false**
///   · set_soft_ccd_prediction(距离)   逐刚体，默认 **0.0 —— 等于关着**
///   · IntegrationParameters::max_ccd_substeps  默认 **1**（同时是全局开关，0 = 全关）
///   · IntegrationParameters::min_ccd_dt        默认 1/6000
///
/// soft_ccd_prediction 是**推测 CCD**：把碰撞体按这个距离外扩去做连续检测。
/// 它就是本引擎原本 max_speculative_margin(1.5 px) 的对应物 ——
/// 默认 0.0 意味着快物体没有任何提前量，这正是穿模的来源。
#[no_mangle]
pub extern "C" fn rb_body_set_ccd(w: *mut World, id: u32, enabled: i32, soft_pred: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        w.bodies[h].enable_ccd(enabled != 0);
        w.bodies[h].set_soft_ccd_prediction(soft_pred as f32);
    }
}

/// CCD 子步上限。**它同时是全局 CCD 开关**（0 = 整个世界关掉 CCD，
/// 包括"快动态体 vs 固定碰撞体"的自动 CCD）。默认 1 太小 ——
/// 大步长（低帧率 / 帧卡顿 / 爆炸初速）下一次子步撑不住。
#[no_mangle]
pub extern "C" fn rb_world_set_ccd_substeps(w: *mut World, n: u32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    w.params.max_ccd_substeps = n as usize;
}

/// 清空累积的力与力矩。
///
/// ⚠️ 必须有这个：Rapier 的 add_force 是**跨步累积**的（直到 reset_forces），
/// 而引擎的 accum_force 是"当前总力"语义（Box2D 那种，显式 clear_forces 才清）。
/// 直接每步 add 一次会让力矩按 1+2+…+N 增长 —— 实测 60 步差 33 倍。
/// 正确做法是"先 reset 再 add"，等价于 set。
#[no_mangle]
pub extern "C" fn rb_body_reset_forces(w: *mut World, id: u32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        w.bodies[h].reset_forces(false);
        w.bodies[h].reset_torques(false);
    }
}

/// 线性/角阻尼。Rapier 的公式是 v *= 1/(1+damping*dt)，与引擎 _integrate_forces
/// 里那两行**完全同构** —— 所以直接把引擎的值设进去就等价，不需要自己再乘一遍。
#[no_mangle]
pub extern "C" fn rb_body_set_damping(w: *mut World, id: u32, lin: f64, ang: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        w.bodies[h].set_linear_damping(lin as f32);
        w.bodies[h].set_angular_damping(ang as f32);
    }
}

/// 重力缩放（对应 PBody.gravity_scale）。Rapier 是逐刚体的 —— 直接设。
#[no_mangle]
pub extern "C" fn rb_body_set_gravity_scale(w: *mut World, id: u32, scale: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        w.bodies[h].set_gravity_scale(scale as f32, true);
    }
}

/// 静态 <-> 动态切换（对应 PBody.make_static / make_dynamic）。
#[no_mangle]
pub extern "C" fn rb_body_set_type(w: *mut World, id: u32, is_static: i32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) {
        let t = if is_static != 0 { RigidBodyType::Fixed } else { RigidBodyType::Dynamic };
        w.bodies[h].set_body_type(t, true);
    }
}

#[no_mangle]
pub extern "C" fn rb_body_is_sleeping(w: *mut World, id: u32) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    match w.map.get(&id) {
        Some(&h) => if w.bodies[h].is_sleeping() { 1 } else { 0 },
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn rb_body_wake(w: *mut World, id: u32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(&h) = w.map.get(&id) { w.bodies[h].wake_up(true); }
}

/// 接触对数量（只数有流形点的）。
#[no_mangle]
pub extern "C" fn rb_contact_count(w: *mut World) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    w.index_contacts();
    w.contact_pairs.len() as i32
}

/// 读第 i 个接触对：out 至少 **8** 个 f64 ——
/// id_a, id_b, nx, ny, px, py, dist, impulse。
///
/// ⚠️ 法向与接触点都必须是**世界系**：
///   · 法向直接取 Rapier 的 \`ContactManifoldData.normal\`（它本来就是世界系）；
///   · 点要由 **collider1 的位姿**把 \`local_p1\` 变换过去 —— 它本身是 collider1 的局部坐标。
///     第一版直接把它当世界坐标输出，结果是错的（但看起来"有个数"）。
// ⚠️⚠️ rb_contact_get（旧 op 12）**已删除**。
//    它只取 manifolds().first() 的 points.first() 作**位置**，却用 pair.total_impulse()
//    作**冲量** —— 整个面的冲量被附在一个代表点上，宽面撞击照着它打洞就是一次尖刺。
//    而且实测它在项目里静默返回全 0（tests/diag_contact_points4.gd 有记录）。
//    替代品是 rb_contact_get_points（op 35）：全部流形 × 全部点，每点带**自己的**冲量。

/// 读第 i 个接触对的**全部接触点**：out 至少 4 + 6*n 个 f64 ——
/// id_a, id_b, n_points, total_impulse，然后每个点 nx, ny, px, py, dist, impulse。
/// 返回**点个数**；cap 不够时只返回个数、不写数据，调用方扩容后重来。
///
/// ⚠️⚠️⚠️ **这条路径在本项目里是死的，别指望它** —— 2026-10 实测
/// （tests/diag_contact_points2.gd）：方块平放在地面上**确实停住**了
/// （底面 100.008 vs 地面顶 100，正好是 penetration_slop），但每一帧接触对都是 0。
///
/// 真因：判据 `has_any_active_contact()` 查的是 Rapier 的 **solver_manifolds**
/// （源码：`self.solver_manifolds().iter().any(|m| !m.data.solver_contacts.is_empty())`），
/// 而本项目默认走**自己的**宽相与求解器（use_native_solve/use_native_broadphase ->
/// _packed_manifolds），**Rapier 的求解器根本不跑** -> solver_manifolds 永远为空。
/// 于是 op 11 / op 12 / 这条 op 35 都拿不到任何东西，**而且不报任何错**。
/// （项目自己的墓碑 pworld.gd:1366 已经记着半句："冲量留在 C++ 里且**不回写**"。）
///
/// 要拿到"全部接触点 + 各自冲量"，正确的数据源是**项目自己的流形**：
/// _broadphase_native 的打包数据（C++ 侧）/ GDScript 的 manifolds 对象数组。
/// 冲量也在那边 —— 要补的是**把每个点的冲量回写出来**，不是再从 Rapier 里读一遍。
///
/// ⚠️ 下面这段代码本身是对的（遍历所有流形 × 所有点、取每点自己的冲量），
///    只是**数据源是空的**。等数据源换到项目自己的流形上，这段逻辑可以复用。
///
/// ⚠️ 为什么必须导出**全部**点：一次物理更新里，整个面可以同时存在多个接触点
/// （面-面接触通常 2 个，见 Rapier 的流形），引擎内部本来就是按多点求解的。
/// 旧接口 rb_contact_get 只取 `manifolds().first()` 的 `points.first()` 作**位置**，
/// 却用 `pair.total_impulse()` 作**冲量** —— 整个面受到的冲量被附在一个代表点上返回了。
/// 消费方若照着这个点打洞，宽面撞击就会错误地集中成一次尖刺攻击。
/// 60 Hz 是**更新时间**，不是接触数量限制。
#[no_mangle]
pub extern "C" fn rb_contact_get_points(w: *mut World, i: i32, out: *mut f64, cap: i32) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    if out.is_null() || i < 0 { return 0; }
    w.index_contacts();
    let Some(&(ca, cb)) = w.contact_pairs.get(i as usize) else { return 0 };
    if let Some(pair) = w.nf.contact_pair(ca, cb) {
        let ca = pair.collider1;
        let cb = pair.collider2;
        let ida = w.colliders[ca].parent().map(|h| w.bodies[h].user_data as u32).unwrap_or(0);
        let idb = w.colliders[cb].parent().map(|h| w.bodies[h].user_data as u32).unwrap_or(0);
        let pose = w.colliders[ca].position();
        let total = pair.total_impulse().length();
        let mut n = 0i32;
        for m in pair.manifolds() {
            n += m.points.len() as i32;
        }
        if cap < 4 + n * 9 {
            return n; // 让调用方扩容后重来
        }
        unsafe {
            *out = ida as f64;
            *out.add(1) = idb as f64;
            *out.add(2) = n as f64;
            *out.add(3) = total as f64;
        }
        let mut o = 4usize;
        for m in pair.manifolds() {
            let nrm = m.data.normal;
            for pt in m.points.iter() {
                let p = pose.translation + pose.rotation * pt.local_p1;
                unsafe {
                    *out.add(o) = nrm.x as f64;
                    *out.add(o + 1) = nrm.y as f64;
                    *out.add(o + 2) = p.x as f64;
                    *out.add(o + 3) = p.y as f64;
                    *out.add(o + 4) = pt.dist as f64;
                    // ⚠️ 流形里的点是 parry 的 TrackedContact<ContactData> 包装：
                    //    几何（local_p1/dist）在包装上，**冲量在内层的 data 里**。
                    //    写 pt.impulse 编译不过（no field impulse on TrackedContact）。
                    *out.add(o + 5) = pt.data.impulse as f64;
                    // 接触特征 id（parry 的 PackedFeatureId -> u32）：
                    // 这两个合起来标识"同一个接触特征"，跨帧稳定 —— warm start 靠它，
                    // 多点伤害也靠它避免"同一特征被重复领取预算"。
                    // 切向（**摩擦**）冲量：接触点的冲量是"法向 + 切向"两个分量之和，
                    // 只有摩擦为零时才沿法向。这里是切向那个标量（2D 的切空间是 1 维），
                    // 世界向量 = perp(法向) * 它。符号遵循 Rapier 的约定。
                    *out.add(o + 6) = pt.data.tangent_impulse.x as f64;
                    *out.add(o + 7) = pt.fid1.0 as f64;
                    *out.add(o + 8) = pt.fid2.0 as f64;
                }
                o += 9;
            }
        }
        return n;
    }
    0
}

#[no_mangle]
pub extern "C" fn rb_body_count(w: *mut World) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    w.map.len() as i32
}

// ================= 关节（约束） =================
//
// 五种类型，都用 Rapier 的**冲量关节**（ImpulseJoint）：
//   0 hinge   铰链（RevoluteJoint）    只剩一个转动自由度，可限位、可上马达
//   1 slider  滑轨（PrismaticJoint）   只剩沿轴平移
//   2 weld    焊接（FixedJoint）       完全锁死
//   3 rope    绳（RopeJoint）          只限制**最大**距离（不可伸长）
//   4 spring  弹簧（SpringJoint）      拉向静止长度
//
// 为什么不用 MultibodyJoint（多体关节）：那是**树形**结构（父子刚体、刚度更高、
// 同样迭代次数下更硬），但插入/删除要维护整棵树，而且同一个刚体不能同时属于
// 两棵树 —— 破坏类玩法随时会切开刚体、随时建/删关节。冲量关节是**图**结构，
// 任意两个刚体都能连，正合这种用法。
const JK_HINGE: i32 = 0;
const JK_SLIDER: i32 = 1;
const JK_WELD: i32 = 2;
const JK_ROPE: i32 = 3;
const JK_SPRING: i32 = 4;

/// 关节的自由度轴：铰链是角度（AngX），其余都是"沿轴的距离"（LinX）。
fn joint_axis(kind: i32) -> JointAxis {
    if kind == JK_HINGE { JointAxis::AngX } else { JointAxis::LinX }
}

/// 外部 id -> 刚体句柄。**id = 0 表示静态世界**（世界锚刚体）。
fn body_handle(w: &World, id: u32) -> Option<RigidBodyHandle> {
    if id == 0 { Some(w.anchor) } else { w.map.get(&id).copied() }
}

/// 建关节。返回外部关节 id（>0）；0 = 失败。
///
///   kind           上面的 0..4
///   id_a / id_b    两个刚体的外部 id；**0 = 静态世界**
///   a1x,a1y        锚点 A，**刚体 A 的局部坐标**（世界锚时就是世界坐标）
///   a2x,a2y        锚点 B，刚体 B 的局部坐标
///   axis_x,axis_y  滑轨的轴，**世界坐标**
///   p1,p2,p3       绳：最大长度；弹簧：静止长度 / 刚度 / 阻尼
#[no_mangle]
pub extern "C" fn rb_joint_new(
    w: *mut World, kind: i32, id_a: u32, id_b: u32,
    a1x: f64, a1y: f64, a2x: f64, a2y: f64,
    axis_x: f64, axis_y: f64,
    p1: f64, p2: f64, p3: f64,
) -> u32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    let Some(ha) = body_handle(w, id_a) else { return 0 };
    let Some(hb) = body_handle(w, id_b) else { return 0 };
    // 自己连自己：相对位姿恒为 0，约束退化，Rapier 的求解会直接给出 NaN。
    if ha == hb { return 0; }
    let a1 = Vector::new(a1x as f32, a1y as f32);
    let a2 = Vector::new(a2x as f32, a2y as f32);
    // ⚠️ rotation() 返回的是**引用**；下面要做乘法/求逆，所以这里拷一份（Rot2 是 Copy）。
    let r1: Rotation = *w.bodies[ha].rotation();
    let r2: Rotation = *w.bodies[hb].rotation();

    // 关节帧的旋转必须是"创建时的相对朝向"。
    //
    // ⚠️ Rapier 的 builder 默认把两个关节帧的旋转都设成**单位旋转**，于是：
    //    · 铰链的 angle() 从"两个刚体当前朝向之差"起算 —— 两个各自转了 90° 的
    //      刚体一连上，限位 [0, 0.5] 当场就是满的（角度根本不是从 0 开始的）；
    //    · 焊接会把两个刚体硬拧到**同一个朝向**（创建瞬间就有一个巨大的初始误差，
    //      表现为"焊完自己转一下才停"）。
    //    把 frame2 的旋转设成 R2⁻¹·R1 之后，创建时刻的约束误差恒为 0，
    //    角度/相对位姿都从 0 起算 —— 这才是"关节"该有的语义。
    let rel = (r2.inverse() * r1).angle();

    let mut j: GenericJoint = match kind {
        JK_HINGE => RevoluteJointBuilder::new().build().into(),
        JK_SLIDER => PrismaticJointBuilder::new(Vector::X).build().into(),
        JK_WELD => FixedJointBuilder::new().build().into(),
        JK_ROPE => {
            // Rapier 要求 max_dist > 0：0 会让约束退化成"两点必须重合"，
            // 求解时除零。这里直接拒绝，而不是让它变成一个隐形的焊接。
            if !(p1 > 0.0) { return 0; }
            RopeJointBuilder::new(p1 as f32).build().into()
        }
        JK_SPRING => SpringJointBuilder::new(p1 as f32, p2 as f32, p3 as f32).build().into(),
        _ => return 0,
    };
    match kind {
        JK_HINGE | JK_WELD => {
            j.set_local_frame1(Pose::new(a1, 0.0));
            j.set_local_frame2(Pose::new(a2, rel));
        }
        JK_SLIDER => {
            // 轴按**世界系**传进来，两端各自转到自己的局部系。
            // ⚠️ 不能照抄 PrismaticJoint::new(axis)：它给两个刚体设**同一个局部轴**，
            //    两个刚体朝向不同时这两根轴在世界系里根本不平行 —— 求解器会在
            //    创建瞬间把它们拧到平行（表现为"啪"地转一下）。
            let wa = Vector::new(axis_x as f32, axis_y as f32);
            j.set_local_anchor1(a1);
            j.set_local_anchor2(a2);
            j.set_local_axis1(r1.inverse() * wa);
            j.set_local_axis2(r2.inverse() * wa);
        }
        _ => {
            j.set_local_anchor1(a1);
            j.set_local_anchor2(a2);
        }
    }
    let handle = w.ij.insert(ha, hb, j, true);
    let id = w.next_joint_id;
    w.next_joint_id += 1;
    w.joints.insert(id, JointRec { handle, kind });
    id
}

/// 删关节。对**已经不存在**的 id 是安全的空操作 —— 刚体被删时 Rapier 已经把
/// 挂在它上面的关节一起删了，GDScript 侧的清理还会拿着旧 id 再来一次。
#[no_mangle]
pub extern "C" fn rb_joint_remove(w: *mut World, id: u32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if let Some(rec) = w.joints.remove(&id) {
        w.ij.remove(rec.handle, true);
    }
}

/// 限位。铰链是角度（弧度），滑轨是距离。**min > max 表示不限制**。
#[no_mangle]
pub extern "C" fn rb_joint_set_limits(w: *mut World, id: u32, min: f64, max: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(rec) = w.joints.get(&id) else { return };
    let axis = joint_axis(rec.kind);
    let handle = rec.handle;
    let (lo, hi) = if min > max { (-Real::MAX, Real::MAX) } else { (min as f32, max as f32) };
    if let Some(j) = w.ij.get_mut(handle, true) {
        j.data.set_limits(axis, [lo, hi]);
    }
}

/// 速度马达：让关节以 target_vel 运动（铰链是角速度 rad/s，滑轨是线速度 px/s）。
///
///   damping    速度误差的修正速率（Rapier 的 AccelerationBased 模型：
///              a = damping × (target_vel − v)）—— 与质量无关，所以轻重物手感一致。
///   max_force  **冲量上限 = max_force × dt**。0 = 禁用（对应参考 API 里
///              "strength 0 关闭马达"的语义）。
#[no_mangle]
pub extern "C" fn rb_joint_motor_velocity(w: *mut World, id: u32, target_vel: f64, damping: f64, max_force: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(rec) = w.joints.get(&id) else { return };
    let axis = joint_axis(rec.kind);
    let handle = rec.handle;
    if let Some(j) = w.ij.get_mut(handle, true) {
        if max_force <= 0.0 {
            j.data.set_motor_max_force(axis, 0.0);
        } else if damping > 0.0 {
            j.data.set_motor_velocity(axis, target_vel as f32, damping as f32);
            j.data.set_motor_max_force(axis, max_force as f32);
        }
        // damping <= 0 直接不发：Rapier 的 AccelerationBased 马达在
        // stiffness = damping = 0 时算出的系数是 0 × ∞ = NaN，会把整个求解污染掉。
        // （调用方那边已经 push_error 了，这里只是不让坏参数进求解器。）
    }
}

/// 位置/角度伺服：走到 target（铰链是角度，滑轨是距离）。
/// stiffness / damping 同样是 AccelerationBased 语义；max_force = 0 表示关掉。
#[no_mangle]
pub extern "C" fn rb_joint_motor_position(
    w: *mut World, id: u32, target: f64, stiffness: f64, damping: f64, max_force: f64,
) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(rec) = w.joints.get(&id) else { return };
    let axis = joint_axis(rec.kind);
    let handle = rec.handle;
    if let Some(j) = w.ij.get_mut(handle, true) {
        if max_force <= 0.0 {
            j.data.set_motor_max_force(axis, 0.0);
        } else if stiffness > 0.0 || damping > 0.0 {
            j.data.set_motor_position(axis, target as f32, stiffness as f32, damping as f32);
            j.data.set_motor_max_force(axis, max_force as f32);
        }
        // 同上：两个系数都为 0 时不发（NaN 防线）。
    }
}

/// 关掉马达（保留限位）。注意不是"删掉马达参数"，而是把冲量上限设成 0。
#[no_mangle]
pub extern "C" fn rb_joint_motor_off(w: *mut World, id: u32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(rec) = w.joints.get(&id) else { return };
    let axis = joint_axis(rec.kind);
    let handle = rec.handle;
    if let Some(j) = w.ij.get_mut(handle, true) {
        j.data.set_motor_max_force(axis, 0.0);
    }
}

/// 读关节**上一步**的约束冲量：out 至少 2 个 f64 —— [线性冲量模长, 角冲量]。
/// 返回 1 表示成功。断裂判定用它（Rapier 没有"关节断裂"这个概念，得自己判）。
///
/// ⚠️ Rapier 存的冲量是**关节局部系**的分量（按自由度），所以这里只输出**模长**：
///    拿它做阈值判据是稳的，但别指望它是一个世界系矢量。
#[no_mangle]
pub extern "C" fn rb_joint_impulse(w: *mut World, id: u32, out: *mut f64) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    if out.is_null() { return 0; }
    let Some(rec) = w.joints.get(&id) else { return 0 };
    let Some(j) = w.ij.get(rec.handle) else { return 0 };
    let imp = j.impulses; // SpatialVector = Vec3（2D：x, y, 角）
    unsafe {
        *out = (imp.x * imp.x + imp.y * imp.y).sqrt() as f64;
        *out.add(1) = imp.z as f64;
    }
    1
}

/// 当前关节数（诊断用：测试靠它确认"删刚体时关节没有泄漏"）。
#[no_mangle]
pub extern "C" fn rb_joint_count(w: *mut World) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    // ⚠️ 报的是 **Rapier 侧**的数量（ij.len()），不是我们那张 id 表 ——
    //    后者永远和我们自己一致，"泄漏"这类问题只有前者看得见。
    w.ij.len() as i32
}

/// 两个**被关节连着**的刚体之间要不要生成接触。默认 **关**（0）。
///
/// 为什么默认关：关节和接触是**两个求解器**，目标相反 ——
/// 关节要把两个刚体按创建时的相对位姿按住，接触要把重叠的体素推开。
/// 于是"焊在一起但体素重合"的两个刚体会**一直抽搐**（实测：速度在 0~40 之间来回，
/// 关节冲量几十倍于静止载荷）。关掉接触，关节才是唯一权威。
///
/// 这条和 Box2D 的 `collideConnected = false` 是同一个默认值；
/// 确实需要"连在一起还互相碰"时再打开（Rapier 的窄相会查这个标志并跳过配对，
/// 见 rapier 的 geometry/narrow_phase/pair_update.rs）。
#[no_mangle]
pub extern "C" fn rb_joint_set_contacts(w: *mut World, id: u32, enabled: i32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(rec) = w.joints.get(&id) else { return };
    let handle = rec.handle;
    if let Some(j) = w.ij.get_mut(handle, true) {
        j.data.set_contacts_enabled(enabled != 0);
    }
}

// ================= 碰撞层 / 掩码 =================

/// 碰撞层（layer，位 0..31）与掩码（mask，位 0..31）—— 映射到 Rapier 的 InteractionGroups。
///
/// 判据是**双向**的（Rapier 的 test_and）：
///     (A.memberships & B.filter) != 0  且  (B.memberships & A.filter) != 0
/// 也就是"我在你要的层里，你在我想要的层里"。这与 Godot 的 collision_layer /
/// collision_mask、Box2D 的 category/maskBits 是同一套语义。
///
/// layer = 0 表示"不在任何层"（谁都碰不到它，它谁也碰不到）；mask = 0 同理。
///
/// ⚠️ 分组挂在 **Collider** 上，不是刚体上 —— 本项目一个刚体有 N 个矩形碰撞体，
///    所以这里遍历它的全部碰撞体一起设。
/// ⚠️ 也因此 rb_body_set_rects 重建碰撞体之后必须**再设一次**：新碰撞体拿到的是
///    Rapier 默认分组（全 1），旧分组不会自动继承。实测症状：擦掉一块地形 ->
///    重建碰撞体 -> 那个刚体静默变回"和所有层都碰"（子弹又开始打中它）。
#[no_mangle]
pub extern "C" fn rb_body_set_groups(w: *mut World, id: u32, layer: u32, mask: u32) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(&h) = w.map.get(&id) else { return };
    let groups = InteractionGroups::new(
        Group::from_bits_truncate(layer),
        Group::from_bits_truncate(mask),
        InteractionTestMode::And,
    );
    // 先收集再改：colliders() 借着 bodies，直接在循环里改 colliders 过不了借用检查。
    let cols: Vec<ColliderHandle> = w.bodies[h].colliders().iter().copied().collect();
    for c in cols {
        w.colliders[c].set_collision_groups(groups);
    }
}

/// 设置刚体的**密度**（材质密度），并按新密度重算质量 / 惯量。
///
/// ⚠️⚠️ 这个函数修的是一个**静默的质量分叉**：
///     GDScript 侧 `PBody.mass` 是按**材质密度**算的（`Σ density(material)`），
///     而 Rapier 侧的碰撞体一直拿的是默认密度 **1.0** —— 两边质量差一个密度倍率，
///     而且**不报任何错**。
///
///     后果不是"手感差一点"，而是所有按 mass 算出来的力全错：抓取的限力是
///     `max_accel * mass * dt`。实测（密度 7.8 的金属、目标不动）：
///     一步就把速度从 +9.9 打成 **-73.4**（8.4 倍过冲），随后在 ±280 之间来回，
///     也就是甲方看到的"拖动焊接物体不断抽搐"。
///
/// ⚠️ 两步缺一不可：`Collider::set_density` 只改碰撞体，**不会**自动更新刚体的
///     质量属性（Rapier 文档明说），必须再调 `recompute_mass_properties_from_colliders`。
#[no_mangle]
pub extern "C" fn rb_body_set_density(w: *mut World, id: u32, density: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(&h) = w.map.get(&id) else { return };
    // 先收集再改：colliders() 借着 bodies，直接在循环里改 colliders 过不了借用检查。
    let cols: Vec<ColliderHandle> = w.bodies[h].colliders().iter().copied().collect();
    for c in cols {
        w.colliders[c].set_density(density as Real);
    }
    if let Some(rb) = w.bodies.get_mut(h) {
        rb.recompute_mass_properties_from_colliders(&w.colliders);
    }
}

/// 摩擦系数（材质属性）-> 该刚体的**所有**碰撞体。
///
/// ⚠️ Rapier 的接触系数是**两个碰撞体按 CoefficientCombineRule 合成**的（默认 Average）：
///    地面 0.8 + 箱子 0.2 -> 接触处 0.5。所以"想让某个材质说了算"就得两边设同一个值。
///    以后要"取最大/取最小"，得再开一个 combine rule 的旋钮（Rapier 有，现在没接）。
///
/// ⚠️ 和密度不同：改摩擦/恢复系数**不需要** recompute_mass_properties ——
///    它们不参与质量属性。别照着 rb_body_set_density 抄那两行。
#[no_mangle]
pub extern "C" fn rb_body_set_friction(w: *mut World, id: u32, friction: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(&h) = w.map.get(&id) else { return };
    let cols: Vec<ColliderHandle> = w.bodies[h].colliders().iter().copied().collect();
    for c in cols {
        w.colliders[c].set_friction(friction as Real);
    }
}

/// 碰撞恢复系数（0 = 完全不弹，1 = 完全弹性）-> 该刚体的所有碰撞体。
/// 合成规则同 rb_body_set_friction（默认 Average）。
#[no_mangle]
pub extern "C" fn rb_body_set_restitution(w: *mut World, id: u32, restitution: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    let Some(&h) = w.map.get(&id) else { return };
    let cols: Vec<ColliderHandle> = w.bodies[h].colliders().iter().copied().collect();
    for c in cols {
        w.colliders[c].set_restitution(restitution as Real);
    }
}


// ---- 抓取：这里**故意没有**任何 FFI ----
//
// ⚠️ 试过"鼠标关节"（运动学锚点刚体 + 两轴位置马达），已删除。原因是 Rapier 的马达
//    只在**锁住的轴**上生效，而锁住的轴本身就是硬约束：
//      · 锁住 LIN_X|LIN_Y + 马达 -> 跟踪误差恒为 0.0~0.36 px，等于**强制位移跟随**
//        （甲方："不应该强制位移跟随鼠标，使用力控"）；
//      · 放开轴（JointAxesMask::empty()）-> 马达完全不产生力，物体自由落体。
//    抓取现在在 GDScript 侧做**力控**（src/physics/grab.gd：每子步一个受限的力），
//    这里不需要新原语。

/// 关节求解**软度**：自然频率（Hz）+ 阻尼比。
///
/// 频率越高越硬（约束误差越小、越少迭代就收敛），越低越"软"（允许漂移，看起来像
/// 带弹性的连接）。不调就是 Rapier 的 `SpringCoefficients::joint_defaults()`。
///
/// ⚠️ 这是**求解器参数**，不是"关节类型"：焊接仍然是焊接（自由度照样全锁），
///    软度只决定"违约被拉回的速度"。
#[no_mangle]
pub extern "C" fn rb_joint_set_softness(w: *mut World, id: u32, frequency: f64, damping: f64) -> i32 {
    let Some(w) = (unsafe { wref(w) }) else { return 0 };
    let Some(rec) = w.joints.get(&id) else { return 0 };
    let handle = rec.handle;
    if let Some(j) = w.ij.get_mut(handle, true) {
        // ⚠️ frequency <= 0 = **调回 Rapier 默认**（joint_defaults）—— 没有这条，用户设了软度
        //    就再也回不到默认（只能自己猜那个数）。
        let sc = if frequency > 0.0 {
            SpringCoefficients::new(frequency as f32, damping as f32)
        } else {
            SpringCoefficients::joint_defaults()
        };
        j.data.set_softness(sc);
        return 1;
    }
    0
}

/// 世界级**关节求解**参数。三个都是"显式设过才推"（iterations > 0 / warmstart >= 0 /
/// coeff >= 0），没设的保持 Rapier 默认 —— 这样"没调过"的场景逐位不变。
///
///   iterations 求解迭代次数（越多越准、越贵）
///   warmstart  关节是否用 warmstart（>= 0 才推；0 = 关，1 = 开）
///   coeff      warmstart 系数（>= 0 才推）
#[no_mangle]
pub extern "C" fn rb_world_set_joint_solver(w: *mut World, iterations: i32, warmstart: i32, coeff: f64) {
    let Some(w) = (unsafe { wref(w) }) else { return };
    if iterations > 0 {
        w.params.num_solver_iterations = iterations as usize;
    }
    if warmstart >= 0 {
        w.params.warmstart_joints = warmstart != 0;
    }
    if coeff >= 0.0 {
        w.params.warmstart_coefficient = coeff as f32;
    }
}

