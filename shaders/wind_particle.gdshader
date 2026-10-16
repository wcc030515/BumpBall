shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform float wind_phase = 0.0;
uniform float wind_strength : hint_range(0.0, 1.0) = 0.0;
uniform int particle_kind = 0; // 0: slender air streak, 1: leaf, 2: pollen
varying float leaf_fold;

void vertex() {
	leaf_fold = 1.0;
	if (particle_kind == 1) {
		float flutter = wind_phase * 10.0 + INSTANCE_CUSTOM.x * 1.7;
		leaf_fold = 0.45 + 0.55 * abs(sin(flutter));
		VERTEX.x *= leaf_fold;
		VERTEX.z += sin(VERTEX.y * 15.0 + flutter) * 0.025;
	}
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float shape = 0.0;
	vec3 tint = COLOR.rgb;
	if (particle_kind == 1) {
		float half_width = sqrt(max(0.0, 1.0 - p.y * p.y)) * 0.78;
		shape = 1.0 - smoothstep(half_width * 0.72, half_width + 0.04, abs(p.x));
		shape *= 1.0 - smoothstep(0.86, 1.0, abs(p.y));
		float vein = 1.0 - smoothstep(0.02, 0.08, abs(p.x + p.y * 0.06));
		tint = mix(vec3(0.39, 0.56, 0.18), vec3(0.86, 0.91, 0.45), UV.x);
		tint = mix(tint, vec3(0.95, 0.95, 0.63), vein * 0.4);
		tint *= 0.78 + 0.22 * leaf_fold;
	} else if (particle_kind == 2) {
		shape = 1.0 - smoothstep(0.12, 1.0, length(p));
		tint = vec3(0.96, 0.97, 0.78);
	} else {
		float taper = pow(max(0.0, 1.0 - p.y * p.y), 0.65);
		shape = (1.0 - smoothstep(0.14 * taper, 0.88 * taper + 0.01, abs(p.x)));
		shape *= 1.0 - smoothstep(0.68, 1.0, abs(p.y));
		tint = mix(vec3(0.41, 0.78, 0.78), vec3(0.94, 1.0, 0.96), UV.y);
	}
	ALBEDO = tint;
	EMISSION = tint * (particle_kind != 1 ? 0.06 : 0.0);
	ALPHA = shape * COLOR.a * wind_strength * (particle_kind == 1 ? 0.76 : 0.48);
}
