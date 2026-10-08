@tool
extends Node2D
## 像素渲染层。
##
## @@tool@@ 是为了**在场景编辑器里也能看见像素**（甲方要求）。
## 本类是无状态的 —— 只按 @@sync(body)@@ 给的刚体重建贴图，自己不推进物理，
## 所以加 @@tool@@ 是安全的：编辑器里画的就是场景里已有的那些刚体。
##
## 设计要点（见框架文档第 5 节）：
##   逻辑 chunk = 8x8（物理/破坏的粒度）
##   渲染单元  = 每个 Body 一张 RGBA8 贴图，尺寸 = 该 Body 的局部 AABB
##   -> 静态世界按 128x128 切成多个 Body，破坏时只重建受影响的那几张
##
## 用 Image.create_from_data 一次性建图，避免逐像素 set_pixel 的调用开销。

const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const PixelChunk := preload("res://addons/pixel_destruction/core/pixel_chunk.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const _PixelShading := preload("res://addons/pixel_destruction/render/pixel_shading.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PixelScale := preload("res://addons/pixel_destruction/core/pixel_scale.gd")

## 材质 id -> 颜色（id 0 = 空，必须保持透明）。
##
## ⚠️ 数组下标**就是** PixelShape 里存的材质 id —— 也就是说
## "体素颜色"这件事在引擎里是通过**材质表**表达的，不是逐像素存颜色。
## 好处：改整块颜色只要改这张表 + 重建贴图；像素数据只存 1 字节材质 id。
## 想换配色就 set_material_color() 或直接替换整个数组。
var palette: Array = [
	Color(0, 0, 0, 0),
	Color(0.62, 0.60, 0.56),   # 1 石材/地面
	Color(0.72, 0.52, 0.32),   # 2 木材
	Color(0.55, 0.58, 0.66),   # 3 金属
	Color(0.80, 0.32, 0.30),   # 4 砖
	Color(0.42, 0.72, 0.45),   # 5 植被
	Color(0.85, 0.78, 0.42),   # 6 沙
]

var _nodes := {}          # body.id -> Sprite2D
var _textures := {}       # body.id -> ImageTexture
var _bounds := {}         # body.id -> Rect2i
## body.id -> true 表示"像素内容变了，下次 sync 要重建贴图"。
## 位置/旋转变化不在此列 —— 那些只改 node.transform，不需要重做贴图。
var _rev := {}           # body.id -> 上次建贴图时的内容版本
var _warned_material := false
## 上一次 sync 重建了几块贴图（诊断用）。
##
## ⚠️ 加它是因为：分块贴图写完**看起来**对了，但完全可能每笔都走
##    rebuild_all（那就等于没分块，白做）。这个计数器让"有没有真的分块"
##    变成一个可断言的事实，而不是靠读代码推断。
## body.id -> 上次**全量重建**时的 (revision - range_revision) 差值。
##
## ⚠️⚠️ 不能直接比 revision != range_revision —— 那是**累计**的，
##    只要历史上出现过一次 touch()（比如启动时烘焙那一次），
##    差值就永远不为 0，快路径被**永久禁用**（实测差值恒为 2，
##    分块贴图退回 24/24 全量重建，白做）。
##
##    要比的是"**自上次全量重建以来**有没有未记录的改动"。
var _rev_offset := {}
var last_debug := ""
var last_tiles_rebuilt := 0
var last_tiles_total := 0
## 原生栅格化真的走了几次 / 退回 GDScript 几次（诊断用）。
##
## ⚠️ 加它的理由与 last_tiles_rebuilt 同一个：没有它，"原生路径生效了吗"只能靠
##    读代码推断 —— 而**退回分支看起来和成功一样**（两条路的结果本来就该逐位相同，
##    所以任何"结果对不对"的判据都抓不到它）。
var native_calls := 0
var native_fallbacks := 0
## body.id -> Image（**持久**，供分块增量重绘）。
## 以前每次重建都是新建一张 Image，所以"只重画脏块"无处落脚。
var _images := {}
## body.id -> Node2D（只持有 body 的 transform，不再自己带贴图）
var _tiles := {}
## body.id -> { 块键 -> ImageTexture }
var _tile_tex := {}
## body.id -> { 块键 -> Image }（源图，与 _tile_tex 一一对应）
##
## ⚠️ 为什么留一份 Image：**headless 下 ImageTexture.get_image() 拿不回图像**
##    （没有渲染服务器）。测试和调试要逐像素读回，只能靠这份源图。
##    这也是"读回验证"能在无头环境跑起来的前提。
var _tile_img := {}

## 逐像素着色（边沿压暗 + 顶面提亮 + 色调扰动）。见 PixelShading 的说明。
##
## ⚠️ **默认关闭**。做出来之后试了一版，色调扰动在成片的地面和碎块上读起来
##    就是"噪点"而不是"质感" —— 画面像蒙了一层灰。像素画要的是干净利落的色块。
##    所以默认走纯色；确实想要体积感时再打开（它是烘进贴图的，运行时零开销）。
var shading := false


## 所有形状的 revision 之和 —— 任何一处像素改动都会让它变。
static func _content_revision(body) -> int:
	var r := 0
	for s: PixelShape in body.shapes:
		r += s.revision
	return r


## 强制下次 sync 重建某刚体的贴图。
##
## 正常情况下**不需要调** —— revision 会自动发现内容变化。
## 只有一种情况要手动来一下：换了 palette（形状没动，但画出来的颜色要变）。
func mark_dirty(body_id: int) -> void:
	_rev.erase(body_id)


func mark_all_dirty() -> void:
	_rev.clear()

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

## 一次同步全部刚体（含回收已消失的）。
##
## ⚠️ 与逐帧路径的区别：逐帧路径靠 prune(_live_ids()) 回收，
##    而这里**不能**那样做 —— 编辑器里 @tool 的 _ready 只跑一次，
##    如果按"当前世界里的 id"去 prune，会把上一次构建留下的贴图误删。
##    所以这里只做增量同步，不回收。
func sync_all(bodies: Array) -> void:
	for b in bodies:
		sync(b)


## 回收已经不存在的 Body 对应的 Sprite（分裂销毁 / 预算淘汰都会用到）
func prune(live: Dictionary) -> void:
	var dead: Array = []
	for id in _nodes:
		if not live.has(id):
			dead.append(id)
	for id in dead:
		forget(id)


func forget(body_id: int) -> void:
	var n: Node = _nodes.get(body_id)
	if n != null:
		n.queue_free()
	_nodes.erase(body_id)
	_textures.erase(body_id)
	_bounds.erase(body_id)
	_rev.erase(body_id)
	_images.erase(body_id)
	_rev_offset.erase(body_id)
	for key in (_tiles.get(body_id, {}) as Dictionary):
		var sp: Sprite2D = (_tiles[body_id] as Dictionary)[key]
		if sp != null:
			sp.queue_free()
	_tiles.erase(body_id)
	_tile_tex.erase(body_id)
	_tile_img.erase(body_id)

## 改一种材质的颜色（会自动扩容；id 0 忽略）。
func set_material_color(material: int, color: Color) -> void:
	if material <= 0:
		return
	while palette.size() <= material:
		palette.append(color)
	palette[material] = color


func material_color(material: int) -> Color:
	if material >= 0 and material < palette.size():
		return palette[material]
	return Color(0, 0, 0, 0)


func sync(body) -> void:
	if body.shapes.is_empty():
		forget(body.id)
		return
	var aabb: Rect2i = _local_bounds(body)
	if aabb.size.x <= 0 or aabb.size.y <= 0:
		forget(body.id)
		return
	var holder: Node2D = _nodes.get(body.id)
	var fresh := false
	if holder == null:
		holder = Node2D.new()
		holder.name = "Body%d" % body.id
		add_child(holder)
		_nodes[body.id] = holder
		_bounds[body.id] = Rect2i()
		fresh = true
	# 🔥 只在**内容真的变了**时才重建贴图。
	#
	# ⚠️⚠️ 这里以前是无条件 node.texture = _build_texture(body, aabb)，
	#    而 _build_texture 要逐像素重填 Image 再 tex.update() ——
	#    Ground 是 800x40 = 32000 像素，**每帧**跑一遍，掉帧就是这么来的。
	#    位置/旋转变化完全不需要重建贴图（那只是改 node.transform）。
	#
	#    AABB 变化是"形状变了"的可靠信号（破坏一定会改变外接，
	#    除非恰好在内部挖洞 —— 那种情况调用方要显式 mark_dirty()）。
	# 🔥 只在**像素内容真的变了**时才重建贴图。
	#
	# ⚠️⚠️ 第一版这里写的是 `_dirty.get(body.id, true)` + `erase()` ——
	#    那是个**恒真**的表达式：默认 true，erase 之后键没了、下次 get 又拿默认 true。
	#    于是每帧都在重建贴图（800x40 的地面 = 32000 像素/帧），
	#    "修掉帧"的那个提交其实一点没修掉，而且不报任何错。
	#    教训：**用"默认值 + 删除键"表达布尔状态，默认值就是真正的状态**，删除毫无意义。
	#
	#    现在比较的是形状自带的 revision（见 PixelShape.revision）——
	#    谁改了内容谁 +1，不依赖任何调用方记得调 mark_dirty()。
	#
	# 🔥 分块增量重绘（"物理一个刚体、渲染按区块"）：
	#    AABB 没变、只是**内容**变了的话，不再整张重建 —— 只重画
	#    mark_dirty_range 标出来的那一小块，blit 进持久 Image，再 tex.update。
	#
	#    擦除地面时：整张重建 ~44 ms，而伤害只碰到 2.4% 的块。
	#
	# 🔥🔥 每块**一张独立贴图**（"1 个 Node2D + N 个 Sprite2D"）。
	#
	# ⚠️ 为什么不能停在"整张一张贴图 + blit 脏块"：
	#    CPU 光栅化确实只剩 2.4% 了，但 tex.update(img) 仍然要**上传整张**
	#    768x100 贴图（307 KB），实测还剩 ~30 ms —— 瓶颈从 CPU 挪到了 GPU 上传。
	#    拆成每块一张之后，update 只碰脏块那一张（64x64 = 16 KB）。
	#
	# ⚠️ 块格对齐到**局部像素空间的 64 的倍数**，不是对齐到 aabb ——
	#    否则 aabb 一变所有块的边界跟着挪，缓存全部失效。
	var rev := _content_revision(body)
	var size_changed: bool = _bounds.get(body.id, Rect2i()) != aabb
	var content_changed: bool = _rev.get(body.id, -1) != rev
	var dirty := Rect2i()
	# ⚠️ 尺寸变了**也要取走脏信息**。以前这里是 content_changed and not size_changed
	#    —— 那时"尺寸变了就全量重建"，脏信息没用了。现在不再全量：
	#    切开一个大物体时 AABB 会变（768x100 -> 382x100），而像素其实只差切口
	#    那一条 —— 实测母体重建 12/12 块要 24 ms，其中 20 块**区域和像素都没变**
	#    （tests/diag_bigfrag_hitch.gd）。
	if content_changed:
		dirty = _take_dirty_rect(body, aabb)
	if size_changed:
		_bounds[body.id] = aabb
	if content_changed or size_changed:
		_rev[body.id] = rev
	var tiles: Dictionary = _tiles.get(body.id, {})
	var tts: Dictionary = _tile_tex.get(body.id, {})
	var tis: Dictionary = _tile_img.get(body.id, {})
	if _tiles.get(body.id) == null:
		_tiles[body.id] = tiles
		_tile_tex[body.id] = tts
		_tile_img[body.id] = tis
	# ⚠️⚠️ 只要**有未记录的改动**（revision != range_revision，即有人调过 touch()），
	#    就必须全量重建 —— 那种情况下脏集合是**不完整**的，
	#    只重建脏块会漏掉改动，症状是"擦出来的图形缺一块"。
	#
	#    这是我把"只重建脏块"上线后引入的回归：fracture 先 mark_dirty_range，
	#    紧接着 PBody.rebuild 又 touch()（split 换了 shape 对象、碎片搬走了像素），
	#    渲染器看到脏集合非空就只重建那几块 —— touch() 那部分改动全丢了。
	# ⚠️⚠️ 判据必须**按 shape 身份**比，不能比求和。
	#
	#    旧实现是 `Σ (revision - range_revision)` 与上次存的和比较。而破坏会**换掉
	#    shape 对象**（split/_assemble 产出新对象），新对象带着自己的 revision 进来 ——
	#    和一变就判 untracked -> **整张重建**。实测（tests/validation_local_repaint.gd）：
	#    detach 内部挖 20x20 -> 24/24 块、sync 56 ms，而同样条件下 fracture_pixels
	#    只要 2/24 块、0.35 ms —— 差别全在这个假阳性上。
	#
	#    现在：已知 shape 的差值**变了**才算 untracked；**新** shape 只在它自己
	#    已经不平衡（> 0，说明有人对它 touch 过）时才保守全量。
	#    ⚠️ 安全网一个字没动：content_changed 且**没有任何脏标记** -> 仍然全量重建
	#    （见 rebuild_all 的最后一项）；touch() 之后差值 > 0 -> 仍然全量。
	var prev_off: Dictionary = _rev_offset.get(body.id, {})
	var untracked := false
	for s2: PixelShape in body.shapes:
		var off2 := s2.revision - s2.range_revision
		if off2 > 0 and (not prev_off.has(s2) or prev_off[s2] != off2):
			untracked = true
	# ⚠️ 判据：**只有"内容变了、但没有可用的脏信息"才允许全量重建**。
	#    size_changed 以前是"一律全量"的理由，那是错的（见上面 dirty 的说明）。
	# ⚠️ 安全网一个字没动：size_changed 而**内容没变**（revision 没动）说明有人
	#    直接改了 chunk 却没标脏（pitfalls.md 里那条），那种情况仍然全量。
	var rebuild_all: bool = tiles.is_empty() or untracked \
			or (content_changed and dirty.size.x <= 0) \
			or (size_changed and not content_changed)
	var revinfo := ""
	for s3: PixelShape in body.shapes:
		revinfo += " rev=%d/%d" % [s3.revision, s3.range_revision]
	last_debug = "size=%s untracked=%s dirty=%s%s" % [
		str(size_changed), str(untracked), str(dirty), revinfo]
	if content_changed or size_changed:
		# 快照：**按 shape 身份**记"未记录改动数"（见上面 untracked 的说明）。
		# ⚠️ 它持有 shape 的引用直到下一次快照（很短），不会长期留着旧 shape。
		var snap := {}
		for s4: PixelShape in body.shapes:
			snap[s4] = s4.revision - s4.range_revision
		_rev_offset[body.id] = snap
		last_tiles_rebuilt = 0
		last_tiles_total = 0
		var live := {}
		var x0 := aabb.position.x >> 6
		var y0 := aabb.position.y >> 6
		var x1 := (aabb.position.x + aabb.size.x - 1) >> 6
		var y1 := (aabb.position.y + aabb.size.y - 1) >> 6
		for ty in range(y0, y1 + 1):
			for tx in range(x0, x1 + 1):
				# ⚠️ 键用 Vector2i，**不要**用 (tx<<32)^ty 这种 64 位打包 ——
				#    实测那个表达式把 ty 那一半吃成了 0（键变成 0, 1<<32, 2<<32...），
				#    于是查表永远不命中、贴图全查不到，而画面"看起来"是对的。
				var key := Vector2i(tx, ty)
				last_tiles_total += 1
				live[key] = true
				var rx := maxi(tx << 6, aabb.position.x)
				var ry := maxi(ty << 6, aabb.position.y)
				var rx2 := mini((tx << 6) + 64, aabb.position.x + aabb.size.x)
				var ry2 := mini((ty << 6) + 64, aabb.position.y + aabb.size.y)
				if rx2 <= rx or ry2 <= ry:
					continue
				var tr := Rect2i(rx - aabb.position.x, ry - aabb.position.y, rx2 - rx, ry2 - ry)
				# ⚠️ Rect2i.intersects() 只有一个参数（include_borders 是 Rect2 的）——
				#    传两个会编译失败，而且报错指向"依赖它的脚本"，不指向这里。
				# ⚠️ 跳过本块的判据必须含 **region_changed**：块的区域（局部原点+尺寸）
				#    一变，旧图的内容映射就错了 —— 哪怕脏矩形没碰到它也得重画。
				#    AABB 缩小（大物体被切开）正好是这种情况：边界那几块的宽度变了。
				var region_changed := _tile_region_changed(
					tiles.get(key), tis.get(key), tts.get(key), Vector2(rx, ry), tr.size)
				if not rebuild_all and not region_changed and not dirty.intersects(tr):
					continue
				last_tiles_rebuilt += 1
				var sp: Sprite2D = tiles.get(key)
				if sp == null:
					sp = Sprite2D.new()
					sp.centered = false
					sp.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
					holder.add_child(sp)
					tiles[key] = sp
				var cur: Image = tis.get(key)
				var tex: ImageTexture = tts.get(key)
				var need_full: bool = rebuild_all or region_changed
				if need_full:
					cur = _build_region_image(body.shapes, aabb, tr)
					tis[key] = cur
					tex = ImageTexture.create_from_image(cur)
					tts[key] = tex
					sp.texture = tex
				else:
					# 🔥🔥 只画**脏矩形与本块的交集**，再 blit 进持久图。
					#
					# ⚠️ 这里以前是"整块 64x64 重画"：一笔擦除的脏矩形只有 24x24
					#    （实测 _take_dirty_rect -> 24x24），却要重画 4096 个像素 ——
					#    **7 倍的浪费**，而逐像素循环是 sync 的几乎全部成本
					#    （64x64 实心块实测 2.41 ms ≈ 0.59 us/像素）。
					#
					#    blit_rect 是原生操作（逐字节拷贝），所以"画一小块 + 贴进去"
					#    比"整块重画"便宜得多。贴图上传仍然要整块（tex.update），
					#    那部分没法省 —— 但它不是瓶颈。
					#
					# ⚠️ 正确性依赖两条既有契约，缺一不可：
					#    · dirty 覆盖本次**全部**改动像素（mark_dirty_range 的契约）
					#    · 有未记录改动时 rebuild_all 为真（revision != range_revision）
					#    两者任一不成立，持久图就会**静默**落后于形状。
					var sub := dirty.intersection(tr)
					if sub.size.x > 0 and sub.size.y > 0:
						var patch := _build_region_image(body.shapes, aabb, sub)
						cur.blit_rect(patch, Rect2i(0, 0, sub.size.x, sub.size.y), sub.position - tr.position)
					tex.update(cur)
				# ⚠️⚠️ offset 必须是**区域**在局部坐标里的原点（rx, ry），
				#    不是块的网格原点 Vector2(tx << 6, ty << 6)。
				#
				#    图像从 rx = maxi(tx<<6, aabb.position.x) 开始 ——
				#    两者只在 aabb 原点恰好是 64 的倍数时相等。
				#
				#    **碎片就是反例**：它们的局部 aabb 起点是任意值（比如 -13），
				#    于是 tx<<6 = -64 而图像从 -13 开始，sprite 被摆到 -64 ——
				#    "擦除生成的形状和碰撞箱之间有一个 offset"就是它。
				#
				#    而且必须**每次都设**：aabb 一变，区域原点就跟着变，
				#    只在创建时设一次的话，旧的 offset 会一直留着。
				sp.offset = Vector2(rx, ry)
		# 回收已经不在 aabb 里的块（形状被削小 / 分裂）
		for key in tiles.keys():
			if not live.has(key):
				var sp2: Sprite2D = tiles[key]
				if sp2 != null:
					sp2.queue_free()
				tiles.erase(key)
				tts.erase(key)
				tis.erase(key)
	# 贴图是 1 纹素 = 1 体素；靠节点缩放把每个体素放大成"大块像素"。
	# 最近邻采样（TEXTURE_FILTER_NEAREST）保证放大后依然是硬边方块，不会糊。
	# 这里**不做任何缩放**：1 个体素 = 1 个世界单位，渲染与物理共用同一坐标系。
	# 「大像素」交给 camera.zoom 实现（纯视图变换）。
	# 曾经在这里乘 voxel_world_size，结果画出来的几何比碰撞体大 4 倍 ——
	# 视觉上物体整个扎进地面，而物理检测却说只嵌入了 0.6 像素。
	var cs := cos(body.rotation)
	var sn := sin(body.rotation)
	holder.transform = Transform2D(Vector2(cs, sn), Vector2(-sn, cs), body.position)
	# ⚠️⚠️ 新建的 holder 必须重置物理插值状态。上面是"先 add_child 入树、后设 transform"，
	#    而 project 开着 physics/common/physics_interpolation 时，新节点这一帧会从**入树时
	#    的变换（原点）**插值过来 —— 症状就是新碎片诞生那一帧被画在错位置（实测最小复现：
	#    质心偏 593 px，reset 后 0.4 px）。只对**新建**那一帧 reset：每帧 reset 等于关掉插值。
	if fresh:
		holder.reset_physics_interpolation()

static func _local_bounds(body) -> Rect2i:
	var box := Rect2i()
	var first := true
	for s: PixelShape in body.shapes:
		var b: Rect2i = s.local_aabb()
		if b.size.x <= 0:
			continue
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box

## ---- 蓝图：不属于任何刚体、不参与物理的形状 ----
##
## 用途：游戏层「画完一笔先不固化」的预览层。蓝图不在 world.bodies 里 ——
## 宽相扫不到、不受重力、不被破坏，纯粹是画面。solidify 时才 add_body。
##
## id 走负数区间（普通刚体 id 非负），避免撞号。
var _blueprint_nodes := {}


func sync_blueprint(id: int, shape: PixelShape, xform: Transform2D) -> void:
	if shape == null or shape.is_empty():
		forget_blueprint(id)
		return
	var key := -1 - absi(id)
	var aabb: Rect2i = shape.local_aabb()
	var node: Sprite2D = _blueprint_nodes.get(key)
	if node == null:
		node = Sprite2D.new()
		node.centered = false
		node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		node.modulate = Color(1, 1, 1, 0.6)      # 半透明：一眼看出"还没固化"
		add_child(node)
		_blueprint_nodes[key] = node
		_bounds[key] = Rect2i()
	if _bounds[key] != aabb:
		_bounds[key] = aabb
		_textures.erase(key)
	node.texture = _build_texture_impl([shape], aabb, key)
	node.offset = Vector2(aabb.position)
	node.transform = xform


func forget_blueprint(id: int) -> void:
	var key := -1 - absi(id)
	var n: Node = _blueprint_nodes.get(key)
	if n != null:
		n.queue_free()
	_blueprint_nodes.erase(key)
	_textures.erase(key)
	_bounds.erase(key)


## 只挪蓝图的位置/朝向，**不重建贴图**。
##
## ⚠️ 为什么必须单独一个方法：sync_blueprint 会**无条件**重跑 _build_texture_impl
##    （逐像素重填 Image + tex.update）。降级的灰尘每帧都在动，但它的**像素内容
##    一个字都没变** —— 该更新的是 transform，不是贴图。每帧对每粒灰调一次
##    sync_blueprint 就是灾难（贴图重建是这条路里最贵的一步）。
func place_blueprint(id: int, xform: Transform2D) -> void:
	var n: Node2D = _blueprint_nodes.get(-1 - absi(id))
	if n != null:
		n.transform = xform


## 单独调一条蓝图的透明度（灰尘淡出用）。同样不碰贴图。
func tint_blueprint(id: int, alpha: float) -> void:
	var n: Node2D = _blueprint_nodes.get(-1 - absi(id))
	if n != null:
		n.modulate = Color(1, 1, 1, alpha)


func clear_blueprints() -> void:
	for key in _blueprint_nodes.keys():
		var n: Node = _blueprint_nodes[key]
		if n != null:
			n.queue_free()
		_textures.erase(key)
		_bounds.erase(key)
	_blueprint_nodes.clear()


func _build_texture(body, aabb: Rect2i):
	return _build_texture_impl(body.shapes, aabb, body.id)


## 只把 region（相对 aabb 的像素矩形）那一块画成一张小 Image。
##
## ⚠️ 存在的理由：擦除地面时重建**整个** 768x100 贴图要 ~44 ms，
##    而伤害其实只碰到 2.4% 的块（mark_dirty_range 标的）。
##    有了这个小图就能 blit 进持久 Image，只上传脏的那一块的像素。
## ---- 原生栅格化（GDExtension 的 PixelRaster）----
##
## ⚠️ 为什么值得：逐像素在 GDScript 里填 RGBA8 是**实测 0.65 us/像素**
##    （就是下面那个 _build_region_image_gd）—— 一块 64x64 要 2.5 ms，
##    768x100 的地面首次建图 **50 ms**。而"大物体被切开"那一帧里，渲染重建
##    比破坏本身还贵（实测 53 ms vs 23.7 ms，见 tests/diag_bigfrag_hitch.gd）。
##
## ⚠️ GDScript 那条路**必须留着**：它是参照实现，逐位对拍靠它
##    （tests/validation_raster_native.gd）；shading 打开时也只能走它。
var _raster: Object = null
var _raster_checked := false
## 256 项 RGBA 表（u32，小端 = r,g,b,255）—— 交给原生直接拷贝。
##
## ⚠️ 三条规则（int(c*255) 截断 / alpha 强制 255 / 材质 id 越界 clamp 到最后一格）
##    只在这里写一次；原生只做拷贝，浮点语义**不复制第二份**。
var _palette_table := PackedByteArray()
## 自校验指纹：这张表是**按这份 palette** 建的。
##
## ⚠️ 用 Array 深比较（原生实现）而不是"改了调色板就置脏"的标志位：
##    后者要求每个改动路径都记得置脏，而 palette 是**公开数组** ——
##    用户既可以直接替换整个数组，也可以就地改某一格。
##    深比较把两条路都盖住了，代价是每次重建一次原生比较（微秒级）。
##    （本仓库在"标志位漏置"上栽过太多次，所以宁可每次比。）
var _palette_src: Array = []


## 懒加载原生栅格化器。返回 null 表示扩展不可用（调用方退回 GDScript）。
func _ensure_raster() -> Object:
	if not _raster_checked:
		_raster_checked = true
		if ClassDB.class_exists("PixelRaster"):
			_raster = ClassDB.instantiate("PixelRaster")
			# ⚠️ 与 RapierPhys 同一个 Godot 已知问题（issue #111075）：
			#    GDExtension 实例化出来的 RefCounted 引用计数是 2，多出来的那份
			#    没人还 -> 退出时报实例泄漏。判 > 1 再 unreference
			#    （计数为 1 时调它会真的把对象释放掉）。
			if _raster != null and _raster.get_reference_count() > 1:
				_raster.unreference()
		if _raster == null:
			# ⚠️ 这里只警告、不回退到 assert：渲染**有**一条正确的慢路径，
			#    和物理（缺扩展就没法跑）不同 —— 少画/画错才是不可接受的。
			push_warning("PixelRaster 扩展不可用 —— 渲染退回 GDScript 逐像素路径（慢 ~50 倍）。" +
				"跑 python tools/build_native.py 重编 fastphys.dll。")
	return _raster


func _palette_table_bytes() -> PackedByteArray:
	var n := palette.size()
	if n <= 0:
		return PackedByteArray()
	if _palette_src == palette and _palette_table.size() == 1024:
		return _palette_table
	_palette_src = palette.duplicate()
	var t := PackedByteArray()
	t.resize(1024)
	for i in 256:
		# 越界材质 id 夹到最后一格 —— 与参照实现同一条规则
		var mi: int = i if i <= n - 1 else n - 1
		var col: Color = palette[mi]
		t.encode_u32(i << 2,
			(int(col.r * 255.0)) | (int(col.g * 255.0) << 8)
			| (int(col.b * 255.0) << 16) | (255 << 24))
	_palette_table = t
	return t


## 走原生填一块区域。协议见 gdext/fastphys.cpp 的 PixelRaster 一节。
##
## ⚠️ 失败时**吵闹地**退回 GDScript 参照实现，而不是"能画多少画多少" ——
##    静默画错比慢得多难查（本仓库的规矩）。
func _build_region_image_native(shapes: Array, aabb: Rect2i, region: Rect2i) -> Image:
	native_calls += 1
	var w: int = region.size.x
	var h: int = region.size.y
	var ox: int = aabb.position.x
	var oy: int = aabb.position.y
	var rx: int = region.position.x
	var ry: int = region.position.y
	# 与参照实现**同一个块范围**（都按 8 像素的块网格推）
	var kx0 := (rx + ox) >> 3
	var ky0 := (ry + oy) >> 3
	var kx1 := (rx + ox + w - 1) >> 3
	var ky1 := (ry + oy + h - 1) >> 3
	# ① 收集本区域覆盖到的块（只传非空块；区域外的块由原生按同一判据跳过）
	var hits: Array = []
	for s: PixelShape in shapes:
		for cy in range(ky0, ky1 + 1):
			for cx in range(kx0, kx1 + 1):
				var c: PixelChunk = s.chunks.get(PixelShape.make_key(cx, cy))
				if c != null:
					hits.append(cx)
					hits.append(cy)
					hits.append(c)
	var n := hits.size() / 3
	var need := w * h * 4
	# ② 头 + 调色板表（append_array 一次搬 1024 字节）
	var cmds := PackedByteArray()
	cmds.resize(1 + 4 * 6 + 4)
	cmds.encode_u8(0, 1)                 # op 1 = fill_region
	cmds.encode_s32(1, w)
	cmds.encode_s32(5, h)
	cmds.encode_s32(9, rx)
	cmds.encode_s32(13, ry)
	cmds.encode_s32(17, ox)
	cmds.encode_s32(21, oy)
	cmds.encode_s32(25, n)
	cmds.append_array(_palette_table_bytes())
	# ③ 每条块记录：cx, cy, occ(int64), mat(64 字节)
	#    ⚠️ mat 只能用 append_array 搬（64 次 encode_u8 会把收益吃光）；
	#       所以记录是**顺序**写出来的：头 16 字节 resize + encode，mat 整体追加。
	for i in n:
		var c2: PixelChunk = hits[i * 3 + 2]
		var off := cmds.size()
		cmds.resize(off + 16)
		cmds.encode_s32(off, hits[i * 3])
		cmds.encode_s32(off + 4, hits[i * 3 + 1])
		cmds.encode_s64(off + 8, c2.occ)
		cmds.append_array(c2.mat)
	var inp := PackedByteArray()
	inp.resize(8)
	inp.encode_s32(0, need)
	inp.encode_s32(4, cmds.size())
	inp.append_array(cmds)
	var tmpl := PackedByteArray()
	tmpl.resize(4 + need)
	var res: PackedByteArray = _raster.fill_region(inp, tmpl)
	if res.size() < 4 + need or res.decode_s32(0) != need:
		native_fallbacks += 1
		push_error("PixelRaster.fill_region 返回长度不对（res=%d 期望=%d）—— 退回 GDScript 参照实现" % [
			res.size(), 4 + need])
		return _build_region_image_gd(shapes, aabb, region)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, res.slice(4, 4 + need))


