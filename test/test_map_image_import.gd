extends SceneTree

const GifDecoder := preload("res://debug/creative/src/gif_decoder.gd")
const MapImage := preload("res://debug/creative/src/map_imported_image.gd")
const Creative := preload("res://debug/creative/src/creative.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, condition: bool) -> void:
	print("[MapImage] %s %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1


func _run() -> void:
	check("creative editor script compiles", Creative != null)
	var gif_bytes := FileAccess.get_file_as_bytes("res://ui/menu/title_fx/doc/标题涟漪.gif")
	var gif := GifDecoder.decode(gif_bytes)
	check("GIF decoder reads complete animation", not gif.has("error")
		and gif.frames.size() == 145 and gif.delays.size() == 145
		and gif.frames[0].get_size() == Vector2i(720, 405))
	if gif.has("error"):
		print("[MapImage] GIF error: ", gif.error)
	var bitmap := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	bitmap.fill(Color.TRANSPARENT)
	bitmap.set_pixel(1, 2, Color.RED)
	var png := Image.new()
	check("PNG decoder reads transparent pixels", png.load_png_from_buffer(bitmap.save_png_to_buffer()) == OK
		and png.get_pixel(1, 2).r > 0.9 and png.get_pixel(0, 0).a == 0.0)
	var scene_root := Node2D.new()
	scene_root.name = "Map"
	root.add_child(scene_root)
	var image := MapImage.new() as Sprite2D
	image.name = "ImportedImage"
	image.z_index = 15 # 模拟旧地图里已经存下的错误层级。
	var textures: Array[Texture2D] = [ImageTexture.create_from_image(png)]
	image.frames = textures
	image.frame_delays = PackedFloat32Array([0.1])
	image.source_data = bitmap.save_png_to_buffer()
	image.source_format = "png"
	image.original_filename = "demo.png"
	scene_root.add_child(image)
	check("legacy imported image layer migrates", image.z_index == -1 and not image.z_as_relative)
	image.owner = scene_root
	image.position = Vector2(15, 20)
	image.scale = Vector2.ONE * 1.5
	check("image pick region follows transform", image.pick_rect().has_point(Vector2(18, 23)))
	var packed := PackedScene.new()
	check("scene packs imported image", packed.pack(scene_root) == OK)
	var path := "user://map_image_import_test.tscn"
	check("scene saves embedded source", ResourceSaver.save(packed, path) == OK)
	var restored_scene := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var restored := restored_scene.instantiate() if restored_scene != null else null
	var restored_image = restored.get_node_or_null("ImportedImage") if restored != null else null
	check("image survives scene reload", restored_image != null and restored_image.texture != null
		and restored_image.texture.get_image().get_pixel(1, 2).r > 0.9
		and restored_image.source_data == image.source_data)
	if restored != null:
		restored.free()
	var gif_root := Node2D.new()
	gif_root.name = "AnimatedMap"
	var gif_node := MapImage.new() as Sprite2D
	gif_node.name = "AnimatedImage"
	gif_node.source_data = gif_bytes
	gif_node.source_format = "gif"
	gif_root.add_child(gif_node)
	gif_node.owner = gif_root
	var gif_scene := PackedScene.new()
	gif_scene.pack(gif_root)
	var gif_scene_path := "user://animated_map_image_import_test.tscn"
	check("GIF scene saves compressed source", ResourceSaver.save(gif_scene, gif_scene_path) == OK
		and FileAccess.get_file_as_bytes(gif_scene_path).size() < 8 * 1024 * 1024)
	var reloaded_gif_scene := ResourceLoader.load(gif_scene_path, "PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var reloaded_gif = reloaded_gif_scene.instantiate() if reloaded_gif_scene != null else null
	if reloaded_gif != null:
		root.add_child(reloaded_gif)
	var reloaded_gif_node = reloaded_gif.get_node_or_null("AnimatedImage") if reloaded_gif != null else null
	check("GIF animation survives reload", reloaded_gif_node != null and reloaded_gif_node.frames.size() == 145
		and reloaded_gif_node.is_processing())
	if reloaded_gif_node != null:
		reloaded_gif_node._process(reloaded_gif_node._delay(0))
		check("GIF advances to next frame", reloaded_gif_node._frame == 1)
	if reloaded_gif != null:
		reloaded_gif.queue_free()
	gif_root.free()
	scene_root.queue_free()
	await process_frame
	quit(1 if failures else 0)
