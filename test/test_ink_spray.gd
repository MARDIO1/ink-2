extends SceneTree
## 黑墨喷溅验收：伤害事件 → 纯 shader 的喷溅表、阈值、去重、寿命；且不碰物理世界与墨水账。

const InkSpray = preload("res://ink/src/ink_spray.gd")
const ImpactDamage = preload("res://root/src/impact_damage.gd")
const PWorld = preload("res://addons/pixel_destruction/physics/pworld.gd")
const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape = preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const InkPalette = preload("res://ink/src/ink_palette.gd")

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])


func _body(world, position: Vector2, size: Vector2i, material: int = 1):
	var shape = Shape.new()
	shape.fill_rect(Rect2i(Vector2i.ZERO, size), material)
	var body = PBody.new()
	body.position = position
	world.add_body(body, [shape])
	return body


## 只比颜色，不比透明度：墨是半透明的，alpha 由 opacity 单独控制。
func _same_hue(a: Color, b: Color) -> bool:
	return is_equal_approx(a.r, b.r) and is_equal_approx(a.g, b.g) and is_equal_approx(a.b, b.b)


func _hit(amount: float, position: Vector2, player: bool = true, material: int = 0) -> Dictionary:
	return {"position": position, "direction": Vector2.RIGHT, "amount": amount,
		"material": material, "player": player}