## 只把 region（相对 aabb 的像素矩形）那一块画成一张小 Image。
##
## 有原生栅格化器就走原生（0.65 us/像素 -> ~0.01 us/像素），否则走 GDScript
## 参照实现。两条路**必须逐位一致** —— 闸门 tests/validation_raster_native.gd。
func _build_region_image(shapes: Array, aabb: Rect2i, region: Rect2i) -> Image:
	# ⚠️ 四条前置条件缺一不可：
	#   · shading 打开时只能走 GDScript（逐像素着色是 GDScript 的规则）
	#   · palette 为空时参照实现自己就会报错，原生表也无从建起
	#   · 区域必须非空
	#   · 扩展在不在
	if not shading and palette.size() > 0 and region.size.x > 0 and region.size.y > 0 \
			and _ensure_raster() != null:
		return _build_region_image_native(shapes, aabb, region)
	return _build_region_image_gd(shapes, aabb, region)


## **参照实现**：逐像素在 GDScript 里填 RGBA8。
##
## ⚠️ 原生化之后它仍然是真源之一：原生那条路的每一条规则（块范围推导、
##    越界跳过、调色板 clamp、alpha 强制 255）都以它为准，逐位对拍。
func _build_region_image_gd(shapes: Array, aabb: Rect2i, region: Rect2i) -> Image:
	var w: int = region.size.x
	var h: int = region.size.y
	var data := PackedByteArray()
	data.resize(w * h * 4)
	var ox: int = aabb.position.x
	var oy: int = aabb.position.y
	var rx: int = region.position.x
	var ry: int = region.position.y
	# ⚠️⚠️ **只遍历本块覆盖到的 chunk**，不要遍历整个形状。
	#
	#    第一版写的是 for k in s.chunks（全部 1248 个），在循环里判断像素
	#    在不在区域内 —— 于是每块都要扫 1248 个 chunk，
	#    24 块 = **29952 次访问**。实测每笔 sync 821 ms，
	#    折合 8.3 us/像素，比整张重建（0.57 us/像素）还慢 14 倍。
	#
	#    "分块"如果实现成"每块都扫全局"，比不分块还慢 —— 这是分块算法
	#    最容易犯的错，而且画面上完全看不出来。
	var kx0 := (rx + ox) >> 3
	var ky0 := (ry + oy) >> 3
	var kx1 := (rx + ox + w - 1) >> 3
	var ky1 := (ry + oy + h - 1) >> 3
	for s: PixelShape in shapes:
		for cy in range(ky0, ky1 + 1):
			for cx in range(kx0, kx1 + 1):
				var c: PixelChunk = s.chunks.get(PixelShape.make_key(cx, cy))
				if c == null:
					continue
				var bx := (cx << 3) - ox
				var by := (cy << 3) - oy
				var bits := c.occ
				while bits != 0:
					var i := Bits.first_bit_index(bits)
					bits &= bits - 1
					var gx := bx + (i & 7)
					var gy := by + (i >> 3)
					var lx := gx - rx
					var ly := gy - ry
					if lx < 0 or lx >= w or ly < 0 or ly >= h:
						continue
					var mi: int = c.mat[i]
					if mi >= palette.size():
						mi = palette.size() - 1
					var col: Color = palette[mi]
					if shading:
						col = _PixelShading.shade(s, gx + ox, gy + oy, col)
					var o := (ly * w + lx) << 2
					data.encode_u32(o,
						(int(col.r * 255.0)) | (int(col.g * 255.0) << 8)
						| (int(col.b * 255.0) << 16) | (255 << 24))
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)


