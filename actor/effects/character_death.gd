extends Node2D
## 角色死亡的纯视觉残影：不引用原角色，不烘焙、不碰撞、不参与存档。
signal finished

const DeathShader := preload("res://actor/effects/character_death.gdshader")
const HIT_PAUSE_SECONDS := 0.06
enum Style { PLAYER, SOLDIER, SHIELD, BOMB, REVIVE }
var style := Style.SOLDIER
var duration := 0.9
var elapsed := 0.0
var dissolve_only := false
var direction := 1.0
var pieces: Array[Dictionary] = []
var _origin := Vector2.ZERO
var _height := 100.0
var _width := 70.0


static func spawn(host: Node2D, sprites: Array, effect_style: Style,
		foot: Vector2, hit_direction := 1.0, only_dissolve := false):
	var effect := load("res://actor/effects/character_death.gd").new() as Node2D
	effect.name = "CharacterDeathEffect"
	effect.add_to_group(&"character_death_effect")
	effect.style = effect_style
	effect.duration = [1.2, 0.9, 1.5, 1.0, 0.25][effect_style]
	effect.direction = -1.0 if hit_direction < 0.0 else 1.0
	effect.dissolve_only = only_dissolve
	if only_dissolve:
		effect.duration = 0.65
	host.add_child(effect)
	effect.global_transform = Transform2D(0.0, foot)
	effect._origin = foot
	for source: Sprite2D in sprites:
		if source.texture == null or not source.is_visible_in_tree():
			continue
		effect._copy_piece(source)
	effect._prepare()
	return effect


static func visible_sprites(node: Node) -> Array:
	var result: Array = []
	for sprite: Sprite2D in node.find_children("*", "Sprite2D", true, false):
		if sprite.texture != null and sprite.is_visible_in_tree():
			result.append(sprite)
	return result


static func foot_position(sprite: Sprite2D) -> Vector2:
	# 使用画面下缘；倒置时纹理的局部底边实际在头顶，不能作为地面锚点。
	var bounds: Rect2 = sprite.global_transform * sprite.get_rect()
	return Vector2(bounds.get_center().x, bounds.end.y)


static func sprites_foot_position(sprites: Array, fallback: Vector2) -> Vector2:
	var bounds := Rect2()
	for sprite: Sprite2D in sprites:
		if sprite.texture == null or sprite.name == "ShieldArt" or not sprite.is_visible_in_tree():
			continue
		var rect := Rect2(sprite.texture.get_image().get_used_rect())
		if rect.size == Vector2.ZERO:
			continue
		if sprite.flip_h:
			rect.position.x = sprite.texture.get_width() - rect.end.x
		if sprite.flip_v:
			rect.position.y = sprite.texture.get_height() - rect.end.y
		rect.position += sprite.get_rect().position
		var world_rect: Rect2 = sprite.global_transform * rect
		bounds = world_rect if bounds.size == Vector2.ZERO else bounds.merge(world_rect)
	return Vector2(bounds.get_center().x, bounds.end.y) if bounds.size != Vector2.ZERO else fallback


