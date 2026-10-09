extends Node2D


func _ready() -> void:
	if "--capture-preview" not in OS.get_cmdline_user_args():
		return
	for _frame in range(8):
		await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_error("Viewport returned no preview image")
		get_tree().quit(1)
		return
	image.save_png("res://preview_unified.png")
	get_tree().quit(0)
