# 蓝墨数值内核

`energy_kernel.hpp` 只处理局部像素与能量，不持有 Godot 对象或物理插件指针。
`energy_extension.cpp` 是 Godot 4.7 C ABI 的薄绑定，每个 EnergyFlow 拥有一个
InkEnergyGrid2，并在释放时显式销毁。`energy_flow.gd` 会自动识别
InkEnergyGrid2/旧版 InkEnergyGrid；旧 DLL 继续走旧协议，不会错位。游戏侧接触、燃料、保存仍在 GDScript。

Windows x86_64，安装 MinGW 后在项目根目录执行：

```powershell
python ink/blue/native/build.py --compiler C:/mingw64/bin/g++.exe
```

编译前退出加载了该 DLL 的游戏/编辑器。使用 `-static` 避免额外依赖 winpthread DLL。
交付的 `ink_energy.gdextension` 当前只声明 Windows x86_64；其他平台尚未交付。
`gdextension_interface.h` 来自 Godot 官方 C 接口，头部保留 MIT 版权许可。

命令流由 `energy_flow.gd` 产生，有长度/容量边界。1 登记像素，2 更新姿态，
3 生产，4 清接触，5 电机足迹，6 滑环，7 相邻载体，9 退场，
10 同步推进，11 参数，12 碎裂读回，13 重新取快照，14 保留年龄迁移。
容量不足只扩容重取，不重复推进、发包、消费或删除。

迎面对冲在同步 front 上比较反向能量，标记败者后统一耗散；不炸线。
11 参数中的 `opposition_recovery` 可把同格败者能量的一部分转给胜者：
0 = 全部耗散（默认），0.5 = 回收一半，1 = 全部回收；能量账保持平衡。
来向访问表允许胜者通过败者反向足迹，寿命和同向重复访问限制防止无限绕圈。
旧短路计数和显示删除/闪点槽保留为 0，兼容外层统计；不再有烧线/注入口豁免代码。
碎裂读回每格 80 字节，保存四方向能量、原年龄/波号/组号、滑环入口、来源和生物标记。

性能和玩法回归入口见 `ink/blue/doc/蓝墨.md`。
