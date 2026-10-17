extends SceneTree

const EnergyFlow := preload("res://ink/blue/src/energy_flow.gd")
const BlueInk := preload("res://ink/blue/src/blue_ink.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")

class FakeBody:
	var shapes: Array = []

func _init() -> void:
	var flow = EnergyFlow.new()
	var rule = BlueInk.new()
	rule.fuel_contact_radius = 3
	var body = FakeBody.new()
	var shape = Shape.new()
	body.shapes = [shape]
	shape.set_pixel(0, 0, Palette.RED.id)
	shape.set_pixel(3, 0, Palette.RED.id)
	shape.set_pixel(4, 0, Palette.RED.id)
	var account := {"credit": 1.0, "contacts": {Vector2i.ZERO: true}}
	var result := {}
	flow._settle_fuel_account(rule, body, account, result)
	var removed: Dictionary = result[body][shape]
	var pass_local := removed.has(Vector2i(3, 0)) and not removed.has(Vector2i.ZERO) \
		and not removed.has(Vector2i(4, 0))
	print("PASS local radius burns far nearby red first" if pass_local
		else "FAIL local radius burns far nearby red first")
	shape.clear_pixel(3, 0)
	account = {"credit": 1.0, "contacts": {Vector2i.ZERO: true}}
	result = {}
	flow._settle_fuel_account(rule, body, account, result)
	removed = result[body][shape]
	var pass_terminal := removed.has(Vector2i.ZERO) and not removed.has(Vector2i(4, 0))
	print("PASS terminal burns only after local fuel is empty" if pass_terminal
		else "FAIL terminal burns only after local fuel is empty")
	rule.free()
	flow = null
	shape = null
	body = null
	quit(0 if pass_local and pass_terminal else 1)
