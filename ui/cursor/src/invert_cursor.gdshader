shader_type canvas_item;
// 画笔光标反色混合：在任何背景上都自动反相显示，黑墨上显白、白纸上显黑。
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

void fragment() {
	vec4 cursor = texture(TEXTURE, UV);
	vec3 background = texture(screen_texture, SCREEN_UV).rgb;
	// 保留素材自身的黑白层次，不能把白描边也染黑而变成实心块。
	float luminance = dot(background, vec3(0.299, 0.587, 0.114));
	vec3 ink = luminance < 0.5 ? vec3(1.0) - cursor.rgb : cursor.rgb;
	COLOR = vec4(ink, cursor.a);
}
