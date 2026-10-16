extends SceneTree
const Flow := preload("res://ink/blue/src/energy_flow.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
var checks := 0
var failures := 0

class Body:
	extends RefCounted
	var position := Vector2.ZERO
	var rotation := 0.0
	var shapes: Array = []
	func to_world(p: Vector2) -> Vector2:
		return p.rotated(rotation) + position
	func to_local(p: Vector2) -> Vector2:
		return (p - position).rotated(-rotation)

class Sink:
	extends RefCounted
	var energy := 0.0
	func receive_energy(amount: float) -> float:
		energy += amount
		return amount

func _initialize() -> void:
	call_deferred("run")

func check(label: String, condition: bool) -> void:
	checks += 1
	failures += 0 if condition else 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])

func wire_rects(rects: Array):
	var wire := Wire.new()
	var pixels := {}
	for rect: Rect2i in rects:
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				pixels[Vector2i(x, y)] = true
	wire.cells = PackedVector2Array(pixels.keys())
	wire.body = Body.new()
	root.add_child(wire)
	return wire

func connect_sink(flow, wire, rect: Rect2i):
	var sink := Sink.new()
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			flow.consumers.get_or_add(wire, {})[Vector2i(x, y)] = [sink]
	return sink

func advance(flow, wire, steps: int) -> void:
	for i in steps:
		flow.advance([wire], 1.0 / flow.speed)

