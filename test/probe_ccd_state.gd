extends SceneTree
## CCD 到底开没开（运行时实测）。
##   godot --headless --path . --script res://test/probe_ccd_state.gd
##
## ⚠️ 探针只读**确定存在**的旋钮。挂住的机制很隐蔽：任何一个运行时错误都会让
##    协程死掉 -> 走不到 quit() -> 进程不退；而输出走管道**有缓冲**，症状就是
##    "一个字都没打印"，看着像引擎卡死。要排查就把输出重定向到文件（*> out.txt）。
##    （旧名字 max_linear_velocity 现在叫 rp_max_linear_velocity，点号访问不存在
##    就是这种死法 —— 而 w.get("...") 在这里也报错，原因没查清。）
const MAIN := preload("res://map/main.tscn")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: Node = MAIN.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var w = scene.world
	print("=== CCD 实测 ===")
	print("  ccd_enabled=%s  ccd_auto=%s  rp_ccd_substeps=%d  ccd_max_motion=%.1f" % [
		str(w.ccd_enabled), str(w.ccd_auto), w.rp_ccd_substeps, w.ccd_max_motion])
	print("  判定：%s" % ("CCD 开着（两层都开）" if (w.ccd_enabled and w.rp_ccd_substeps > 0)
		else "CCD 关着（两层都关）—— 检查 physics_step.gd 的引擎配置。"))
	quit()
