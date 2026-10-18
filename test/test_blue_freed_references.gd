extends SceneTree
## 回归：蓝色墨水系统里"对已释放对象取 id"不能再崩溃。
##
## 现场 bug：碰到蓝墨水（瓶子吸蓝、电机烧毁/碎裂）后，缓存里还留着已释放的电机/形状，
## 刷新接触时 `entry.get_instance_id()` 抛
## `Attempt to call function 'get_instance_id' in base 'previously freed'`。

const EnergyFlow := preload("res://ink/blue/src/energy_flow.gd")

var checks := 0
var failures := 0


## 最小替身：`_revision` 只读 `shapes` 数组和每个形状的 `revision`。
class FakeShape extends Node2D:
	var revision := 7


class FakeBody extends Node2D:
	var shapes: Array = []


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[BlueFreed] %s %s" % ["PASS" if ok else "FAIL", label])


func _run() -> void:
	var flow = EnergyFlow.new()

	# 1) 过滤已释放的电机条目：不能崩，且只留活的。
	var live := Node2D.new()
	root.add_child(live)
	var dead := Node2D.new()
	root.add_child(dead)
	dead.free()
	check("已释放的电机被摘掉", flow.drop_dead_entries.call([dead, live], 0) == [live])

	# 2) 目标电机自己已释放（dead_id 命中活实例的 id）也要能被摘掉。
	check("按 id 摘掉指定电机", flow.drop_dead_entries.call([live], live.get_instance_id()).is_empty())

	# 3) 全是已释放对象时返回空数组，而不是抛错。
	check("全失效返回空", flow.drop_dead_entries.call([dead], 12345).is_empty())

	# 4) `_revision` 跳过已释放形状：body.shapes 里残留死形状时不再崩。
	var body := FakeBody.new()
	root.add_child(body)
	var shape := FakeShape.new()
	body.add_child(shape)
	body.shapes = [dead, shape]
	var revision: Array = flow.call("_revision", body)
	check("_revision 跳过死形状", revision.size() == 2 and revision[1] == 7)

	live.queue_free()
	body.queue_free()
	await process_frame
	print("[BlueFreed] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
