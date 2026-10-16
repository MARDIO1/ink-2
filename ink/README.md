# Ink 目录边界

`ink/` 按颜色分模块：`black` / `grey` / `red` / `white` / `yellow` / `blue` / `invisible`。
每个颜色自己持有它的 `src` / `asset` / `doc` / `native`，没有内容的子目录不创建。

`general/` 只放跨颜色共用的能力：

- `general/src/ink_palette.gd`：墨水色表和材质公开入口。
- `general/src/ink_runtime.gd`：项目启动时的墨水材质注册。
- `general/src/pixel_art_layer.gd`：多种材质共用的纯表现层。

不要把“暂时不知道放哪”的文件放进 `general/`。只被一种颜色使用的实现，必须回到该颜色目录。