func _copy_piece(source: Sprite2D) -> void:
	if source.texture.get_image().get_used_rect().size == Vector2i.ZERO:
		return
	var sprite := Sprite2D.new()
	if source.name == "BombArt":
		sprite.name = "BombArt"
	sprite.texture = source.texture
	sprite.centered = source.centered
	sprite.offset = source.offset
	sprite.flip_h = source.flip_h
	sprite.flip_v = source.flip_v
	sprite.modulate = source.modulate
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.z_as_relative = false
	var depth := 0
	var ancestor: Node = source
	while ancestor is CanvasItem:
		depth += ancestor.z_index
		if not ancestor.z_as_relative:
			break
		ancestor = ancestor.get_parent()
	sprite.z_index = clampi(depth, -4096, 4096)
	var material := ShaderMaterial.new()
	material.shader = DeathShader
	sprite.material = material
	add_child(sprite)
	sprite.global_transform = source.global_transform
	var role := str(source.get_parent().name)
	if source.name == "ShieldArt":
		role = "Shield"
	elif style in [Style.PLAYER, Style.REVIVE]:
		role = "Hand" if source.get_path().get_concatenated_names().contains("/Arm/") else "Bottle"
		material.set_shader_parameter("death_face", style == Style.PLAYER and source.name == "Visual")
	var mask_texture: Texture2D = source.texture
	var mask := source.get_parent().get_node_or_null("OcclusionMask") as Sprite2D
	if mask == null:
		mask = source.get_parent().get_node_or_null(role + "OcclusionMask") as Sprite2D
	if role == "BodyBone":
		mask = source.get_parent().get_node_or_null("BodyOcclusionMask") as Sprite2D
	# 手持炸弹是独立实心图像，不能复用手臂的线稿遮罩。
	if mask != null and source.name != "BombArt":
		mask_texture = mask.texture
	var bounds := Rect2(source.texture.get_image().get_used_rect())
	bounds.position += source.offset
	if source.centered:
		bounds.position -= source.texture.get_size() * 0.5
	if source.flip_h:
		bounds.position.x = source.get_rect().position.x + source.texture.get_width() - (bounds.position.x - source.get_rect().position.x) - bounds.size.x
	if source.flip_v:
		bounds.position.y = source.get_rect().position.y + source.texture.get_height() - (bounds.position.y - source.get_rect().position.y) - bounds.size.y
	var pivot := to_local(source.get_parent().global_position)
	pieces.append({"sprite": sprite, "base": sprite.transform, "role": role,
		"mask": mask_texture, "bounds": bounds, "pivot": pivot})
	material.set_shader_parameter("cell_pixels", (5.0 if style == Style.SHIELD else 2.5)
		/ maxf(source.global_transform.x.length(), 0.01))
	if style == Style.PLAYER and role == "Bottle" and source.name == "Visual":
		material.set_shader_parameter("cut_cap", true)
		var cap := Sprite2D.new()
		cap.texture = sprite.texture
		cap.centered = false
		cap.offset = sprite.offset
		cap.region_enabled = true
		cap.region_rect = Rect2(0, 0, sprite.texture.get_width(), sprite.texture.get_height() * 0.24)
		cap.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		cap.z_index = sprite.z_index
		cap.z_as_relative = false
		cap.material = material.duplicate()
		cap.material.set_shader_parameter("cut_cap", false)
		cap.material.set_shader_parameter("death_face", false)
		add_child(cap)
		cap.transform = sprite.transform
		pieces.append({"sprite": cap, "base": cap.transform, "role": "Cap",
			"mask": sprite.texture, "bounds": cap.get_rect(), "pivot": pivot})


func _prepare() -> void:
	pieces.sort_custom(func(a, b): return a.sprite.z_index > b.sprite.z_index)
	var bounds := Rect2()
	for piece in pieces:
		if piece.role == "Hand":
			continue
		var rect: Rect2 = _piece_bounds(piece)
		bounds = rect if bounds.size == Vector2.ZERO else bounds.merge(rect)
	_height = maxf(bounds.size.y, 20.0)
	_width = maxf(bounds.size.x, 20.0)
	_update_pose(0.0)


func _piece_bounds(piece: Dictionary) -> Rect2:
	return piece.sprite.transform * Rect2(piece.bounds)


func _process(delta: float) -> void:
	elapsed += delta
	var clock := elapsed
	if style != Style.REVIVE and not dissolve_only:
		# 仅残影短暂停顿，不修改全场时间倍率或物理步长。
		clock = maxf(0.0, elapsed - HIT_PAUSE_SECONDS) * duration / (duration - HIT_PAUSE_SECONDS)
	_update_pose(minf(floorf(clock * 12.0) / 12.0, duration))
	if elapsed >= duration:
		finished.emit()
		queue_free()


