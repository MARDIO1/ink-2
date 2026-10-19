extends SceneTree
const Effect := preload("res://actor/general/effects/character_death.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1280, 900)
	root.content_scale_size = Vector2i(1280, 900)
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	var paper := ColorRect.new()
	paper.size = Vector2(1280, 900)
	paper.color = Color(0.93, 0.92, 0.88)
	root.add_child(paper)
	var stage := Node2D.new()
	root.add_child(stage)
	var level := (load("res://test/fixtures/maps/base_level.tscn") as PackedScene).instantiate()
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	root.add_child(level)
	level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
	await process_frame
	await physics_frame
	level.get_node("Camera2D").enabled = false
	var creative = level.get_node("Creative")
	creative.set_active(true)
	var actors: Array = [level.get_node("Player")]
	for kind in [1, 3, 2]:
		actors.append(creative.place_monster(kind, Vector2(700 + kind * 500, 0), false))
	await process_frame
	creative.set_active(false)
	level.process_mode = Node.PROCESS_MODE_DISABLED
	var inverted := "--inverted" in OS.get_cmdline_user_args()
	if inverted:
		var bottle: Node2D = actors[0].get_node("Visual")
		var pivot: Vector2 = bottle.global_transform * bottle.get_rect().get_center()
		var turn := Transform2D(PI, pivot) * Transform2D(0.0, -pivot)
		for path in ["Visual", "BottledInk"]:
			var part: Node2D = actors[0].get_node(path)
			part.global_transform = turn * part.global_transform
	var styles := [Effect.Style.PLAYER, Effect.Style.SOLDIER, Effect.Style.SHIELD, Effect.Style.BOMB]
	for column in 4:
		var actor: Node2D = actors[column]
		var visual: Node2D = actor.get_node("Visual")
		var records: Array[Dictionary] = []
		if column == 0:
			records = actor.get_node("FallDeath")._death_records(Effect.Style.PLAYER)
		else:
			records = actor._death_records()
		for row in 3:
			var foot := Vector2(160 + column * 320, 260 + row * 295)
			var original_foot := actor.global_position
			if column == 0:
				original_foot = Effect.foot_position(visual)
			else:
				original_foot = Effect.records_foot_position(records, original_foot)
			var effect = Effect.spawn(stage, records, styles[column], original_foot)
			effect._origin = foot
			effect.set_process(false)
			var factor: float = 160.0 / effect._height
			var resize := Transform2D(Vector2(factor, 0), Vector2(0, factor), Vector2.ZERO)
			for piece in effect.pieces:
				piece.base = resize * Transform2D(piece.base)
				piece.pivot *= factor
			effect._height *= factor
			effect._width *= factor
			effect.elapsed = effect.duration * [0.12, 0.43, 0.78][row]
			effect._update_pose(effect.elapsed)
		var label := Label.new()
		label.text = ["Player", "Soldier", "Shield", "Bomb"][column]
		label.position = Vector2(40 + column * 320, 15)
		label.modulate = Color.BLACK
		root.add_child(label)
	level.visible = false
	for layer: CanvasLayer in level.find_children("*", "CanvasLayer", true, false):
		layer.visible = false
	await process_frame
	await RenderingServer.frame_post_draw
	var path := "res://.codex-tmp/character_death_preview.png"
	if inverted:
		path = "res://.codex-tmp/character_death_inverted_preview.png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.codex-tmp"))
	var error := root.get_texture().get_image().save_png(path)
	print("[DeathPreview] ", error, " ", ProjectSettings.globalize_path(path))
	level.queue_free()
	await process_frame
	quit(0 if error == OK else 1)
