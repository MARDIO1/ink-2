extends SceneTree

const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")

var MAPS := PackedStringArray([
	"res://map/main.tscn",
	"res://map/asset/imported/1.tscn",
	"res://map/asset/imported/2.tscn",
	"res://map/asset/imported/3.（盾兵）.tscn",
	"res://map/asset/imported/4.（投掷手）.tscn",
	"res://map/asset/imported/基础.tscn",
	"res://map/asset/imported/平路（新）.tscn",
	"res://map/asset/imported/平路地图.tscn",
])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid := true
	for map_path in MAPS:
		var level := (load(map_path) as PackedScene).instantiate()
		root.add_child(level)
		await process_frame
		var creative := level.get_node_or_null("Creative")
		valid = valid and creative != null
		if creative != null:
			creative.set_active(true)
			# 用与真实鼠标相同的屏幕坐标转换，验证每张地图都能通过输入落下大盾。
			creative.select_monster_tool(MapMonsterScript.Kind.SHIELD_SIDE)
			var world_point := Vector2(120, 120)
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			click.position = root.get_viewport().get_canvas_transform() * world_point
			click.global_position = click.position
			creative._input(click)
			await process_frame
			valid = valid and creative.monster_count() == 1
			var shield := level.get_node_or_null("Monsters/ShieldSide") as Node2D
			valid = valid and shield != null and shield.global_position.distance_to(world_point) < 0.01
			for kind in [MapMonsterScript.Kind.LITTLE_SOLDIER, MapMonsterScript.Kind.BOMB_SIDE]:
				var monster: Node2D = creative.place_monster(kind, Vector2(240 + kind * 60, 160))
				valid = valid and monster != null and int(monster.kind) == kind
			valid = valid and creative.monster_count() == 3
		level.queue_free()
		await process_frame
	if not valid:
		printerr("[MonsterPlacement] imported monsters or map placement: FAIL")
		quit(1)
		return
	print("[MonsterPlacement] imported monsters and all-map placement: PASS")
	quit()
