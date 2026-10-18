extends RefCounted
## 形状与框选菜单：按钮点开、右键切换、选中后交回画布。
##
## 只负责建菜单与定位；「选中的工具怎么生效」仍在 `canvas.gd`（它才持有 surface 与按钮状态）。

const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")

const SHAPES := [
	{"label": "矩形", "tool": SurfaceScript.Tool.RECT},
	{"label": "圆形", "tool": SurfaceScript.Tool.CIRCLE},
	{"label": "直线", "tool": SurfaceScript.Tool.LINE},
]
const SELECTIONS := [
	{"label": "矩形框选", "tool": SurfaceScript.Tool.SELECT_DELETE},
	{"label": "圆形框选", "tool": SurfaceScript.Tool.SELECT_CIRCLE},
]


static func build_shapes(host: Node, on_picked: Callable, on_hidden: Callable) -> PopupMenu:
	var menu := PopupMenu.new()
	menu.name = "ShapePopup"
	for entry in SHAPES:
		menu.add_item(entry.label, entry.tool)
	menu.id_pressed.connect(on_picked)
	menu.popup_hide.connect(on_hidden)
	host.add_child(menu)
	return menu


## 左键沿用矩形框选；右键选择矩形或圆形，不占用额外工具栏位置。
static func build_selection(host: Node, on_picked: Callable) -> PopupMenu:
	var menu := PopupMenu.new()
	menu.name = "SelectionPopup"
	for entry in SELECTIONS:
		menu.add_item(entry.label, entry.tool)
	menu.id_pressed.connect(on_picked)
	host.add_child(menu)
	return menu


## 在鼠标位置弹出。按钮在 Node2D 父级下 `global_rect` 不准，所以用视口坐标。
static func popup_at(menu: PopupMenu, host: Node) -> void:
	if menu == null or not menu.is_inside_tree():
		return
	menu.position = Vector2i(host.get_viewport().get_mouse_position())
	menu.reset_size()
	menu.popup()


static func shape_name(tool: int) -> String:
	match tool:
		SurfaceScript.Tool.CIRCLE:
			return "圆形"
		SurfaceScript.Tool.LINE:
			return "直线"
		_:
			return "矩形"
