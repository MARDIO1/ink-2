extends RefCounted
## 仅供离线制作：用普通墨水实体和已有黄墨组件装配第五、六段。
## 本脚本不挂到地图，不在游玩时驱动、限位或同步任何物体。
const P = preload("res://ink/general/src/ink_palette.gd")
const Item = preload("res://actor/ink_item/src/ink_item.gd")
const Shape = preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Axle = preload("res://ink/yellow/src/axle.gd")
const Rail = preload("res://ink/yellow/src/rail.gd")
const Pin = preload("res://ink/yellow/src/slider_pin.gd")
const Spring = preload("res://ink/yellow/src/stroke.gd")
const Wire = preload("res://ink/blue/src/wire_layer.gd")
const Gear = preload("res://actor/canvas/src/gear_tool.gd")
const Centers = preload("res://actor/canvas/src/gear_centers.gd")

static func own(level, node, parent=null):
    (level if parent==null else parent).add_child(node)
    node.owner=level

static func image(size_:Vector2i) -> Image:
    return Image.create(size_.x,size_.y,false,Image.FORMAT_R8)

static func fill(im:Image, rect:Rect2i, material:int=P.BLACK.id):
    im.fill_rect(rect,Color(float(material)/255.0,0,0))

static func shape(level, host, im:Image, at:=Vector2.ZERO, title:="Pixels"):
    var node=Shape.new()
    node.name=title
    node.source=3
    node.paint=im
    node.position=at
    own(level,node,host)

static func body(level,title:String,at:Vector2,im:Image,fixed:=false):
    var node=Item.new()
    node.name=title
    node.position=at
    node.is_static=fixed
    node.add_to_group("ink_item",true)
    node.set_meta("blue_ascent_machine",true)
    var occupied:=PackedVector2Array()
    var targets=[Vector2(5,im.get_height()-5),Vector2(im.get_width()-5,im.get_height()-5),Vector2(im.get_width()/2,5)]
    for target in targets:
        var best=Vector2.ZERO
        var distance=INF
        for y in im.get_height():
            for x in im.get_width():
                var pixel_at=Vector2(x,y)
                if im.get_pixel(x,y).r<=0 or occupied.has(pixel_at): continue
                var d=pixel_at.distance_squared_to(target)
                if d<distance:
                    distance=d
                    best=pixel_at
        occupied.append(best)
    if fixed: node.fixed_nails=PackedVector2Array([occupied[0],occupied[1]])
    node.infinite_nails=PackedVector2Array([occupied[2]])
    node.infinite_nail_body=true
    own(level,node)
    shape(level,node,im)
    return node

static func rect(level,title:String,at:Vector2,size_:Vector2i,material:int=P.BLACK.id,fixed:=true):
    var im=image(size_)
    fill(im,Rect2i(Vector2i.ZERO,size_),material)
    return body(level,title,at,im,fixed)

static func axle(level,title:String,wheel,support,at:Vector2,wm:int,sm:int):
    var pin=Axle.new()
    pin.name=title
    pin.explicit=true
    pin.fixed_to_world=false
    pin.gear_material=wm
    pin.support_material=sm
    pin.wheel_path=NodePath("../"+str(wheel.name))
    pin.support_path=NodePath("../"+str(support.name))
    pin.yellow_position=at
    pin.black_position=at
    pin.wheel_local=wheel.transform.affine_inverse()*at
    pin.support_local=support.transform.affine_inverse()*at
    pin.saved_local_anchors=true
    own(level,pin)

static func material_at(carrier, at:Vector2i) -> int:
    for node in carrier.get_children():
        if not node.get("paint") is Image: continue
        var p=at-Vector2i(node.position)
        if Rect2i(Vector2i.ZERO,node.paint.get_size()).has_point(p):
            var value=roundi(node.paint.get_pixelv(p).r*255)
            if value>0: return value
    return 0

