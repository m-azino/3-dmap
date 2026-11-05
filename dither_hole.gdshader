shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// ---------------------------------------------------------------------------
// DITHERED SEE-THROUGH HOLE
//
// Cuts a Bayer-dithered "tunnel" along the navigation path out of any mesh
// that is between the camera and the path. Everything else about the look
// mimics a default StandardMaterial3D (albedo colour/texture, roughness,
// metallic, specular, optional alpha-scissor for foliage).
//
// Path data is shared by every material through ONE small float texture that
// dither_hole.gd updates (nothing is written per-material or per-frame):
//   texel 0 : (point_count, hole_radius, depth_margin, edge_softness)
//   texel 1 : (dither_pixel_size, camera_back.x, camera_back.y, camera_back.z)
//   texel 2+: path points in world space (xyz)
//
// The hole only runs when the camera that is rendering matches the main
// camera's direction (texel 1). Shadow-map passes use the light's orientation,
// so they fail that check and are left uncut.
// ---------------------------------------------------------------------------

uniform sampler2D hole_data : filter_nearest, repeat_disable;

// --- StandardMaterial3D look-alike inputs (copied by dither_hole.gd) ---
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec2 uv1_scale = vec2(1.0);
uniform vec2 uv1_offset = vec2(0.0);
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.0; // > 0 = alpha scissor (leaves)
uniform bool use_vertex_color = false;

varying vec3 v_world;
varying vec4 v_color;

// 4x4 Bayer matrix, thresholds = (index + 0.5) / 16
const float BAYER[16] = float[16](
	0.03125, 0.53125, 0.15625, 0.65625,
	0.78125, 0.28125, 0.90625, 0.40625,
	0.21875, 0.71875, 0.09375, 0.59375,
	0.96875, 0.46875, 0.84375, 0.34375
);

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_color = COLOR;
}

// 0.0 = untouched, 1.0 = fully open. 'back' is the camera's +Z axis in world
// space (pointing from the scene towards the viewer).
float hole_coverage(vec3 p, vec3 back) {
	vec4 head = texelFetch(hole_data, ivec2(0, 0), 0);
	int count = int(head.x + 0.5);
	if (count <= 0) {
		return 0.0;
	}
	float radius = head.y;
	float margin = head.z;
	float inner = radius * (1.0 - head.w);

	float cover = 0.0;
	vec3 a = texelFetch(hole_data, ivec2(2, 0), 0).xyz;
	int segs = max(count - 1, 1);

	for (int i = 0; i < segs; i++) {
		vec3 b = texelFetch(hole_data, ivec2(2 + min(i + 1, count - 1), 0), 0).xyz;
		vec3 s = b - a;
		vec3 v = p - a;

		// Work in the plane perpendicular to the view direction
		vec3 sp = s - back * dot(s, back);
		vec3 vp = v - back * dot(v, back);
		float len2 = dot(sp, sp);
		float t = 0.0;
		if (len2 > 0.0001) {
			t = clamp(dot(vp, sp) / len2, 0.0, 1.0);
		}
		float d = length(vp - sp * t);

		// How far this fragment is in FRONT of the path point (towards the camera)
		float depth = dot(v - s * t, back);

		float edge = 1.0 - smoothstep(inner, radius, d);
		float gate = clamp(depth - margin, 0.0, 1.0);
		cover = max(cover, edge * gate);
		a = b;
	}
	return cover;
}

void fragment() {
	vec4 col = albedo * texture(albedo_tex, UV * uv1_scale + uv1_offset);
	if (use_vertex_color) {
		col *= v_color;
	}
	if (col.a < alpha_cut) {
		discard;
	}

	vec4 h1 = texelFetch(hole_data, ivec2(1, 0), 0);
	vec3 back = normalize(INV_VIEW_MATRIX[2].xyz);
	if (dot(back, h1.yzw) > 0.999) {
		float cover = hole_coverage(v_world, back);
		if (cover > 0.0) {
			vec2 cell = floor(FRAGCOORD.xy / max(h1.x, 1.0));
			ivec2 px = ivec2(mod(cell, 4.0));
			if (cover > BAYER[px.y * 4 + px.x]) {
				discard;
			}
		}
	}

	ALBEDO = col.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;
}
