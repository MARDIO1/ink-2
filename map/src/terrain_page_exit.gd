@tool
extends "res://actor/portal/src/map_portal.gd"
## 普通纸洞出口；最后一页通关后回到目录，不循环进入其他地图。
@export var final_page := false
@export var machine_paths: Array[NodePath] = []

func editor_destination_text() -> String:
	return "登顶完成：返回关卡目录" if final_page else super()

func _activate() -> void:
	for path in machine_paths:
		var machine := get_node_or_null(path)
		if machine == null or not machine.completed:
			_status = "先完成标记的机构，让指示灯全部亮起"
			queue_redraw()
			return
	if not final_page:
		super()
		return
	_pending = true
	_status = "登顶完成！"
	queue_redraw()
	var router := get_tree().get_first_node_in_group(&"level_router")
	if router != null:
		await router.finish_current_level()
	else:
		get_tree().change_scene_to_file("res://root/root.tscn")
