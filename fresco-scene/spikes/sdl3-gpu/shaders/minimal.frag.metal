#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 uv;
};

fragment float4 main0(
    VertexOutput input [[stage_in]],
    texture2d<float> colorTexture [[texture(0)]],
    sampler colorSampler [[sampler(0)]])
{
    return colorTexture.sample(colorSampler, input.uv);
}
