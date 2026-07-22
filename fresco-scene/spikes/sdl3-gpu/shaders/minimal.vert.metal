#include <metal_stdlib>
using namespace metal;

struct VertexInput {
    float3 position [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct VertexOutput {
    float4 position [[position]];
    float2 uv;
};

struct ResolvedTransform {
    float4x4 mvp;
};

vertex VertexOutput main0(
    VertexInput input [[stage_in]],
    constant ResolvedTransform& transform [[buffer(0)]])
{
    VertexOutput output;
    output.position = transform.mvp * float4(input.position, 1.0);
    output.uv = input.uv;
    return output;
}
