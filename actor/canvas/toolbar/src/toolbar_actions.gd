extends RefCounted
## 工具栏按钮与工具的对应关系：谁高亮、提示文字写什么。
##
## 纯查表 + 写控件状态，不持有 Canvas；工具是否允许由调用方先判断。

const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")
const Tool := SurfaceScript.Tool

## 按钮名 → 该按钮代表的工具集合。`Shape` 和 `SelectDelete` 是一对多。
const BUTTON_TOOLS := {
	"Brush": [Tool.BRUSH],
	"Eraser": [Tool.ERASER],
	"Nail": [Tool.NAIL],
	"Bucket": [Tool.BUCKET],
	"Shape": [Tool.RECT, Tool.CIRCLE, Tool.LINE],
	"SelectDelete": [Tool.SELECT_DELETE, Tool.SELECT_CIRCLE],
}

const SELECTION_TOOLTIP := "%s（6）\n左键拖动选区和内容；Ctrl+左键只移动选框；框内右键删除\n" \
	+ "R 每次顺时针旋转 2°；按钮上右键切换矩形 / 圆形选区，Ctrl+Z 撤销"


## 把工具对应到按钮的按下态；`hand_button` 不在网格里，单独处理。
static func highlight(tool_grid: Node, hand_button: BaseButton, tool: int) -> void:
	if hand_button != null:
		hand_button.set_pressed_no_signal(tool == Tool.HAND)
	if tool_grid == null:
		return
	for button_name in BUTTON_TOOLS.keys():
		var button := tool_grid.get_node_or_null(NodePath(button_name)) as BaseButton
		if button != null:
			button.set_pressed_no_signal(tool in BUTTON_TOOLS[button_name])
	var select_button := tool_grid.get_node_or_null("SelectDelete") as BaseButton
	if select_button != null:
		select_button.tooltip_text = selection_tooltip(tool)


static func selection_tooltip(tool: int) -> String:
	return SELECTION_TOOLTIP % ("圆形框选" if tool == Tool.SELECT_CIRCLE else "框选")


## 「自选形状」按钮的提示，跟随当前形状切换。
static func shape_tooltip(tool: int) -> String:
	var name := "矩形"
	if tool == Tool.CIRCLE:
		name = "圆形"
	elif tool == Tool.LINE:
		name = "直线"
	return "自选形状：%s（3）\n点击按钮或按 3 选择形状" % name
