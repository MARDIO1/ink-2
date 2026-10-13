extends SceneTree
## 回归：扉页的大型白墨是纯贴图，不能生成物理实体或启动擦除。

const TITLE_LEVEL := "res://map/asset/imported/扉页.tscn"
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, ok: bool) -> void:
	print("[TitleEntry] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _run() -> void:
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var entered: bool = await app.request_level_change(TITLE_LEVEL)
	var level: Node = app.level_root.get_child(0) if app.level_root.get_child_count() > 0 else null
	_check("title level transition completes", entered and not app._transition.busy and level != null)
	if level != null:
		var scenery := level.get_node_or_null("Ink51") as Sprite2D
		_check("large white scenery is visual-only", scenery != null
			and not scenery.is_in_group("ink_item") and scenery.get_child_count() == 0)
		_check("painted shape and position are preserved", scenery != null
			and scenery.texture != null
			and scenery.texture.get_size() == Vector2(552, 567)
			and scenery.position + scenery.offset == Vector2(1554, 181))
		var shader_material := scenery.material as ShaderMaterial if scenery != null else null
		_check("scenery uses white wobble and rain shader", shader_material != null
			and shader_material.shader.code.contains("rain_speed")
			and shader_material.shader.code.contains("COLOR = vec4(1.0, 1.0, 1.0"))
	for i in 30:
		await process_frame
	_check("game continues processing frames", Engine.get_process_frames() > 30)
	level = null
	app.queue_free()
	app = null
	for i in 3:
		await process_frame
	quit(1 if failures else 0)
