extends Node
## 删除前保存红墨事件，下一固定步反应；没有独立的撞击阈值或点火扫描。
const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const Query = preload("res://addons/pixel_destruction/physics/query.gd")
const RED_ID: int = 8

## 引爆门槛使用 red.tres 的材料强度，不另设点火阈值。
@export_group("爆炸调参")
@export_range(0.0, 1.0, 0.01) var propagation_decay: float = 0.9
@export var impulse_per_pixel: float = 300000.0
## 爆炸伤害与实际推力分开调参，不修改普通碰撞伤害。
@export_range(0.0, 2.0, 0.01) var damage_multiplier: float = 0.05
@export_range(0.0, 8.0, 0.1) var impulse_multiplier: float = 2.0
@export var blast_radius: float = 48.0
@export_range(4, 64, 4) var ray_count: int = 32
## 爆炸事件归组尺寸，不改变引擎 8×8 像素存储。
@export_range(8, 64, 8) var event_chunk_size: int = 64

var _pending: Array = []
var _profile_enabled: bool = false
var _profile: Dictionary = {}


func set_profile_enabled(enabled: bool) -> void:
	_profile_enabled = enabled
	_profile.clear()


func take_profile() -> Dictionary:
	var result: Dictionary = _profile.duplicate()
	_profile.clear()
	return result


## 裂纹触及红墨后，将同一分组内全部红墨加入删除计划；其他材料不额外删除。
## 必须在 fracture 前调用，事件能量按本次实际消耗的全部红像素计算。
func observe_removals(body: PBody, removals: Dictionary, retention: float = 1.0) -> void:
	var start: int = Time.get_ticks_usec() if _profile_enabled else 0
	var groups: Dictionary = {}
	var size: int = maxi(1, event_chunk_size)
	for shape in removals:
		for cell: Vector2i in removals[shape]:
			if shape.get_pixel(cell.x, cell.y) != RED_ID:
				continue
			var key: Vector2i = Vector2i(floori(float(cell.x) / size), floori(float(cell.y) / size))
			if not groups.has(key):
				groups[key] = {"center": Vector2.ZERO, "count": 0, "cells": []}
			groups[key].center += Vector2(cell) + Vector2(0.5, 0.5)
			groups[key].count += 1
			groups[key].cells.append(Vector2(cell) + Vector2(0.5, 0.5))
	for key: Vector2i in groups:
		var group: Dictionary = groups[key]
		var mean: Vector2 = group.center / float(group.count)
		var origin: Vector2 = group.cells[0]
		for cell: Vector2 in group.cells:
			if cell.distance_squared_to(mean) < origin.distance_squared_to(mean):
				origin = cell
		var consumed: int = 0
		var region: Rect2i = Rect2i(key * size, Vector2i.ONE * size)
		for shape in body.shapes:
			var bounds: Rect2i = shape.local_aabb().intersection(region)
			if not bounds.has_area():
				continue
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					if shape.get_pixel(x, y) != RED_ID:
						continue
					if not removals.has(shape):
						removals[shape] = {}
					removals[shape][Vector2i(x, y)] = true
					consumed += 1
		_pending.append({"body": body, "local": origin,
			"energy": float(consumed) * retention})
		if _profile_enabled:
			_profile.reacted_cells = _profile.get("reacted_cells", 0) + consumed
	if _profile_enabled:
		_profile.observe_us = _profile.get("observe_us", 0) + Time.get_ticks_usec() - start


func resolve(world, damage, player_body: PBody, protected_bodies: Array) -> Dictionary:
	var start: int = Time.get_ticks_usec() if _profile_enabled else 0
	var result: Dictionary = {"removals": {}, "player_damage": 0.0,
		"bursts": {}, "impulses": [], "reaction_scale": propagation_decay}
	var current: Array = _pending
	_pending = []
	for event in current:
		# fracture 保留坐标变换；原体删光也不会丢失这次爆炸。
		var center: Vector2 = event.body.to_world(event.local)
		_blast(world, damage, center, event.energy, player_body, protected_bodies, result)
	if _profile_enabled:
		_profile.resolve_us = _profile.get("resolve_us", 0) + Time.get_ticks_usec() - start
	return result


func _blast(world, damage, center: Vector2, energy: float,
		player_body: PBody, protected_bodies: Array, result: Dictionary) -> void:
	if blast_radius <= 0.0 or ray_count <= 0:
		return
	var candidates: Array = Query.aabb_bodies(Rect2(center - Vector2.ONE * blast_radius,
		Vector2.ONE * blast_radius * 2.0))
	if _profile_enabled:
		_profile.blasts = _profile.get("blasts", 0) + 1
		_profile.candidates = _profile.get("candidates", 0) + candidates.size()
	var ray_impulse: float = impulse_per_pixel * energy / float(ray_count)
	# 第一轮只生成伤害；统一破坏后按同一组方向再查询一次并施力。
	result.impulses.append({"origin": center, "radius": blast_radius,
		"ray_count": ray_count, "impulse": ray_impulse * impulse_multiplier})
	for i in ray_count:
		var direction: Vector2 = Vector2.from_angle(TAU * float(i) / float(ray_count))
		var ray_start: int = Time.get_ticks_usec() if _profile_enabled else 0
		var hit = raycast_candidates(candidates, center, direction, blast_radius)
		if _profile_enabled:
			_profile.rays = _profile.get("rays", 0) + 1
			_profile.raycast_us = _profile.get("raycast_us", 0) + Time.get_ticks_usec() - ray_start
		if not hit.hit:
			continue
		var point: Vector2 = hit.point + direction * 0.001
		var damage_start: int = Time.get_ticks_usec() if _profile_enabled else 0
		damage.apply_impulse_damage(world, hit.body, point, direction, ray_impulse * damage_multiplier,
			player_body, protected_bodies, result, RED_ID)
		if _profile_enabled:
			_profile.ray_hits = _profile.get("ray_hits", 0) + 1
			_profile.damage_us = _profile.get("damage_us", 0) + Time.get_ticks_usec() - damage_start


## AABB 先裁到入点，再复用引擎细射线 DDA，避免对小碎片遍历整段空域。
static func raycast_candidates(candidates: Array, origin: Vector2, direction: Vector2,
		max_distance: float):
	var best = Query.Hit.new()
	best.distance = max_distance
	for body in candidates:
		var near: float = 0.0
		var far: float = best.distance
		for axis in 2:
			var lo: float = body.aabb.position[axis]
			var hi: float = body.aabb.end[axis]
			if absf(direction[axis]) < 0.000001:
				if origin[axis] < lo or origin[axis] > hi:
					far = -1.0
					break
				continue
			var a: float = (lo - origin[axis]) / direction[axis]
			var b: float = (hi - origin[axis]) / direction[axis]
			near = maxf(near, minf(a, b))
			far = minf(far, maxf(a, b))
		if far < near:
			continue
		var offset: float = maxf(0.0, near - 0.001)
		var hit = Query._ray_vs_body(body, origin + direction * offset,
			direction, minf(far + 0.001, best.distance) - offset, 0.0)
		if hit.hit and hit.distance + offset < best.distance:
			hit.distance += offset
			best = hit
	return best
