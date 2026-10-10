extends SceneTree

const HitFeedback = preload("res://root/src/hit_feedback.gd")
const InkHealth = preload("res://actor/player/src/ink_health.gd")
const InkPalette = preload("res://Ink/src/ink_palette.gd")
const Player = preload("res://actor/player/src/player_physics.gd")

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
