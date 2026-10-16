# 蓝墨数值内核

`energy_kernel.hpp` 只处理局部像素与能量，不持有 Godot 对象或物理插件指针。
`energy_extension.cpp` 是 Godot 4.7 C ABI 的薄绑定，每个 EnergyFlow 拥有一个
InkEnergyGrid，并在释放时显式销毁。游戏侧接触、燃料、保存仍在 GDScript。

Windows x86_64，安装 MinGW 后在项目根目录执行：

```powershell
python ink/blue/native/build.py --compiler C:/mingw64/bin/g++.exe
```

编译前退出加载了该 DLL 的游戏/编辑器。使用 `-static` 避免额外依赖 winpthread DLL。
交付的 `ink_energy.gdextension` 当前只声明 Windows x86_64；其他平台尚未交付。
`gdextension_interface.h` 来自 Godot 官方 C 接口，头部保留 MIT 版权许可。

命令流由 `energy_flow.gd` 产生，有长度/容量边界。1 登记像素，2 更新姿态，
3 生产，4 清接触，5 电机足迹，6 滑环，7 相邻载体，8 修复测试像素，9 退场，
10 同步推进，11 参数，12 碎裂读回，13 重新取快照，14 保留年龄迁移。
容量不足只扩容重取，不重复推进、发包、消费或删除。

性能和玩法回归入口见 `ink/blue/doc/蓝墨.md`。
