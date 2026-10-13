extends SceneTree
## 复用原有材质图烘焙器；只生成视觉资源，不重烘物理手。
const BakeArt := preload("res://tools/bake_art.gd")

func _initialize() -> void:
	var bake := BakeArt.new()
	for spec in [["player_hand_climb_source.png", 4, Vector2i(36, 31), Vector2i.ZERO, "player_hand_climb.tres"],
		["player_hand_idle_source.png", 32, Vector2i(41, 29), Vector2i(0, 1), "player_hand_idle.tres"],
		["player_hand_grip_source.png", 4, Vector2i(35, 31), Vector2i(1, 0), "player_hand_grip.tres"]]:
		var data := bake.analyse(spec[0], spec[1], true, 3, 0)
		if data.is_empty():
			quit(1)
			return
		var image := Image.create_from_data(data.w, data.h, false, Image.FORMAT_R8, data.mat)
		image.resize(spec[2].x, spec[2].y, Image.INTERPOLATE_NEAREST)
		var aligned := Image.create_empty(44, 34, false, Image.FORMAT_R8)
		aligned.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), spec[3])
		var result := ResourceSaver.save(aligned, "res://actor/player/asset/" + spec[4])
		if result != OK:
			quit(1)
			return
		print("[HandPoseBake] ", spec[4], " ", image.get_size())
	quit()
