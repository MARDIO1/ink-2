extends "res://test/test_blue_ascent_linkages.gd"
func remaining() -> void:
	feet.hand_control.set_grip(false)
	runtime.get_node("PhysicsStep").freeze_view_scale=100.0
	await frames(90)
	check(level.get_node("BG06_Gate").body.position.y>200,"yellow compression spring leaves unpowered gate closed")
	await anti_push()
	yellow_link("CrateLessonCanvas",Vector2(1252,1740),Vector2(1270,1740),12)
	arrow("BridgeLessonCanvas","BG02_Bridge",Vector2(414,20),Vector2(270,20),7)
	check(motor_for("BG02_Bridge")!=null,"normal 7px bridge arrow is supported")
	arrow("CrateLessonCanvas","BG04_Tall",Vector2(126,104),Vector2(20,104),12)
	check(motor_for("BG04_Tall")!=null,"default 12px crate arrow is supported")
	for i in 40:
		await frames(30)
		if i%5==4:
			for title in ["BG02_Bridge","BG04_Tall","BG04_Short"]:
				var motor=motor_for(title)
				print("SEAL_DRIVE ",i," ",title," x=",level.get_node(title).body.position.x," force=",motor.applied_force if motor!=null else 0)
	check(level.get_node("BG02_Bridge").body.position.x<870,"powered bridge extends after releasing yellow seal")
	check(level.get_node("BG04_Tall").body.position.x<745,"powered high box releases seal and reaches dock")
	check(level.get_node("BG04_Short").body.position.x<980,"tow spring releases short-box seal and forms steps")
