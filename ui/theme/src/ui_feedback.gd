extends Node
## 场景和动态生成的按钮共用反馈；不占用输入，也不往地图保存运行时节点。
const Feedback := preload("res://ui/theme/src/button_feedback.gd")
const Appearance := preload("res://ui/theme/src/button_appearance.gd")

func _ready() -> void:
	get_tree().node_added.connect(_observe)
	for node in get_tree().root.find_children("*", "BaseButton", true, false):
		_observe(node)

func _observe(node: Node) -> void:
	if node is BaseButton:
		_install.call_deferred(weakref(node))

func _install(reference: WeakRef) -> void:
	var button := reference.get_ref() as BaseButton
	if button == null or not button.is_inside_tree() or button.has_node("ButtonFeedback"):
		return
	# 墨水色盘已有按实际颜色绘制的圆形选择标记，不叠加矩形菜单反馈。
	if button.has_node("InkSelectionIndicator"):
		return
	var image_tool := button.has_node("IconFeedback")
	# 主菜单/关卡选择的按钮自己实现了悬停反色，抹平会把它覆盖掉。
	if button is Button and not image_tool and not button.has_meta(&"menu_action"):
		Appearance.uniform(button)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var feedback := Feedback.new()
	feedback.name = "ButtonFeedback"
	feedback.button = button
	feedback.image_tool = image_tool
	button.add_child(feedback)
