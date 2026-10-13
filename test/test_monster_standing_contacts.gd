extends SceneTree

const Contacts := preload("res://root/src/monster_contacts.gd")
const Body := preload("res://addons/pixel_destruction/physics/pbody.gd")
const World := preload("res://addons/pixel_destruction/physics/pworld.gd")
var failures := 0

class Receiver extends Node2D:
	var minimum_hit_speed := 15.0
	var _dead := false
	var _hit_cooldown := 0.0
	var calls := 0
	var health := 2000.0
	var recovery := 0.0
	func receive_contact_impact(_point: Vector2, impulse: Vector2, _body, attack: bool) -> void:
		calls += 1
		recovery = 0.45
		if attack:
			health -= impulse.length() * 0.001

func _initialize() -> void:
	run.call_deferred()

func check(label: String, condition: bool) -> void:
	print("[StandingContacts] ", label, ": ", "PASS" if condition else "FAIL")
	if not condition:
		failures += 1

func run() -> void:
	var rule := Contacts.new()
	root.add_child(rule)
	var receiver := Receiver.new()
	root.add_child(receiver)
	var world := World.new()
	world.gravity = Vector2(0, 1470)
	world.last_substeps = 16
	var monster := Body.new()
	monster.id = 1
	monster.tags["monster_receiver"] = weakref(receiver)
	var player := Body.new()
	player.id = 2
	player.pre_vy = 20.0
	var hand := Body.new()
	hand.id = 3
	var context := {"world": world, "player_body": player}
	var point := {"position": Vector2.ZERO, "normal": Vector2.UP, "impulse": 100000.0, "tangent_impulse": 100000.0}
	var contact := {"a": monster, "b": player, "points": [point], "approach": 1000.0}
	var started := Time.get_ticks_usec()
	for frame in 2000:
		rule.resolve_contacts(context, [contact])
	check("standing solver pressure does not damage or deform enemy", receiver.health == 2000.0 and receiver.calls == 0 and receiver.recovery == 0.0)
	print("[StandingContacts] 2000 support callbacks us=", Time.get_ticks_usec() - started)
	# 交换接触两端和法向，仍是同一站立事件。
	point.normal = Vector2.DOWN
	contact.a = player
	contact.b = monster
	rule.resolve_contacts(context, [contact])
	check("body order does not change support handling", receiver.calls == 0)
	# 完全离开后重新高速踩下，仅触发一次真实撞击。
	for frame in 200:
		rule.resolve_contacts(context, [])
	player.pre_vy = 400.0
	point.impulse = 1000.0
	point.tangent_impulse = 0.0
	for frame in 100:
		rule.resolve_contacts(context, [contact])
	check("fast landing is one impact, not repeated support damage", receiver.calls == 1 and receiver.health == 1999.0)
	# 手部攻击是另一接触对，仍能结算。
	contact.a = monster
	contact.b = hand
	point.normal = Vector2.RIGHT
	rule.resolve_contacts(context, [contact])
	check("hand strike still damages enemy", receiver.calls == 2 and receiver.health == 1998.0)
	for frame in 500:
		rule.resolve_contacts(context, [contact])
	check("held hand does not retrigger same collision", receiver.calls == 2)
	for frame in 200:
		rule.resolve_contacts(context, [])
	rule.resolve_contacts(context, [contact])
	check("separate and strike again rearms contact", receiver.calls == 3)
	for frame in 1000:
		rule.resolve_contacts(context, [])
	check("inactive pair cache is reclaimed", rule._contact_pairs.is_empty())
	# 重力方向改变时同样区分承重，避免硬编码世界竖直方向。
	world.gravity = Vector2.RIGHT * 1470
	player.pre_vx = 20.0
	player.pre_vy = 0.0
	point.normal = Vector2.LEFT
	contact.b = player
	rule.resolve_contacts(context, [contact])
	check("support respects gravity direction", receiver.calls == 3)
	# 出生时同伴盾牌挤靠不得触发受击或像素破坏。
	var ally := Body.new()
	ally.id = 4
	var ally_receiver := Receiver.new()
	root.add_child(ally_receiver)
	ally.tags["monster_receiver"] = weakref(ally_receiver)
	contact.b = ally
	point.normal = Vector2.RIGHT
	rule.resolve_contacts(context, [contact])
	check("friendly contact does not release either pose", receiver.calls == 3 and ally_receiver.calls == 0)
	var damage: Node = load("res://root/src/impact_damage.gd").new()
	root.add_child(damage)
	var effects: Dictionary = damage.calculate(world, [contact])
	check("friendly contact does not fracture shields", effects.removals.is_empty())
	var floor_body := Body.new()
	floor_body.is_static = true
	contact.b = floor_body
	point.normal = Vector2.DOWN
	effects = damage.calculate(world, [contact])
	check("monster landing does not fracture terrain", effects.removals.is_empty())
	damage.free()
	ally_receiver.free()
	rule.free()
	receiver.free()
	print("STANDING_CONTACTS: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