## 供测试 / 调试：读回某个**局部像素点**所在的块贴图（块内坐标另算）。
func tile_image_at(body_id: int, local_x: int, local_y: int) -> Image:
	var tiles: Dictionary = _tiles.get(body_id, {})
	var key := Vector2i(local_x >> 6, local_y >> 6)
	if not tiles.has(key):
		return null
	return (_tile_img.get(body_id, {}) as Dictionary).get(key)


## 这一块的**区域**（在局部像素里的原点 + 尺寸）变了吗？
##
## ⚠️ 区域一变，缓存下来的那张图的内容映射就错了 —— 必须重画，
##    哪怕脏矩形根本没碰到它。AABB 缩小（大物体被切开）正是这种情况：
##    边界那几块的宽度变了，而它们的像素其实一个都没动。
static func _tile_region_changed(sp: Sprite2D, cur: Image, tex: ImageTexture,
		origin: Vector2, size: Vector2i) -> bool:
	if sp == null or cur == null or tex == null:
		return true
	return sp.offset != origin or tex.get_width() != size.x or tex.get_height() != size.y


## 取走各形状的脏块，合并成一个**相对 aabb 的像素矩形**，并清空脏集合。
##
## 返回 Rect2i() 表示"**没有块级信息**"（例如走 touch() 的原生路径）——
## 调用方此时只能全量重建。这是有意的保守：宁可多画，不能少画。
func _take_dirty_rect(body, aabb: Rect2i) -> Rect2i:
	var lo_x := 1 << 30
	var lo_y := 1 << 30
	var hi_x := -(1 << 30)
	var hi_y := -(1 << 30)
	var any := false
	for s: PixelShape in body.shapes:
		if not s.has_dirty():
			continue
		any = true
		for k: int in s.dirty_chunks():
			var bx := (PixelShape.key_x(k) << 3) - aabb.position.x
			var by := (PixelShape.key_y(k) << 3) - aabb.position.y
			lo_x = mini(lo_x, bx)
			lo_y = mini(lo_y, by)
			hi_x = maxi(hi_x, bx + 8)
			hi_y = maxi(hi_y, by + 8)
		s.clear_dirty()
	if not any or hi_x <= lo_x or hi_y <= lo_y:
		return Rect2i()
	# ⚠️⚠️ **不要**把它夹进 aabb。曾经夹过（理由是"脏块可能落在外面"），
	#    症状：大物体被切开时切口整条都落在母体**新** AABB 之外 ——
	#    夹完 hi_x <= lo_x -> 返回空矩形 -> 调用方读成"没有块级信息"
	#    -> 保守全量重建 12/12 块（实测 24 ms，而母体一个像素都没变）。
	#    现在返回**未夹的**矩形：越界部分命中不了任何块（块都在 aabb 内），
	#    而"到底有没有脏信息"这个信号保住了。
	#    真正需要裁剪的是逐块 patch 那一步，那里用 dirty.intersection(tr) 裁，
	#    tr 本身就在 aabb 内 —— 所以这里不夹是安全的。
	return Rect2i(lo_x, lo_y, hi_x - lo_x, hi_y - lo_y)


