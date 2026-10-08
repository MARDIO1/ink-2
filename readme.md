做好分工，本工程尽量少修改引擎，引擎也ignore了，在外部仓库

分布式模块化，player的贴图就放当Player的tscn旁边，并且给我整理好，src和assest还有doc，doc存放AI给AI看的md

干净就是好，减少测试代码，守卫代码等等；如果有崩溃，不要使用守卫代码避免崩溃，而是让他彻底崩溃暴露问题，修改上游代码。有相同的实现达到类似效果，就使用精简，代码量少得到效果





-----以下是AI写的，如果和上面有冲突，听我的-----
## 目录
- [代码规范](doc/代码规范.md)
- [文件组织](doc/文件组织.md)
- [身体](actor/player/doc/身体.md)
- [脚](actor/player/doc/脚.md)
- [手](actor/player/doc/手.md)
- [墨水](actor/player/doc/墨水.md)
- [生命值](actor/player/doc/生命值.md)
- [画布](actor/canvas/doc/画布.md)
- [创造模式 / 地图编辑器](debug/creative/doc/创造模式.md)
- [烘焙](tools/doc/烘焙.md)
- [验收](test/doc/验收.md)
- [关卡选择](ui/level_select/doc/关卡选择.md)
- [主菜单](ui/menu/doc/主菜单.md)
- [HUD](ui/hud/doc/HUD.md)
- [ESC 菜单](ui/esc/doc/ESC菜单.md)
- [像素打字机对话框](ui/dialogue/doc/对话框.md)
