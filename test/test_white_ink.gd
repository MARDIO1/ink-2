extends SceneTree
const World := preload("res://addons/pixel_destruction/physics/pworld.gd")
const Body := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const White := preload("res://ink/src/white_ink.gd")
const Palette := preload("res://ink/src/ink_palette.gd")
const Item := preload("res://actor/ink_item/src/ink_item.gd")
const ShapeNode := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Step := preload("res://root/src/physics_step.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_test_bake()
	_test_sweep(Vector2(48, 0), 0.0)
	_test_sweep(Vector2(48, 37), 0.43)
	_test_motion()
	_test_holes()
	_test_wide_gap()
	_test_split_mass_cache()
	_test_perf()
	_test_perf(Vector2i(7, 40))
	_test_continuous()
	_test_native_equivalence()
	print("WHITE_INK_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)

func _test_bake() -> void:
	var ids: Dictionary = {}
	for material in Palette.all_materials():
		ids[material.id] = true
	_check("material ids are unique", ids.size() == Palette.all_materials().size())
	var node = Item.new()
	var shape = ShapeNode.new()
	shape.rect_size = Vector2i(3, 4)
	shape.material_id = Palette.WHITE.id
	node.add_child(shape)
	var body = node.bake()
	_check("saved white bakes as ghost", body.tags.has("white_ink") and body.collision_layer == 0 and body.collision_mask == 0 and not body.is_static)
	node.is_static = true
	var fixed_body = node.bake()
	_check("fixed white scenery does not erase the map", fixed_body.is_static
		and not fixed_body.tags.has("white_ink")
		and fixed_body.collision_layer == 0 and fixed_body.collision_mask == 0)
	node.free()
	var world = World.new()
	var tagged_static = _add(world, Rect2i(0, 0, 3, 4), Palette.WHITE.id)
	tagged_static.make_static()
	var rule = White.new()
	rule.prepare_fixed(_context(world), 1.0 / 60.0)
	_check("static body with legacy white tag is ignored", rule._whites.is_empty())
	_cleanup(world, rule)

func _context(world) -> Dictionary:
	return {"world": world, "player_body": null, "protected_bodies": [], "services": {}}

func _add(world, rect: Rect2i, material: int, at := Vector2.ZERO):
	var shape = Shape.new()
	shape.fill_rect(rect, material)
	var body = Body.new()
	body.position = at
	if material == Palette.WHITE.id:
		body.tags.white_ink = true
		body.tags.linear_damping = 0.0
		body.tags.angular_damping = 0.0
		body.collision_layer = 0
		body.collision_mask = 0
	return world.add_body(body, [shape])

func _test_sweep(motion: Vector2, angle: float) -> void:
	var world = World.new()
	var rule = White.new()
	rule.base_yield = 100.0
	rule.max_yield = 100.0
	var white = _add(world, Rect2i(0, 0, 8, 11), Palette.WHITE.id)
	var target = _add(world, Rect2i(-10, -10, 100, 70), Palette.BLACK.id)
	target.rotation = angle
	target.update_aabb()
	var ctx := _context(world)
	rule.prepare_fixed(ctx, 1.0 / 60.0)
	white.position += motion
	white.linear_velocity = motion * 60.0
	white.update_aabb()
	var original: int = white.shapes[0].pixel_count()
	var mass: float = white.mass
	var revision: int = white.rects_rev
	var result: Dictionary = rule.resolve_fixed(ctx)
	var mask: Dictionary = result.removals.get(target, {}).get(target.shapes[0], {})
	var expected := 0
	var clean := true
	# 独立判据：目标格心与扫掠矩形的线段/盒相交，检查所有目标格。
	for y in range(-10, 60):
		for x in range(-10, 90):
			var p: Vector2 = target.to_world(Vector2(x + 0.5, y + 0.5))
			var hit := _segment_box(p, p - motion, Rect2(0, 0, 8, 11))
			if hit:
				expected += 1
			clean = clean and (not hit or mask.has(Vector2i(x, y)))
	_check("coarse sweep covers every exact path pixel angle=%.2f" % angle, clean and expected > 0)
	_check("no white rebuild/split", is_equal_approx(white.mass, mass) and white.rects_rev == revision and world.bodies.size() == 2)
	_check("area consumed, speed unchanged", White._area(white) < original and white.linear_velocity.is_equal_approx(motion * 60.0))
	_cleanup(world, rule)

static func _segment_box(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	var lo := 0.0
	var hi := 1.0
	for axis in 2:
		var d: float = b[axis] - a[axis]
		if d == 0.0:
			if a[axis] < rect.position[axis] or a[axis] >= rect.end[axis]:
				return false
		else:
			var p: float = (rect.position[axis] - a[axis]) / d
			var q: float = (rect.end[axis] - a[axis]) / d
			lo = maxf(lo, minf(p, q))
			hi = minf(hi, maxf(p, q))
	return lo <= hi

func _test_motion() -> void:
	var world = World.new()
	world.gravity = Vector2(0, 600)
	var rule = White.new()
	rule.base_yield = 100.0
	rule.max_yield = 100.0
	var white = _add(world, Rect2i(0, 0, 4, 8), Palette.WHITE.id)
	white.linear_velocity = Vector2(100, 0)
	var obstacle = _add(world, Rect2i(0, 0, 20, 20), Palette.GREY.id, Vector2(4, 0))
	obstacle.make_static()
	var ctx := _context(world)
	rule.prepare_fixed(ctx, 1.0 / 60.0)
	world.step(1.0 / 60.0)
	rule.resolve_fixed(ctx)
	_check("gravity and no collision impulse", is_equal_approx(white.linear_velocity.x, 100.0) and white.linear_velocity.y > 0.0)
	var velocity: Vector2 = white.linear_velocity
	white.apply_impulse(Vector2(100000, 0), white.com_world())
	rule.prepare_fixed(ctx, 1.0 / 60.0)
	_check("external impulse ignored next step", white.linear_velocity.is_equal_approx(velocity))
	_cleanup(world, rule)

func _test_holes() -> void:
	var world = World.new()
	var rule = White.new()
	rule.base_yield = 100.0
	rule.max_yield = 100.0
	var white = _add(world, Rect2i(0, 0, 8, 8), Palette.WHITE.id)
	for y in 8:
		white.shapes[0].clear_pixel(3, y)
		white.shapes[0].clear_pixel(4, y)
	var target = _add(world, Rect2i(0, 0, 8, 8), Palette.BLACK.id)
	var ctx := _context(world)
	rule.prepare_fixed(ctx, 1.0 / 60.0)
	var result: Dictionary = rule.resolve_fixed(ctx)
	var mask: Dictionary = result.removals.get(target, {}).get(target.shapes[0], {})
	_check("coarse brush may fill sub-grid channel", mask.size() == 64)
	_check("fractional cost accumulates", White._area(white) == 48 and white.tags.white_cost > 0.0)
	_cleanup(world, rule)

func _test_wide_gap() -> void:
	var world = World.new()
	var rule = White.new()
	rule.base_yield = 1000.0
	rule.max_yield = 1000.0
	var white = _add(world, Rect2i(0, 0, 64, 16), Palette.WHITE.id)
	for y in 16:
		for x in range(16, 48):
			white.shapes[0].clear_pixel(x, y)
	var target = _add(world, Rect2i(0, 0, 64, 16), Palette.BLACK.id)
	target.shapes[0].set_pixel(0, 0, 7)
	var ctx := _context(world)
	rule.prepare_fixed(ctx, 1.0 / 60.0)
	var result: Dictionary = rule.resolve_fixed(ctx)
	var mask: Dictionary = result.removals.get(target, {}).get(target.shapes[0], {})
	_check("coarse brush keeps large empty channel", not mask.has(Vector2i(32, 8)) and mask.has(Vector2i(8, 8)) and mask.has(Vector2i(56, 8)))
	_check("coarse block does not remove nail material", not mask.has(Vector2i.ZERO))
	_cleanup(world, rule)

func _test_split_mass_cache() -> void:
	var world = World.new()
	world.set_material_density(Palette.BLACK.id, 3.0)
	var body = _add(world, Rect2i(-24, -16, 96, 64), Palette.BLACK.id)
	var mask := {}
	for y in range(-16, 48):
		mask[Vector2i(8, y)] = true
	var result: Dictionary = world.fracture_pixels(body, {body.shapes[0]: mask})
	var correct: bool = result.fragments.size() == 1
	for piece in world.bodies:
		var fresh = preload("res://addons/pixel_destruction/core/mass_props.gd").compute(piece.shapes[0], world.density_callable())
		correct = correct and is_equal_approx(piece.mass, fresh.mass) and piece.local_com.is_equal_approx(fresh.com) and is_equal_approx(piece.inertia, fresh.inertia)
	_check("adopted chunk cache matches fresh fragment mass, COM and inertia", correct)
	_cleanup(world, White.new())

func _test_perf(size := Vector2i(64, 64)) -> void:
	var world = World.new()
	world.profile_enabled = true
	var rule = White.new()
	var white = _add(world, Rect2i(Vector2i.ZERO, size), Palette.WHITE.id)
	_add(world, Rect2i(0, 0, 800, 200), Palette.BLACK.id)
	var ctx := _context(world)
	rule.prepare_fixed(ctx, 1.0 / 60.0)
	white.position += Vector2(16, 0)
	white.linear_velocity = Vector2(960, 0)
	white.update_aabb()
	var start := Time.get_ticks_usec()
	var result: Dictionary = rule.resolve_fixed(ctx)
	var elapsed := Time.get_ticks_usec() - start
	var removed := 0
	for plan in result.removals.values():
		for mask in plan.values():
			removed += mask.size()
	var step = Step.new()
	var commit_start := Time.get_ticks_usec()
	var committed: Dictionary = step.commit(world, result.removals)
	var commit_us := Time.get_ticks_usec() - commit_start
	print("WHITE_BENCH size=%s sweep=16 target=160000 erased=%d resolve_us=%d commit_us=%d total_us=%d" % [size, removed, elapsed, commit_us, elapsed + commit_us])
	print("WHITE_COMMIT_STAGES ", world.profile_counts)
	_check("large target full lane, conservative extra erase", removed >= (size.x + 16) * size.y and result.removals.size() == 1)
	_check("large target single commit", committed.calls == 1)
	step.free()
	_cleanup(world, rule)

func _test_continuous() -> void:
	var world = World.new()
	world.gravity = Vector2.ZERO
	var rule = White.new()
	rule.base_yield = 100.0
	rule.max_yield = 100.0
	var white = _add(world, Rect2i(0, 0, 64, 64), Palette.WHITE.id)
	white.linear_velocity = Vector2(960, 0)
	var target = _add(world, Rect2i(0, -50, 800, 200), Palette.BLACK.id)
	var step = Step.new()
	var ctx := _context(world)
	var samples: Array[int] = []
	var erased := 0
	for frame in 40:
		var start := Time.get_ticks_usec()
		rule.prepare_fixed(ctx, 1.0 / 60.0)
		world.step(1.0 / 60.0)
		var result: Dictionary = rule.resolve_fixed(ctx)
		for plan in result.removals.values():
			for mask in plan.values():
				erased += mask.size()
		step.commit(world, result.removals)
		samples.append(Time.get_ticks_usec() - start)
	var clean := true
	for y in 64:
		for x in range(16, 640):
			clean = clean and target.shapes[0].get_pixel(x, y) == 0
	samples.sort()
	print("WHITE_CONTINUOUS frames=40 erased=%d median_us=%d p95_us=%d max_us=%d" % [erased, samples[20], samples[37], samples[39]])
	_check("continuous sweep leaves no pixels", clean and erased > 40000)
	_check("continuous white preserves speed and one target", is_equal_approx(white.linear_velocity.x, 960.0) and world.bodies.size() == 2)
	step.free()
	_cleanup(world, rule)

func _test_native_equivalence() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261013
	var raster = Destruction._ensure_raster()
	var same := true
	var split_same := true
	for trial in 32:
		var shape = Shape.new()
		shape.fill_rect(Rect2i(-24, -16, 96, 64), Palette.BLACK.id)
		for cut in 100:
			shape.clear_pixel(rng.randi_range(-24, 71), rng.randi_range(-16, 47))
		var box := Rect2i(rng.randi_range(-30, 50), rng.randi_range(-20, 30), 15, 19)
		var native: int = Destruction.local_connectivity(shape, box, 8)
		Destruction._raster = null
		var cpu: int = Destruction.local_connectivity(shape, box, 8)
		Destruction._raster = raster
		same = same and native == cpu
		# 切穿形状：核对原生组装与旧 CPU 路径的块掩码和材质。
		for y in range(-16, 48):
			shape.clear_pixel(8, y)
		var keys: Array = shape.chunks.keys()
		var reference: Array = Destruction._assemble(shape, keys, Destruction._components_cpu(shape, keys), 8)
		var accelerated: Array = Destruction.split(shape, 8, true)
		split_same = split_same and accelerated.size() == reference.size()
		for index in mini(accelerated.size(), reference.size()):
			var a = accelerated[index]
			var b = reference[index]
			split_same = split_same and a.chunks.keys() == b.chunks.keys()
			for key in a.chunks:
				split_same = split_same and a.chunks[key].occ == b.chunks[key].occ and a.chunks[key].mat == b.chunks[key].mat
	_check("32 native local probes match CPU including negative coordinates", same)
	_check("32 native splits preserve CPU ordering, masks and materials", split_same and Destruction.native_calls > 0)

func _cleanup(world, rule) -> void:
	rule._previous.clear()
	rule._whites.clear()
	rule.free()
	for body in world.bodies.duplicate():
		for shape in body.shapes:
			shape.owner_body = null
		world.remove_body(body)
		body.shapes.clear()
	world._rp = null

func _check(title: String, passed: bool) -> void:
	checks += 1
	print("PASS " if passed else "FAIL ", title)
	if not passed:
		failures += 1
