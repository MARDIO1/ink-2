extends SceneTree
const Health := preload("res://actor/player/src/ink_health.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(800, 540)
	root.content_scale_size = root.size
	var paper := ColorRect.new()
	paper.size = Vector2(root.size)
	paper.color = Color(0.94, 0.93, 0.89)
	root.add_child(paper)
	# 三行分别对应：满墨、部分消耗、白墨见底。黑墨只走瓶身，扣它不影响彩色横条，
	# 所以每行都要单独扣几种彩色墨，否则预览看不出彩色段的对齐方式。
	var drains := [
		[],
		[[Palette.GREY.id, 10000.0], [Palette.RED.id, 15000.0], [Palette.YELLOW.id, 5000.0], [Palette.BLUE.id, 2000.0]],
		[[Palette.WHITE.id, 20000.0], [Palette.RED.id, 4000.0]],
	]
	for index in 3:
		var health := Health.new()
		health.name = "InkHealth%d" % index
		root.add_child(health)
		var hud := (load("res://ui/hud/hud.tscn") as PackedScene).instantiate()
		# 必须走 health_path：HUD 的 _ready 会按它重新解析血量节点，
		# 直接赋 _health 会在延迟绑定之后被清回 null。
		hud.health_path = NodePath("../InkHealth%d" % index)
		root.add_child(hud)
		hud.get_node("Root/HealthUI").position = Vector2(24, 20 + index * 175)
		hud.get_node("Root/ExitButton").hide()
		hud.get_node("Root/LogButton").hide()
		for drain in drains[index]:
			health.reduce(drain[0], drain[1])
		hud._refresh_ink()
		var label := Label.new()
		label.position = Vector2(490, 55 + index * 175)
		label.text = ["满墨", "灰红黄蓝消耗", "白墨见底"][index]
		label.modulate = Color.BLACK
		root.add_child(label)
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png("res://.codex-tmp/health_hud_preview.png")
	quit(0 if error == OK else 1)
