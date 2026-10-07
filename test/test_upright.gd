extends SceneTree
## 回复力矩的验收：真实主场景 + 真 Rapier。
##
## 覆盖六件事：
##   1. 默认值已开启，并且是在真实玩家几何上标定过的数值；
##   2. 正常撞击（kick=3 rad/s）不倒地、回到竖直、尾巴不抖；
##   3. 极限翻滚（kick=12 rad/s）也能收住；
##   4. 关掉控制器（k=d=0）后同样的撞法必须摔倒 —— 证明回正不是别的东西做的；
##   5. 腾空（连续 support == null）时力矩恒为 0；
##   6. 手抓住世界、脚仍踩在地上时力矩照常出力（抓握不吞回复力矩）；
##   另外每条路径都要求 |力矩| <= max_upright_torque。

const MAIN = preload("res://map/main.tscn")

var failures := 0
var checks := 0
var _scene
var _feet
var _body
var _cap := 0.0


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])


func _settle(frames: int) -> void:
	for i in frames:
		await physics_frame


## 一次 kick：240 帧观察 + 60 帧尾巴窗口。
func _kick(spin: float) -> Dictionary:
	_body.angular_velocity = spin
	var peak := 0.0
	var fall := -1
	var over_cap := false
	var tau := 0.0
	for i in 240:
		await physics_frame
		peak = maxf(peak, absf(_body.rotation))
		tau = maxf(tau, absf(_feet.debug_upright_torque))
		over_cap = over_cap or absf(_feet.debug_upright_torque) > _cap * (1.0 + 1e-6)
		if fall < 0 and absf(_body.rotation) > 1.0:
			fall = i
	var tail_rot := 0.0
	var tail_w := 0.0
	var tail_jerk := 0.0
	var previous := 0.0
	for i in 60:
		await physics_frame
		tail_rot = maxf(tail_rot, absf(_body.rotation))
		tail_w = maxf(tail_w, absf(_body.angular_velocity))
		tail_jerk = maxf(tail_jerk, absf(_body.angular_velocity - previous))
		previous = _body.angular_velocity
	return {"peak": peak, "fall": fall, "tau": tau, "over_cap": over_cap,
		"tail_rot": tail_rot, "tail_w": tail_w, "tail_jerk": tail_jerk}


## 一份主场景：关掉破坏（砸出来的坑会让下一次落地找不到支撑），手也不参与。
func _open() -> void:
	_scene = MAIN.instantiate()
	_scene.auto_step = false
	root.add_child(_scene)
	await process_frame
	await process_frame
	_feet = _scene.get_node("Player/PlayerInput")
	_body = _scene.get_node("Player").body
	_scene.get_node("Player/Arm/Hand/HandControl").set_physics_process(false)
	_scene.get_node("CollisionDamage").min_approach = 1.0e12


