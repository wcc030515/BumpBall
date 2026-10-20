shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

instance uniform float opacity = 0.7;
instance uniform float variation = 0.0;
instance uniform float progress = 0.0;

void vertex() {
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	float sz = length(MODEL_MATRIX[2].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sx, INV_VIEW_MATRIX[1] * sy, INV_VIEW_MATRIX[2] * sz, MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

float lobe(vec2 p, vec2 center, float radius) {
	return 1.0 - smoothstep(radius * 0.54, radius, length(p - center));
}

void fragment() {
	vec2 p = vec2((UV.x - 0.5) * 2.0, (0.5 - UV.y) * 2.0);
	p.x += sin(p.y * 7.0 + variation + progress * 2.7) * 0.035;
	float cloud = lobe(p, vec2(-0.26, -0.12), 0.60);
	cloud = max(cloud, lobe(p, vec2(0.23, -0.12), 0.64));
	cloud = max(cloud, lobe(p, vec2(0.02, 0.23), 0.57));
	cloud = max(cloud, lobe(p, vec2(-0.36, 0.15), 0.38));
	cloud = max(cloud, lobe(p, vec2(0.40, 0.17), 0.35));
	float upper_light = smoothstep(-0.75, 0.53, p.y + p.x * 0.16);
	vec3 lower_tone = vec3(0.34, 0.29, 0.24);
	vec3 upper_tone = vec3(0.88, 0.82, 0.71);
	vec3 ink = mix(lower_tone, upper_tone, upper_light);
	ink *= mix(0.82, 1.0, smoothstep(0.0, 0.65, cloud));
	ALBEDO = ink;
	ALPHA = cloud * opacity;
}