static func wire(level,title:String,carrier,paths:Array,width:=15):
    var cells={}
    for path in paths:
        for index in path.size()-1:
            var a:Vector2=path[index]
            var b:Vector2=path[index+1]
            var steps=maxi(1,ceili(a.distance_to(b)))
            for step in steps+1:
                var center=Vector2i(a.lerp(b,float(step)/steps).round())
                for y in range(-width/2,width/2+1):
                    for x in range(-width/2,width/2+1):
                        var at=center+Vector2i(x,y)
                        if material_at(carrier,at) in [P.BLACK.id,P.YELLOW.id]: cells[at]=true
    var node=Wire.new()
    node.name=title
    node.position=carrier.position
    node.rotation=carrier.rotation
    node.active=true
    node.carrier_path=NodePath("../"+str(carrier.name))
    node.carrier_local=true
    node.cells=PackedVector2Array(cells.keys())
    node.carrier_material=material_at(carrier,Vector2i(node.cells[0]))
    own(level,node)
    return node

static func lesson(level,title:String,at:Vector2,size_:Vector2i):
    var node=level.get_node(title)
    node.position=at
    node.canvas_size=size_
    node.get_node("CanvasSurface").selected_ink=5
    node.get_node("WorkbenchUI/BrushPanel/PenSlider").value=12

static func old_region(point:Vector2) -> bool:
    return Rect2(900,970,1100,600).has_point(point) or Rect2(880,-20,720,810).has_point(point)

static func clear_old(level):
    var removed={}
    for node in level.get_children():
        var title=str(node.name)
        if title in ["BG06_Finish","BG05_TurnStepA","BG05_TurnStepB","BG05_B_SmoothRamp","BG06_SmoothRamp"]: continue
        if title.begins_with("BG05_") or title.begins_with("BG06_"): removed[node]=true
    for node in level.get_children():
        if node is Axle:
            if removed.has(node.get_node_or_null(node.wheel_path)) or removed.has(node.get_node_or_null(node.support_path)) or old_region(node.yellow_position): removed[node]=true
        elif node is Rail:
            if old_region(node.saved_a): removed[node]=true
        elif node is Pin:
            if old_region(node.saved_source): removed[node]=true
        elif node is Spring:
            if old_region(node.saved_anchor_a) or old_region(node.saved_anchor_b): removed[node]=true
    for node in removed: node.free()

