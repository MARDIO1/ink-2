extends SceneTree

const Palette := preload("res://ink/src/ink_palette.gd")
const Health := preload("res://actor/player/src/ink_health.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, okay: bool) -> void:
	print("[ColorInkHUD] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1


func _run() -> void:
	var health := Health.new()
	health.name = "InkHealth"
	root.add_child(health)
	var hud = load("res://ui/hud/hud.tscn").instantiate()
	hud.health_path = NodePath("../InkHealth")
	root.add_child(hud)
	await process_frame
	var bar = hud.color_ink_bar
	_check("all four colors begin at 20000 px independently",
		bar.remaining == PackedInt32Array([20000, 20000, 20000, 20000]))
	health.reduce(Palette.GREY.id, 10000)
	health.reduce(Palette.RED.id, 15000)
	health.reduce(Palette.YELLOW.id, 5000)
	health.reduce(Palette.WHITE.id, 20000)
	_check("bar segments follow each color's own remaining ratio",
		bar.remaining == PackedInt32Array([10000, 5000, 15000, 0])
		and is_equal_approx(bar.ratios[0], 0.5)
		and is_equal_approx(bar.ratios[1], 0.25)
		and is_equal_approx(bar.ratios[2], 0.75)
		and is_equal_approx(bar.ratios[3], 0.0))
	_check("black ink remains on bottle only",
		hud.bottle_fill.value == 100.0 and hud.ink_meter.text == "黑墨 20000 px")
	_check("every segment has a numeric label",
		bar.get_node("Ink0").text == "灰 10000"
		and bar.get_node("Ink1").text == "红 5000"
		and bar.get_node("Ink2").text == "黄 15000"
		and bar.get_node("Ink3").text == "白 0")
	_check("colored bar hides with the rest of the health UI",
		bar.is_in_group("health_ui"))
	hud.queue_free()
	health.queue_free()
	await process_frame
	quit(1 if failures else 0)
