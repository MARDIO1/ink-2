做好分工，本工程尽量少修改引擎，引擎也ignore了，在外部仓库

分布式模块化，保持region分块和每个函数注释，player的贴图就放当Player的tscn旁边，并且给我整理好，src和assest还有doc，doc存放AI给AI看的md

干净就是好，减少测试代码，守卫代码等等；如果有崩溃，不要使用守卫代码避免崩溃，而是让他彻底崩溃暴露问题，修改上游代码。有相同的实现达到类似效果，就使用精简，代码量少得到效果


-----以下是AI写的，如果和上面有冲突，听我的-----
## 目录
- [代码规范](doc/代码规范.md)
- [文件组织](doc/文件组织.md)
- [身体](actor/player/doc/身体.md)
- [脚](actor/player/doc/脚.md)
- [手](actor/player/doc/手.md)
- [墨水](actor/player/doc/墨水.md)
- [黑墨喷溅](ink/black/doc/黑墨喷溅.md)
- [生命值](actor/player/doc/生命值.md)
- [画布](actor/canvas/doc/画布.md)
- [创造模式 / 地图编辑器](debug/creative/doc/创造模式.md)
- [烘焙](tools/doc/烘焙.md)
- [验收](test/doc/验收.md)
- [关卡选择](ui/level_select/doc/关卡选择.md)
- [主菜单](ui/menu/doc/主菜单.md)
- [HUD](ui/hud/doc/HUD.md)
- [ESC 菜单](ui/esc/doc/ESC菜单.md)
- [代码审计](doc/代码审计.md)
- [调研：喷射战士墨水与涟漪](doc/调研-喷射战士墨水与涟漪.md)
- [像素打字机对话框](ui/dialogue/doc/对话框.md)
- [蓝图系统](ui/hud/blueprint/doc/blueprints.md)
- [传送门](actor/portal/doc/portal.md)
- [安全脱困](actor/player/doc/safe_unstuck.md)
- [画布邻近交互](actor/canvas/doc/canvas_proximity.md)
- [编辑撤销](debug/creative/doc/editing_undo.md)


目录按“谁实例化、跟随谁、由谁负责生命周期”归属，不要只看功能名称：

- `actor/` 只放需要作为独立对象实例化进地图的东西。每个 `actor/<模块>` 必须有作为入口的 `.tscn`，能被关卡直接放置或实例化；只有脚本、数据、存储、编解码或管理器而没有 Actor 场景的模块，不准放进 `actor/`。
- 跟随 Canvas 存在、由 Canvas 创建或销毁的功能，放进 `actor/canvas/` 的对应子目录，不要另起一个假的 Actor 模块。
- 跟随屏幕 HUD 存在、切换界面时一起创建或销毁的功能，放进 `ui/hud/` 的对应子目录，不要放进 `actor/`。
- 跟随 Player、Monster 等具体对象的脚本、贴图和组件，就放在该对象目录和它的 `.tscn` 旁边。只有确实被多个独立 Actor 共用的非独立组件，才放 `actor/general/`。
- 新建目录前先回答：入口 `.tscn` 是什么、谁实例化它、生命周期跟随谁、是否需要直接放进地图。答不出就不要新建顶层模块，更不能因为名字像“游戏功能”就塞进 `actor/`。
- 仓库里已经存在但不符合这些规则的目录属于待迁移旧债，不能当作后续文件归属的范例。
