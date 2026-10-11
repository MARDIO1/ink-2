extends SceneTree

const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")

var MAPS := PackedStringArray([
	"res://map/asset/imported/第一关.tscn",
	"res://map/asset/imported/平路（新）.tscn",
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
			creative.auto_save_edits = false
			creative.auto_save_on_exit = false
			creative.set_active(true)
			for kind in [MapMonsterScript.Kind.LITTLE_SOLDIER, MapMonsterScript.Kind.BOMB_SIDE, MapMonsterScript.Kind.SHIELD_SOLDIER]:
				var monster: Node2D = creative.place_monster(kind, Vector2(240 + kind * 60, 160))
				valid = valid and monster != null and int(monster.kind) == kind
			valid = valid and creative.monster_count() == 3
			var shield_button := creative._monster_buttons.back() as Button
			shield_button.pressed.emit()
			valid = valid and creative._monster_mode == MapMonsterScript.Kind.SHIELD_SOLDIER and shield_button.button_pressed
		level.queue_free()
		await process_frame
	if not valid:
		printerr("[MonsterPlacement] imported monsters or map placement: FAIL")
		quit(1)
		return
	print("[MonsterPlacement] imported monsters and all-map placement: PASS")
	quit()
