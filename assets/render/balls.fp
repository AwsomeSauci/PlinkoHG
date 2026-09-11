#version 140
in mediump vec2 var_uv;
in lowp vec4 var_color;
out vec4 out_fragColor;
void main() {
    float distance_to_center = length(var_uv);
    float edge = 1.0 - smoothstep(0.87, 1.0, distance_to_center);
    if (edge * var_color.a <= 0.0) discard;
    float light = 1.0 - smoothstep(0.0, 1.3, length(var_uv - vec2(-0.35, 0.4)));
    vec3 sphere = mix(var_color.rgb * 0.55, min(var_color.rgb * 1.28, vec3(1.0)), light);
    float shine = 1.0 - smoothstep(0.04, 0.32, length(var_uv - vec2(-0.3, 0.4)));
    sphere = mix(sphere, vec3(1.0, 0.97, 0.85), shine * 0.75);
    // Low-alpha vertices are flat trails; opaque ones are shaded balls.
    out_fragColor = vec4(mix(var_color.rgb, sphere, step(0.9, var_color.a)), edge * var_color.a);
}
