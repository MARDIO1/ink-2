shader_type canvas_item;

// 墨水瓶图层：把「玩家剪影」里**液面以下**的像素染成墨色。
//
// 液面的位置不在这里算 —— 世界竖直方向、液面到原点的距离都由
// bottled_ink.gd 每帧算好后推上来。这里只做两件事：
//   1) 遮罩：剪影之外（alpha = 0）直接丢弃 —— 这就是「只显示玩家区域内的方形」；
//   2) 液面：沿 down_local 投影不达 level 的丢弃 = 液面以上是空的。
//
// ⚠️ 液面抖动（波浪/惯性）以后只加在这一个 shader 里，不要动 GDScript 侧的液体模型。
uniform vec4 ink_color : source_color = vec4(0.09, 0.11, 0.28, 1.0);
// 世界「向下」方向在本节点局部坐标下的单位向量。
uniform vec2 down_local = vec2(0.0, 1.0);
// 液面沿 down_local 到本节点原点的有符号距离，单位像素。
uniform float level = 0.0;

void fragment() {
	if (texture(TEXTURE, UV).a <= 0.0) {
		discard;
	}
	if (dot(VERTEX, down_local) - level < 0.0) {
		discard;
	}
	COLOR = ink_color;
}
