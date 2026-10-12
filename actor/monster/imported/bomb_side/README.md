炸弹狂来自 D:/2D Admination/Finished/炸弹狂/unified，导入的是已调整位置、镜像并加上遮罩的版本。

游戏角色场景：scenes/bomb_side_character.tscn。
地图入口：res://actor/monster/bomb_side.tscn。
创造模式的工具面板中选择“炸弹狂”后，可在地图单击放置。

保留五根原始骨骼和 idle/walk/throw 动画。遮罩从前到后为左手、左脚、身体、右脚、右手；前置轮廓剔除后置角色像素，透明内部显示真实背景。
scripts/bomb_side_rig.gd 同步遮罩变换和翻转；shaders/part_occlusion.gdshader 执行遮挡。
此场景沿用炸弹狂的视觉受击机制，未启用小兵和盾兵的关节刚体。

验证：Godot --headless --path D:/Ink --script res://test/test_bomb_side_rig.gd。
