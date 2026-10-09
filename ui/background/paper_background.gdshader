shader_type canvas_item;
// 无限纸背景：横向把一张纸拉伸成超宽纸跟着相机滚（不循环、无竖直接缝）；
// 竖向 fract 循环拼接，行间距严格等于纸高；保持图片原色。

uniform sampler2D paper : source_color, hint_default_white;
// 当前活动相机的世界坐标（由 paper_background.gd 每帧喂入）。
uniform vec2 world_camera_pos;
// 视口可见尺寸（世界单位 = 屏幕像素，本游戏 1px = 1 单位）。
uniform vec2 viewport_size = vec2(960.0, 540.0);
// 纸纹竖向循环高度（= 原图高）；行间距严格等于它，拉伸只在横向。
uniform float paper_tile_height = 762.0;
// 纸纹横向拉伸后的世界宽度：一张纸拉这么宽跟着相机滚，不循环、无接缝。
// 越大横向拉伸越厉害、纸左右色差越被拉平，但视差滚动也越慢。
uniform float paper_wide_width = 1920.0;

void fragment() {
	// 屏幕 UV 0..1 -> 该像素对应的世界坐标：屏幕中心就是相机位置。
	vec2 world_pos = world_camera_pos + (SCREEN_UV - vec2(0.5)) * viewport_size;
	// 横向：拉伸成一张宽纸，不循环；+0.5 让相机 x=0 时屏幕正对纸中间。
	// 屏幕宽 960 < paper_wide_width 1920，屏幕内永远只看到纸的一段，不会碰到边缘。
	float u = world_pos.x / paper_wide_width + 0.5;
	// 竖向：fract 循环，行间距不变。
	float v = fract(world_pos.y / paper_tile_height);
	COLOR = texture(paper, vec2(u, v));
}
