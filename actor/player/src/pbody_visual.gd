@tool
extends "res://addons/pixel_destruction/nodes/pixel_sprite_2d.gd"


## 只画**父刚体认的**形状（PixelBody2D.collect_shapes()）。引擎默认的 _collect() 是
## duck-typing 收兄弟里所有有 build_shape() 的节点 —— Player 下的 Arm（手，rect_size 4x4）
## 因此会被画成 16 个黑像素。物理认什么就画什么，两边不再分叉。
##
## **美术贴图**：挂在本节点（渲染节点）下的形状只画不物理 —— 物理只看刚体的直接子形状
## （collect_shapes() 不动这一层）。可见的那张优先，于是"换贴图"= 切 visible。
func _collect() -> Array:
	for child in get_children():
		if child.visible and child.has_method("get_shape"):
			return [child.get_shape()]
	var p := get_parent()
	if p == null or not p.has_method("collect_shapes"):
		return super()
	return p.collect_shapes()


## 丢掉贴图缓存并重建。切美术贴图必须走它 —— 基类的 rebuild() 用 ImageTexture.update()
## 复用旧贴图，而 update() **不接受尺寸变化**（两张姿态图宽高不同时报
## "new image dimensions must match" 并静默留旧图）。引擎侧的正式修法是 rebuild() 里
## 比一次尺寸再决定 create/update；本工程先用这个入口绕开。
func refresh() -> void:
	_tex = null
	rebuild()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var physics_body = get_parent()
	if physics_body.body == null:
		return
	var pixel_world = physics_body.get_node(physics_body.world_path)
	global_position = pixel_world.to_global(physics_body.body.position)
	global_rotation = pixel_world.global_rotation + physics_body.body.rotation
