extends SceneTree
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const Spring := preload("res://ink/yellow/src/stroke.gd")
const ORIGIN := Vector2(-520,0)
var picture: Image

func point(at: Vector2, color: Color, width := 1) -> void:
	var p := Vector2i((at-ORIGIN).round())
	picture.fill_rect(Rect2i(p-Vector2i.ONE*(width/2),Vector2i.ONE*width).intersection(Rect2i(Vector2i.ZERO,picture.get_size())),color)

func _initialize() -> void:
	var level = load("res://.codex-tmp/blue_ascent_machines_work.tscn").instantiate()
	picture = Image.create(2800,4000,false,Image.FORMAT_RGBA8)
	picture.fill(Color("f3efe4"))
	for y in range(0,4000,32): picture.fill_rect(Rect2i(0,y,2800,1),Color("e0dbd0"))
	var draft := Image.new()
	assert(draft.load_png_from_buffer(level.get_node("Creative").editor_draft.black)==OK)
	picture.blend_rect(draft,Rect2i(Vector2i.ZERO,draft.get_size()),Vector2i.ZERO)
	for item in level.get_children():
		if not item.has_meta("blue_ascent_machine"): continue
		for shape in item.get_children():
			var paint = shape.get("paint")
			if not paint is Image: continue
			for y in paint.get_height():
				for x in paint.get_width():
					var material := roundi(paint.get_pixel(x,y).r*255)
					if material>0: point(item.transform*shape.transform*Vector2(x,y),Palette.color_for_material_id(material))
	for item in level.get_children():
		if item is Spring and item.path.size()>1:
			item.build_pixels()
			var axis:Vector2=(item.path[-1]-item.path[0]).normalized()
			for p in item.cells:
				point(item.path[0]+axis*(p.x+0.5)+axis.orthogonal()*(p.y+0.5),Palette.YELLOW.color)
		if item is Wire:
			var body = level.get_node_or_null(item.carrier_path)
			if body != null:
				for p in item.cells: point(body.transform*p,Palette.BLUE.color,2)
		if item is Motor:
			for p in Motor.pixels_for(item.tip,item.brush_width): point(item.transform*p,Palette.BLUE.color)
	DirAccess.make_dir_recursive_absolute("res://output/blue_ascent_complete")
	assert(picture.save_png("res://output/blue_ascent_complete/map_actual.png")==OK)
	picture.resize(1120,1600,Image.INTERPOLATE_NEAREST)
	assert(picture.save_png("res://output/blue_ascent_complete/overview.png")==OK)
	level.free()
	print("[BlueOverview] exported actual scene geometry")
	quit()
