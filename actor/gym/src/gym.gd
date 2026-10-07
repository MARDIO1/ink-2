extends Node2D
## 健身房：把角色控制器的可调数值摆成旋钮，**倍率 ×0.25 ~ ×5** 即时调。
##
## 和 canvas 一样是**世界物件**：整块面板就是 `gym.tscn` 里的节点（`Panel`），摆在关卡里，
## 相机怎么动它就待在原地 —— 不是贴在屏幕上的 `CanvasLayer`。
## 样式也照 canvas 那套：`ui/theme/asset/ink_attack_theme.tres` + 它的 `CardPanel` /
## `TitleLabel` / `MutedLabel` 变体，场景里不内联 StyleBox。
## ⚠️ 每个旋钮打谁写在**行节点的 metadata** 上（`target_path` / `target_prop`），不在这里再列一遍；
##    加/删旋钮只动场景：复制一行、改 `Name` 文本和两个 metadata。
## ⚠️ `target_path` 相对本节点 —— 本节点是关卡根的子级，所以是 `../Player/...`。
## ⚠️ 启动时**一个值都不写**（只记基准 + 显示读数）：没拖过滑块，关卡物理就跟没它一样。
##
## 倍率模型：`_ready` 时把每个目标的**当前值**记成基准，滑块只写 `基准 × 倍率` ——
## 拉回 1.00 就是原值，不会累积。
## ⚠️ 质量（`shape_density_scale`）走 `drag_ended` 而不是每帧：改一次要重算质量
##    （逐像素扫描 + 贪心分解 + 重推密度，玩家 3 千多格 ≈ 2~3ms），拖拽中每帧刷会卡。

## 质量旋钮要重算质量，走 `drag_ended` 不走 `value_changed`。
const MASS_PROP := "shape_density_scale"

@onready var knobs: VBoxContainer = $Panel/Rows/Knobs
@onready var toggle: Button = $Panel/Rows/Header/Toggle

var _sliders: Array[HSlider] = []
var _reads: Array[Label] = []
var _base: Array[float] = []
var _targets: Array[Node] = []
var _props: Array[String] = []


func _ready() -> void:
	_bind_rows()
	toggle.pressed.connect(_toggle_knobs)


## 按 `Knobs` 里的行绑定：打谁写在行节点的 metadata 上（场景里改，不在这里重复）。
func _bind_rows() -> void:
	var rows := knobs.get_children()
	if rows.is_empty():
		push_error("健身房：%s 下一行旋钮都没有" % knobs.get_path())
	for i in rows.size():
		var row: Node = rows[i]
		var path := str(row.get_meta("target_path", ""))
		var prop := str(row.get_meta("target_prop", ""))
		var target := get_node_or_null(NodePath(path))
		if target == null:
			# 路径写错就是真错：静默跳过只会让滑块显示一堆 0，却什么都不改。
			push_error("健身房：%s 的 target_path 找不到：%s" % [row.name, path])
		var slider: HSlider = row.get_node("Slider")
		var read: Label = row.get_node("Read")
		_sliders.append(slider)
		_reads.append(read)
		_targets.append(target)
		_props.append(prop)
		_base.append(float(target.get(prop)) if target != null else 0.0)
		# 只记基准、只显示读数：启动时**一个值都不写**。玩家不拖滑块，关卡物理就碰不到它。
		read.text = "×%.2f = %s" % [slider.value, String.num(_base[i], 5)]
		if prop == MASS_PROP:
			slider.drag_ended.connect(func(_changed: bool) -> void: _apply(i))
		else:
			slider.value_changed.connect(func(_v: float) -> void: _apply(i))


## 供自测/脚本调用（旋钮滑块的入口）。index = `Knobs` 里的第几行。
func set_knob(index: int, mult: float) -> void:
	_sliders[index].value = clampf(mult, _sliders[index].min_value, _sliders[index].max_value)
	_apply(index)  # 质量旋钮靠 drag_ended，程序化改值不会自动触发


## 隐藏 / 显示旋钮本体；标题和这个按钮自己一直露着（跟 canvas 工具栏的开关一样）。
func _toggle_knobs() -> void:
	knobs.visible = not knobs.visible
	toggle.text = "显示" if not knobs.visible else "隐藏"


func _apply(index: int) -> void:
	var target := _targets[index]
	var value: float = _base[index] * _sliders[index].value
	target.set(_props[index], value)
	_reads[index].text = "×%.2f = %s" % [_sliders[index].value, String.num(value, 5)]
	if _props[index] == MASS_PROP:
		# 质量是"密度倍率"：写进**当前**形状再让像素物理重算并推给 Rapier。
		# （刚体节点上的 `shape_density_scale` 只在烘焙时读一次，运行中改属性不会自己生效。）
		# ⚠️ 密度回调必须用世界节点的 `_density_of`：PWorld 自带的 `density_of_material()`
		#    会把密度 0 兜底成 1.0（玩家白标签 1310 格会凭空多出 1310 质量）。
		var world := target.get_parent()
		if world != null and world.has_method("_density_of"):
			for shape in target.body.shapes:
				shape.density_scale = value
			world.world.refresh_mass(target.body, Callable(world, "_density_of"))
