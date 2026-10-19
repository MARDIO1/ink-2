extends RefCounted
## 离线迁移：只留下现有蓝图格式能够完整表达的普通墨水组件。
const Spring=preload("res://ink/yellow/src/stroke.gd")
const Motor=preload("res://ink/blue/src/motor.gd")

static func apply(level):
    var anchor=level.get_node("BG02_Seal_Anchor")
    anchor.position.x=1828
    for node in level.get_children():
        if node is Motor and node.area<=0:
            node.area=Motor.pixels_for(node.tip,node.brush_width).size()
        if not node is Spring: continue
        if absf(node.saved_anchor_a.y-2951)<1:
            node.name="BG02_Seal"
            node.path[0].x=1840
            node.saved_anchor_a.x=1840
        elif absf(node.saved_anchor_a.y-1590)<1:
            node.name="BG04_TallSeal"
        elif absf(node.saved_anchor_a.y-1700)<1:
            node.name="BG04_ShortSeal"
        if str(node.name) in ["BG02_Seal","BG04_TallSeal","BG04_ShortSeal"]:
            # 预拉量不在通用蓝图格式中，改用原长保险簧；原磨损仍是普通擦除结果。
            node.rest_length=node.saved_anchor_a.distance_to(node.saved_anchor_b)
    level.set_meta("blue_ascent_portable_ink",true)
