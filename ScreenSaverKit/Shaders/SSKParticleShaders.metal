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

// --- Particle initialization compute kernel ---

// ParticleState structure must match SSKParticleState in SSKParticleSystem.m
struct ParticleState {
    float2 position;
    float2 velocity;
    float2 userVector;
    float2 sizeRange;
    float4 color;
    float4 baseColor;
    float life;
    float maxLife;
    float size;
    float baseSize;
    float sizeVelocity;
    float rotation;
    float rotationVelocity;
    float damping;
    float userScalar;
    uint behaviorFlags;
    uint alive;
    uint padding0;
    uint padding1;
};

// SpawnParameters structure must match SSKParticleSpawnParameters (with alignment)
struct SpawnParameters {
    uint regionType;        // SSKParticleSpawnRegionType
    float padding0;         // Align to 16 bytes for float2
    float2 center;
    float2 size;
    float2 velocityXRange;
    float2 velocityYRange;
    float2 speedRange;
    float directionAngle;
    float directionSpread;
    float2 sizeRange;
    float2 lifeRange;
    float4 colorMin;
    float4 colorMax;
    float2 rotationVelocityRange;
    float2 dampingRange;
    uint behaviorOptions;
    float padding1;         // Align to 16 bytes for float2
    float2 sizeOverLifeRange;
};

// Simple hash-based random number generator for GPU
static inline float hashRandom(uint seed) {
    uint n = seed;
    n = (n << 13) ^ n;
    n = n * (n * n * 15731 + 789221) + 1376312589;
    return fract(float(n) * (1.0 / 4294967296.0));
}

static inline float2 hashRandom2(uint seed) {
    return float2(hashRandom(seed), hashRandom(seed + 1));
}

static inline float4 hashRandom4(uint seed) {
    return float4(hashRandom(seed), hashRandom(seed + 1), hashRandom(seed + 2), hashRandom(seed + 3));
}

// Generate random position based on spawn region type
static inline float2 generateSpawnPosition(uint index, constant SpawnParameters &params) {
    float2 rnd = hashRandom2(index * 7919 + 12345);
    
    switch (params.regionType) {
        case 0: { // SSKParticleSpawnRegionTypeRectangle
            return params.center + float2(
                (rnd.x - 0.5f) * params.size.x,
                (rnd.y - 0.5f) * params.size.y
            );
        }
        case 1: { // SSKParticleSpawnRegionTypeCircle
            float angle = rnd.x * 2.0f * 3.14159265359f;
            float radius = sqrt(rnd.y) * params.size.x; // sqrt for uniform distribution
            return params.center + float2(cos(angle), sin(angle)) * radius;
        }
        case 2: // SSKParticleSpawnRegionTypePoint
        default:
            return params.center;
    }
}

// Generate random velocity based on parameters
static inline float2 generateVelocity(uint index, constant SpawnParameters &params) {
    float2 rnd = hashRandom2(index * 7919 + 23456);
    
    // Check if using directional spawning (speedRange is set)
    if (params.speedRange.y > params.speedRange.x) {
        float speed = mix(params.speedRange.x, params.speedRange.y, rnd.x);
        float angle = params.directionAngle + (rnd.y - 0.5f) * params.directionSpread;
        return float2(cos(angle), sin(angle)) * speed;
    } else {
        // Use velocity ranges
        float vx = mix(params.velocityXRange.x, params.velocityXRange.y, rnd.x);
        float vy = mix(params.velocityYRange.x, params.velocityYRange.y, rnd.y);
        return float2(vx, vy);
    }
}

kernel void initializeParticles(device ParticleState *particles [[buffer(0)]],
                                constant SpawnParameters &params [[buffer(1)]],
                                device uint *indices [[buffer(2)]],
                                constant uint &count [[buffer(3)]],
                                uint id [[thread_position_in_grid]]) {
    if (id >= count) { return; }
    
    uint particleIndex = indices[id];
    ParticleState state;
    
    // Initialize with defaults
    state.alive = 1u;
    state.life = 0.0f;
    state.rotation = 0.0f;
    state.sizeVelocity = 0.0f;
    state.userScalar = 0.0f;
    state.userVector = float2(0.0f, 0.0f);
    
    // Generate spawn position
    state.position = generateSpawnPosition(id, params);
    
    // Generate velocity
    state.velocity = generateVelocity(id, params);
    state.userVector = normalize(state.velocity);
    
    // Generate size
    float sizeRnd = hashRandom(id * 7919 + 34567);
    state.size = mix(params.sizeRange.x, params.sizeRange.y, sizeRnd);
    state.baseSize = state.size;
    state.sizeRange = params.sizeOverLifeRange;
    
    // Generate life
    float lifeRnd = hashRandom(id * 7919 + 45678);
    state.maxLife = mix(params.lifeRange.x, params.lifeRange.y, lifeRnd);
    
    // Generate color
    float4 colorRnd = hashRandom4(id * 7919 + 56789);
    state.color = mix(params.colorMin, params.colorMax, colorRnd);
    state.baseColor = state.color;
    
    // Generate rotation velocity
    float rotVelRnd = hashRandom(id * 7919 + 67890);
    state.rotationVelocity = mix(params.rotationVelocityRange.x, params.rotationVelocityRange.y, rotVelRnd);
    
    // Generate damping
    float dampingRnd = hashRandom(id * 7919 + 78901);
    state.damping = mix(params.dampingRange.x, params.dampingRange.y, dampingRnd);
    
    // Set behavior options
    state.behaviorFlags = params.behaviorOptions;
    
    // Write state to particle buffer
    particles[particleIndex] = state;
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
    // Use linear filtering for better quality when upscaling from half-resolution bloom
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    // Calculate UV coordinates in destination space, then map to bloom texture space
    // This handles both full-res and half-res bloom textures correctly
    float2 destUV = (float2(gid) + 0.5f) / float2(destination.get_width(), destination.get_height());
    float4 bloom = bloomTex.sample(s, destUV);
    float4 dest = destination.read(gid);
    float glow = bloom.a * intensity;
    if (glow > 0.0001f) {
        dest.rgb = clamp(dest.rgb + bloom.rgb * glow, float3(0.0f), float3(1.0f));
    }
    destination.write(dest, gid);
}
