extends SceneTree
const Health := preload("res://actor/player/src/ink_health.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(800, 540)
	root.content_scale_size = root.size
	var paper := ColorRect.new()
	paper.size = Vector2(root.size)
	paper.color = Color(0.94, 0.93, 0.89)
	root.add_child(paper)
	for index in 3:
		var health := Health.new()
		root.add_child(health)
		var hud := (load("res://ui/hud/hud.tscn") as PackedScene).instantiate()
		root.add_child(hud)
		hud._health = health
		health.changed.connect(hud._refresh_ink)
		hud.get_node("Root/HealthUI").position = Vector2(24, 20 + index * 175)
		hud.get_node("Root/ExitButton").hide()
		hud.get_node("Root/LogButton").hide()
		health.damage([0.0, 5000.0, 20000.0][index])
		hud._refresh_ink()
		var label := Label.new()
		label.position = Vector2(490, 55 + index * 175)
		label.text = ["100%", "75%", "0% / death"][index]
		label.modulate = Color.BLACK
		root.add_child(label)
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png("res://.codex-tmp/health_hud_preview.png")
	quit(0 if error == OK else 1)
