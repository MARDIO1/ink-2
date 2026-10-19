extends RefCounted
## 世界输入命中测试：这个屏幕点是不是落在"该被界面吃掉"的控件上。
##
## 无状态、不挂单例：调用方各自决定"现在是不是模态/放置中"，这里只回答几何问题。
##
## 阻挡规则（明确写死，避免各模块各自猜）：
##  - 交互控件（按钮、输入框、滑条、列表、树、菜单）一定阻挡。
##  - 有可见底/内容的控件（面板、标签、贴图、滚动容器）阻挡。
##  - 纯布局容器（VBox/HBox/Grid/Margin/Center…）**不**自动阻挡：
##    它们常常铺满全屏且全透明，按面积判会吞掉所有点击。
##  - 节点可用 meta `blocks_world_input` 显式覆盖（true 强制阻挡，false 强制放行）。
##  - 祖先 `clip_contents` 裁掉的部分不算命中（滚动列表外的按钮仍在树里，但看不见）。


## `viewport` 是发起查询的视口；`point` 用屏幕（视口）坐标。
static func blocks_world_input(viewport: Viewport, point: Vector2) -> bool:
	if viewport == null or not viewport.is_inside_tree():
		return false
	for control: Control in viewport.get_tree().root.find_children("*", "Control", true, false):
		if control.get_viewport() != viewport or not control.is_visible_in_tree():
			continue
		if not _blocks(control):
			continue
		if not Rect2(Vector2.ZERO, control.size).has_point(
				control.get_global_transform_with_canvas().affine_inverse() * point):
			continue
		if not _clipped(control, point):
			return true
	return false


## 单个控件是否"愿意"阻挡；meta 优先级最高。
static func _blocks(control: Control) -> bool:
	if control.has_meta(&"blocks_world_input"):
		return bool(control.get_meta(&"blocks_world_input"))
	if control.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		return false
	if control is BaseButton or control is LineEdit or control is TextEdit \
	or control is Range or control is ItemList \
	or control is Tree or control is TabBar:
		return true
	if control is Panel or control is PanelContainer or control is Label \
	or control is TextureRect or control is ColorRect or control is ScrollContainer:
		return true
	# 剩下的默认看鼠标过滤；纯布局容器（Container 且不在上面名单里）不阻挡。
	return not (control is Container)


## 祖先 `clip_contents` 是否把这一点裁掉了。
static func _clipped(control: Control, point: Vector2) -> bool:
	var ancestor := control.get_parent()
	while ancestor != null and not ancestor is Viewport:
		if ancestor is Control and ancestor.clip_contents \
		and not Rect2(Vector2.ZERO, ancestor.size).has_point(
				ancestor.get_global_transform_with_canvas().affine_inverse() * point):
			return true
		ancestor = ancestor.get_parent()
	return false
