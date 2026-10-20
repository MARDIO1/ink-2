extends VBoxContainer
## 操作帮助独立维护；只展示说明，不处理世界输入或修改按键绑定。

signal back_pressed

const SECTIONS := {
	"游玩": """移动与抓握
A / D：左右移动；空格：有支撑时跳跃。
移动鼠标控制手的位置；按住左键抓握，松开释放。
Q：切换普通抓握 / 可绕抓点转动的抓握方式。

画布与对话
靠近画布时，两侧工具栏出现；点击工具开始绘制。
F 或「放下画笔」：恢复操纵角色的手。
对话框：单击补全本句，再单击下一句；Esc 跳过整段。
右上角日志按钮：查看已读对话；Esc 关闭日志。

暂停与恢复
Esc：打开 / 关闭暂停菜单；帮助、声音页中返回上一级。
脱离卡死：返回已经经过的最近出生点或复活点。
重新开始：重读地图保存状态，清除本次游玩的绘制和机关变化；地图编辑模式不可用。
Tab：切换调试视图。""",
	"绘制": """选择工具与墨水
1 画笔　2 橡皮　3 形状　4 填充
5 清空　6 框选　7 固化　8 墨化
点击右侧色盘选颜色，拖动滑条调笔触大小。
形状按钮可选矩形、圆形、直线；左键拖动绘制。
画笔模式按住右键临时擦除，松开回到画笔。

让绘制的机关运行
画好后按 7 / E 或点击「固化」，将墨水生成实体。
按 8 或点击「墨化」，把生成的实体转回画布继续修改。
F 切回角色操纵。游玩绘制受当前颜色的墨水余量限制。

框选与修改
6：拖出选区；右键点击框选按钮可选矩形 / 圆形选区。
在选区内左键拖动：移动内容；Ctrl＋左键拖动：只移动选框。
R：选中内容每次顺时针旋转 2°。
Backspace 或选区内右键：删除选中内容。
Ctrl＋Z 撤销；Ctrl＋Y 重做，也可点击色盘下方按钮。

钉子
灰墨＋圆形：固定钉子；白墨＋圆形：背景钉子。
固定钉子使相连实体固定；背景钉子使实体不参与碰撞。""",
	"蓝图": """保存机关
用矩形或圆形框选完整机关，再使用蓝图保存入口。
把机关本体、支座、弹簧两端、导轨与滑块等一起选入，避免缺少连接部件。

查看与放置
点击右上角「蓝图」打开手册，选择要放置的蓝图。
游玩时可随时查看，靠近可用画布后才能放置。
左键：放置一次；Shift＋左键：连续放置。
右键 / Esc：取消放置；手册打开时 Esc 关闭手册。
游玩放置消耗墨水，按预览提示补足颜色余量。
含齿轮的蓝图目前仅地图编辑模式可放置。""",
	"编辑": """进入与浏览
F2：进入 / 退出地图编辑模式。
W / A / S / D：移动视野；按住 Shift 加速。
CapsLock：收起 / 展开右侧地图编辑工具栏。
F：操纵工具；左键选中并拖动物品。
右键删除怪物、文本、对话、图片、传送门或墨泉。
滚轮缩放支持的怪物、文本或图片。

地图工具
工具栏可放置出生点、复活点、画布、传送门和墨泉。
新增画布先设置尺寸；新增传送门先选择目标地图。
9：兼容固定钉子工具；0：扩展画布。
Ctrl＋方向键：向对应方向扩展编辑画布。

齿轮与无限标签
选择八齿 / 十二齿齿轮，按下定圆心，拖动定半径；使用当前墨水颜色，并自带黄色圆轴。
齿轮可框选移动，用 R 每次旋转 2°。
无限标签仅编辑模式可放置；钉在红墨上提供无尽能源。

文字与对话
「文本框」：选择后单击地图，输入场景文字。
「对话」：选择后单击地图，输入按顺序播放的台词。
用操纵工具移动文字 / 对话区域，或右键删除；文本可滚轮缩放。

保存与撤销
F5：打开地图保存窗口，确认后写入地图。
Ctrl＋Z / Ctrl＋Y：撤销 / 重做编辑。
「重新开始」在编辑模式禁用。""",
}


func _ready() -> void:
	name = "HelpPage"
	add_theme_constant_override("separation", 12)
	var title := Label.new()
	title.text = "操作说明"
	title.theme_type_variation = &"TitleLabel"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	var tabs := TabContainer.new()
	tabs.name = "Categories"
	tabs.custom_minimum_size = Vector2(360, 300)
	var paper := StyleBoxFlat.new()
	paper.bg_color = Color(0.96, 0.95, 0.84)
	paper.border_color = Color(0.04, 0.035, 0.025)
	paper.set_border_width_all(2)
	paper.content_margin_left = 8
	paper.content_margin_right = 8
	paper.content_margin_top = 8
	paper.content_margin_bottom = 8
	tabs.add_theme_stylebox_override("panel", paper)
	for state in ["tab_selected", "tab_unselected", "tab_hovered"]:
		var tab := StyleBoxFlat.new()
		tab.bg_color = Color(0.23, 0.22, 0.18) if state == "tab_selected" else Color(0.88, 0.86, 0.73)
		tab.content_margin_left = 12
		tab.content_margin_right = 12
		tab.content_margin_top = 5
		tab.content_margin_bottom = 5
		tabs.add_theme_stylebox_override(state, tab)
	tabs.add_theme_color_override("font_selected_color", Color(0.96, 0.95, 0.84))
	tabs.add_theme_color_override("font_unselected_color", Color.BLACK)
	tabs.add_theme_color_override("font_hovered_color", Color.BLACK)
	add_child(tabs)
	for category: String in SECTIONS:
		var scroll := ScrollContainer.new()
		scroll.name = category
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.focus_mode = Control.FOCUS_ALL
		tabs.add_child(scroll)
		var content := Label.new()
		content.name = "Instructions"
		content.custom_minimum_size.x = 316
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.text = SECTIONS[category]
		scroll.add_child(content)
	var back := Button.new()
	back.name = "BackButton"
	back.text = "返回  Esc"
	back.custom_minimum_size.y = 48
	back.theme_type_variation = &"MenuActionButton"
	back.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	back.pressed.connect(func(): back_pressed.emit())
	add_child(back)
