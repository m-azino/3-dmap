shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

// --- Colors ---
uniform vec4 color_top : source_color = vec4(0.667, 0.922, 0.431, 1.0);
uniform vec4 color_bottom : source_color = vec4(0.651, 0.282, 0.0, 1.0);
uniform vec3 color_variation : source_color = vec3(0.9, 0.9, 0.2);

// --- Shape ---
uniform float blade_bend = 0.5;

// --- Wind & Variation ---
uniform float patch_scale = 5.0;
uniform sampler2D wind_noise : hint_default_white;
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_texture_scale = 20.0;
uniform float wind_speed = 0.1;
uniform float still_sway_speed = 4.5;
uniform float still_sway_strength = 0.1;
uniform float gust_strength = 1.0;
uniform float gust_frequency = 0.08;

// --- Varyings (Passed from vertex to fragment) ---
varying float v_patch;
varying float v_wind_intensity;


void vertex() {
	// Get the world position of the multimesh instance
	vec3 world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	
	// Variation patch factor
	float patch_factor = texture(wind_noise, world_pos.xz / patch_scale).r;
	v_patch = patch_factor;

	// Wind calculation
	vec2 global_uv = world_pos.xz / wind_texture_scale;
	vec2 move_uv = global_uv + (normalize(wind_direction) * TIME * wind_speed);
	float noise_val = texture(wind_noise, move_uv).r;

	float gust_mask = smoothstep(gust_frequency, 1.0, noise_val);

	float idle_sway = sin(TIME * still_sway_speed + world_pos.x + world_pos.z) * still_sway_strength;
	float flutter = sin(TIME * 20.0 + world_pos.x) * 0.1;
	float gust_push = (gust_mask * gust_strength) + (gust_mask * flutter);

	v_wind_intensity = gust_mask;

	// Set up local space vectors and height
	vec3 vertex_pos = VERTEX;
	vec3 object_right_vector = vec3(1.0, 0.0, 0.0);
	vec3 object_forward_vector = vec3(0.0, 0.0, 1.0);
	float height_factor = 1.0 - UV.y;
	float bend_strength = pow(height_factor, 2.0);
	
	// Static blade bend
	vertex_pos += object_forward_vector * blade_bend * bend_strength;

	// Wind mostly along local right axis
	vec3 total_offset = object_right_vector * (idle_sway + gust_push) * bend_strength;
	
	// Preserve volume / prevent stretching
	float dist_moved = length(total_offset.xz);
	float y_drop = dist_moved * 0.2 * bend_strength;
	
	VERTEX = vertex_pos + total_offset;
	VERTEX.y -= y_drop;
}

void fragment() {
	// Base color gradient based on UV height
	vec3 gradient = mix(color_top.rgb, color_bottom.rgb, UV.y);
	
	// Mix in the color variation based on the patch noise
	vec3 varied_color = mix(gradient, color_variation, v_patch * 0.3);
	
	ALBEDO = varied_color;
	
	// Prevent the grass from looking like shiny plastic
	ROUGHNESS = 0.8;
	SPECULAR = 0.1;
}