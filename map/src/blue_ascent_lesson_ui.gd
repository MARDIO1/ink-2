extends Node
## 仅用于蓝墨教学区：为透明工具栏铺纸色衬底，不截获绘制输入。
var _plates := {}

func _process(_delta: float) -> void:
	for canvas in get_tree().get_nodes_in_group(&"canvas_workbench"):
		if canvas.get_parent() != get_parent(): continue
		var title = canvas.get_instance_id()
		if canvas == null or canvas._side_panel == null: continue
		if not _plates.has(title):
			var left := _plate(canvas.workbench)
			var right := _plate(canvas._side_panel.get_parent())
			_plates[title] = [left, right]
		var left: ColorRect = _plates[title][0]
		var right: ColorRect = _plates[title][1]
		var bounds: Rect2 = canvas.buttons.get_rect().merge(canvas.toggle_button.get_rect()).grow(6)
		left.position = bounds.position
		left.size = bounds.size
		left.visible = canvas.buttons.visible and not canvas._map_editor_mode
		right.position = canvas._side_panel.position - Vector2(6, 6)
		right.size = canvas._side_panel.size + Vector2(12, 12)
		right.visible = canvas._side_panel.visible and not canvas._map_editor_mode
		right.modulate = canvas._side_panel.modulate

func _plate(parent: Node) -> ColorRect:
	var plate := ColorRect.new()
	plate.name = "LessonToolPaper"
	plate.color = Color("eeeadd")
	plate.color.a = 0.5
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.z_index = -1
	parent.add_child(plate)
	return plate
