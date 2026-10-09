extends SceneTree

const PWorld = preload("res://addons/pixel_destruction/physics/pworld.gd")
const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape = preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Query = preload("res://addons/pixel_destruction/physics/query.gd")
const RedInk = preload("res://Ink/src/red_ink.gd")
const Damage = preload("res://map/src/impact_damage.gd")
const Step = preload("res://map/src/physics_step.gd")
const Palette = preload("res://Ink/src/ink_palette.gd")

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	_test_cannon()
	_test_grenade()
	_test_air_chain()
	_test_air_chain(4)
	_test_symmetric_shell()
	_test_event_group()
	_test_second_pass()
	_test_chunk_consumption()
	_test_negative_group()
	_test_damage_impulse_tuning()
	print("[RedInk] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _setup() -> Dictionary:
	var world = PWorld.new()
	world.set_material_strength(4, 200.0)
	world.set_material_strength(8, Palette.RED.compress_strength, Palette.RED.resolved_shear())
	world.set_material_strength(1, 100.0)
	world.min_fragment_pixels = 1
	var red = RedInk.new()
	var damage = Damage.new()
	var runtime = Step.new()
	runtime._ink_rules = [red]
	Query.attach(world)
	return {"world": world, "red": red, "damage": damage, "runtime": runtime}


static func cannon_shape():
	var shape = Shape.new()
	shape.fill_rect(Rect2i(0, 0, 50, 7), 4)
	shape.fill_rect(Rect2i(0, 13, 50, 7), 4)
	shape.fill_rect(Rect2i(0, 7, 2, 6), 4)
	shape.fill_rect(Rect2i(2, 7, 1, 6), 8)
	return shape


static func grenade_shape():
	var shape = Shape.new()
	shape.fill_rect(Rect2i(0, 0, 18, 18), 4)
	shape.fill_rect(Rect2i(1, 1, 16, 16), 8)
	return shape


static func add_body(world, position: Vector2, shape):
	var body = PBody.new()
	body.position = position
	world.add_body(body, [shape])
	return body


static func contact(a, b, point: Vector2, impulse: float, approach: float) -> Dictionary:
	return {"a": a, "b": b, "approach": approach,
		"points": [{"position": point, "normal": Vector2.RIGHT,
		"impulse": impulse, "dist": 0.0}]}


func _tick(ctx: Dictionary) -> Dictionary:
	var result: Dictionary = ctx.red.resolve(ctx.world, ctx.damage, null, [])
	ctx.runtime._reaction_scale = result.reaction_scale
	ctx.runtime._defer_dust = true
	ctx.runtime.commit(ctx.world, result.removals)
	ctx.runtime.apply_blast_impulses(result.impulses)
	ctx.runtime.flush_blast_dust()
	ctx.runtime._defer_dust = false
	return result


func _test_cannon() -> void:
	var ctx: Dictionary = _setup()
	var cannon = add_body(ctx.world, Vector2.ZERO, cannon_shape())
	var shot_shape = Shape.new()
	shot_shape.fill_rect(Rect2i(0, 0, 6, 6), 4)
	var shot = add_body(ctx.world, Vector2(20, 7), shot_shape)
	var hammer_shape = Shape.new()
	hammer_shape.fill_rect(Rect2i(0, 0, 8, 6), 1)
	var hammer = add_body(ctx.world, Vector2(-8, 7), hammer_shape)
	var gentle: Dictionary = ctx.damage.calculate(ctx.world,
		[contact(hammer, cannon, Vector2(0, 10), 200000.0, 20.0)])
	_check("gentle contact does not ignite enclosed charge", gentle.removals.is_empty())
	var impact: Dictionary = ctx.damage.calculate(ctx.world,
		[contact(hammer, cannon, Vector2(0, 10), 400000.0, 800.0)])
	var red_removed: int = _red_count(impact.removals)
	_check("existing collision cracks reach enclosed red", red_removed > 0)
	ctx.runtime.commit(ctx.world, impact.removals)
	_check("ignition waits until next tick", shot.linear_velocity.is_zero_approx())
	# 撞击物已经弹开，不让它遮住炮尾。
	ctx.world.remove_body(hammer)
	var blast: Dictionary = {}
	for tick in 12:
		blast = _tick(ctx)
	print("CANNON ", {"red_removed": red_removed, "shot_v": shot.linear_velocity,
		"cannon_v": cannon.linear_velocity, "hits": blast.impulses.size(),
		"bodies": ctx.world.bodies.size()})
	_check("shell launches toward muzzle", shot.linear_velocity.x > 50.0)
	_check("same-body barrel receives emergent recoil", cannon.linear_velocity.x < -1.0)
	_check("blast produces finite angular velocity", is_finite(cannon.angular_velocity))
	_release(ctx, [hammer])


func _test_grenade() -> void:
	var ctx: Dictionary = _setup()
	var grenade = add_body(ctx.world, Vector2.ZERO, grenade_shape())
	var hammer_shape = Shape.new()
	hammer_shape.fill_rect(Rect2i(0, 0, 8, 4), 1)
	var hammer = add_body(ctx.world, Vector2(-8, 10), hammer_shape)
	var impact: Dictionary = ctx.damage.calculate(ctx.world,
		[contact(hammer, grenade, Vector2(0, 12), 1000000.0, 800.0)])
	_check("thin-wall collision cracks ignite interior red", _red_count(impact.removals) > 0)
	ctx.runtime.commit(ctx.world, impact.removals)
	ctx.world.remove_body(hammer)
	var reacted: int = 0
	var peak_bodies: int = 0
	var outward: int = 0
	for tick in 16:
		var result: Dictionary = _tick(ctx)
		reacted += result.impulses.size()
		peak_bodies = maxi(peak_bodies, ctx.world.bodies.size())
		var flying: int = 0
		for body in ctx.world.bodies:
			var radial: Vector2 = body.com_world() - Vector2(9, 9)
			if radial.dot(body.linear_velocity) > 1.0:
				flying += 1
		outward = maxi(outward, flying)
	print("GRENADE ", {"bodies": ctx.world.bodies.size(), "peak_bodies": peak_bodies, "outward": outward, "hits": reacted})
	_check("thin casing separates into fragments", peak_bodies > 1)
	_check("surviving fragments receive outward momentum after fracture", outward >= 2)
	_check("reaction consumes red without stale shape references", ctx.red._pending.is_empty())
	_release(ctx, [hammer])


func _test_air_chain(seed_size: int = 8) -> void:
	var ctx: Dictionary = _setup()
	var seed_shape = Shape.new()
	seed_shape.fill_rect(Rect2i(0, 0, seed_size, seed_size), 8)
	var seed = add_body(ctx.world, Vector2.ZERO, seed_shape)
	var target_shape = Shape.new()
	target_shape.fill_rect(Rect2i(0, 0, 4, 4), 8)
	var target = add_body(ctx.world, Vector2(12, 2), target_shape)
	# 第一轮可能删掉全部射线命中点；后方不可破坏靶验证第二轮真实受力。
	ctx.world.set_material_strength(4, 0.0)
	var rear_shape = Shape.new()
	rear_shape.fill_rect(Rect2i(0, 0, 4, 4), 4)
	var rear = add_body(ctx.world, Vector2(20, 2), rear_shape)
	var cells: Dictionary = {}
	for y in seed_size:
		for x in seed_size:
			cells[Vector2i(x, y)] = true
	ctx.runtime.commit(ctx.world, {seed: {seed_shape: cells}})
	var result: Dictionary = _tick(ctx)
	_check("destroyed source still emits next-tick blast across air", not result.impulses.is_empty())
	_check("%dx%d charge ignites separate red cluster" % [seed_size, seed_size], not ctx.red._pending.is_empty())
	_check("second pass reaches rear target even when seed is gone", rear.linear_velocity.x > 0.0)
	_release(ctx, [seed, target])


func _test_symmetric_shell() -> void:
	var ctx: Dictionary = _setup()
	ctx.world.set_material_strength(4, 0.0)
	var shell_shape = Shape.new()
	shell_shape.fill_rect(Rect2i(-10, -10, 21, 21), 4)
	for y in range(-9, 10):
		for x in range(-9, 10):
			shell_shape.clear_pixel(x, y)
	var shell = add_body(ctx.world, Vector2.ZERO, shell_shape)
	var seed_shape = Shape.new()
	seed_shape.fill_rect(Rect2i(-1, -1, 2, 2), 8)
	var seed = add_body(ctx.world, Vector2.ZERO, seed_shape)
	var mask: Dictionary = {}
	for y in range(-1, 1):
		for x in range(-1, 1):
			mask[Vector2i(x, y)] = true
	ctx.runtime.commit(ctx.world, {seed: {seed_shape: mask}})
	_tick(ctx)
	_check("sealed symmetric casing cancels linear impulses", shell.linear_velocity.length() < 0.001)
	_check("sealed symmetric casing cancels angular impulses", absf(shell.angular_velocity) < 0.001)
	_release(ctx, [seed])


func _test_event_group() -> void:
	var ctx: Dictionary = _setup()
	var shape = Shape.new()
	shape.fill_rect(Rect2i(0, 0, 16, 16), 8)
	var body = add_body(ctx.world, Vector2.ZERO, shape)
	var mask: Dictionary = {}
	for y in 16:
		for x in 16:
			mask[Vector2i(x, y)] = true
	ctx.red.event_chunk_size = 16
	ctx.red.observe_removals(body, {shape: mask})
	_check("16px events merge storage chunks without losing charge",
		ctx.red._pending.size() == 1 and ctx.red._pending[0].energy == 256.0)
	ctx.red._pending.clear()
	ctx.red.event_chunk_size = 8
	ctx.red.observe_removals(body, {shape: mask})
	_check("event grouping is exported independently of storage", ctx.red._pending.size() == 4)
	_release(ctx)


func _test_second_pass() -> void:
	var ctx: Dictionary = _setup()
	var front_shape = Shape.new()
	front_shape.fill_rect(Rect2i(0, 0, 1, 1), 4)
	var front = add_body(ctx.world, Vector2(4, 0), front_shape)
	var target_shape = Shape.new()
	target_shape.fill_rect(Rect2i(0, 0, 2, 2), 4)
	var target = add_body(ctx.world, Vector2(8, 0), target_shape)
	var side_shape = Shape.new()
	side_shape.fill_rect(Rect2i(0, 0, 1, 1), 4)
	var side = add_body(ctx.world, Vector2(4, 3), side_shape)
	ctx.runtime.commit(ctx.world, {front: {front_shape: {Vector2i.ZERO: true}}})
	ctx.runtime.apply_blast_impulses(
		[{"origin": Vector2(0.5, 0.5), "radius": 16.0, "ray_count": 1, "impulse": 100.0}])
	_check("second pass crosses deleted front and hits surviving rear", target.linear_velocity.x > 0.0)
	_check("second pass does not redirect momentum to nearby off-ray piece", side.linear_velocity.is_zero_approx())
	_check("second pass applies impulse only and does not create damage", target_shape.get_pixel(0, 0) == 4)
	_release(ctx, [front])


func _test_chunk_consumption() -> void:
	var ctx: Dictionary = _setup()
	var shape = Shape.new()
	shape.fill_rect(Rect2i(0, 0, 65, 2), 8)
	shape.set_pixel(2, 0, 4)
	var body = add_body(ctx.world, Vector2.ZERO, shape)
	var removals: Dictionary = {body: {shape: {Vector2i.ZERO: true}}}
	ctx.runtime.commit(ctx.world, removals)
	_check("one touched red pixel consumes every red pixel in its 64px group",
		removals[body][shape].size() == 127)
	_check("group consumption does not delete gray or the next group",
		not removals[body][shape].has(Vector2i(2, 0)) and not removals[body][shape].has(Vector2i(64, 0)))
	_check("group explosion energy counts all consumed red exactly once",
		ctx.red._pending.size() == 1 and ctx.red._pending[0].energy == 127.0)
	var red_left: int = 0
	for piece in ctx.world.bodies:
		for remaining_shape in piece.shapes:
			var bounds: Rect2i = remaining_shape.local_aabb()
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					red_left += 1 if remaining_shape.get_pixel(x, y) == 8 else 0
	_check("consumed group leaves no red fragments, untouched group survives", red_left == 2)
	ctx.red._pending.clear()
	ctx.red.observe_removals(body, {shape: {Vector2i.ZERO: true}})
	_check("consumed pixels cannot enqueue a second explosion", ctx.red._pending.is_empty())
	_release(ctx, [body])


func _test_negative_group() -> void:
	var ctx: Dictionary = _setup()
	var first = Shape.new()
	first.fill_rect(Rect2i(-2, 0, 3, 1), 8)
	var second = Shape.new()
	second.fill_rect(Rect2i(-3, 2, 1, 1), 8)
	var body = PBody.new()
	ctx.world.add_body(body, [first, second])
	var mask: Dictionary = {first: {Vector2i(-1, 0): true}}
	ctx.red.observe_removals(body, mask)
	_check("negative coordinates consume only the matching group",
		mask[first].has(Vector2i(-2, 0)) and not mask[first].has(Vector2i.ZERO))
	_check("group consumption spans all shapes of the same body",
		mask.has(second) and mask[second].has(Vector2i(-3, 2)) and ctx.red._pending[0].energy == 3.0)
	_release(ctx)


func _test_damage_impulse_tuning() -> void:
	var ctx: Dictionary = _setup()
	var seed_shape = Shape.new()
	seed_shape.fill_rect(Rect2i(0, 0, 8, 8), 8)
	var seed = add_body(ctx.world, Vector2.ZERO, seed_shape)
	var wall_shape = Shape.new()
	wall_shape.fill_rect(Rect2i(0, 0, 8, 8), 4)
	add_body(ctx.world, Vector2(12, 0), wall_shape)
	ctx.runtime.commit(ctx.world, {seed: {seed_shape: {Vector2i.ZERO: true}}})
	var events: Array = ctx.red._pending.duplicate()
	ctx.red.damage_multiplier = 1.0
	ctx.red.impulse_multiplier = 1.0
	var old: Dictionary = ctx.red.resolve(ctx.world, ctx.damage, null, [])
	ctx.red._pending = events.duplicate()
	ctx.red.damage_multiplier = 0.05
	ctx.red.impulse_multiplier = 2.0
	var tuned: Dictionary = ctx.red.resolve(ctx.world, ctx.damage, null, [])
	var old_pixels: int = 0
	var tuned_pixels: int = 0
	for shapes in old.removals.values():
		for mask in shapes.values():
			old_pixels += mask.size()
	for shapes in tuned.removals.values():
		for mask in shapes.values():
			tuned_pixels += mask.size()
	_check("explosion tuning reduces damage while increasing impulse",
		tuned_pixels < old_pixels and tuned.impulses[0].impulse == old.impulses[0].impulse * 2.0)
	ctx.red._pending = events.duplicate()
	ctx.red.impulse_multiplier = 4.0
	var stronger: Dictionary = ctx.red.resolve(ctx.world, ctx.damage, null, [])
	_check("increasing physical impulse does not increase first-pass damage", stronger.removals == tuned.removals)
	ctx.red._pending = events.duplicate()
	ctx.red.damage_multiplier = 0.0
	var push_only: Dictionary = ctx.red.resolve(ctx.world, ctx.damage, null, [])
	_check("zero explosion damage still schedules physical impulse", push_only.removals.is_empty() and push_only.impulses[0].impulse > 0.0)
	_release(ctx, [seed])


func _red_count(removals: Dictionary) -> int:
	var count: int = 0
	for shapes in removals.values():
		for shape in shapes:
			for cell: Vector2i in shapes[shape]:
				if shape.get_pixel(cell.x, cell.y) == 8:
					count += 1
	return count


func _check(label: String, condition: bool) -> void:
	checks += 1
	failures += 0 if condition else 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])


func _release(ctx: Dictionary, extra: Array = []) -> void:
	Query.detach(ctx.world)
	for body in ctx.world.bodies.duplicate():
		ctx.world.remove_body(body)
		extra.append(body)
	ctx.red._pending.clear()
	for body in extra:
		for shape in body.shapes:
			shape.owner_body = null
		body.shapes.clear()
	ctx.world._rp = null
	ctx.red.free()
	ctx.damage.free()
	ctx.runtime.free()
