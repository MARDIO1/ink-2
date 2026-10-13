extends SceneTree
## 可复现的像素 UI 图标导出；不修改项目鼠标设置。

func _initialize() -> void:
	var pixel_size := 15
	var asset_path := "res://ui/cursor/asset/ink_cursor_%dx%d" % [pixel_size, pixel_size]
	var image := Image.load_from_file(asset_path + ".svg")
	assert(image != null and image.get_size() == Vector2i(pixel_size, pixel_size))
	assert(image.get_pixel(0, 0).a == 1.0 and image.get_pixel(pixel_size - 1, pixel_size - 1).a == 0.0)
	var colors := {}
	for y in pixel_size:
		for x in pixel_size:
			var color := image.get_pixel(x, y)
			assert(color.a == 0.0 or color.a == 1.0)
			colors[color.to_html()] = true
	assert(colors.size() == 3)
	assert(image.save_png(asset_path + ".png") == OK)
	var preview := image.duplicate() as Image
	preview.resize(240, 240, Image.INTERPOLATE_NEAREST)
	assert(preview.save_png("C:/Users/youli/.codex/visualizations/2026/10/11/01a12987-d6cc-7a63-9192-35e2107dc184/ink-cursor-15x15-preview.png") == OK)
	print("[CursorAsset] PASS: 15x15, two solid colors, transparent background; hotspot (0, 0)")
	quit()
