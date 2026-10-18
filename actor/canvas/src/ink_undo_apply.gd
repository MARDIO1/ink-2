extends RefCounted
## 撤销/重做的**状态捕获与还原**：把一步操作前后的像素、图层与账本搬进搬出。
##
## 只处理一类东西——"这一步之前/之后长什么样"；何时调用、如何协调工具与历史，
## 仍由画布的 `undo_last_edit` / `redo_last_edit` 决定。

const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const NAIL_COST := 10


static func capture_redo_state(surface, step: Dictionary) -> Dictionary:
	if step.has("bucket_before"):
		return {"bucket_after": surface.black_image.get_data(),
			"bucket_material": step.bucket_material, "bucket_count": step.bucket_count}
	if step.has("transaction") or step.has("yellow"):
		var bounds: Rect2 = step.get("transaction", {}).get("bounds", Rect2())
		# 重做还要捕获此次固化新建的支撑，否则撤销后再重做会丢失它。
		var body_filter: Dictionary = step.get("transaction", {}).get("body_filter", {}).duplicate()
		if not body_filter.is_empty():
			body_filter.merge(step.transaction.remove_ids)
		var state: Dictionary = surface.get_parent().History.capture(surface.get_parent(), step.has("transaction"), bounds, body_filter)
		if bounds.has_area():
			state["bounds"] = bounds
		if step.has("transaction"):
			for id in step.transaction.remove_ids:
				state.remove_ids[id] = true
			# 电路可能原地扩充；重做前先移除撤销恢复的旧版本，避免画出两层线。
			for entry in state.blue:
				state.blue_remove[entry.id] = true
			for id in step.transaction.get("blue_remove", {}):
				state.blue_remove[id] = true
		return {"transaction": state}
	if step.has("rod_pixels"):
		var current := {"rod_pixels": {}, "rod_anchors": surface.rod_layer.anchor_points.duplicate(),
			"rod_delta": -int(step.rod_delta)}
		for cell: Vector2i in step.rod_pixels:
			current.rod_pixels[cell] = surface.rod_layer.pixels.get_pixelv(cell).a > 0.5
		if step.has("rod_springs"):
			current.rod_springs = surface.yellow_rule().draft_data(surface)
		if step.has("rod_rails"):
			current.rod_rails = surface.rod_layer.rails.duplicate(true)
		if step.has("rod_pins"):
			current.rod_pins = surface.rod_layer.slider_pins.duplicate(true)
		if step.has("black_pixels"):
			current.black_pixels = {}
			for cell in step.black_pixels:
				if cell is Vector2i:
					current.black_pixels[cell] = surface.black_image.get_pixelv(cell)
			if step.black_pixels.has("gear_centers"):
				current.black_pixels["gear_centers"] = surface.gear_centers.duplicate(true)
			if step.black_pixels.has("draft_bearings"):
				current.black_pixels["draft_bearings"] = surface.draft_bearings.duplicate(true)
			if step.black_pixels.has("blue"):
				current.black_pixels["blue"] = capture_blue_edit(surface)
			if step.black_pixels.has("nails"):
				current.black_pixels["nails"] = surface.nail_layer.snapshot()
		return current
	var current := {}
	for pixel in step:
		if pixel is Vector2i:
			current[pixel] = surface.black_image.get_pixelv(pixel)
	if step.has("gear_centers"):
		current["gear_centers"] = surface.gear_centers.duplicate(true)
	if step.has("draft_bearings"):
		current["draft_bearings"] = surface.draft_bearings.duplicate(true)
	if step.has("blue"):
		current["blue"] = capture_blue_edit(surface)
	if step.has("nails"):
		current["nails"] = surface.nail_layer.snapshot()
	return current


static func restore_nail_edit(surface, state: Dictionary) -> void:
	var before: Dictionary = surface.nail_layer.snapshot()
	surface._bump_ink(InkPalette.GREY.id,
		(state.get("fixed", {}).size() - before.fixed.size()) * surface.NAIL_COST)
	surface._bump_ink(InkPalette.WHITE.id,
		(state.get("background", {}).size() - before.background.size()) * surface.NAIL_COST)
	surface.nail_layer.restore(state)


static func capture_blue_edit(surface) -> Dictionary:
	return {"cells": surface.blue_layer.cells.duplicate(),
		"motors": surface.blue_rule().capture(surface) if surface.blue_rule() != null else [],
		"ledger": surface.ink_px_of(InkPalette.BLUE.id)}


static func restore_blue_edit(surface, state: Dictionary) -> void:
	surface.blue_layer.cells = state.cells
	surface.blue_layer.rebuild()
	if surface.blue_rule() != null:
		surface.blue_rule().restore(surface, state.motors)
	surface._bump_ink(InkPalette.BLUE.id, int(state.ledger) - surface.ink_px_of(InkPalette.BLUE.id))


static func restore_bucket_image(surface, data: PackedByteArray, material_id: int, count: int) -> void:
	surface.black_image.set_data(surface.canvas_size.x, surface.canvas_size.y, false, Image.FORMAT_RGBA8, data)
	surface.rebuild_ink_tiles()
	surface._bump_ink(material_id, count)
	surface._flush_ink()


static func restore_black_pixels(surface, pixels: Dictionary) -> void:
	for cell in pixels:
		if cell is Vector2i:
			surface._set_pixel_raw(cell, pixels[cell])
	if pixels.has("gear_centers"):
		surface.gear_centers = pixels.gear_centers
	if pixels.has("draft_bearings"):
		surface.draft_bearings = pixels.draft_bearings
	if pixels.has("blue"):
		restore_blue_edit(surface, pixels.blue)
	if pixels.has("nails"):
		restore_nail_edit(surface, pixels.nails)
	surface._flush_texture()
	surface._flush_ink()


static func finish_redo_capture(surface, after: Dictionary) -> void:
	if not after.has("transaction"):
		return
	var state: Dictionary = after.transaction
	var health = surface._health_node()
	if health != null:
		for id in state.get("health", {}):
			state.health_delta[id] = state.health[id] - health.ink_of(id)
