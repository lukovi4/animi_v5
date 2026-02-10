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

// MARK: - Quad Shaders

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

fragment float4 quad_fragment(
    QuadVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float4 color = tex.sample(samp, in.texCoord);
    // Premultiplied alpha: multiply all channels by opacity
    return color * in.opacity;
}

// MARK: - Mask Shaders

struct MaskVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex MaskVertexOut mask_vertex(
    QuadVertexIn in [[stage_in]],
    constant QuadUniforms& uniforms [[buffer(1)]]
) {
    MaskVertexOut out;
    out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment void mask_fragment(
    MaskVertexOut in [[stage_in]],
    texture2d<float> maskTex [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float alpha = maskTex.sample(samp, in.texCoord).r;
    // Discard fragments where mask alpha is zero
    if (alpha < 0.004) {
        discard_fragment();
    }
    // Fragment passes - stencil will be written via depth stencil state
}

// MARK: - Matte Composite Shaders

struct MatteCompositeUniforms {
    float4x4 mvp;
    int mode;       // 0=alpha, 1=alphaInverted, 2=luma, 3=lumaInverted
    float3 _padding;
};

struct MatteCompositeVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex MatteCompositeVertexOut matte_composite_vertex(
    QuadVertexIn in [[stage_in]],
    constant MatteCompositeUniforms& uniforms [[buffer(1)]]
) {
    MatteCompositeVertexOut out;
    out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 matte_composite_fragment(
    MatteCompositeVertexOut in [[stage_in]],
    texture2d<float> consumerTex [[texture(0)]],
    texture2d<float> matteTex [[texture(1)]],
    sampler samp [[sampler(0)]],
    constant MatteCompositeUniforms& uniforms [[buffer(1)]]
) {
    float4 consumer = consumerTex.sample(samp, in.texCoord);
    float4 matte = matteTex.sample(samp, in.texCoord);

    float factor;
    int mode = uniforms.mode;

    if (mode == 0) {
        // alpha
        factor = matte.a;
    } else if (mode == 1) {
        // alphaInverted
        factor = 1.0 - matte.a;
    } else if (mode == 2) {
        // luma: luminance = 0.2126*r + 0.7152*g + 0.0722*b
        float luma = 0.2126 * matte.r + 0.7152 * matte.g + 0.0722 * matte.b;
        factor = luma;
    } else {
        // lumaInverted
        float luma = 0.2126 * matte.r + 0.7152 * matte.g + 0.0722 * matte.b;
        factor = 1.0 - luma;
    }

    // Apply factor to premultiplied consumer
    return float4(consumer.rgb * factor, consumer.a * factor);
}

// MARK: - GPU Mask Coverage Shaders

struct CoverageUniforms {
    float4x4 mvp;
};

struct CoverageVertexOut {
    float4 position [[position]];
};

// Renders path triangles to R8 coverage texture.
// Output is raw coverage (1.0 inside triangles, 0.0 outside).
// Inverted and opacity are applied later in mask_combine_kernel.
vertex CoverageVertexOut coverage_vertex(
    uint vertexID [[vertex_id]],
    const device float2* positions [[buffer(0)]],
    constant CoverageUniforms& uniforms [[buffer(1)]]
) {
    CoverageVertexOut out;
    float2 pos = positions[vertexID];
    out.position = uniforms.mvp * float4(pos, 0.0, 1.0);
    return out;
}

fragment float coverage_fragment(CoverageVertexOut in [[stage_in]]) {
    // Output raw coverage = 1.0 inside path triangles
    // No blending - triangulation produces non-overlapping triangles
    // saturate() in combine kernel handles any edge cases
    return 1.0;
}

// MARK: - Masked Composite Shaders (content × mask)

struct MaskedCompositeUniforms {
    float4x4 mvp;
    float opacity;
    float3 _padding;
};

vertex QuadVertexOut masked_composite_vertex(
    QuadVertexIn in [[stage_in]],
    constant MaskedCompositeUniforms& uniforms [[buffer(1)]]
) {
    QuadVertexOut out;
    out.position = uniforms.mvp * float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.opacity = uniforms.opacity;
    return out;
}

fragment float4 masked_composite_fragment(
    QuadVertexOut in [[stage_in]],
    texture2d<float> contentTex [[texture(0)]],
    texture2d<float> maskTex [[texture(1)]],
    sampler samp [[sampler(0)]]
) {
    float4 content = contentTex.sample(samp, in.texCoord);
    float maskValue = maskTex.sample(samp, in.texCoord).r;

    // Apply mask to premultiplied content
    float factor = maskValue * in.opacity;
    return float4(content.rgb * factor, content.a * factor);
}

// MARK: - Mask Combine Compute Kernel

// Mode constants for boolean operations
constant int MASK_MODE_ADD = 0;
constant int MASK_MODE_SUBTRACT = 1;
constant int MASK_MODE_INTERSECT = 2;

struct MaskCombineParams {
    int mode;           // 0=add, 1=subtract, 2=intersect
    int inverted;       // 1 if coverage should be inverted before op
    float opacity;      // coverage opacity multiplier (0-1)
    float _padding;
};

kernel void mask_combine_kernel(
    texture2d<float, access::read> coverageTex [[texture(0)]],
    texture2d<float, access::read> accumInTex [[texture(1)]],
    texture2d<float, access::write> accumOutTex [[texture(2)]],
    constant MaskCombineParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= accumOutTex.get_width() || gid.y >= accumOutTex.get_height()) {
        return;
    }

    // Read current accumulator value
    float acc = accumInTex.read(gid).r;

    // Read and process coverage
    float cov = coverageTex.read(gid).r;

    // Clamp coverage to [0,1] (triangulation may cause slight overdraw)
    cov = saturate(cov);

    // Apply inverted flag
    if (params.inverted != 0) {
        cov = 1.0 - cov;
    }

    // Apply opacity
    cov *= params.opacity;

    // Apply boolean operation
    float result;
    if (params.mode == MASK_MODE_ADD) {
        // ADD: acc = max(acc, cov)
        result = max(acc, cov);
    } else if (params.mode == MASK_MODE_SUBTRACT) {
        // SUBTRACT: acc = acc * (1 - cov)
        result = acc * (1.0 - cov);
    } else {
        // INTERSECT: acc = min(acc, cov)
        result = min(acc, cov);
    }

    accumOutTex.write(float4(result, 0.0, 0.0, 0.0), gid);
}
