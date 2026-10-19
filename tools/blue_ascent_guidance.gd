extends RefCounted
## 离线整理教学文本；与工具栏共用 MapTextTools，不增加游玩期脚本。
const TextLabel := preload("res://ui/map_text/src/map_text_label.gd")
const TextTools := preload("res://debug/creative/features/map_text_tools.gd")

const NOTES := {
	"Gate": [Vector2(90,3465), "① 蓝墨·画笔 7px\n连接门底横向蓝线的缺口，再按「固化」。\n等门升起，从门下向右通过，沿黑坡上层。"],
	"GateGap": [Vector2(328,3635), "门底：左侧短蓝线 → 右侧竖蓝线"],
	"Bridge": [Vector2(1290,2760), "② 蓝墨·形状→矩形 7px\n从红墨左侧短蓝线起笔，沿黑色横条向左拖。\n箭头朝左，再按「固化」；动力会拉断黄墨保险簧。\n等桥伸到左岸，向左过桥，再沿黑坡向上走。"],
	"Ramp": [Vector2(430,2095), "③ 先走到平桥中段；切蓝墨·画笔 7px。\n找到右侧下悬黑臂底部、红墨右边的两段蓝线。\n竖着补齐蓝线缺口，再按「固化」。\n等桥向右上方抬起，沿桥上行，从右端短跳上岸。",16],
	"Crates": [Vector2(1000,1420), "④ 黄墨·画笔 12px：连接两箱相邻的黑色安装座，固化。\n切蓝墨·形状→矩形 7–12px。\n从高箱红墨左侧短蓝线，沿黑色横条向左拖出箭头。\n再按「固化」，等高箱牵引矮箱一起向左停靠。\n从右侧跳上矮箱，再跳上高箱，最后向左上岸。"],
	"CrateSpring": [Vector2(1410,1620), "黄墨：连接两箱内侧黑座 ↓"],
	"CrateArrow": [Vector2(1000,1540), "高箱：向左蓝箭头 ↓"],
	"Lift": [Vector2(980,960), "⑤ 双黄杆与配重摆渡台\n从左侧台阶落到黄杆，沿黄杆缓坡走上右侧黑色踏台。\n蓝墨·形状→矩形 12px：从黑臂底部红墨旁的蓝点起笔，\n沿黑臂竖直向上画箭头，再按「固化」。\n双黄杆保持踏台水平，左端配重辅助向左上摆升。\n等停稳后向左落到接落台，沿黑坡向左上行。",14],
	"LaunchArrow": [Vector2(1620,1420), "右侧黑色下悬臂：向上箭头 ↑\n蓝墨·矩形 12px",14],
	"LaunchExit": [Vector2(1120,1110), "停稳后向左落台 ←",14],
	"Finale": [Vector2(840,320), "⑥ 齿轮提闸门\n站上左侧短台阶，选蓝墨·矩形 12px。\n从黑轮左下短蓝线起笔，竖直向上画箭头，固化。",14],
	"FinaleDrive": [Vector2(1200,370), "蓝墨·画笔 15px：补齐红墨右侧黄轴上的蓝线。\n小黑轮转动 → 大黄轮反转 → 齿条带门上升。\n等门到顶停稳，沿固定黑桥向右通过。",14],
	"Turn": [Vector2(320,780), "从长坡顶端向左上短跳，落到左上黑台；\n沿左上方黑坡和两块短台阶前进，\n再向右上方短跳，返回第⑥段桥前。"],
}

static func apply(level: Node2D) -> void:
	var container := level.get_node("MapTexts")
	# 编辑器只拾取 MapTexts 下的标准文本；先接回旧根节点引导。
	for child in level.get_children():
		if child is Label and child.get_script()==TextLabel:
			var local_transform:Transform2D=child.get_transform()
			child.owner=null
			level.remove_child(child)
			container.add_child(child)
			local_transform=container.transform.affine_inverse()*local_transform
			child.position=local_transform.origin
			child.rotation=local_transform.get_rotation()
			child.scale=local_transform.get_scale()
			child.owner=level
	if not container.has_node("MachineNote_FinaleDrive"):
		var drive=TextTools.create(container,NOTES.FinaleDrive[0],NOTES.FinaleDrive[1],"blue_ascent_note_finale_drive",load("res://ui/map_text/asset/Muyao-Softbrush.ttf"))
		drive.name="MachineNote_FinaleDrive"
		drive.owner=level
	var used_ids := {}
	for label in container.get_children():
		if not label is Label: continue
		if label.get_script()!=TextLabel: label.set_script(TextLabel)
		# 统一使用工具栏的48px字号与缩放，删除后撤销也能恢复相同外观。
		var old_font_size:int=label.get_theme_font_size("font_size")
		label.scale*=float(old_font_size)/48.0
		label.add_theme_font_size_override("font_size",48)
		label.z_index=20
		label.mouse_filter=Control.MOUSE_FILTER_IGNORE
		label.autowrap_mode=TextServer.AUTOWRAP_OFF
		var text_id:String=label.editor_id
		if text_id.is_empty() or used_ids.has(text_id):
			text_id="blue_ascent_"+str(used_ids.size()+1)
			while used_ids.has(text_id): text_id+="_text"
		label.editor_id=text_id
		used_ids[text_id]=true
		var key:=str(label.name).trim_prefix("MachineNote_")
		if NOTES.has(key):
			label.position=NOTES[key][0]
			label.text=NOTES[key][1]
			var display_size:float=NOTES[key][2] if NOTES[key].size()>2 else 18.0
			label.scale=Vector2.ONE*(display_size/48.0)
		elif label.text.begins_with("01"):
			label.position=Vector2(90,3415)
		elif label.text.begins_with("02"):
			label.position=Vector2(1290,2710)
		elif label.text.begins_with("03"):
			label.position=Vector2(100,2180)
		elif label.text.begins_with("04"):
			label.position=Vector2(1000,1370)
		elif label.text.begins_with("05"):
			label.text="05  黄墨配重摆渡台 ↖"
			label.position=Vector2(980,920)
		elif label.text.begins_with("06"):
			label.text="06  齿轮传动提闸门 →"
			label.position=Vector2(910,30)
		elif label.text=="蓝色攀升":
			label.position=Vector2(90,3340)
		label.reset_size()
	print("[BlueGuidance] standard editable text boxes=",used_ids.size())