static func fifth(level):
    var base_im=image(Vector2i(220,44))
    fill(base_im,Rect2i(0,0,220,44))
    var base=body(level,"BG05_PowerBase",Vector2(1244,1336),base_im,true)
    var im=image(Vector2i(320,194))
    fill(im,Rect2i(0,0,320,6))
    fill(im,Rect2i(0,18,320,6))
    for x in [0,30,206,314]: fill(im,Rect2i(x,0,6 if x in [0,314] else 28,24))
    fill(im,Rect2i(194,0,52,46))
    fill(im,Rect2i(207,42,26,104))
    fill(im,Rect2i(229,126,4,19),P.RED.id)
    var platform=body(level,"BG05_Platform",Vector2(1534,1240),im)
    platform.infinite_nails=PackedVector2Array([Vector2(231,135)])
    platform.infinite_fuel_body=true
    var delta=Vector2(310,-100)
    var angle=delta.angle()
    var length=delta.length()
    for index in 2:
        var origin=Vector2(1264+180*index,1356)
        var rod=rect(level,"BG05_Lever"+str(index+1),origin-Vector2(14,14).rotated(angle),Vector2i(roundi(length)+28,28),P.YELLOW.id,false)
        rod.rotation=angle
        var rod_pixels=rod.get_node("Pixels").paint
        rod_pixels.fill(Color(0,0,0))
        fill(rod_pixels,Rect2i(0,16,roundi(length)+28,12),P.YELLOW.id)
        fill(rod_pixels,Rect2i(0,0,28,28),P.YELLOW.id)
        fill(rod_pixels,Rect2i(roundi(length),0,28,28),P.YELLOW.id)
        rod.infinite_nails=PackedVector2Array([Vector2(170,22)])
        var rear=image(Vector2i(148,28))
        fill(rear,Rect2i(0,8,148,12),P.YELLOW.id)
        fill(rear,Rect2i(0,0,28,28),P.YELLOW.id)
        shape(level,rod,rear,Vector2(-120,0),"CounterweightArm")
        var rear_at=rod.transform*Vector2(-106,14)
        var weight=rect(level,"BG05_Counterweight"+str(index+1),rear_at-Vector2(75,10),Vector2i(150,100),P.BLACK.id,false)
        axle(level,"BG05_WeightAxle"+str(index+1),weight,rod,rear_at,P.BLACK.id,P.YELLOW.id)
        axle(level,"BG05_BaseAxle"+str(index+1),rod,base,origin,P.YELLOW.id,P.BLACK.id)
        axle(level,"BG05_DeckAxle"+str(index+1),platform,rod,origin+delta,P.BLACK.id,P.YELLOW.id)
    # 红墨端子属于踏台自身墨迹；蓝箭头推动双黄杆与配重，没有隐藏供能或跟随电池。
    wire(level,"BG05_DeckWire",platform,[[Vector2(220,135),Vector2(220,135)]],19)
    # 登台由黄杆上的缓坡完成；固定踏台不横穿黄杆的实际摆动扫掠区。
    rect(level,"BG05_BoardingLanding",Vector2(1054,1265),Vector2i(190,20))
    rect(level,"BG05_LowerRestRight",Vector2(1842,1264),Vector2i(12,18))
    # 转动黄杆碰到独立黑墨挡块；不是轴承角度上限。
    rect(level,"BG05_UpperStop",Vector2(1310,1200),Vector2i(14,24))
    rect(level,"BG05_CatchLanding",Vector2(1120,1140),Vector2i(200,24))
    lesson(level,"LiftLessonCanvas",Vector2(1190,1085),Vector2i(710,420))
    platform.set_meta("lesson_arrow_start",Vector2(220,135))
    platform.set_meta("lesson_arrow_end",Vector2(220,15))

static func gear(level,title:String,center:Vector2,pitch:float,teeth:int,material:int,phase:float):
    # 圆齿灯笼轮：齿冠与辐条都是普通墨水，圆角为像素碰撞留出脱离空间。
    var tooth_radius=12.0
    var tip_circle=pitch+4.0
    var radius=tip_circle+tooth_radius
    var extent=ceili(radius)+2
    var im=image(Vector2i(extent*2+1,extent*2+1))
    var core=pitch*0.85
    var ends=[]
    for index in teeth: ends.append(Vector2.from_angle(phase+TAU*index/teeth)*tip_circle)
    for y in im.get_height():
        for x in im.get_width():
            var point=Vector2(x-extent,y-extent)
            var inside=point.length_squared()<=core*core
            if not inside:
                for end in ends:
                    if point.distance_squared_to(end)<=tooth_radius*tooth_radius or point.distance_squared_to(Geometry2D.get_closest_point_to_segment(point,end.normalized()*(core-4),end))<=49.0:
                        inside=true
                        break
            if inside: fill(im,Rect2i(x,y,1,1),material)
    var node=body(level,title,center-Vector2(extent,extent),im)
    node.gear_centers=[Centers.make(Vector2(extent,extent),radius,material)]
    return node