func _build_texture_impl(shapes: Array, aabb: Rect2i, cache_key: int):
	var w: int = aabb.size.x
	var h: int = aabb.size.y
	var data := PackedByteArray()
	data.resize(w * h * 4)
	var ox: int = aabb.position.x
	var oy: int = aabb.position.y
	for s: PixelShape in shapes:
		for k: int in s.chunks:
			var c: PixelChunk = s.chunks[k]
			var bx := (PixelShape.key_x(k) << 3) - ox
			var by := (PixelShape.key_y(k) << 3) - oy
			var bits := c.occ
			while bits != 0:
				var i := Bits.first_bit_index(bits)
				bits &= bits - 1
				var gx := bx + (i & 7)
				var gy := by + (i >> 3)
				if gx < 0 or gx >= w or gy < 0 or gy >= h:
					continue
				# ⚠️ 不要取模回绕：材质 id 越界时 7 % 7 = 0，而索引 0 通常是
				#    Color(0,0,0,0) —— 像素会在画面上**直接消失**（物理还在），
				#    极难联想到是材质表不够长。夹紧 + 明确警告。
				var mi: int = c.mat[i]
				if mi >= palette.size():
					if not _warned_material:
						_warned_material = true
						push_warning("PixelRenderer: 材质 id %d 超出调色板（只有 %d 项），已夹到末项。请在材质表里补上。" % [mi, palette.size()])
					mi = palette.size() - 1
				var col: Color = palette[mi]
				if shading:
					# ⚠️ 坐标要用**形状局部**的：gx/gy 是贴图局部，
					#    查四邻域必须加上外接盒原点，否则边沿会沿着贴图边界算，
					#    表现为形状内部凭空出现一条暗线。
					col = _PixelShading.shade(s, gx + ox, gy + oy, col)
				# ⚠️ 一次 encode_u32，不是四次逐字节写。
				#    768x100 的地面 = 76800 像素，逐字节写是 30.7 万次 GDScript
				#    数组写入；encode_u32 把它压成 7.7 万次。这是擦除卡顿里
				#    "重建贴图 ~46 ms" 的主要成分。
				var o := (gy * w + gx) << 2
				data.encode_u32(o,
					(int(col.r * 255.0)) | (int(col.g * 255.0) << 8)
					| (int(col.b * 255.0) << 16) | (255 << 24))
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)
	_images[cache_key] = img
	var tex: ImageTexture = _textures.get(cache_key)
	if tex == null:
		tex = ImageTexture.create_from_image(img)
		_textures[cache_key] = tex
	else:
		tex.update(img)
	return tex
