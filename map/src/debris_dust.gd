extends Node
## 纯视觉灰尘层：显示从物理世界降级的碎片，并在短时间后移除。
## 灰尘不在 world.bodies 中，不碰撞、不受破坏，也不继承原刚体的线速度或角速度。
## 本脚本仅模拟竖直重力、阻尼和淡出；贴图内容不变时只更新蓝图变换。
## PixelRenderer 延迟创建，解析成功前暂停寿命计时，超时后丢弃积压项。

## 灰尘寿命（秒）；到期后释放对应蓝图。
@export var lifetime: float = 0.55
## 视觉重力（px/s²），不参与物理世界。
@export var gravity: float = 600.0
## 速度衰减比例，0 表示不衰减。
@export_range(0.0, 1.0, 0.01) var damping: float = 0.35
## 起始不透明度。
@export_range(0.0, 1.0, 0.01) var alpha: float = 0.6
## 等待渲染器的最长时间（秒）。
@export var resolve_timeout: float = 2.0

var _main = null
var _renderer = null
var _items: Array = []
var _next_id: int = 1
var _waited: float = 0.0


## 传入 PixelWorld；renderer 可能尚未创建。
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


func _process(delta: float) -> void:
	if _items.is_empty():
		return
	if _renderer == null:
		_renderer = _resolve()
		if _renderer == null:
			# 等待期间不推进寿命，超时后丢弃积压项。
			_waited += delta
			if _waited > resolve_timeout:
				_items.clear()
				_waited = 0.0
			return
		# renderer 就绪后补建积压蓝图。
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
