# Actor General

`actor/general/` 只放多个 Actor 共用的组件、纯逻辑和表现资源。

## 准入条件

文件进入这里前必须同时满足：

1. 至少被两个不同的 Actor 模块使用。
2. 不是可以单独放入地图、保存或选中的完整实体。
3. 不依赖 `player` / `monster` / `portal` 等具体 Actor 的内部节点路径或实现细节。

`general` 可以被各 Actor 引用，但不得反向引用具体 Actor 模块。

## 当前内容

- `effects/character_death.gd`：Player 和 Monster 共用的死亡残影。
- `effects/character_death.gdshader`：死亡残影的溶解表现。
- `effects/character_hit_flash.gdshader`：角色受击闪白。

## 不应放进来

- Player、Monster、Portal、Fountain 等可独立实例化的实体。
- Nail、InkItem 等有明确领域归属的运行时对象。
- 只有单个 Actor 使用的脚本或资源。
- 地图、UI、调试和测试代码。

`general` 不是待分类文件的临时目录；无法满足上述条件时，文件应留在所属 Actor 模块。
