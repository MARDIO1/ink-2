extends Node2D
## 健身房：滑块按基准倍率调，数值框直接调；只有“保存为默认”会写配置文件。

const MASS_PROP := "shape_density_scale"
const Palette := preload("res://ink/general/src/ink_palette.gd")

@onready var knobs: VBoxContainer = $Panel/Rows/Knobs
@onready var toggle: Button = $Panel/Rows/Header/Toggle
@onready var save_button: Button = $Panel/Rows/Header/Save

var _sliders: Array[HSlider] = []
var _numbers: Array[SpinBox] = []
var _base: Array[float] = []
var _base_display: Array[float] = []
var _targets: Array = []
var _props: Array[String] = []
var _config_props: Array[String] = []
var _configs: Array = []
var _absolute: Array[bool] = []
var _heavy: Array[bool] = []
var _dirty_indices := {}
var _config: Resource
var _syncing := false


func _ready() -> void:
	var player := get_node_or_null("../Player")
	_config = player.controller_config if player != null else null
	_setup_scroll()
	_bind_rows()
	_build_ink_rows()
	# Range controls keep keyboard focus after a click by default. The Gym is an
	# in-world debug panel, so stale focus must not keep swallowing camera keys.
	for slider in _sliders:
		slider.focus_mode = Control.FOCUS_NONE
	toggle.pressed.connect(_toggle_knobs)
	save_button.pressed.connect(_save)
	if OS.has_feature("standalone"):
		save_button.disabled = true
		save_button.tooltip_text = "导出版本不能覆盖项目配置"


func _input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and $Panel.is_ancestor_of(focus) \
			and not $Panel.get_global_rect().has_point(event.position):
		focus.release_focus()


func _setup_scroll() -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.custom_minimum_size = Vector2(420, 560)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	$Panel/Rows.add_child(scroll)
	knobs.reparent(scroll)
	knobs.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## 每行仍只靠 target_path / target_prop 描述目标；配置字段名由脚、手、身体三类自动拼出。
func _bind_rows() -> void:
	for row in knobs.get_children():
		var path := str(row.get_meta("target_path", ""))
		var prop := str(row.get_meta("target_prop", ""))
		var target := get_node_or_null(NodePath(path))
		if target == null:
			push_error("健身房：%s 的 target_path 找不到：%s" % [row.name, path])
			continue
		_register_row(row, target, prop, _config, _config_prop(path, prop), false,
			prop == MASS_PROP)


