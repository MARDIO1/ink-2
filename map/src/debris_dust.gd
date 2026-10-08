extends Node
## 灰尘层（档 C-3）：太薄、**没进物理**的碎片在这里活一小会儿然后消失。
##
## ⚠️ 为什么要有它：那些碎片不配当刚体 —— PBody.needs_ccd 的判据对小碎片是**反向**的
##    （物体越小，变成「快体」所需的速度越低），实测一个 2x2 的碎片以 40000 px/s 飞过
##    能把全世界的子步顶到 334（876 矩形下 593 ms/固定步）。
##    引擎的 min_fragment_thickness 把它们挡在物理之外，这里负责
##    「别让玩家看见东西凭空消失」—— roxlap 的做法就是碎片落地即碎成纯表现粒子。
##
## ⚠️ 走渲染器的 **blueprint** 通道（sync_blueprint / place_blueprint / tint_blueprint /
##    forget_blueprint）：蓝图**不在 world.bodies 里** —— 宽相扫不到、不受重力、不被破坏，
##    纯粹是画面。这正是「降级」要的语义：还看得见，但不再参与任何物理。
##
## ⚠️⚠️ 每帧只调 place_blueprint / tint_blueprint，**绝不**调 sync_blueprint：
##    后者会无条件重跑 _build_texture_impl（逐像素重填 Image + tex.update）。
##    灰尘每帧都在动，但它的**像素内容一个字都没变** —— 该更新的是 transform，不是贴图。
##
## ⚠️⚠️ 渲染器是**延迟**加进树的（pixel_world.gd 用 add_child.call_deferred），
##    所以 setup() 拿到的世界节点里 renderer 大概率还是 null。**第一版我在这里写错了**：
##    注释写着「拿不到就每帧再试一次」，代码却是「拿不到就把这一批直接丢掉」——
##    注释和代码说的不是一件事，而症状是「灰尘一个都看不见」（碎片凭空消失）。
##    现在真的按帧重试，并且重试期间**不烧寿命**（否则等渲染器出现时它们已经过期了）。

## 灰尘寿命（秒）。到点就 forget（不是隐藏 —— 蓝图留着会一直占贴图）。
@export var lifetime: float = 0.55
## 灰尘的重力（px/s²）。它们只做**最简单的**抛物运动，不碰任何东西。
@export var gravity: float = 600.0
## 速度衰减（每秒的比例，0 = 不衰减）。给一点阻尼，看起来更像灰而不是石子。
@export_range(0.0, 1.0, 0.01) var damping: float = 0.35
## 起始不透明度（渲染器的 blueprint 默认 0.6，这里跟着它）。
@export_range(0.0, 1.0, 0.01) var alpha: float = 0.6
## 等渲染器最多等多久（秒）。等不到就放弃这一批 —— 不能无限攒着。
@export var resolve_timeout: float = 2.0

var _main = null
var _renderer = null
var _items: Array = []
var _next_id: int = 1
var _waited: float = 0.0


## 传**世界节点**（PixelWorld），不是 renderer —— 后者这时多半还是 null。
func setup(main) -> void:
	_main = main
	_renderer = _resolve()
	set_process(true)


func _resolve():
	if _main == null:
		return null
	return _main.renderer


## entries: [{shape, position, rotation}] —— 引擎 fracture_pixels 的 result.downgraded。
func spawn(entries: Array) -> void:
	if entries.is_empty():
		return
	for e in entries:
		var shape = e.get("shape")
		if shape == null:
			continue
		var id: int = _next_id
		_next_id += 1
		var pos: Vector2 = e.get("position", Vector2.ZERO)
		var rot: float = e.get("rotation", 0.0)
		_items.append({"id": id, "shape": shape, "pos": pos, "rot": rot,
			"vel": Vector2.ZERO, "life": lifetime})
		if _renderer != null:
			_renderer.sync_blueprint(id, shape, Transform2D(rot, pos))


func count() -> int:
	return _items.size()


func clear() -> void:
	if _renderer != null:
		for it in _items:
			_renderer.forget_blueprint(it["id"])
	_items.clear()


func _process(delta: float) -> void:
	if _items.is_empty():
		return
	if _renderer == null:
		_renderer = _resolve()
		if _renderer == null:
			# 还没拿到渲染器：**不推进寿命**，等它出现。等太久就放弃这一批。
			_waited += delta
			if _waited > resolve_timeout:
				_items.clear()
				_waited = 0.0
			return
		# 拿到了：把积压的这批补画上（它们还没开始老化）。
		for it in _items:
			_renderer.sync_blueprint(it["id"], it["shape"], Transform2D(it["rot"], it["pos"]))
	_waited = 0.0
	var keep: Array = []
	for it in _items:
		it["life"] = it["life"] - delta
		if it["life"] <= 0.0:
			_renderer.forget_blueprint(it["id"])
			continue
		var v: Vector2 = it["vel"]
		v.y += gravity * delta
		v *= maxf(0.0, 1.0 - damping * delta)
		it["vel"] = v
		var pos: Vector2 = it["pos"] + v * delta
		it["pos"] = pos
		_renderer.place_blueprint(it["id"], Transform2D(it["rot"], pos))
		_renderer.tint_blueprint(it["id"], alpha * clampf(it["life"] / maxf(lifetime, 1e-3), 0.0, 1.0))
		keep.append(it)
	_items = keep