#include <metal_stdlib>
using namespace metal;

struct InstanceData {
    float2 position;
    float2 direction;
    float width;
    float length;
    float4 color;
    float softness;
};

struct ParticleVertexOut {
    float4 position [[position]];
    float4 color;
    float2 quad;
    float2 extent;
    float softness;
};

vertex ParticleVertexOut particleVertex(uint vertexID [[vertex_id]],
                                        uint instanceID [[instance_id]],
                                        constant float2 *quadVertices [[buffer(0)]],
                                        constant InstanceData *instances [[buffer(1)]],
                                        constant float2 &viewport [[buffer(2)]]) {
    InstanceData data = instances[instanceID];
    float2 forward = normalize(data.direction);
    if (!isfinite(forward.x) || !isfinite(forward.y)) {
        forward = float2(1.0, 0.0);
    }
    float2 right = float2(-forward.y, forward.x);
    float2 quad = quadVertices[vertexID];
    float2 offset = right * quad.x * data.width + forward * quad.y * data.length;
    float2 world = data.position + offset;
    float2 clip = float2((world.x / viewport.x) * 2.0 - 1.0,
                         (world.y / viewport.y) * 2.0 - 1.0);
    clip.y = -clip.y;
    ParticleVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    out.color = data.color;
    out.quad = quad;
    out.extent = float2(data.length * 0.5, data.width * 0.5);
    out.softness = data.softness;
    return out;
}

fragment float4 particleFragment(ParticleVertexOut in [[stage_in]]) {
    float softness = in.softness;
    if (softness <= 0.01) {
        return in.color;
    }
    float2 extent = max(in.extent, float2(0.0001));
    float2 local = float2(in.quad.x * extent.x, in.quad.y * extent.y);
    float2 norm = float2(local.x / extent.x, local.y / extent.y);
    float dist = length(norm);
    float alpha = in.color.a * exp(-max(softness, 0.01) * dist * dist * 4.0);
    return float4(in.color.rgb, alpha);
}

// --- Gaussian blur compute kernels ---

#define SSK_MAX_BLUR_RADIUS 32u

kernel void gaussianBlurHorizontal(texture2d<float, access::sample> inTexture [[texture(0)]],
                                   texture2d<float, access::write> outTexture [[texture(1)]],
                                   constant float *weights [[buffer(0)]],
                                   constant uint &radius [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    uint clampedRadius = min(radius, SSK_MAX_BLUR_RADIUS);
    float2 texSize = float2(inTexture.get_width(), inTexture.get_height());
    float2 uv = (float2(gid) + 0.5f) / texSize;
    float4 accum = inTexture.sample(s, uv) * weights[0];
    float2 pixelStep = float2(1.0f / texSize.x, 0.0f);
    for (uint i = 1u; i <= clampedRadius; ++i) {
        float weight = weights[i];
        float2 offset = pixelStep * float(i);
        accum += inTexture.sample(s, uv + offset) * weight;
        accum += inTexture.sample(s, uv - offset) * weight;
    }
    outTexture.write(accum, gid);
}

kernel void gaussianBlurVertical(texture2d<float, access::sample> inTexture [[texture(0)]],
                                 texture2d<float, access::write> outTexture [[texture(1)]],
                                 constant float *weights [[buffer(0)]],
                                 constant uint &radius [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
        return;
    }
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    uint clampedRadius = min(radius, SSK_MAX_BLUR_RADIUS);
    float2 texSize = float2(inTexture.get_width(), inTexture.get_height());
    float2 uv = (float2(gid) + 0.5f) / texSize;
    float4 accum = inTexture.sample(s, uv) * weights[0];
    float2 pixelStep = float2(0.0f, 1.0f / texSize.y);
    for (uint i = 1u; i <= clampedRadius; ++i) {
        float weight = weights[i];
        float2 offset = pixelStep * float(i);
        accum += inTexture.sample(s, uv + offset) * weight;
        accum += inTexture.sample(s, uv - offset) * weight;
    }
    outTexture.write(accum, gid);
}

// --- Bloom kernels ---

static inline float bloomLuminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

kernel void bloomThresholdKernel(texture2d<float, access::sample> source [[texture(0)]],
                                 texture2d<float, access::write> bright [[texture(1)]],
                                 constant float &threshold [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= bright.get_width() || gid.y >= bright.get_height()) {
        return;
    }
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float4 srcColor = source.sample(s, (float2(gid) + 0.5f) / float2(source.get_width(), source.get_height()));
    float lum = bloomLuminance(srcColor.rgb);
    float bloomFactor = max(lum - threshold, 0.0f);
    float scale = bloomFactor > 0.0f ? bloomFactor / max(lum, 0.0001f) : 0.0f;
    float3 bloomColor = srcColor.rgb * scale;
    bright.write(float4(bloomColor, bloomFactor), gid);
}

kernel void bloomCompositeKernel(texture2d<float, access::sample> bloomTex [[texture(0)]],
                                 texture2d<float, access::read_write> destination [[texture(1)]],
                                 constant float &intensity [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    float4 bloom = bloomTex.sample(s, (float2(gid) + 0.5f) / float2(bloomTex.get_width(), bloomTex.get_height()));
    float4 dest = destination.read(gid);
    float glow = bloom.a * intensity;
    if (glow > 0.0001f) {
        dest.rgb = clamp(dest.rgb + bloom.rgb * glow, float3(0.0f), float3(1.0f));
    }
    destination.write(dest, gid);
}