func _build_ink_rows() -> void:
	var runtime := get_node_or_null("../SimulationRuntime")
	if runtime == null:
		return
	var tuning: Resource = runtime.tuning_config
	_add_rule_section("蓝墨", runtime.get_node("BlueInk"), tuning, "blue_", [
		["单位长度力", "force_per_length", 0.0, 1000000.0, 1000.0],
		["单位宽度功率", "power_per_width", 0.0, 1500000000.0, 1000000.0],
		["红墨接触功率", "source_power_per_pixel", 0.0, 1500000000.0, 1000000.0],
		["待机功率", "idle_power", 0.0, 100000000.0, 100000.0],
		["红墨像素储能", "energy_per_red_pixel", 1000000.0, 3000000000.0, 1000000.0],
		["耗料结算周期", "fuel_interval", 0.02, 1.0, 0.01],
		["燃料接触半径", "fuel_contact_radius", 0.0, 8.0, 1.0],
		["传播速度", "propagation_speed", 100.0, 2400.0, 10.0],
		["发包周期", "emission_interval", 0.02, 1.0, 0.01],
		["电机缓冲时间", "motor_buffer_seconds", 0.05, 3.0, 0.05],
		["电机启动延迟", "motor_startup_delay", 0.0, 0.5, 0.01],
		["电机功率窗口", "motor_power_window", 0.02, 1.0, 0.01],
		["电机爬坡", "motor_force_ramp", 0.01, 0.5, 0.01],
		["交汇回收", "opposition_recovery", 0.0, 1.0, 0.05],
		["能源寿命", "energy_lifetime", 1.0, 60.0, 1.0],
		["短箭头衰减指数", "short_falloff_exponent", 0.25, 3.0, 0.05],
		["短箭头最低倍率", "short_min_scale", 0.0, 1.0, 0.05],
		["生物默认功率", "biological_default_power", 0.0, 5000000000.0, 10000000.0],
		["生物推力/自重", "biological_force_weight_ratio", 0.0, 5.0, 0.05],
	])
	_add_rule_section("黄墨", runtime.get_node("YellowInk"), tuning, "yellow_", [
		["显示透明度", "yellow_opacity", 0.0, 1.0, 0.01],
		["虚线长度", "dash_length", 1.0, 64.0, 1.0],
		["虚线间隔", "dash_gap", 1.0, 64.0, 1.0],
		["单位宽度劲度", "stiffness_per_width", 0.0, 50000.0, 100.0],
		["阻尼比", "damping_ratio", 0.0, 2.0, 0.01],
		["单位宽度安全力", "safe_force_per_width", 0.0, 5000000.0, 10000.0],
		["每秒磨损像素", "wear_pixels_per_second", 0.0, 100.0, 0.5],
	])
	_add_rule_section("红墨", runtime.get_node("RedInk"), tuning, "red_", [
		["传播衰减", "propagation_decay", 0.0, 1.0, 0.01],
		["单位像素冲量", "impulse_per_pixel", 0.0, 1500000.0, 1000.0],
		["伤害倍率", "damage_multiplier", 0.0, 2.0, 0.01],
		["冲量倍率", "impulse_multiplier", 0.0, 8.0, 0.1],
		["爆炸半径", "blast_radius", 1.0, 256.0, 1.0],
		["射线数", "ray_count", 4.0, 128.0, 4.0],
		["事件分块", "event_chunk_size", 8.0, 128.0, 8.0],
	])
	_add_rule_section("白墨", runtime.get_node("WhiteInk"), tuning, "white_", [
		["每秒腐蚀像素", "corrosion_pixels_per_second", 0.0, 400.0, 1.0],
		["腐蚀周期", "corrosion_interval", 0.02, 1.0, 0.01],
		["单批腐蚀像素", "corrosion_pixels_per_batch", 1.0, 64.0, 1.0],
		["腐蚀产出率", "corrosion_yield", 0.0, 10.0, 0.1],
		["玩家每秒伤害", "player_damage_per_second", 0.0, 100.0, 1.0],
		["最大飞行距离", "max_travel_from_spawn", 64.0, 8192.0, 64.0],
	])
	_add_section("墨水材质")
	for entry: Dictionary in Palette.INKS:
		var material: Resource = entry.material
		var name: String = entry.name
		_add_dynamic_row(name + "·密度", material, "density", material, "density", 0.0, 10.0, 0.05, true)
		_add_dynamic_row(name + "·摩擦", material, "friction", material, "friction", 0.0, 3.0, 0.05, true)
		_add_dynamic_row(name + "·抗压", material, "compress_strength", material, "compress_strength", 0.0, 1000.0, 1.0)
		_add_dynamic_row(name + "·抗剪", material, "shear_strength", material, "shear_strength", -1.0, 1000.0, 1.0)


func _add_rule_section(title: String, target, config: Resource, prefix: String,
		descriptors: Array) -> void:
	_add_section(title)
	for item: Array in descriptors:
		_add_dynamic_row(title + "·" + item[0], target, item[1], config,
			prefix + item[1], item[2], item[3], item[4])


func _add_section(title: String) -> void:
	var label := Label.new()
	label.text = "— %s —" % title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	knobs.add_child(label)


func _add_dynamic_row(label_text: String, target, prop: String, config: Resource,
		config_prop: String, minimum: float, maximum: float, step: float,
		heavy := false) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.custom_minimum_size = Vector2(150, 0)
	label.text = label_text
	label.theme_type_variation = &"MutedLabel"
	var slider := HSlider.new()
	slider.name = "Slider"
	slider.custom_minimum_size = Vector2(120, 20)
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	var number := SpinBox.new()
	number.name = "Read"
	number.custom_minimum_size = Vector2(125, 0)
	row.add_child(label)
	row.add_child(slider)
	row.add_child(number)
	knobs.add_child(row)
	_register_row(row, target, prop, config, config_prop, true, heavy)


