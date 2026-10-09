extends Node2D

@onready var animation_player: AnimationPlayer = $Bomber/AnimationPlayer
@onready var state_label: Label = $UI/Panel/VBox/State
@onready var bone_overlay: Node2D = $Bomber/BoneOverlay


func _ready() -> void:
	animation_player.animation_finished.connect(_on_animation_finished)
	play_animation(&"idle")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	match key_event.keycode:
		KEY_1:
			play_animation(&"idle")
		KEY_2:
			play_animation(&"walk")
		KEY_3:
			play_animation(&"throw")
		KEY_B:
			bone_overlay.visible = not bone_overlay.visible


func play_animation(animation_name: StringName) -> void:
	# Apply the authored rest pose first so switching away from a one-shot
	# animation never leaves the bomb or a limb at its previous final key.
	animation_player.play(&"RESET")
	animation_player.advance(0.0)
	animation_player.play(animation_name, 0.18)
	state_label.text = "当前动画：%s" % animation_name


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name == &"throw":
		play_animation(&"idle")
