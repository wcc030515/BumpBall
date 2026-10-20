shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(123.34, 456.21))) * 45678.9123);
}

float noise21(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0)), f.x), f.y);
}

void fragment() {
	float across = abs(UV.x * 2.0 - 1.0);
	float ripple = noise21(vec2(UV.y * 7.0, UV.x * 3.0));
	// A continuous oval density gradient has no opaque plateau or visible capsule rim.
	float along = (UV.y - 0.40) / 0.60;
	float radius_squared = across * across + along * along;
	float oval_distance = sqrt(radius_squared);
	float density = exp(-1.5 * radius_squared);
	float outer_fade = 1.0 - smoothstep(0.40, 1.08, oval_distance);
	float front_fade = smoothstep(0.0, 0.14, UV.y);
	float strands = 0.80 + 0.20 * noise21(vec2(UV.x * 5.0, UV.y * 4.0));
	vec3 center_tone = vec3(0.87, 0.78, 0.60);
	ALBEDO = center_tone * (0.97 + ripple * 0.03);
	ALPHA = COLOR.a * density * outer_fade * strands * front_fade;
}
