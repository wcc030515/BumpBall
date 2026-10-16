shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Native spatial water: geometry swell + procedural capillary normals.
// The near shore refracts the actual Godot scene; no bitmap water plane.
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform float island_radius = 9.05;
// The same waves and refraction now follow the approved island's real wet edge.
uniform bool shore_profile_enabled = false;
uniform sampler2D shore_profile_texture : repeat_enable, filter_linear;
uniform vec3 deep_color : source_color = vec3(0.018, 0.225, 0.325);
uniform vec3 shallow_color : source_color = vec3(0.10, 0.66, 0.60);
uniform vec3 sun_direction = vec3(-0.40, 0.82, 0.35);
uniform bool high_quality = true;
uniform float water_time = 0.0;
varying vec3 world_position;
varying vec3 wave_normal;
varying float wave_height;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float noise21(vec2 p) {
	vec2 a = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(a), hash21(a + vec2(1.0, 0.0)), f.x),
		mix(hash21(a + vec2(0.0, 1.0)), hash21(a + vec2(1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	return noise21(p) * 0.57 + noise21(p * 2.03 + 14.2) * 0.28 + noise21(p * 4.09 + 3.7) * 0.15;
}
void gerstner(inout vec3 p, inout vec3 tx, inout vec3 tz, vec2 direction,
	float amplitude, float wavelength, float speed, vec2 original) {
	vec2 d = normalize(direction);
	float k = 6.2831853 / wavelength;
	float phase = k * dot(d, original) - water_time * speed;
	float s = sin(phase);
	float c = cos(phase);
	float steepness = 0.48;
	p.xz += d * amplitude * steepness * c;
	p.y += amplitude * s;
	tx += vec3(-steepness * d.x * d.x * amplitude * k * s,
		d.x * amplitude * k * c, -steepness * d.x * d.y * amplitude * k * s);
	tz += vec3(-steepness * d.x * d.y * amplitude * k * s,
		d.y * amplitude * k * c, -steepness * d.y * d.y * amplitude * k * s);
}
vec3 sky_reflection(vec3 direction) {
	float up = max(direction.y, 0.0);
	vec3 color = mix(vec3(0.68, 0.84, 0.90), vec3(0.18, 0.44, 0.69), pow(up, 0.55));
	float cloud = smoothstep(0.59, 0.79, fbm(direction.xz / (up + 0.18) * 2.0 + vec2(water_time * 0.005, 0.0)));
	color = mix(color, vec3(0.92, 0.96, 0.96), cloud * smoothstep(0.03, 0.3, up) * 0.32);
	float sun_dot = max(dot(direction, normalize(sun_direction)), 0.0);
	color += vec3(1.0, 0.90, 0.69) * pow(sun_dot, 320.0) * 2.5;
	return color;
}
vec2 micro_slope(vec2 p) {
	vec2 n = vec2(0.0);
	n += vec2(0.93, 0.37) * cos(dot(p, vec2(9.1, 3.6)) - water_time * 3.3) * 0.058;
	n += vec2(-0.69, 0.72) * cos(dot(p, vec2(-7.4, 7.8)) - water_time * 4.1) * 0.044;
	n += vec2(0.31, 0.95) * cos(dot(p, vec2(7.2, 21.8)) - water_time * 5.4) * 0.026;
	if (high_quality) {
		n += vec2(0.97, -0.24) * cos(dot(p, vec2(32.0, -7.9)) - water_time * 7.5) * 0.018;
		n += vec2(-0.62, -0.78) * cos(dot(p, vec2(-36.7, -46.2)) - water_time * 9.8) * 0.011;
	}
	return n;
}
void vertex() {
	vec3 p = VERTEX;
	vec3 tx = vec3(1.0, 0.0, 0.0);
	vec3 tz = vec3(0.0, 0.0, 1.0);
	vec2 original = p.xz;
	gerstner(p, tx, tz, vec2(0.94, 0.34), 0.21, 12.0, 1.4, original);
	gerstner(p, tx, tz, vec2(-0.72, 0.68), 0.12, 7.3, 1.8, original);
	gerstner(p, tx, tz, vec2(0.28, 0.96), 0.075, 4.2, 2.35, original);
	gerstner(p, tx, tz, vec2(0.85, -0.52), 0.040, 2.6, 2.8, original);
	if (high_quality) {
		gerstner(p, tx, tz, vec2(-0.91, -0.41), 0.022, 1.6, 3.6, original);
	}
	VERTEX = p;
	wave_normal = normalize(mat3(MODEL_MATRIX) * normalize(cross(tz, tx)));
	world_position = (MODEL_MATRIX * vec4(p, 1.0)).xyz;
	wave_height = p.y;
}
void fragment() {
	vec3 view_direction = normalize(CAMERA_POSITION_WORLD - world_position);
	float view_distance = length(CAMERA_POSITION_WORLD - world_position);
	vec2 fine = micro_slope(world_position.xz);
	float detail_fade = 1.0 - smoothstep(28.0, 95.0, view_distance);
	vec3 n = normalize(wave_normal + vec3(fine.x, 0.0, fine.y) * detail_fade);
	vec3 reflected_direction = reflect(-view_direction, n);
	float fresnel = 0.025 + 0.975 * pow(1.0 - max(dot(n, view_direction), 0.0), 5.0);
	float angle = atan(world_position.z, world_position.x);
	float shore_radius = island_radius + sin(angle * 5.0 + 0.4) * 0.12 + sin(angle * 9.0) * 0.06;
	if (shore_profile_enabled) {
		float profile_u = fract(angle / 6.2831853 + 1.0 + 0.5 / 512.0);
		shore_radius = texture(shore_profile_texture, vec2(profile_u, 0.5)).r;
	}
	float shore_distance = length(world_position.xz) - shore_radius;
	float shallow = exp(-max(shore_distance, 0.0) * 0.34);
	vec3 water = mix(deep_color, shallow_color, shallow * 0.90);
	water *= 0.86 + 0.14 * max(dot(n, normalize(sun_direction)), 0.0);
	water += vec3(0.02, 0.08, 0.075) * max(wave_height + 0.15, 0.0);

	// Depth-aware screen refraction shows submerged native rocks/sand.
	float raw_depth = texture(depth_texture, SCREEN_UV).r;
	vec3 ndc;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		ndc = vec3(SCREEN_UV, raw_depth) * 2.0 - 1.0;
	#else
		ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	#endif
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	scene_view.xyz /= max(abs(scene_view.w), 0.0001);
	float depth_difference = max(-scene_view.z - (-VERTEX.z), 0.0);
	vec2 refraction_uv = clamp(SCREEN_UV + n.xz * 0.007 * min(depth_difference, 2.0), vec2(0.002), vec2(0.998));
	vec3 floor_color = textureLod(screen_texture, refraction_uv, 0.0).rgb;
	float transmission = shallow * exp(-depth_difference * 0.34) * (1.0 - fresnel) * 0.25;
	water = mix(water, floor_color * vec3(0.65, 0.94, 0.87), transmission);
	vec3 color = mix(water, sky_reflection(reflected_direction), min(0.87, 0.08 + fresnel * 0.82));
	vec3 half_vector = normalize(view_direction + normalize(sun_direction));
	float specular = pow(max(dot(n, half_vector), 0.0), 380.0);
	float broad_specular = pow(max(dot(n, half_vector), 0.0), 52.0);
	color += vec3(1.0, 0.94, 0.79) * (specular * 2.0 + broad_specular * 0.12);

	// Broken advancing breakers, never a static white ring.
	float breaker_noise = fbm(world_position.xz * 1.65 + vec2(water_time * 0.18, -water_time * 0.11));
	float phase = shore_distance * 3.6 + water_time * 2.2 + breaker_noise * 3.0;
	float breaker = pow(max(0.0, sin(phase)), 10.0);
	float surf_zone = exp(-pow((shore_distance - 0.65) / 1.06, 2.0));
	float broken = smoothstep(0.29, 0.63, breaker_noise);
	float wash = smoothstep(0.16, 0.45, sin(water_time * 1.55 + angle * 2.1 + breaker_noise * 5.0))
		* exp(-max(shore_distance, 0.0) * 3.5);
	float foam = max(breaker * surf_zone * broken, wash * broken * 0.59);
	foam *= smoothstep(-0.3, 0.12, shore_distance);
	foam *= 0.53 + smoothstep(0.43, 0.68, noise21(world_position.xz * 24.0 + water_time * 0.3)) * 0.47;
	float crest_foam = smoothstep(0.27, 0.36, wave_height)
		* smoothstep(0.70, 0.85, fbm(world_position.xz * 2.2 - water_time * 0.1)) * 0.18;
	color = mix(color, vec3(0.88, 0.97, 0.96), clamp(foam * 0.85 + crest_foam, 0.0, 0.87));
	float haze = 1.0 - exp(-view_distance * view_distance * 0.000018);
	color = mix(color, vec3(0.43, 0.66, 0.76), haze * 0.50);
	ALBEDO = color;
	ALPHA = mix(0.999, 0.88, shallow * (1.0 - fresnel) * (1.0 - foam));
}