func run() -> void:
	for width in [1, 7, 17]:
		var wire = wire_rects([Rect2i(0, 0, 120, width)])
		var flow := Flow.new()
		var sink = connect_sink(flow, wire, Rect2i(110, 0, 1, width))
		for y in width:
			flow.inject(wire, Vector2i(0, y), 1, 100.0)
		advance(flow, wire, 115)
		check("straight width %d neither branches internally nor shorts" % width, flow.stats.shorts == 0 and is_equal_approx(sink.energy, width * 100.0))
		wire.queue_free()
	var bend = wire_rects([Rect2i(0, 0, 51, 7), Rect2i(44, 0, 7, 70)])
	var flow := Flow.new()
	var sink = connect_sink(flow, bend, Rect2i(44, 60, 7, 1))
	for y in 7:
		flow.inject(bend, Vector2i(0, y), 1, 100.0)
	advance(flow, bend, 140)
	check("thick bend transports energy without self short", sink.energy > 0.0 and flow.stats.shorts == 0)
	check("bend energy ledger balances", is_equal_approx(flow.stats.injected, flow.stats.consumed + flow.stats.lost + flow.stored_energy()))
	var diagonal_rects: Array = []
	for i in 80:
		diagonal_rects.append(Rect2i(i, i, 7, 7))
	var diagonal = wire_rects(diagonal_rects)
	flow = Flow.new()
	sink = connect_sink(flow, diagonal, Rect2i(80, 79, 7, 8))
	flow.inject(diagonal, Vector2i(0, 3), 1, 100.0)
	advance(flow, diagonal, 200)
	check("thick diagonal staircase transports without self short", flow.stats.shorts == 0 and sink.energy > 0.0)
	var tee = wire_rects([Rect2i(0, 40, 100, 7), Rect2i(44, 0, 7, 90)])
	flow = Flow.new()
	var top = connect_sink(flow, tee, Rect2i(44, 1, 7, 1))
	var bottom = connect_sink(flow, tee, Rect2i(44, 88, 7, 1))
	var right = connect_sink(flow, tee, Rect2i(98, 40, 1, 7))
	for y in range(40, 47):
		flow.inject(tee, Vector2i(0, y), 1, 100.0)
	advance(flow, tee, 160)
	check("thick fork delivers to all forward branches", top.energy > 0 and bottom.energy > 0 and right.energy > 0 and flow.stats.shorts == 0)
	check("thick fork splits equally by geometric outlet", absf(top.energy - right.energy) < 0.01 and absf(bottom.energy - right.energy) < 0.01)
	check("fork never duplicates energy", is_equal_approx(flow.stats.injected, flow.stats.consumed + flow.stats.lost + flow.stored_energy()))
	var narrow = wire_rects([Rect2i(0, 0, 40, 7), Rect2i(40, 3, 30, 1), Rect2i(70, 0, 50, 7)])
	flow = Flow.new()
	flow.pixel_power = 1000.0
	sink = connect_sink(flow, narrow, Rect2i(110, 0, 1, 7))
	for y in 7:
		flow.inject(narrow, Vector2i(0, y), 1, 100.0)
	advance(flow, narrow, 160)
	check("narrow then wide does not restore lost energy", sink.energy > 0.0 and sink.energy <= 100.001)
	for separation in [19, 20]:
		var wire = wire_rects([Rect2i(0, 0, 24, 1)])
		flow = Flow.new()
		flow.inject(wire, Vector2i(1, 0), 1, 100.0, 11)
		flow.inject(wire, Vector2i(separation, 0), 0, 100.0, 22)
		advance(flow, wire, 24)
		check("equal head-on preserves wire in both parity phases %d" % separation, flow.stats.shorts == 0 and wire.mask.size() == 24 and is_equal_approx(flow.stats.injected, flow.stats.consumed + flow.stats.lost + flow.stored_energy()))
	for adjacent in [false, true]:
		for strong_right in [false, true]:
			var wire = wire_rects([Rect2i(0, 0, 50, 1)])
			flow = Flow.new()
			sink = connect_sink(flow, wire, Rect2i(40 if strong_right else 2, 0, 1, 1))
			flow.inject(wire, Vector2i(20, 0), 1, 100.0 if strong_right else 40.0, -42)
			flow.inject(wire, Vector2i(21 if adjacent else 20, 0), 0, 40.0 if strong_right else 100.0, 22)
			advance(flow, wire, 25)
			check("larger opposing current reaches sink adjacent=%s right=%s" % [adjacent, strong_right], is_equal_approx(sink.energy, 100.0) and is_equal_approx(flow.stats.lost, 40.0) and flow.stored_energy() == 0.0 and wire.mask.size() == 50)
	for reverse in [false, true]:
		var wire = wire_rects([Rect2i(0, 0, 50, 1)])
		flow = Flow.new()
		for direction in ([0, 1] if reverse else [1, 0]):
			flow.inject(wire, Vector2i(20, 0), direction, 100.0, direction + 1)
		advance(flow, wire, 1)
		var front: Dictionary = flow.state(wire).front
		check("equal current tie keeps fixed direction independent of injection order %s" % reverse, front.has(Vector2i(21, 0)) and is_equal_approx(flow.stored_energy(), 100.0) and is_equal_approx(flow.stats.lost, 100.0))
	var trail = wire_rects([Rect2i(0, 0, 50, 1)])
	flow = Flow.new()
	sink = connect_sink(flow, trail, Rect2i(45, 0, 1, 1))
	flow.inject(trail, Vector2i(1, 0), 1, 100.0, 11)
	flow.inject(trail, Vector2i(30, 0), 0, 40.0, 22)
	advance(flow, trail, 48)
	check("winner traverses defeated current's reverse visited trail", is_equal_approx(sink.energy, 100.0) and is_equal_approx(flow.stats.lost, 40.0))
	var arrival = wire_rects([Rect2i(0, 0, 50, 1)])
	flow = Flow.new()
	sink = connect_sink(flow, arrival, Rect2i(21, 0, 1, 1))
	flow.inject(arrival, Vector2i(20, 0), 1, 100.0, 11)
	flow.inject(arrival, Vector2i(21, 0), 0, 40.0, 22)
	advance(flow, arrival, 1)
	var before_arrival: bool = sink.energy == 0.0 and is_equal_approx(flow.stored_energy(), 100.0)
	advance(flow, arrival, 1)
	check("defeated current cannot activate a motor before winner arrives", before_arrival and is_equal_approx(sink.energy, 100.0))
	var cross = wire_rects([Rect2i(0, 10, 21, 1), Rect2i(10, 0, 1, 21)])
	flow = Flow.new()
	flow.inject(cross, Vector2i(0, 10), 1, 100.0)
	flow.inject(cross, Vector2i(10, 20), 2, 100.0)
	advance(flow, cross, 24)
	check("perpendicular arrivals merge without short", flow.stats.shorts == 0)
	var line = wire_rects([Rect2i(0, 0, 300, 1)])
	flow = Flow.new()
	flow.speed = 125.5
	flow.inject(line, Vector2i.ZERO, 1, 100.0)
	for frame in 60:
		flow.advance([line], 1.0 / 60.0)
	check("fractional speed keeps distance remainder", flow.clock == 125 and absf(flow.distance_credit - 0.5) < 0.00001 and flow.state(line).front.has(Vector2i(125, 0)))
	var loop = wire_rects([Rect2i(0, 0, 31, 1), Rect2i(0, 20, 31, 1), Rect2i(0, 0, 1, 21), Rect2i(30, 0, 1, 21), Rect2i(-10, 10, 11, 1)])
	flow = Flow.new()
	flow.inject(loop, Vector2i(-10, 10), 1, 100.0, 42)
	advance(flow, loop, 300)
	check("same-source closed loop dissipates without damaging wire", flow.stats.shorts == 0 and loop.mask.size() == 110 and flow.active_cells() == 0 and is_equal_approx(flow.stats.lost, 100.0))
	flow = Flow.new()
	flow.lifetime = 0.01
	flow.inject(loop, Vector2i(-10, 10), 1, 100.0, 42)
	advance(flow, loop, 20)
	check("packet lifetime still bounds loop energy", flow.active_cells() == 0 and is_equal_approx(flow.stats.lost, 100.0) and loop.mask.size() == 110)
	var cut_line = wire_rects([Rect2i(0, 0, 5, 1), Rect2i(6, 0, 25, 1)])
	flow = Flow.new()
	sink = connect_sink(flow, cut_line, Rect2i(20, 0, 1, 1))
	flow.inject(cut_line, Vector2i.ZERO, 1, 100.0)
	flow.advance([cut_line], 1.0)
	check("multiple pixels per update never skip an intermediate cut", sink.energy == 0.0 and flow.active_cells() == 0)
	var first = wire_rects([Rect2i(0, 0, 10, 1)])
	var second = wire_rects([Rect2i(10, 0, 10, 1)])
	flow = Flow.new()
	flow.neighbours[first] = [second]
	flow.neighbours[second] = [first]
	sink = connect_sink(flow, second, Rect2i(18, 0, 1, 1))
	flow.inject(first, Vector2i.ZERO, 1, 100.0)
	for i in 24:
		flow.advance([first, second], 1.0 / flow.speed)
	check("strictly touching independent carriers pass energy", is_equal_approx(sink.energy, 100.0))
	for rotated in [false, true]:
		var a = wire_rects([Rect2i(0, 0, 20, 1)])
		var b = wire_rects([Rect2i(0, 0, 21, 1)] if rotated else [Rect2i(20, 0, 21, 1)])
		if rotated:
			b.body.position = Vector2(41, 1)
			b.body.rotation = PI
		flow = Flow.new()
		flow.neighbours[a] = [b]
		flow.neighbours[b] = [a]
		flow.inject(a, Vector2i(19, 0), 1, 40.0, 11)
		flow.inject(b, Vector2i(20, 0), 1 if rotated else 0, 100.0, 22)
		flow.advance([a, b], 1.0 / flow.speed)
		var front: Dictionary = flow.state(a).front
		check("foreign carrier opposition keeps stronger direction rotated=%s" % rotated, front.has(Vector2i(19, 0)) and is_equal_approx(front[Vector2i(19, 0)][0].x, 100.0) and is_equal_approx(flow.stats.lost, 40.0) and a.mask.size() == 20 and b.mask.size() == 21)
	var ring_input = wire_rects([Rect2i(0, 40, 11, 1)])
	var ring_output = wire_rects([Rect2i(-20, 60, 41, 1)])
	ring_output.body.rotation = PI
	flow = Flow.new()
	flow.bridges[ring_input] = {Vector2i(5, 40): [ring_output, Vector2i(0, 60)]}
	flow.bridges[ring_output] = {Vector2i(0, 60): [ring_input, Vector2i(5, 40)]}
	var through_sink = connect_sink(flow, ring_input, Rect2i(9, 40, 1, 1))
	var left_sink = connect_sink(flow, ring_output, Rect2i(-18, 60, 1, 1))
	var right_sink = connect_sink(flow, ring_output, Rect2i(18, 60, 1, 1))
	flow.inject(ring_input, Vector2i(0, 40), 1, 100.0)
	for i in 40:
		flow.advance([ring_input, ring_output], 1.0 / flow.speed)
	check("passing wire also branches through slip ring", through_sink.energy > 0.0 and left_sink.energy > 0.0 and right_sink.energy > 0.0)
	check("rotated slip ring feeds both local directions without duplicating energy", is_equal_approx(through_sink.energy, 50.0) and is_equal_approx(left_sink.energy, 25.0) and is_equal_approx(right_sink.energy, 25.0) and flow.stats.shorts == 0 and is_equal_approx(flow.stats.injected, flow.stats.consumed + flow.stats.lost + flow.stored_energy()))
	flow = Flow.new()
	flow.inject(first, Vector2i(2, 0), 1, 100.0)
	flow.advance([first], 1.0 / flow.speed)
	var replacement = wire_rects([Rect2i(0, 0, 10, 1)])
	flow.rebind_wire(first, [replacement])
	flow.advance([replacement], 1.0 / flow.speed)
	check("fracture preserves packet age and does not bill a second emission", flow.stats.injected == 100.0 and flow.state(replacement).front.has(Vector2i(4, 0)) and is_equal_approx(flow.stats.lost + flow.stored_energy(), 100.0))
	var large = wire_rects([Rect2i(0, 0, 2, 6000)])
	flow = Flow.new()
	for y in 6000:
		flow.inject(large, Vector2i(0, y), 1, 100.0)
	flow.advance([large], 1.0 / flow.speed)
	check("snapshot grows by live data without repeating simulation", flow.active_cells() == 6000 and flow.clock == 1 and flow.stats.injected == 600000.0)
	check("large fracture readback grows without advancing or dropping directions", flow.state(large).front.size() == 6000 and flow.clock == 1)
	print("BLUE_ENERGY_RESULT checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
