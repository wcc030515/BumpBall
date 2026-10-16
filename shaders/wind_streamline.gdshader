shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

// All motion is controlled by the authoritative gust phase, never TIME.
uniform float wind_phase = 0.0;
uniform float wind_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3 line_color : source_color = vec3(0.83, 1.0, 0.96);

void fragment() {
	float seed = COLOR.r;
	float along = fract(UV.x - wind_phase * 0.54 + seed);
	// A long fading wake ends at a compact, brighter leading tip.
	float wake = smoothstep(0.0, 0.16, along) * (1.0 - smoothstep(0.18, 0.21, along));
	float second = fract(along + 0.5);
	float wake2 = smoothstep(0.0, 0.12, second) * (1.0 - smoothstep(0.14, 0.17, second));
	float cross_distance = abs(UV.y * 2.0 - 1.0);
	float soft_edge = 1.0 - smoothstep(0.24, 1.0, cross_distance);
	float core = 1.0 - smoothstep(0.0, 0.34, cross_distance);
	float pulse = max(wake, wake2 * 0.62);
	ALBEDO = mix(vec3(0.25, 0.66, 0.70), line_color, core * 0.65 + 0.35);
	EMISSION = line_color * 0.10 * core;
	ALPHA = pulse * soft_edge * wind_strength * COLOR.g * 0.72;
}
