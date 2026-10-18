extends SceneTree

func _initialize() -> void:
	var step = load("res://root/src/physics_step.gd").new()
	var world = load("res://addons/pixel_destruction/physics/pworld.gd").new()
	var body = load("res://addons/pixel_destruction/physics/pbody.gd").new()
	world.bodies.append(body)
	var valid: bool = step._minimum_substeps(world) == 1
	body.tags[step.MIN_SUBSTEPS_TAG] = 4
	valid = valid and step._minimum_substeps(world) == 4
	body.frozen = true
	valid = valid and step._minimum_substeps(world) == 1
	body.frozen = false
	body.is_static = true
	valid = valid and step._minimum_substeps(world) == 1
	body.is_static = false
	body.tags.erase(step.MIN_SUBSTEPS_TAG)
	valid = valid and step._minimum_substeps(world) == 1
	step.free()
	print("PHYSICS_SUBSTEP_FLOOR: ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
