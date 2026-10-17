extends SceneTree
const P=preload("res://ink/general/src/ink_palette.gd")
const Motor=preload("res://ink/blue/src/motor.gd")
const Rail=preload("res://ink/yellow/src/rail.gd")
const Pin=preload("res://ink/yellow/src/slider_pin.gd")
const Item=preload("res://actor/ink_item/src/ink_item.gd")
const DEST="res://map/logic/MOS门电路实验室.tscn"
var level; var canvas; var s; var blue; var plugs:Array[Vector2i]=[]
func _initialize(): call_deferred("run")
func rect(r:Rect2i,c:Color):
	for y in range(r.position.y,r.end.y):
		for x in range(r.position.x,r.end.x): s.write_pixel(Vector2i(x,y),c)
func wire(a:Vector2,b:Vector2,w:=2):
	s.brush_size=w;s.blue_layer.begin(a);s.blue_layer.extend(b);s.blue_layer.finish()
func arrow(a:Vector2,b:Vector2,w:int):
	s.brush_size=w;blue.begin(s,a);assert(blue.finish(s,b))
func spring(a:Vector2,b:Vector2):
	s.brush_size=6;var yellow=level.get_node("SimulationRuntime/YellowInk");yellow.begin(s,a);assert(yellow.finish(s,b))
func rail(a:Vector2,b:Vector2,p:Vector2):
	s.selected_ink=3;s.brush_size=9;s.rod_layer.begin_rail(a);assert(s.rod_layer.finish_rail(b));assert(s.rod_layer.place_slider_pin(p));assert(s.rod_layer.place_anchor(a));assert(s.rod_layer.place_anchor(b))
func label(t:String,p:Vector2,z:=16,c:=Color("171712")):
	var n=Label.new();n.text=t;n.position=canvas.position+p;n.add_theme_font_size_override("font_size",z);n.add_theme_color_override("font_color",c);level.add_child(n);n.owner=level
func gate(name:String,y:int,n:int,length:float,width:int,start:int):
	rect(Rect2i(120,y-14,22,28),Color.BLACK);rect(Rect2i(410,y-14,22,28),Color.BLACK)
	s.write_pixel(Vector2i(130,y),P.nail_color());s.write_pixel(Vector2i(420,y),P.nail_color())
	rect(Rect2i(start-55,y-23,110,46),Color.BLACK);rect(Rect2i(start+40,y-8,13,16),P.RED.color)
	# 载体上的源极蓝触点由红墨直接供能；滑到固定漏极时两段蓝墨才接通。
	wire(Vector2(start+30.5,y+.5),Vector2(start+52.5,y+.5),3)
	var ox=439 if name=="NOT" else 398;rect(Rect2i(ox,y-5,252,10),Color.BLACK);wire(Vector2(ox+.5,y+.5),Vector2(644.5,y+.5),3)
	for i in n:
		var iy=y-12+i*24;rect(Rect2i(start-73,iy-7,4,17),Color.BLACK);rect(Rect2i(start-73,iy+6,31,4),Color.BLACK);wire(Vector2(start-54.5,iy+.5),Vector2(start+12.5,iy+.5),2);plugs.append(Vector2i(start-69,iy-6))
		var ax=start-35.0 if length>0 else start+10.0;arrow(Vector2(ax+.5,iy+.5),Vector2(ax+length+.5,iy+.5),width)
	if name!="NOT": spring(Vector2(141.5,y+.5),Vector2(start-37.5,y+.5))
	rail(Vector2(132.5,y+.5),Vector2(421.5,y+.5),Vector2(start+.5,y+.5))
func add_plugs():
	for p in plugs: rect(Rect2i(p.x,p.y,14,12),P.RED.color)
	s.rebuild_ink_tiles();s._rebuild_loaded_metadata();canvas.generate(false)
func mark_infinite()->int:
	var count=0
	for node in level.find_children("*","",true,false):
		if not node is Item: continue
		var found=Vector2i(-999999,-999999)
		for shape in node.collect_shapes():
			var r:Rect2i=shape.local_aabb()
			for y in range(r.position.y,r.end.y):
				for x in range(r.position.x,r.end.x):
					if shape.get_pixel(x,y)==P.RED.id: found=Vector2i(x,y);break
				if found.x!=-999999: break
			if found.x!=-999999: break
		if found.x==-999999: continue
		node.infinite_nails=PackedVector2Array([found]);node.infinite_nail_body=true;node.infinite_fuel_body=true;count+=1
	return count
func run():
	level=load("res://map/asset/imported/main.tscn").instantiate();level.auto_step=false;root.add_child(level);await process_frame;await process_frame
	canvas=level.get_node("SmallCanvas");canvas.position=Vector2(5000,5000);canvas.canvas_size=Vector2i(760,620);s=canvas.surface;s.ink_free=true;s.black_image.fill(Color.TRANSPARENT);blue=level.get_node("SimulationRuntime/BlueInk")
	rect(Rect2i(15,580,730,25),Color.BLACK);rect(Rect2i(35,385,95,12),Color.BLACK);rect(Rect2i(35,205,95,12),Color.BLACK)
	s.write_pixel(Vector2i(25,590),P.nail_color());s.write_pixel(Vector2i(45,390),P.nail_color());s.write_pixel(Vector2i(45,210),P.nail_color())
	gate("AND",140,2,48.0,4,340);gate("OR",320,2,58.0,6,340);gate("NOT",500,1,-64.0,6,350)
	s.refresh();canvas.generate(false);await process_frame;add_plugs();await process_frame;await process_frame
	var sources=mark_infinite();blue.force_per_length=5e6;blue.power_per_width=3e9;blue.source_power_per_pixel=3e9;level.get_node("SimulationRuntime/YellowInk").stiffness_per_width=900.0;level.world.gravity=Vector2(0,980)
	label("门电路实验室　红块插入蓝色插槽=1，拔出=0（左键抓取）",Vector2(24,18),19)
	label("AND 与门　A、B 都通电才输出",Vector2(210,62),18);label("A",Vector2(272,111),16,Color.DARK_RED);label("B",Vector2(272,143),16,Color.DARK_RED)
	label("OR 或门　A、B 任一通电就输出",Vector2(210,242),18);label("A",Vector2(272,291),16,Color.DARK_RED);label("B",Vector2(272,323),16,Color.DARK_RED)
	label("NOT 非门　拔出 A 时输出，插入时关闭",Vector2(210,422),18);label("A",Vector2(304,475),16,Color.DARK_RED)
	for y in [140,320,500]: label("OUT",Vector2(660,y-14),15,Color.DARK_BLUE)
	level.get_node("Camera2D").enabled=false;var cam=Camera2D.new();cam.name="MOSLogicCamera";cam.position=canvas.position+Vector2(380,310);cam.zoom=Vector2.ONE*1.05;level.add_child(cam);cam.owner=level;cam.make_current()
	level.get_node("Player").position=canvas.position+Vector2(82,545);canvas.position+=Vector2(1200,0);level.auto_step=true;level.get_node("Creative").save_preview_on_export=false
	var error=level.get_node("Creative").export_map_to(DEST,false);var rails=level.get_children().filter(func(x):return x is Rail);var pins=level.get_children().filter(func(x):return x is Pin)
	print("MOS_PLAYABLE_MAP motors=",blue.objects(Motor).size()," rails=",rails.size()," pins=",pins.size()," infinite_red_bodies=",sources," error=",error)
	quit(0 if error==OK and blue.objects(Motor).size()==5 and rails.size()==3 and pins.size()==3 and sources==8 else 1)