func _register_row(row: Node, target, prop: String, config: Resource,
		config_prop: String, absolute: bool, heavy: bool) -> void:
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
	_configs.append(config)
	_config_props.append(config_prop)
	_absolute.append(absolute)
	_heavy.append(heavy)
	if absolute:
		slider.value = base
	_setup_number(index)
	if heavy:
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
	number.min_value = slider.min_value if _absolute[index] else base * slider.min_value
	number.max_value = slider.max_value if _absolute[index] else base * slider.max_value
	number.step = slider.step if _absolute[index] else maxf(absf(base) * 0.01, 0.01)
	number.value = base


## 供自测/脚本调用。index 是 Knobs 下的行号。
func set_knob(index: int, multiplier: float) -> void:
	_sliders[index].set_value_no_signal(clampf(multiplier,
		_sliders[index].min_value, _sliders[index].max_value))
	_apply_slider(index)


func _apply_slider(index: int) -> void:
	if _syncing:
		return
	_write(index, _sliders[index].value if _absolute[index]
		else _base[index] * _sliders[index].value)


func _apply_number(index: int, display_value: float) -> void:
	if _syncing:
		return
	var value := display_value
	if _props[index] == MASS_PROP:
		value = _base[index] * display_value / _base_display[index]
	_syncing = true
	_sliders[index].value = value if _absolute[index] else value / _base[index]
	_syncing = false
	_write(index, value)


func _write(index: int, value: float) -> void:
	var target: Variant = _targets[index]
	target.set(_props[index], value)
	_dirty_indices[index] = true
	if _props[index] == MASS_PROP:
		var pixel_world: Node = target.get_parent()
		for shape in target.body.shapes:
			shape.density_scale = value
		pixel_world.world.refresh_mass(target.body, Callable(pixel_world, "_density_of"))
	elif target is Resource and target.get("id") != null:
		_apply_material(target, _props[index])
	_syncing = true
	_numbers[index].value = float(target.body.mass) if _props[index] == MASS_PROP else value
	_syncing = false
	save_button.text = "保存为默认"


func _apply_material(material: Resource, prop: String) -> void:
	var world_node = get_parent()
	if world_node == null or world_node.get("world") == null:
		return
	var world = world_node.world
	match prop:
		"density": world.set_material_density(material.id, material.density)
		"friction": world.set_material_friction(material.id, material.friction)
		"restitution": world.set_material_restitution(material.id, material.restitution)
		"compress_strength", "shear_strength":
			world.set_material_strength(material.id, material.compress_strength,
				material.resolved_shear())
	if prop not in ["density", "friction", "restitution"]:
		return
	for body in world.bodies:
		var found := false
		for shape in body.shapes:
			for chunk in shape.chunks.values():
				if chunk.mat.has(material.id):
					found = true
					break
			if found:
				break
		if found:
			world.refresh_mass(body, Callable(world_node, "_density_of"))


func _save() -> void:
	if _dirty_indices.is_empty():
		save_button.text = "没有修改"
		return
	var resources := {}
	for index: int in _dirty_indices:
		var config: Resource = _configs[index]
		if config == null or config.resource_path.is_empty():
			continue
		config.set(_config_props[index], _targets[index].get(_props[index]))
		resources[config] = true
	if resources.is_empty():
		save_button.text = "没有配置"
		return
	for resource: Resource in resources:
		var error := ResourceSaver.save(resource, resource.resource_path)
		if error != OK:
			save_button.text = "保存失败"
			push_error("健身房：保存配置失败：%s" % error_string(error))
			return
	_dirty_indices.clear()
	_rebase()
	save_button.text = "已保存"


## 保存后的当前值就是新基准；数值不跳，倍率统一回到 1.00。
func _rebase() -> void:
	_syncing = true
	for index in _targets.size():
		_base[index] = float(_targets[index].get(_props[index]))
		_base_display[index] = (float(_targets[index].body.mass)
			if _props[index] == MASS_PROP else _base[index])
		_sliders[index].value = _base[index] if _absolute[index] else 1.0
		_setup_number(index)
	_syncing = false


func _toggle_knobs() -> void:
	knobs.visible = not knobs.visible
	toggle.text = "显示" if not knobs.visible else "隐藏"