func _run() -> void:
	await _open()
	_scene.auto_step = true
	await _settle(90)
	_cap = _feet.max_upright_torque

	_check("tuned defaults are enabled", _feet.upright_stiffness > 0.0 and _feet.upright_damping > 0.0 and _cap > 0.0)
	_check("a balanced player gets no torque", absf(_body.rotation) < 0.01 and absf(_feet.debug_upright_torque) < 1.0e6)

	var soft: Dictionary = await _kick(3.0)
	print("KICK 3  peak=%.3f fall=%d tau_MN=%.0f tail_rot=%.3f tail_w=%.4f tail_jerk=%.4f"
		% [soft.peak, soft.fall, soft.tau / 1.0e6, soft.tail_rot, soft.tail_w, soft.tail_jerk])
	_check("a normal knock engages the controller", soft.tau > 1.0e6)
	_check("a normal knock never tips the player over", soft.fall == -1)
	_check("the player comes back to upright", soft.tail_rot < 0.05)
	_check("coming back does not oscillate", soft.tail_w < 0.01 and soft.tail_jerk < 0.01)
	_check("a normal knock respects the torque cap", not soft.over_cap)

	var hard: Dictionary = await _kick(12.0)
	print("KICK 12 peak=%.3f fall=%d tau_MN=%.0f tail_rot=%.3f tail_w=%.4f tail_jerk=%.4f"
		% [hard.peak, hard.fall, hard.tau / 1.0e6, hard.tail_rot, hard.tail_w, hard.tail_jerk])
	_check("a full tumble ends upright", hard.tail_rot < 0.05)
	_check("a full tumble does not jitter", hard.tail_w < 0.02 and hard.tail_jerk < 0.02)
	_check("a full tumble respects the torque cap", not hard.over_cap)

	# 关掉控制器：同样 kick=3 必须摔倒，否则说明回正是别的东西做的。
	_feet.upright_stiffness = 0.0
	_feet.upright_damping = 0.0
	await _settle(60)
	var off: Dictionary = await _kick(3.0)
	print("OFF 3   peak=%.3f fall=%d tail_rot=%.3f" % [off.peak, off.fall, off.tail_rot])
	_check("without the controller the same knock tips the player over", off.fall >= 0)
	_check("switched off means exactly zero torque", absf(off.tau) == 0.0)

	await _teardown()
	await _test_airborne()
	await _test_grip()
	print("[Upright] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


## 腾空要求：自己跳起来再自旋，整个滞空期间每一帧都不许有回复力矩。
## 用起跳速度而不是瞬移：瞬移会让引擎把位移差当成速度，人会被甩出去。
func _test_airborne() -> void:
	await _open()
	_scene.auto_step = true
	await _settle(60)
	_body.linear_velocity = Vector2(0.0, -360.0)
	_body.angular_velocity = 5.0
	var streak := 0
	var sampled := 0
	var torque := 0.0
	var landed := false
	for i in 300:
		await physics_frame
		if _feet.support == null:
			streak += 1
			# 施力矩那一帧用的支撑可能来自上一帧；连续两帧无支撑才确认真的腾空。
			if streak >= 2:
				sampled += 1
				torque = maxf(torque, absf(_feet.debug_upright_torque))
		else:
			streak = 0
			landed = true
	print("AIRBORNE frames=%d torque=%.4f landed=%s y=%.1f" % [sampled, torque, str(landed), _body.com_world().y])
	_check("the hopping player really goes airborne", sampled > 60)
	_check("no upright torque while airborne", torque == 0.0)
	_check("the airborne player lands back on the ground", landed and _body.com_world().y < 400.0)
	await _teardown()


## 手抓住世界、脚也踩在地上：抓握不许把回复力矩吞掉 —— 脚有支撑就照常出力。
func _test_grip() -> void:
	_scene = MAIN.instantiate()
	_scene.auto_step = false
	_scene.get_node("Player").position = Vector2(-12, 115)
	_scene.get_node("Player/Arm/Hand/HandControl").rest_offset = Vector2(0, 80)
	root.add_child(_scene)
	await process_frame
	await process_frame
	_feet = _scene.get_node("Player/PlayerInput")
	_body = _scene.get_node("Player").body
	var hand = _scene.get_node("Player/Arm/Hand/HandControl")
	_scene.get_node("CollisionDamage").min_approach = 1.0e12
	hand.set_grip(true)
	var welded: bool = hand._begin_grab(_scene.get_node("Ground").body, Vector2(0, 231))
	hand.set_target_world(Vector2(60, 211))
	_scene.auto_step = true
	await _settle(30)
	_body.angular_velocity = 3.0
	var supported := 0
	var gripped := 0
	var torque := 0.0
	for i in 60:
		await physics_frame
		if _feet.support != null:
			supported += 1
		if hand.grabbed_body != null:
			gripped += 1
			torque = maxf(torque, absf(_feet.debug_upright_torque))
	print("GRIP frames=%d support=%d torque=%.4f" % [gripped, supported, torque])
	_check("the hand really holds the world", welded and gripped >= 55)
	_check("the grabbing player still stands on the ground", supported >= 30)
	_check("holding the world does not suppress the upright torque", torque > 1.0e6)
	await _teardown()


func _teardown() -> void:
	_scene.auto_step = false
	_scene.get_node("Player/PlayerInput").set_physics_process(false)
	_scene.get_node("Player/Arm/Hand/HandControl").set_physics_process(false)
	for body in _scene.world.bodies.duplicate():
		for shape in body.shapes:
			shape.owner_body = null
		_scene.world.remove_body(body)
		body.shapes.clear()
	_scene.world.contacts.clear()
	_scene.world._rp = null
	_scene.queue_free()
	await process_frame
