@tool
extends Node2D
## 健身房：把角色控制器的可调数值摆成旋钮，**倍率 ×0.25 ~ ×5** 即时调。
##
## 跑法：打开 `res://gym/gym.tscn` 按 F6（编辑器里也能看见面板，只是滑块要在运行中拖）。
## 场景 = 实例化的 `map/main.tscn`（真地图、真角色），所以调完的手感就是真手感。
##
## 倍率模型：`_ready` 时把每个目标的**当前值**记成基准，滑块只写 `基准 × 倍率` ——
## 拉回 1.00x 就是原值，不会累积、不会污染别的场景。
## ⚠️ 质量（`shape_density_scale`）走 `drag_ended` 而不是每帧：改一次要重算质量
##    （逐像素扫描 + 贪心分解 + 重推密度，玩家 3 千多格 ≈ 2~3ms），拖拽中每帧刷会卡。

## 旋钮表。`path` 相对本节点；`prop` 是该节点上的 export 名。
@export var knobs: Array[Dictionary] = [
	{"path": "Main/Player/PlayerInput", "prop": "max_force", "label": "脚·最大力"},
	{"path": "Main/Player/PlayerInput", "prop": "max_power", "label": "脚·最大功率"},
	{"path": "Main/Player/PlayerInput", "prop": "move_speed", "label": "脚·移动速度"},
	{"path": "Main/Player/PlayerInput", "prop": "jump_impulse", "label": "脚·跳跃冲量"},
	{"path": "Main/Player/PlayerInput", "prop": "upright_stiffness", "label": "脚·回正刚度"},
	{"path": "Main/Player/PlayerInput", "prop": "upright_damping", "label": "脚·回正阻尼"},
	{"path": "Main/Player/PlayerInput", "prop": "max_upright_torque", "label": "脚·回正力矩上限"},
	{"path": "Main/Player/Arm/Hand/HandControl", "prop": "max_force", "label": "手·最大力"},
	{"path": "Main/Player/Arm/Hand/HandControl", "prop": "max_power", "label": "手·最大功率"},
	{"path": "Main/Player/Arm/Hand/HandControl", "prop": "position_stiffness", "label": "手·位置刚度"},
	{"path": "Main/Player/Arm/Hand/HandControl", "prop": "position_damping", "label": "手·位置阻尼"},
	{"path": "Main/Player", "prop": "shape_density_scale", "label": "自身·质量"},
]

const MIN_MULT := 0.25
const MAX_MULT := 5.0

var _base: Array[float] = []
var _sliders: Array[HSlider] = []
var _reads: Array[Label] = []


func _ready() -> void:
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var layer := CanvasLayer.new()
	layer.add_child(panel)
	add_child(layer)
	var title := Label.new()
	title.text = "健身房   ×0.25 ~ ×5（1.00 = 原值）"
	box.add_child(title)
	for i in knobs.size():
		var k: Dictionary = knobs[i]
		var target := get_node_or_null(NodePath(str(k["path"])))
		_base.append(float(target.get(str(k["prop"]))) if target != null else 0.0)
		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = str(k["label"])
		name_label.custom_minimum_size.x = 130.0
		row.add_child(name_label)
		var slider := HSlider.new()
		slider.min_value = MIN_MULT
		slider.max_value = MAX_MULT
		slider.step = 0.05
		slider.value = 1.0
		slider.custom_minimum_size.x = 220.0
		row.add_child(slider)
		var read := Label.new()
		read.custom_minimum_size.x = 150.0
		row.add_child(read)
		box.add_child(row)
		_sliders.append(slider)
		_reads.append(read)
		if _is_mass(k):
			slider.drag_ended.connect(func(_changed: bool) -> void: _apply(i))
		else:
			slider.value_changed.connect(func(_v: float) -> void: _apply(i))
		_apply(i)


## 供自测/脚本调用（旋钮滑块的入口）。index 见 `knobs`。
func set_knob(index: int, mult: float) -> void:
	_sliders[index].value = clampf(mult, MIN_MULT, MAX_MULT)
	_apply(index)  # 质量旋钮靠 drag_ended，程序化改值不会自动触发


func _is_mass(k: Dictionary) -> bool:
	return str(k["prop"]) == "shape_density_scale"


func _apply(index: int) -> void:
	var k: Dictionary = knobs[index]
	var target := get_node_or_null(NodePath(str(k["path"])))
	if target == null:
		return
	var mult: float = _sliders[index].value
	var value: float = _base[index] * mult
	target.set(str(k["prop"]), value)
	_reads[index].text = "×%.2f = %s" % [mult, String.num(value, 5)]
	if _is_mass(k):
		# 质量是"密度倍率"：写进**当前**形状再让像素物理重算并推给 Rapier。
		# （刚体节点上的 `shape_density_scale` 只在烘焙时读一次，运行中改属性不会自己生效。）
		# ⚠️ 密度回调必须用世界节点的 `_density_of`：PWorld 自带的 `density_of_material()`
		#    会把密度 0 兜底成 1.0（玩家白标签 1310 格会凭空多出 1310 质量）。
		var world := target.get_parent()
		if world != null and world.has_method("_density_of"):
			for shape in target.body.shapes:
				shape.density_scale = value
			world.world.refresh_mass(target.body, Callable(world, "_density_of"))
