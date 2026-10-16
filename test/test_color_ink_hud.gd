extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
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
	var segments: Array[Rect2] = bar.segment_rects()
	_check("full ink starts at left edge and fills entire bar",
		is_zero_approx(segments[0].position.x) and is_equal_approx(segments[3].end.x, bar.size.x))
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
	segments = bar.segment_rects()
	_check("remaining ink packs right with all empty space on left",
		is_equal_approx(segments[0].position.x, bar.size.x * 0.625)
		and is_equal_approx(segments[0].end.x, segments[1].position.x)
		and is_equal_approx(segments[1].end.x, segments[2].position.x)
		and is_equal_approx(segments[2].end.x, bar.size.x))
	_check("segment widths still reflect independent balances",
		is_equal_approx(segments[0].size.x, bar.size.x * 0.125)
		and is_equal_approx(segments[1].size.x, bar.size.x * 0.0625)
		and is_equal_approx(segments[2].size.x, bar.size.x * 0.1875)
		and is_zero_approx(segments[3].size.x))
	_check("colored bar contains no remaining-amount labels", bar.find_children("*", "Label", true, false).is_empty())
	health.reduce(Palette.RED.id, 5000)
	segments = bar.segment_rects()
	_check("empty middle color leaves no gap",
		is_zero_approx(segments[1].size.x) and is_equal_approx(segments[0].end.x, segments[2].position.x))
	bar.size.x *= 2.0
	segments = bar.segment_rects()
	_check("resizing keeps colors right aligned", is_equal_approx(segments[2].end.x, bar.size.x))
	health.reduce(Palette.GREY.id, 10000)
	health.reduce(Palette.YELLOW.id, 15000)
	segments = bar.segment_rects()
	_check("empty bar has no visible color segments", segments.all(func(rect): return is_zero_approx(rect.size.x)))
	_check("colored bar hides with the rest of the health UI",
		bar.is_in_group("health_ui"))
	hud.queue_free()
	health.queue_free()
	await process_frame
	quit(1 if failures else 0)
