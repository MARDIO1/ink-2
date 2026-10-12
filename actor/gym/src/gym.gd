extends Node2D
## 健身房：滑块按基准倍率调，数值框直接调；只有“保存为默认”会写配置文件。

const MASS_PROP := "shape_density_scale"

@onready var knobs: VBoxContainer = $Panel/Rows/Knobs
@onready var toggle: Button = $Panel/Rows/Header/Toggle
@onready var save_button: Button = $Panel/Rows/Header/Save

var _sliders: Array[HSlider] = []
var _numbers: Array[SpinBox] = []
var _base: Array[float] = []
var _base_display: Array[float] = []
var _targets: Array[Node] = []
var _props: Array[String] = []
var _config_props: Array[String] = []
var _config: Resource
var _syncing := false


func _ready() -> void:
	var player := get_node_or_null("../Player")
	_config = player.controller_config if player != null else null
	_bind_rows()
	toggle.pressed.connect(_toggle_knobs)
	save_button.pressed.connect(_save)
	if OS.has_feature("standalone"):
		save_button.disabled = true
		save_button.tooltip_text = "导出版本不能覆盖项目配置"


## 每行仍只靠 target_path / target_prop 描述目标；配置字段名由脚、手、身体三类自动拼出。
func _bind_rows() -> void:
	for row in knobs.get_children():
		var path := str(row.get_meta("target_path", ""))
		var prop := str(row.get_meta("target_prop", ""))
		var target := get_node_or_null(NodePath(path))
		if target == null:
			push_error("健身房：%s 的 target_path 找不到：%s" % [row.name, path])
			continue
		var slider: HSlider = row.get_node("Slider")
		var number: SpinBox = row.get_node("Read")
		var base := float(target.get(prop))
		var display := float(target.body.mass) if prop == MASS_PROP else base
		var index := _sliders.size()
		_sliders.append(slider)
		_numbers.append(number)
		_base.append(base)
		_base_display.append(display)
		_targets.append(target)
		_props.append(prop)
		_config_props.append(_config_prop(path, prop))
		_setup_number(index)
		if prop == MASS_PROP:
			slider.drag_ended.connect(func(_changed: bool) -> void: _apply_slider(index))
		else:
			slider.value_changed.connect(func(_value: float) -> void: _apply_slider(index))
		number.value_changed.connect(func(value: float) -> void: _apply_number(index, value))


func _config_prop(path: String, prop: String) -> String:
	if prop == MASS_PROP:
		return "body_density_scale"
	return ("foot_" if path.ends_with("PlayerInput") else "hand_") + prop


func _setup_number(index: int) -> void:
	var number := _numbers[index]
	var slider := _sliders[index]
	var base := _base_display[index]
	number.min_value = base * slider.min_value
	number.max_value = base * slider.max_value
	number.step = maxf(absf(base) * 0.01, 0.01)
	number.value = base


## 供自测/脚本调用。index 是 Knobs 下的行号。
func set_knob(index: int, multiplier: float) -> void:
	_sliders[index].set_value_no_signal(clampf(multiplier,
		_sliders[index].min_value, _sliders[index].max_value))
	_apply_slider(index)


func _apply_slider(index: int) -> void:
	if _syncing:
		return
	_write(index, _base[index] * _sliders[index].value)


func _apply_number(index: int, display_value: float) -> void:
	if _syncing:
		return
	var value := display_value
	if _props[index] == MASS_PROP:
		value = _base[index] * display_value / _base_display[index]
	_syncing = true
	_sliders[index].value = value / _base[index]
	_syncing = false
	_write(index, value)


func _write(index: int, value: float) -> void:
	var target := _targets[index]
	target.set(_props[index], value)
	if _props[index] == MASS_PROP:
		var pixel_world := target.get_parent()
		for shape in target.body.shapes:
			shape.density_scale = value
		pixel_world.world.refresh_mass(target.body, Callable(pixel_world, "_density_of"))
	_syncing = true
	_numbers[index].value = float(target.body.mass) if _props[index] == MASS_PROP else value
	_syncing = false
	save_button.text = "保存为默认"


func _save() -> void:
	if _config == null or _config.resource_path.is_empty():
		save_button.text = "没有配置"
		return
	for index in _targets.size():
		_config.set(_config_props[index], float(_targets[index].get(_props[index])))
	var error := ResourceSaver.save(_config, _config.resource_path)
	if error != OK:
		save_button.text = "保存失败"
		push_error("健身房：保存配置失败：%s" % error_string(error))
		return
	_rebase()
	save_button.text = "已保存"


## 保存后的当前值就是新基准；数值不跳，倍率统一回到 1.00。
func _rebase() -> void:
	_syncing = true
	for index in _targets.size():
		_base[index] = float(_targets[index].get(_props[index]))
		_base_display[index] = (float(_targets[index].body.mass)
			if _props[index] == MASS_PROP else _base[index])
		_sliders[index].value = 1.0
		_setup_number(index)
	_syncing = false


func _toggle_knobs() -> void:
	knobs.visible = not knobs.visible
	toggle.text = "显示" if not knobs.visible else "隐藏"
