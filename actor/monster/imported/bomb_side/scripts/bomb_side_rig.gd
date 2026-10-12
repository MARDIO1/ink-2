@tool
extends Node2D

## 从前到后：左手、左脚、身体、右脚、右手。
const FRONT_TO_BACK: Array[NodePath] = [
	^"Skeleton2D/BodyHead/LeftArm",
	^"Skeleton2D/BodyHead/LeftLeg",
	^"Skeleton2D/BodyHead",
	^"Skeleton2D/BodyHead/RightLeg",
	^"Skeleton2D/BodyHead/RightArm",
]

func _ready() -> void:
	process_priority = 200
	update_masks()

func _process(_delta: float) -> void:
	update_masks()

func update_masks() -> void:
	var masks: Array[Sprite2D] = []
	for index in FRONT_TO_BACK.size():
		var bone := get_node_or_null(FRONT_TO_BACK[index])
		if bone == null:
			continue
		var art := bone.get_node("Art") as Sprite2D
		var mask := bone.get_node("OcclusionMask") as Sprite2D
		mask.transform = art.transform
		mask.centered = art.centered
		mask.offset = art.offset
		mask.flip_h = art.flip_h
		mask.flip_v = art.flip_v
		art.z_index = FRONT_TO_BACK.size() - index - 1
		if art.material is ShaderMaterial:
			var material := art.material as ShaderMaterial
			material.set_shader_parameter("mask_count", masks.size())
			for mask_index in masks.size():
				var front := masks[mask_index]
				# 纹理像素 -> 精灵局部坐标，同时补偿非居中原点与 flip_h/v。
				var rect := front.get_rect()
				var pixel_to_local := Transform2D.IDENTITY
				pixel_to_local.origin = rect.position
				if front.flip_h:
					pixel_to_local.x = Vector2.LEFT
					pixel_to_local.origin.x += rect.size.x
				if front.flip_v:
					pixel_to_local.y = Vector2.UP
					pixel_to_local.origin.y += rect.size.y
				var inverse := (front.global_transform * pixel_to_local).affine_inverse()
				material.set_shader_parameter("mask_%d" % mask_index, front.texture)
				material.set_shader_parameter("mask_%d_inv_x" % mask_index, inverse.x)
				material.set_shader_parameter("mask_%d_inv_y" % mask_index, inverse.y)
				material.set_shader_parameter("mask_%d_inv_origin" % mask_index, inverse.origin)
		masks.append(mask)
