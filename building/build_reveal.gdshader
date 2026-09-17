shader_type spatial;
render_mode cull_disabled, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float reveal_y = 0.0;
uniform float scan_width = 0.12;
uniform vec3 scan_color : source_color = vec3(0.45, 0.98, 1.0);

varying float world_y;

void vertex() {
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	if (world_y > reveal_y) {
		discard;
	}
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb * albedo_color.rgb;
	float edge = 1.0 - smoothstep(reveal_y - scan_width, reveal_y, world_y);
	EMISSION = scan_color * edge * 5.0;
	ROUGHNESS = 0.55;
	METALLIC = 0.15;
}
