shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
uniform vec3 color_a : source_color = vec3(0.090196, 0.243137, 0.411765);
uniform sampler2D footprint_mask : filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 footprint_ink : source_color = vec3(0.090196, 0.243137, 0.411765);
uniform vec3 medallion_color : source_color = vec3(0.980392, 0.968627, 0.937255);
uniform float medallion_radius : hint_range(0.5, 0.9) = 0.8;
varying vec3 local_ball_position;

void vertex() {
	// The print stays in mesh space, so it follows the same physical rolling
	// rotation as the sphere rather than facing the camera like a billboard.
	local_ball_position = VERTEX;
}

void fragment() {
	vec3 sphere = normalize(local_ball_position);
	// Two opposite spherical caps. Their projected diameter is 80% of the
	// sphere, leaving a clear ring of the player's or NPC's base colour.
	float rear = sphere.z < 0.0 ? -1.0 : 1.0;
	vec2 disk = vec2(sphere.x * rear, -sphere.y) / medallion_radius;
	vec2 print_uv = disk * 0.5 + 0.5;
	float edge = max(fwidth(length(disk)), 0.002);
	float medallion = 1.0 - smoothstep(1.0 - edge, 1.0 + edge, length(disk));
	float ink = texture(footprint_mask, print_uv).a * medallion;
	ALBEDO = mix(mix(color_a, medallion_color, medallion), footprint_ink, ink);
	ROUGHNESS = 0.39;
	METALLIC = 0.015;
	SPECULAR = 0.55;
}