func _run() -> void:
	# --- 伤害规则侧：每次落地的伤害都要留下位置、方向、量 ---
	var calc = ImpactDamage.new()
	calc.damage_scale = 0.1
	calc.min_approach = 5.0
	var world = PWorld.new()
	world.set_material_strength(1, 100.0)
	world.set_material_strength(2, 200.0)
	var a = _body(world, Vector2.ZERO, Vector2i(8, 8))
	var b = _body(world, Vector2(8, 0), Vector2i(8, 8))
	var contact = PWorld.Contact.new()
	contact.a = a
	contact.b = b
	contact.approach = 100.0
	contact.points = [
		{"position": Vector2(8, 0), "normal": Vector2.RIGHT, "impulse": 12000.0, "dist": 0.0},
		{"position": Vector2(8, 8), "normal": Vector2.RIGHT, "impulse": 12000.0, "dist": 0.0},
	]
	world.contacts = [contact]
	var result: Dictionary = calc.calculate(world, world.contacts)
	_check("damage records hit events", not result.hits.is_empty())
	var unit: bool = true
	var amounts: bool = true
	for hit in result.hits:
		unit = unit and hit.direction.is_normalized()
		amounts = amounts and hit.amount > 0.0 and hit.position.is_finite()
	_check("hit direction is a unit vector", unit)
	_check("hit carries a positive equivalent-pixel amount", amounts)
	var player_result: Dictionary = calc.calculate(world, world.contacts, a, [b])
	var player_hits: Array = []
	for hit in player_result.hits:
		if hit.player:
			player_hits.append(hit)
	_check("player damage is flagged as a player hit",
		player_result.player_damage > 0.0 and player_hits.size() == 1)
	# 喷出方向 = 受击方被推的方向：左边那体被推向左，右边那体被推向右。
	var right_result: Dictionary = calc.calculate(world, world.contacts, b, [a])
	_check("the struck body sprays in the direction it is pushed",
		player_hits[0].direction.x < -0.99 and right_result.hits[0].direction.x > 0.99)
	# ⚠️ 曾经把方向翻成「从受击表面朝外」，砸地就成了往地里溅 —— 这条钉住它。
	var ground = _body(world, Vector2(100, 100), Vector2i(16, 8))
	var falling = _body(world, Vector2(100, 92), Vector2i(16, 8))
	var slam = PWorld.Contact.new()
	slam.a = ground
	slam.b = falling
	slam.approach = 100.0
	slam.points = [{"position": Vector2(108, 100), "normal": Vector2.UP, "impulse": 12000.0, "dist": 0.0}]
	world.contacts = [slam]
	var slam_result: Dictionary = calc.calculate(world, world.contacts, falling, [ground])
	_check("landing on the ground sprays upward",
		slam_result.hits.size() == 1 and slam_result.hits[0].direction.y < -0.99)
	world.contacts = [contact]

	# --- 表现侧：整个效果只有一张四边形 + 一个片元着色器 ---
	var bodies_before: int = world.bodies.size()
	var spray = InkSpray.new()
	spray.dedup_seconds = 0.0
	root.add_child(spray)
	await process_frame
	spray.set_process(false)
	var rect: ColorRect = spray._rect
	_check("the whole effect is one shader quad",
		spray.get_child_count() == 1 and rect is ColorRect and rect.material is ShaderMaterial)
	var drawables: int = 0
	for child in spray.get_children():
		if child is GPUParticles2D or child is CPUParticles2D or child is Sprite2D:
			drawables += 1
	_check("no particles and no sprites anywhere", drawables == 0)
	_check("the quad never eats mouse input", rect.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("quad starts hidden", not rect.visible)
	_check("the shader is a procedural canvas shader",
		spray._material.shader != null and spray._material.shader.code.contains("shader_type canvas_item"))
	_check("splat table matches the shader array size",
		spray._head.size() == InkSpray.MAX_SPLATS and spray._tail.size() == InkSpray.MAX_SPLATS
		and spray._material.shader.code.contains("splat_head[8]"))

	spray.observe_damage({}, [_hit(0.5, Vector2(10, 10))])
	_check("strength is zero at the threshold", spray._strength_for(spray.min_damage) == 0.0)
	_check("strength is 1 at the reference damage",
		is_equal_approx(spray._strength_for(spray.min_damage + spray.reference_damage), 1.0))
	_check("the curve is gentler than linear",
		spray._strength_for(spray.min_damage + spray.reference_damage * 0.5) < 0.5)
	_check("strength never decreases as damage grows",
		spray._strength_for(spray.min_damage + 10.0) <= spray._strength_for(spray.min_damage + spray.reference_damage)
		and spray._strength_for(spray.min_damage + spray.reference_damage)
			<= spray._strength_for(spray.min_damage + spray.reference_damage * 100.0))
	_check("the reference damage already reaches the cap",
		is_equal_approx(spray._strength_for(spray.min_damage + spray.reference_damage), spray.max_strength))
	_check("huge damage is capped", is_equal_approx(
		spray._strength_for(spray.min_damage + spray.reference_damage * 100000.0), spray.max_strength))
	_check("damage below the threshold is silent", spray.sprayed_count == 0 and spray._splats.is_empty())
	spray.observe_damage({}, [_hit(spray.min_damage, Vector2(10, 10))])
	spray._process(0.016)
	_check("threshold damage sprays once", spray.sprayed_count == 1)
	_check("quad covers the splat", rect.visible and rect.get_rect().has_point(Vector2(10, 10)))
	_check("splat table carries strength, life and direction",
		spray._head[0].w >= 0.0 and spray._tail[0].z > 0.0
		and Vector2(spray._tail[0].x, spray._tail[0].y).is_normalized())
	_check("player hits spray black ink",
		_same_hue(Color(spray._tint[0].x, spray._tint[0].y, spray._tint[0].z),
			InkPalette.color_of(InkPalette.BLACK)))
	_check("droplet count scales with damage",
		spray._material.shader.code.contains("mix(drop_min, drop_max, strength)")
		and is_equal_approx(float(spray._material.get_shader_parameter("drop_max")), float(spray.drop_max)))
	_check("droplets are hard-edged squares",
		spray._material.shader.code.contains("float box_alpha(")
		and spray._material.shader.code.contains("step(max(d.x, d.y), 0.0)"))
	_check("ink fades with distance from the impact",
		spray._material.shader.code.contains("drop_fade"))
	_check("gradient strength reaches the shader",
		is_equal_approx(float(spray._material.get_shader_parameter("gradient")), spray.gradient))
	_check("ink is translucent instead of solid black",
		is_equal_approx(spray._tint[0].w, spray.opacity) and spray._tint[0].w < 1.0)
	var small_reach: Rect2 = spray._reach_rect({"center": Vector2.ZERO, "strength": 0.0,
		"life": spray.lifetime * 0.65})
	var big_reach: Rect2 = spray._reach_rect({"center": Vector2.ZERO, "strength": 1.0,
		"life": spray.lifetime})
	_check("spray range grows with damage", big_reach.size.x > small_reach.size.x * 1.5)
	spray.observe_damage({}, [_hit(spray.reference_damage, Vector2(300, 10))])
	spray._process(0.016)
	_check("heavier damage sprays again", spray.sprayed_count == 2)
	_check("heavier damage is stronger and lasts longer",
		spray._head[1].w > spray._head[0].w and spray._tail[1].z > spray._tail[0].z)
	spray.observe_damage({}, [_hit(spray.reference_damage, Vector2(500, 10), false, 3)])
	_check("non-ink material does not spray", spray.sprayed_count == 2)
	spray.observe_damage({}, [_hit(spray.reference_damage, Vector2(600, 10), false,
		InkPalette.material_id_of(InkPalette.GREY))])
	spray._process(0.016)
	_check("a grey body sprays its own ink", spray.sprayed_count == 3
		and _same_hue(Color(spray._tint[2].x, spray._tint[2].y, spray._tint[2].z),
			InkPalette.color_of(InkPalette.GREY)))
	spray.dedup_seconds = 0.2
	spray.observe_damage({}, [_hit(spray.reference_damage, Vector2(700, 10)),
		_hit(spray.reference_damage, Vector2(701, 11))])
	_check("the same spot is not sprayed twice in one step", spray.sprayed_count == 4)
	spray.dedup_seconds = 0.0
	for i in 5:
		spray.observe_damage({}, [_hit(spray.reference_damage, Vector2(800 + i * 40, 10))])
	_check("oldest splat is evicted when the table is full",
		spray._splats.size() == InkSpray.MAX_SPLATS and spray.sprayed_count == 9)

	# --- 端到端：规则产生的伤害事件真的会喷 ---
	# 规则侧这一下的等效伤害约 1.7 px，把阈值压到它下面，这里只验接线。
	# 墨种数量在喷之前记下来：喷溅不该往色表里加墨（调色板现在有 5 种，含白墨）。
	var ink_kinds_before: int = InkPalette.ink_count()
	spray.min_damage = 1.0
	spray._splats.clear()
	var before: int = spray.sprayed_count
	spray.observe_damage({}, result.hits)
	spray._process(0.016)
	_check("damage events from the rule reach the spray",
		spray.sprayed_count > before and not spray._splats.is_empty())
	spray._process(spray.lifetime + 0.5)
	_check("splats expire and the quad hides itself",
		spray._splats.is_empty() and not rect.visible)
	_check("spray never touches the physics world", world.bodies.size() == bodies_before)
	_check("spray emits nothing into the ink ledger", InkPalette.ink_count() == ink_kinds_before)
	spray.queue_free()
	await process_frame
	print("[InkSpray] %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)