static func sixth(level):
    var power=rect(level,"BG06_RedSource",Vector2(858,174),Vector2i(32,32),P.RED.id)
    power.infinite_fuel_body=true
    var shaft=rect(level,"BG06_YellowPowerShaft",Vector2(890,176),Vector2i(154,28),P.YELLOW.id)
    var driver=gear(level,"BG06_DriveGear",Vector2(1024,190),96,12,P.BLACK.id,0)
    var follower=gear(level,"BG06_FollowerGear",Vector2(1270,190),144,18,P.YELLOW.id,PI/18)
    var bearing=rect(level,"BG06_FollowerBearing",Vector2(1258,178),Vector2i(24,24))
    axle(level,"BG06_DriveAxle",driver,shaft,Vector2(1024,190),P.BLACK.id,P.YELLOW.id)
    axle(level,"BG06_FollowerAxle",follower,bearing,Vector2(1270,190),P.YELLOW.id,P.BLACK.id)
    wire(level,"BG06_ShaftWire",shaft,[[Vector2(0,14),Vector2(26,14)],[Vector2(64,14),Vector2(144,14)]],15)
    var c=Vector2(114,114)
    wire(level,"BG06_WheelWire",driver,[[c,c+Vector2(-40,60)]],15)
    var door=image(Vector2i(64,272))
    fill(door,Rect2i(0,32,64,4))
    fill(door,Rect2i(0,32,4,240))
    fill(door,Rect2i(60,32,4,240))
    fill(door,Rect2i(0,268,64,4))
    fill(door,Rect2i(26,0,12,272))
    var gate=body(level,"BG06_Gate",Vector2(1454,209),door)
    # 齿条和门是同一块连续黑墨，齿面只通过接触带动门。
    var rack=image(Vector2i(46,291))
    fill(rack,Rect2i(40,0,6,291))
    var pitch=TAU*148.0/18.0
    for index in 6:
        var cy=pitch*(float(index)+0.5)
        for y in rack.get_height():
            for x in range(44):
                if Vector2(x-12,y-cy).length_squared()<=144.0 or (absf(y-cy)<=7 and x>=12): fill(rack,Rect2i(x,y,1,1))
    shape(level,gate,rack,Vector2(-50,-19),"RackPixels")
    var coupling=image(Vector2i(42,8))
    fill(coupling,Rect2i(0,0,42,8))
    shape(level,gate,coupling,Vector2(-10,32),"RackCoupling")
    rect(level,"BG06_Walkway",Vector2(1110,481),Vector2i(460,20))
    rect(level,"BG06_DrawingStep",Vector2(840,385),Vector2i(120,96))
    rect(level,"BG06_Guide",Vector2(1478,54),Vector2i(16,230),P.YELLOW.id)
    rect(level,"BG06_RackGuide",Vector2(1440,-30),Vector2i(14,390),P.YELLOW.id)
    var rack_rail=Rail.new()
    rack_rail.name="BG06_RackRail"
    rack_rail.saved_a=Vector2(1447,-20)
    rack_rail.saved_b=Vector2(1447,350)
    rack_rail.rail_width=14
    own(level,rack_rail)
    var rack_pin=Pin.new()
    rack_pin.name="BG06_RackPin"
    rack_pin.saved_source=Vector2(1447,199)
    rack_pin.saved_position=rack_pin.saved_source
    own(level,rack_pin)
    var rail=Rail.new()
    rail.name="BG06_GateRail"
    rail.saved_a=Vector2(1486,64)
    rail.saved_b=Vector2(1486,274)
    rail.rail_width=16
    own(level,rail)
    var pin=Pin.new()
    pin.name="BG06_GatePin"
    pin.saved_source=Vector2(1486,251)
    pin.saved_position=pin.saved_source
    own(level,pin)
    rect(level,"BG06_UpperStop",Vector2(1470,75),Vector2i(32,13),P.YELLOW.id)
    lesson(level,"FinalLessonCanvas",Vector2(850,20),Vector2i(710,595))
    driver.set_meta("lesson_arrow_start",c+Vector2(-40,60))
    driver.set_meta("lesson_arrow_end",c+Vector2(-40,-60))

static func apply(level):
    clear_old(level)
    fifth(level)
    sixth(level)
    level.set_meta("blue_ascent_final_lessons",1)
    print("[FinalLessons] ordinary parallelogram, conductive yellow lever, physical gear pair and rack gate")