func _update_pose(time: float) -> void:
	var progress := clampf(time / duration, 0.0, 1.0)
	var collapse := smoothstep(0.08, 0.55, progress)
	if style == Style.SHIELD:
		collapse = smoothstep(0.28, 0.65, progress)
	var dissolve := smoothstep(0.5, 1.0, progress)
	if dissolve_only:
		collapse = 0.0
		dissolve = progress
	if style == Style.REVIVE:
		collapse = 0.0
		dissolve = 1.0 - progress
	global_transform = Transform2D(0.0, _origin)
	var angle := direction * collapse * (0.78 if style == Style.BOMB else 1.3)
	var shift := Vector2(direction * _height * 0.12 * collapse, 0.0)
	for piece in pieces:
		var role: String = piece.role
		var local_angle := 0.0
		var offset := Vector2.ZERO
		if role.ends_with("Arm"):
			local_angle = direction * collapse * (0.55 if style == Style.BOMB else -0.22)
		elif role.ends_with("Leg"):
			local_angle = direction * collapse * 0.35
			if style == Style.SHIELD:
				local_angle = direction * smoothstep(0.08, 0.3, progress) * 0.65
		elif role == "Shield":
			local_angle = -direction * smoothstep(0.05, 0.3, progress) * 1.2
		elif role == "Hand":
			offset = (Vector2(direction * _width * 0.35, -_height * 0.25) - Vector2(piece.pivot)) * collapse
		elif role == "Cap":
			offset = Vector2(direction * 3.0, -1.0) * collapse
		var pivot: Vector2 = piece.pivot
		if role == "Shield":
			pivot = Transform2D(piece.base) * Rect2(piece.bounds).get_center()
		var bend := Transform2D(local_angle, pivot + offset) * Transform2D(0.0, -pivot)
		piece.sprite.transform = bend * Transform2D(piece.base) if role == "Shield" else Transform2D(angle, shift) * bend * Transform2D(piece.base)
		piece.sprite.material.set_shader_parameter("dissolve", dissolve)
	if not dissolve_only and style != Style.REVIVE:
		var bottom := -INF
		for piece in pieces:
			if piece.role in ["Hand", "Shield"]:
				continue
			bottom = maxf(bottom, _piece_bounds(piece).end.y)
		if is_finite(bottom):
			global_position.y -= bottom
		# 一次很小的接地回弹，随后保持落地；不作用于任何刚体。
		global_position.y -= sin(clampf((progress - 0.35) / 0.18, 0.0, 1.0) * PI) * 2.0
		if progress < 0.1:
			global_position.x += (1.0 if int(time * 24.0) % 2 == 0 else -1.0) * 1.5
		for piece in pieces:
			if piece.role == "Shield":
				piece.sprite.position.y += _origin.y - global_position.y - _piece_bounds(piece).end.y
	_sync_masks()


func _sync_masks() -> void:
	var front: Array[Dictionary] = []
	for piece in pieces:
		var sprite: Sprite2D = piece.sprite
		var material: ShaderMaterial = sprite.material
		var masks := [] if style in [Style.PLAYER, Style.REVIVE] else front.slice(0, 5)
		material.set_shader_parameter("mask_count", masks.size())
		for index in masks.size():
			var mask: Dictionary = masks[index]
			var art: Sprite2D = mask.sprite
			var texture: Texture2D = mask.mask
			var pixel_frame := Transform2D.IDENTITY
			pixel_frame.origin = art.get_rect().position
			if art.flip_h:
				pixel_frame.x = Vector2.LEFT
				pixel_frame.origin.x += texture.get_width()
			if art.flip_v:
				pixel_frame.y = Vector2.UP
				pixel_frame.origin.y += texture.get_height()
			var inverse := (art.global_transform * pixel_frame).affine_inverse()
			material.set_shader_parameter("mask_%d" % index, texture)
			material.set_shader_parameter("mask_%d_inv_x" % index, inverse.x)
			material.set_shader_parameter("mask_%d_inv_y" % index, inverse.y)
			material.set_shader_parameter("mask_%d_inv_origin" % index, inverse.origin)
		front.append(piece)
