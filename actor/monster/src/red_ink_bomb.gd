extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"
## 红墨炸弹使用同一 PixelWorld 的 CCD 刚体，退出时显式清理碰撞与排斥关节。
const Palette := preload("res://ink/src/ink_palette.gd")
var level: Node2D
var art: Sprite2D
var _disposed := false
var exclusions: Array = []
var _launch_velocity := Vector2.ZERO


static func spawn(host: Node2D, source: Sprite2D, shooter: Node2D, target: Vector2):
	var bomb = load("res://actor/monster/src/red_ink_bomb.gd").new()
	bomb.name = "RedInkBomb"
	bomb.level = host
	bomb.art = Sprite2D.new()
	bomb.art.texture = source.texture
	bomb.art.centered = source.centered
	bomb.art.offset = source.offset
	bomb.art.flip_h = source.flip_h
	bomb.art.flip_v = source.flip_v
	bomb.art.visible = false # 贴图仅作轮廓模板，实际红墨由 PixelWorld 渲染。
	bomb.art.transform = Transform2D(source.global_transform.x, source.global_transform.y, Vector2.ZERO)
	bomb.add_child(bomb.art)
	bomb.position = host.to_local(source.global_position)
	bomb.art.transform = host.global_transform.affine_inverse() * source.global_transform
	bomb.art.position -= bomb.position
	bomb.z_index = shooter.z_index + 10
	bomb.internal_render = true
	bomb.material_id = Palette.RED.id
	host.add_child(bomb)
	bomb.add_to_group(&"monster_projectile")
	var physics_body = bomb.body
	var origin: Vector2 = physics_body.com_world()
	var flight := clampf(absf(target.x - origin.x) / 450.0, 0.55, 1.15)
	bomb._launch_velocity = (target - origin) / flight - host.world.gravity * flight * 0.5
	bomb._launch_velocity.x = clampf(bomb._launch_velocity.x, -650.0, 650.0)
	bomb._launch_velocity.y = clampf(bomb._launch_velocity.y, -900.0, -80.0)
	physics_body.linear_velocity = bomb._launch_velocity
	physics_body.angular_velocity = -2.0 if target.x < origin.x else 2.0
	var owned: Array = [shooter.body]
	for part in shooter._ragdoll.parts:
		owned.append(part.body)
	for body in owned:
		var joint = host.world.add_rope(physics_body, body, physics_body.position, body.position, 1000000.0)
		joint.contacts_enabled = false
		bomb.exclusions.append(joint)
	var step := host.get_node_or_null("SimulationRuntime/PhysicsStep")
	if step != null:
		step.body_fractured.connect(bomb._on_body_fractured)
	host.realign_body_nodes()
	return bomb


func _bake_lazily():
	return null if _disposed else level.add_body_node(self)


func build_shape():
	var shape := PixelShape.new()
	var image := art.texture.get_image()
	var frame := Transform2D(global_rotation, global_position)
	var pixel_transform := frame.affine_inverse() * art.global_transform
	var inverse := pixel_transform.affine_inverse()
	var used := Rect2(image.get_used_rect())
	if art.flip_h:
		used.position.x = image.get_width() - used.end.x
	if art.flip_v:
		used.position.y = image.get_height() - used.end.y
	used.position += art.get_rect().position
	var bounds: Rect2 = pixel_transform * used
	# 整数像素网格直接绘制红墨，不把引线的凹部填成凸包。
	for y in range(floori(bounds.position.y), ceili(bounds.end.y)):
		for x in range(floori(bounds.position.x), ceili(bounds.end.x)):
			var point := inverse * (Vector2(x, y) + Vector2.ONE * 0.5) - art.get_rect().position
			if art.flip_h:
				point.x = image.get_width() - point.x
			if art.flip_v:
				point.y = image.get_height() - point.y
			var pixel := Vector2i(point.floor())
			if pixel.x >= 0 and pixel.y >= 0 and pixel.x < image.get_width() and pixel.y < image.get_height() \
					and image.get_pixelv(pixel).a > 0.5:
				shape.set_pixel(x, y, Palette.RED.id)
	# 默认 density_scale=1，与画布固化的红墨质量完全一致。
	return shape


func bake():
	var result = super.bake()
	result.position = level.to_local(global_position)
	result.tags["map_monster"] = true # 临时投射物不能作为旧地图墨块保存。
	result.tags["monster_projectile"] = true
	result.ccd = true
	return result


func _physics_process(_delta: float) -> void:
	var creative := level.get_node_or_null("Creative")
	if creative != null and creative.active:
		queue_free()
		return
	if _disposed or _body == null or not level.world.bodies.has(_body):
		queue_free()
		return
	position = _body.position
	rotation = _body.rotation
	# 仅在出手时避免与手臂重叠；离开投掷者后恢复普通红墨的全部碰撞。
	var overlaps_shooter := false
	for joint in exclusions:
		if joint.body_b != null and _body.aabb.intersects(joint.body_b.aabb):
			overlaps_shooter = true
			break
	if not overlaps_shooter:
		_clear_exclusions()


func _on_body_fractured(_world, source, pieces: Array) -> void:
	if source != _body:
		return
	for piece in pieces:
		if piece != source:
			piece.tags.erase("map_monster")
			piece.tags.erase("monster_projectile")
			piece.internal_render = true


func _cleanup_body() -> void:
	_disposed = true
	if _body == null:
		return
	if is_instance_valid(level):
		_clear_exclusions()
		level.realign_body_nodes()
		if level.world.bodies.has(_body):
			level.remove_body_node(self)
		level.realign_body_nodes()
	for shape in _body.shapes:
		shape.owner_body = null
	_body = null


func _clear_exclusions() -> void:
	for joint in exclusions:
		if level.world.joints.has(joint):
			level.world.remove_joint(joint)
		joint.body_a = null
		joint.body_b = null
	exclusions.clear()


func _exit_tree() -> void:
	_cleanup_body()
	super._exit_tree()
