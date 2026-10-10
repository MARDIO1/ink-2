shader_type canvas_item;
render_mode unshaded;

// 与 Visual 的 player_breath_wobble 用**同一段**呼吸 + 步进抖动，好让墨水死死贴着线框抖。
//
// ⚠️⚠️ 但本节点（墨层）不是整张剪影：它的贴图只是**瓶身内部那块子矩形**（26x14 格），
//    还被 scale=cell_px 放大过 —— UV 空间与 Visual 不是一套，所以**不能直接照抄**那边的
//    sin(UV.y*13.0) 与 from_center：相位和中心都会错位（症状是墨跟线稿各抖各的、边缘露白）。
//
//    办法：先把本节点的 UV 映回 **Visual 的像素空间**，在那里算位移，再换回本节点的纹素：
//        ink_size_px = 1.0 / TEXTURE_PIXEL_SIZE          // 本节点贴图尺寸（纹素）
//        visual_px   = grid_origin + UV * ink_size_px * cell_px
//        visual_uv   = visual_px / visual_size
//    位移在 Visual 像素里算完之后 **除以 cell_px** 换回本节点局部单位（纹素）。
//    三个 uniform 由 bottled_ink.gd 喂（见 _sync_wobble_uniforms）。
//
// ⚠️ 液面**不在这里算**：本工程的液面是 PBF 流体烘进贴图的（见 bottled_ink.gd 的文件头），
//    shader 只负责把烘好的贴图跟着线框一起抖。
uniform vec2 visual_size = vec2(68.0, 87.0);
uniform vec2 grid_origin = vec2(0.0, 0.0);
uniform float cell_px = 1.0;

// Keep the exact breathing and restrained hand-drawn wobble used by Visual.
uniform float breath_period : hint_range(1.5, 5.0, 0.1) = 2.6;
uniform float breath_x : hint_range(0.0, 0.05, 0.001) = 0.016;
uniform float breath_y : hint_range(0.0, 0.05, 0.001) = 0.022;
uniform float wobble_fps : hint_range(1.0, 12.0, 0.5) = 5.0;
uniform float wobble_pixels : hint_range(0.0, 2.0, 0.05) = 0.55;

float hash(float value) {
	return fract(sin(value * 91.3458 + 17.234) * 47453.5453);
}


// ⚠️⚠️ 贴图尺寸必须由**调用点**算好传进来：Godot 的内建量（TEXTURE_PIXEL_SIZE 之类）
//    只在 vertex()/fragment() 本体里可见，用户函数里用会直接编译失败
//    （实测：SHADER ERROR: Unknown identifier in expression: 'TEXTURE_PIXEL_SIZE'）。
vec2 visual_uv_of(vec2 uv, vec2 ink_size_px) {
	return (grid_origin + uv * ink_size_px * cell_px) / max(visual_size, vec2(1.0));
}


void vertex() {
	vec2 ink_size_px = vec2(1.0) / TEXTURE_PIXEL_SIZE;
	vec2 visual_uv = visual_uv_of(UV, ink_size_px);
	float phase = TIME * TAU / max(breath_period, 0.01);
	float breath = sin(phase) * 0.82 + sin(phase * 2.0 - 0.65) * 0.18;
	// 呼吸绕**剪影**中心缩放（不是本节点中心），位移按 Visual 像素算再换回纹素。
	vec2 from_center = (visual_uv - vec2(0.5)) * visual_size;
	VERTEX += from_center * vec2(breath * breath_x, breath * breath_y) / max(cell_px, 0.001);

	float wobble_frame = floor(TIME * wobble_fps);
	vec2 whole_shift = vec2(
		hash(wobble_frame + 3.0) - 0.5,
		hash(wobble_frame + 19.0) - 0.5
	) * wobble_pixels * 0.45;
	VERTEX += whole_shift / max(cell_px, 0.001);
}


void fragment() {
	vec2 ink_size_px = vec2(1.0) / TEXTURE_PIXEL_SIZE;
	vec2 visual_uv = visual_uv_of(UV, ink_size_px);
	float wobble_frame = floor(TIME * wobble_fps);
	float side_wave = sin(visual_uv.y * 13.0 + wobble_frame * 2.17);
	float top_wave = sin(visual_uv.x * 11.0 - wobble_frame * 1.73);
	// Visual 那边采样的是 visual_px + pixel_offset；本节点换算成"纹素"就是除以 cell_px。
	vec2 pixel_offset = vec2(side_wave, top_wave) * wobble_pixels;
	vec2 warped_uv = clamp(UV + pixel_offset / ink_size_px / max(cell_px, 0.001),
		vec2(0.0), vec2(1.0));
	COLOR = texture(TEXTURE, warped_uv) * COLOR;
}
