#include <metal_stdlib>
using namespace metal;

// Vertex structure
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader - takes in vertex data and outputs position and texture coordinates
vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                               constant float4 *vertices [[buffer(0)]]) {
    VertexOut out;

    // Each vertex has 4 floats: x, y, u, v
    float4 vtx = vertices[vertexID];

    out.position = float4(vtx.xy, 0.0, 1.0);
    out.texCoord = vtx.zw;

    return out;
}

// Fragment shader - samples the video texture
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> texture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    float4 color = texture.sample(textureSampler, in.texCoord);

    return color;
}
