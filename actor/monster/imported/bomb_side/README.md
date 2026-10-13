炸弹狂来自 D:/2D Admination/Finished/炸弹狂/unified，当前使用重新绘制的加粗版本。五张素材已归一化到原画布，肩部、髋部骨骼关节和骨骼长度已重新标定，并同步适配动画零位与遮罩。

游戏角色场景：scenes/bomb_side_character.tscn。
地图入口：res://actor/monster/bomb_side.tscn。
创造模式的工具面板中选择“炸弹狂”后，可在地图单击放置。

保留五根原始骨骼和 idle/walk/throw 动画。遮罩从前到后为左手、左脚、身体、右脚、右手；前置轮廓剔除后置角色像素，透明内部显示真实背景。
scripts/bomb_side_rig.gd 同步遮罩变换和翻转；shaders/part_occlusion.gdshader 执行遮挡。
地图角色使用与小兵、盾兵相同的躯干及四肢五部件关节刚体，支持实体碰撞、受击回正、编辑冻结和缩放重建。碰撞轮廓计入非居中原点及素材翻转，纯视觉场景仍可单独预览动画。

碰撞回归：Godot --headless --path D:/Ink --script res://test/test_monster_physics.gd -- --bomb-side。

验证：Godot --headless --path D:/Ink --script res://test/test_bomb_side_rig.gd。
