#include <metal_stdlib>
using namespace metal;

// MARK: - Vertex Input

struct QuadVertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

// MARK: - Uniforms

struct QuadUniforms {
    float4x4 mvp;
    float opacity;
    float3 _padding; // Alignment to 16 bytes
};

// MARK: - Vertex Output / Fragment Input

struct QuadVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float opacity;
};

// MARK: - Vertex Shader

vertex QuadVertexOut quad_vertex(
    QuadVertexIn in [[stage_in]],
    constant QuadUniforms& uniforms [[buffer(1)]]
) {
    QuadVertexOut out;
    out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.opacity = uniforms.opacity;
    return out;
}

// MARK: - Fragment Shader

fragment float4 quad_fragment(
    QuadVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float4 color = tex.sample(samp, in.texCoord);
    // Premultiplied alpha: multiply all channels by opacity
    return color * in.opacity;
}
