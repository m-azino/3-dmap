shader_type spatial;

render_mode depth_draw_always, alpha_to_coverage, unshaded;

// Texture and visual control
uniform sampler2D foliage_texture;
uniform vec2 texture_scale = vec2(1.0, 1.0);
uniform float alpha_threshold : hint_range(0.0, 1.0) = 0.1;

// Color control
uniform vec3 foliage_colour : source_color = vec3(0.13, 0.33, 0.25);
uniform float color_strength : hint_range(0.0, 2.0) = 1.0;

// Fresnel blend
uniform vec3 fresnel_colour : source_color = vec3(0.5, 0.7, 0.4);
uniform float fresnel_strength : hint_range(0.0, 1.0) = 0.3;
uniform float fresnel_power : hint_range(0.1, 5.0) = 1.5;

// Billboard effect control
uniform float billboard_strength : hint_range(0.0, 1.0) = 1.0;
uniform vec2 vertex_offset_scale = vec2(1.0, 1.0);
uniform bool flip_normal = true;

// Wind sway control
uniform bool use_wind = true;
uniform float wind_strength : hint_range(0.0, 1.0) = 0.1;
uniform float wind_speed : hint_range(0.1, 5.0) = 1.0;
uniform vec3 wind_direction = vec3(1.0, 0.0, 0.0);

void vertex()
{
    if (flip_normal) {
        NORMAL = -NORMAL;
    }

    // Billboard positioning
    vec2 viewspace_offset = (UV - vec2(0.5)) * vertex_offset_scale;
    vec4 modelspace_offset = inverse(MODELVIEW_MATRIX) * vec4(viewspace_offset, 0.0, 0.0);
    VERTEX += modelspace_offset.xyz * billboard_strength;

    // Wind sway (optional)
    if (use_wind) {
        float sway = sin(TIME * wind_speed + UV.x * 5.0) * wind_strength;
        VERTEX.xyz += wind_direction * sway;
    }
}

void fragment()
{
    vec2 scaled_uv = UV * texture_scale;
    float alpha = texture(foliage_texture, scaled_uv).g;

    if (alpha < alpha_threshold) {
        discard;
    }

    // Fake Fresnel effect: based on view direction and normal
    vec3 view_dir = normalize(-FRAGCOORD.xyz);
    float fresnel = pow(1.0 - dot(NORMAL, view_dir), fresnel_power);
    vec3 final_color = mix(foliage_colour, fresnel_colour, fresnel * fresnel_strength);

    ALBEDO = final_color * color_strength;
    ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
