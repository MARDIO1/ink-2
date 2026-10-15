extends SceneTree

const White := preload("res://ink/src/white_ink.gd")
const Sweep := preload("res://ink/src/white_ink_sweep.gd")
const Damage := preload("res://root/src/impact_damage.gd")
const Red := preload("res://ink/src/red_ink.gd")
const Palette := preload("res://ink/src/ink_palette.gd")
const World := preload("res://addons/pixel_destruction/physics/pworld.gd")
const Body := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Item := preload("res://actor/ink_item/src/ink_item.gd")
const ShapeNode := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Step := preload("res://root/src/physics_step.gd")

class PlayerProbe:
	extends RefCounted
	var damage := 0.0
	func apply_corrosion_damage(amount: float) -> void:
		damage += amount

var failures := 0
var checks := 0


func _initialize() -> void:
	_test_bake()
	_test_circle_routing()
	_test_circle_sweep()
	_test_contact_attachment()
	_test_gradual_irregular_erosion()
	_test_red_is_not_explosive()
	_test_player_damage_does_not_stack()
	_test_perf()
	print("WHITE_INK_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)


func _test_bake() -> void:
	var node = Item.new()
	var shape = ShapeNode.new()
	shape.rect_size = Vector2i(8, 8)
	shape.material_id = Palette.WHITE.id
	node.add_child(shape)
	var body = node.bake()
	_check("moving white bakes with real collision", body.tags.has("white_ink")
		and body.tags.has("no_impact_damage") and body.collision_layer == 1
		and body.collision_mask == 0xFFFFFFFF and not body.is_static)
	node.is_static = true
	var fixed = node.bake()
	_check("static white is scenery, not corrosion", fixed.is_static
		and not fixed.tags.has("white_ink"))
	node.free()


func _test_circle_routing() -> void:
	var ring = Shape.new()
	var square = Shape.new()
	var center := Vector2(10.5, 10.5)
	for y in 21:
		for x in 21:
			var distance := Vector2(x + 0.5, y + 0.5).distance_to(center)
			if distance >= 7.0 and distance <= 10.0:
				ring.set_pixel(x, y, Palette.WHITE.id)
			if x < 3 or x >= 18 or y < 3 or y >= 18:
				square.set_pixel(x, y, Palette.WHITE.id)
	_check("white circle routes to the retained sweep", Item._looks_like_white_circle([ring]))
	_check("white square remains sticky corrosion", not Item._looks_like_white_circle([square]))


func _test_circle_sweep() -> void:
	var world = _world()
	var rule = Sweep.new()
	var white = _add(world, Vector2.ZERO, Vector2i(16, 16), Palette.WHITE.id)
	white.tags.white_sweep = true
	white.collision_layer = 0
	white.collision_mask = 0
	var target = _add(world, Vector2(20, -8), Vector2i(48, 32), Palette.BLACK.id, true)
	var context := _context(world)
	rule.prepare_fixed(context, 1.0 / 60.0)
	white.position += Vector2(32, 0)
	white.linear_velocity = Vector2(1920, 0)
	var result: Dictionary = rule.resolve_fixed(context)
	_check("circle sweep violently erases its whole path", _count(result) > 100
		and result.carves.has(target))
	_cleanup(world, rule)


func _test_contact_attachment() -> void:
	var world = _world()
	var rule = White.new()
	var white = _add(world, Vector2.ZERO, Vector2i(8, 8), Palette.WHITE.id)
	var target = _add(world, Vector2(8, 0), Vector2i(48, 16), Palette.BLACK.id, true)
	var context := _context(world)
	rule.resolve_contacts(context, [_contact(white, target, Vector2(8, 4), Vector2.RIGHT)])
	_check("first contact creates one attachment", rule._attached.has(white)
		and world.joints.size() == 1)
	_check("attached white becomes a non-colliding region", white.collision_layer == 0
		and white.collision_mask == 0 and white.gravity_scale == 0.0)
	_check("weld disables the joined contact pair", not world.joints[0].contacts_enabled)
	_cleanup(world, rule)


func _test_gradual_irregular_erosion() -> void:
	var world = _world()
	var rule = White.new()
	rule.corrosion_pixels_per_second = 120.0
	rule.corrosion_interval = 0.1
	rule.corrosion_pixels_per_batch = 12
	rule.corrosion_seed_spacing = 4.0
	rule.corrosion_yield = 3.0
	var white = _add(world, Vector2.ZERO, Vector2i(12, 12), Palette.WHITE.id)
	var target = _add(world, Vector2(12, -24), Vector2i(96, 64), Palette.BLACK.id, true)
	var context := _context(world)
	rule.resolve_contacts(context, [_contact(white, target, Vector2(12, 6), Vector2.RIGHT)])
	_check("wide white creates several corrosion seeds",
		rule._attached[white].seeds.size() >= 2)
	var white_before := White._area(white)
	rule.prepare_fixed(context, 0.1)
	var result: Dictionary = rule.resolve_fixed(context)
	var removal := _count(result)
	var first_y := 1 << 30
	var last_y := -(1 << 30)
	for mask in result.carves.get(target, {}).values():
		for cell: Vector2i in mask:
			first_y = mini(first_y, cell.y)
			last_y = maxi(last_y, cell.y)
	_check("one corrosion tick is locally capped", removal > 0 and removal <= 12)
	_check("wide contact erodes separated irregular patches", last_y - first_y >= 4)
	_check("white fuel shrinks without collider rebuild", White._area(white) < white_before)
	var step = Step.new()
	var target_before := White._area(target)
	var committed: Dictionary = step.carve(world, result.carves)
	_check("one target is committed once", committed.calls == 1
		and target_before - White._area(target) == removal)
	step.free()
	_cleanup(world, rule)


func _test_red_is_not_explosive() -> void:
	var world = _world()
	var rule = White.new()
	rule.corrosion_pixels_per_second = 120.0
	rule.corrosion_interval = 0.1
	var white = _add(world, Vector2.ZERO, Vector2i(8, 8), Palette.WHITE.id)
	var red = _add(world, Vector2(8, -8), Vector2i(48, 24), Palette.RED.id, true)
	var context := _context(world)
	rule.resolve_contacts(context, [_contact(white, red, Vector2(8, 4), Vector2.RIGHT)])
	rule.prepare_fixed(context, 0.1)
	var result: Dictionary = rule.resolve_fixed(context)
	var reaction = Red.new()
	reaction.observe_removals(context, red, result.carves.get(red, {}))
	_check("red corrosion bypasses the explosion observer", _count(result) > 0
		and reaction._pending.is_empty())
	reaction.free()
	_cleanup(world, rule)


func _test_player_damage_does_not_stack() -> void:
	var world = _world()
	var rule = White.new()
	rule.player_damage_per_second = 30.0
	var player = _add(world, Vector2(8, -8), Vector2i(32, 24), Palette.BLACK.id)
	player.tags.living = true
	var probe = PlayerProbe.new()
	var context := _context(world)
	context.player_body = player
	context.player_node = probe
	for offset in [0.0, 12.0]:
		var white = _add(world, Vector2(0, offset), Vector2i(8, 8), Palette.WHITE.id)
		rule.resolve_contacts(context,
			[_contact(white, player, Vector2(8, offset + 4.0), Vector2.RIGHT)])
	rule.prepare_fixed(context, 0.1)
	rule.resolve_fixed(context)
	_check("several attached whites deal one flat DPS tick", is_equal_approx(probe.damage, 3.0))
	_cleanup(world, rule)


func _test_perf() -> void:
	var world = _world()
	var rule = White.new()
	rule.corrosion_pixels_per_second = 240.0
	rule.corrosion_interval = 1.0 / 60.0
	rule.corrosion_pixels_per_batch = 16
	var white = _add(world, Vector2.ZERO, Vector2i(64, 64), Palette.WHITE.id)
	var target = _add(world, Vector2(64, -80), Vector2i(800, 192), Palette.BLACK.id, true)
	var context := _context(world)
	rule.resolve_contacts(context, [_contact(white, target, Vector2(64, 32), Vector2.RIGHT)])
	var samples: Array[int] = []
	var erased := 0
	for frame in 120:
		var start := Time.get_ticks_usec()
		rule.prepare_fixed(context, 1.0 / 60.0)
		var result: Dictionary = rule.resolve_fixed(context)
		erased += _count(result)
		samples.append(Time.get_ticks_usec() - start)
	samples.sort()
	var p95: int = samples[113]
	var maximum: int = samples[-1]
	print("WHITE_ATTACHED_PERF frames=120 erased=%d p95_us=%d max_us=%d" % [erased, p95, maximum])
	_check("corrosion rule stays below 50 FPS CPU budget", erased > 0 and p95 < 20000)
	_cleanup(world, rule)


func _world():
	var world = World.new()
	world.set_material_strength(Palette.BLACK.id, 100.0)
	world.set_material_strength(Palette.GREY.id, 200.0)
	world.set_material_strength(Palette.RED.id, 25.0)
	return world


func _context(world) -> Dictionary:
	return {"world": world, "player_body": null, "player_node": null,
		"protected_bodies": [], "services": {&"damage": Damage.new()}}


func _add(world, at: Vector2, size: Vector2i, material: int, fixed := false):
	var shape = Shape.new()
	shape.fill_rect(Rect2i(Vector2i.ZERO, size), material)
	var body = Body.new()
	body.position = at
	body.is_static = fixed
	if material == Palette.WHITE.id:
		body.tags.white_ink = true
		body.tags.no_impact_damage = true
		body.collision_layer = 1
		body.collision_mask = 0xFFFFFFFF
	return world.add_body(body, [shape])


func _contact(a, b, point: Vector2, normal: Vector2):
	var contact = World.Contact.new()
	contact.a = a
	contact.b = b
	contact.point = point
	contact.normal = normal
	contact.approach = 100.0
	contact.points = [{"position": point, "normal": normal, "impulse": 100.0, "dist": 0.0}]
	return contact


func _count(result: Dictionary) -> int:
	var count := 0
	for field in ["removals", "carves"]:
		for shapes in result.get(field, {}).values():
			for mask in shapes.values():
				count += mask.size()
	return count


func _cleanup(world, rule) -> void:
	for service in []:
		service.free()
	rule.free()
	for body in world.bodies.duplicate():
		world.remove_body(body)
		for shape in body.shapes:
			shape.owner_body = null
		body.shapes.clear()
	world._rp = null


func _check(title: String, passed: bool) -> void:
	checks += 1
	print("PASS " if passed else "FAIL ", title)
	if not passed:
		failures += 1
