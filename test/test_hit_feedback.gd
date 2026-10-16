extends SceneTree

const HitFeedback = preload("res://root/src/hit_feedback.gd")
const ContactImpact = preload("res://root/src/contact_impact.gd")
const ImpactSoundProfile = preload("res://root/src/impact_sound_profile.gd")
const InkHealth = preload("res://actor/player/src/ink_health.gd")
const InkPalette = preload("res://ink/general/src/ink_palette.gd")
const Player = preload("res://actor/player/src/player_physics.gd")
const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const PWorld = preload("res://addons/pixel_destruction/physics/pworld.gd")

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])


func _run() -> void:
	var feedback = HitFeedback.new()
	root.add_child(feedback)
	await process_frame
	_check("minimum impulse is silent", feedback.intensity_for_impulse(feedback.minimum_impulse) == 0.0)
	var light_db: float = feedback.volume_db_for_impulse(500.0)
	var medium_db: float = feedback.volume_db_for_impulse(4000.0)
	var heavy_db: float = feedback.volume_db_for_impulse(feedback.full_volume_impulse)
	_check("volume rises with impulse", light_db < medium_db and medium_db < heavy_db)
	_check("volume is capped", is_equal_approx(heavy_db, feedback.maximum_volume_db)
		and is_equal_approx(feedback.volume_db_for_impulse(feedback.full_volume_impulse * 10.0), heavy_db))
	_check("contact points use total impulse", is_equal_approx(feedback._total_impulse([
		{"impulse": 120.0}, {"impulse": 80.0}, {"impulse": -10.0}
	]), 200.0))
	_check("voices are spatial", feedback._voices[0] is AudioStreamPlayer2D)
	var a := PBody.new()
	var b := PBody.new()
	a.id = 1
	b.id = 2
	a.mass = 10.0
	b.mass = 30.0
	var event := ContactImpact.build_event({"a": a, "b": b, "approach": 400.0, "points": [
		{"position": Vector2.ZERO, "normal": Vector2.RIGHT, "dist": 0.0, "impulse": 100.0},
		{"position": Vector2(8.0, 0.0), "normal": Vector2.RIGHT, "dist": 0.0, "impulse": 300.0},
	]})
	_check("event uses reduced mass", is_equal_approx(event.reduced_mass, 7.5)
		and is_equal_approx(event.energy, 600000.0))
	_check("event keeps weighted contact point", event.position.is_equal_approx(Vector2(6.0, 0.0)))
	b.is_static = true
	var static_event := ContactImpact.build_event({"a": a, "b": b, "approach": 400.0,
		"points": [{"position": Vector2.ZERO, "normal": Vector2.RIGHT, "dist": 0.0, "impulse": 400.0}]})
	_check("static pair uses dynamic mass", is_equal_approx(static_event.reduced_mass, a.mass))
	var world := PWorld.new()
	world.ccd_ignore_mass = 100.0
	world.bodies = [a, b]
	_check("light dynamic body is debris but static body is not",
		ContactImpact.dust_bodies(world, null, []).has(a)
		and not ContactImpact.dust_bodies(world, null, []).has(b))
	var debris_event := static_event.duplicate()
	debris_event["is_debris"] = true
	debris_event["total_impulse"] = feedback.full_volume_impulse
	debris_event["energy"] = feedback.full_volume_energy
	_check("debris volume is capped", feedback.volume_db_for_event(debris_event)
		<= feedback.debris_maximum_volume_db)
	var exact := ImpactSoundProfile.new()
	exact.material_a = 2
	exact.material_b = 6
	var wildcard := ImpactSoundProfile.new()
	wildcard.material_a = 2
	feedback.sound_profiles.append(wildcard)
	feedback.sound_profiles.append(exact)
	_check("sound table prefers exact unordered pair", feedback._profile_for(6, 2) == exact)
	exact.volume_db = 12.0
	debris_event["a_material"] = 6
	debris_event["b_material"] = 2
	debris_event["intensity"] = feedback.intensity_for_event(debris_event)
	feedback._play_audio(debris_event)
	_check("profile gain cannot bypass debris cap",
		feedback._voices[0].volume_db <= feedback.debris_maximum_volume_db)
	var player = Player.new()
	var health = InkHealth.new()
	health.name = "InkHealth"
	player.add_child(health)
	health._ready()
	var black_id: int = InkPalette.material_id_of(InkPalette.BLACK)
	var grey_id: int = InkPalette.material_id_of(InkPalette.GREY)
	var black_before: float = health.ink_of(black_id)
	var grey_before: float = health.ink_of(grey_id)
	player.apply_collision_damage(25.0)
	_check("collision damage drains black ink", is_equal_approx(health.ink_of(black_id), black_before - 25.0))
	_check("collision damage leaves other inks unchanged", is_equal_approx(health.ink_of(grey_id), grey_before))
	player.free()
	feedback.queue_free()
	await process_frame
	print("[HitFeedback] %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
