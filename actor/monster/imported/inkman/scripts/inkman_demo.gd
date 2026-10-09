extends Node2D

@onready var character: InkmanCharacter = $InkmanCharacter
@onready var expression_option: OptionButton = $UI/Panel/Margin/VBox/ExpressionRow/ExpressionOption
@onready var ink_slider: HSlider = $UI/Panel/Margin/VBox/InkRow/InkSlider
@onready var ink_value: Label = $UI/Panel/Margin/VBox/InkRow/InkValue
@onready var wobble_toggle: CheckButton = $UI/Panel/Margin/VBox/ToggleRow/Wobble


func _ready() -> void:
	expression_option.clear()
	for item_name in InkmanCharacter.EXPRESSION_NAMES:
		expression_option.add_item(item_name)
	expression_option.select(character.expression)
	ink_slider.value = character.ink_amount
	_update_ink_label(character.ink_amount)
	wobble_toggle.button_pressed = character.hand_drawn_wobble


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_6:
			var index := int(event.keycode - KEY_1)
			character.set_expression_index(index)
			expression_option.select(index)
		elif event.keycode == KEY_UP:
			ink_slider.value = minf(ink_slider.value + 0.05, 1.0)
		elif event.keycode == KEY_DOWN:
			ink_slider.value = maxf(ink_slider.value - 0.05, 0.0)


func _on_expression_selected(index: int) -> void:
	character.set_expression_index(index)


func _on_ink_changed(value: float) -> void:
	character.ink_amount = value
	_update_ink_label(value)


func _on_wobble_toggled(enabled: bool) -> void:
	character.hand_drawn_wobble = enabled


func _on_reset_pressed() -> void:
	character.reset_pose()
	character.set_expression_index(InkmanCharacter.Mood.COMMON)
	character.ink_amount = 0.72
	expression_option.select(InkmanCharacter.Mood.COMMON)
	ink_slider.value = 0.72


func _update_ink_label(value: float) -> void:
	ink_value.text = "%d%%" % roundi(value * 100.0)
