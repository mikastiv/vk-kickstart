#version 460

layout(location = 0) in vec3 frag_color;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(frag_color, 1.0);
}
