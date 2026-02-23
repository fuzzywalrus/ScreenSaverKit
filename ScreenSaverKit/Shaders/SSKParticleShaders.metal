#include <metal_stdlib>
using namespace metal;

struct InstanceData {
    float2 position;
    float2 direction;
    float width;
    float length;
    float4 color;
    float softness;
    float rotation;
    float padding[2];
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
    // Apply per-particle rotation on top of velocity direction
    if (abs(data.rotation) > 0.0001f) {
        float cosR = cos(data.rotation);
        float sinR = sin(data.rotation);
        forward = float2(forward.x * cosR - forward.y * sinR,
                         forward.x * sinR + forward.y * cosR);
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
    float endColor_rg;      // packed half2: r in high 16 bits, g in low 16 bits
    float endColor_ba;      // packed half2: b in high 16 bits, a in low 16 bits
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
    uint zDepthEnabled;
    float zDepthScale;
    float lengthMultiplier;
    float padding2;         // Align to 16 bytes
    float4 endColorMin;
    float4 endColorMax;
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

// Pack a float4 color into two floats using half-float bit packing.
// Each float stores two half-float values (high 16 bits + low 16 bits).
static inline void packEndColor(float4 color, thread float &out_rg, thread float &out_ba) {
    half r = half(color.x);
    half g = half(color.y);
    half b = half(color.z);
    half a = half(color.w);
    uint rg_bits = (uint(as_type<ushort>(r)) << 16) | uint(as_type<ushort>(g));
    uint ba_bits = (uint(as_type<ushort>(b)) << 16) | uint(as_type<ushort>(a));
    out_rg = as_type<float>(rg_bits);
    out_ba = as_type<float>(ba_bits);
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
    
    // Generate z-depth first (needed for velocity scaling)
    float zDepth = 1.0f;
    if (params.zDepthEnabled != 0u) {
        float zRandom = hashRandom(id * 7919 + 56789);
        // Map scale to a nearer minimum, but keep a floor so distant drops aren't comically slow.
        // scale 1 -> minZ ~0.5, scale 100 -> minZ ~0.2 (floor)
        float minZ = max(0.2f, 1.0f / (params.zDepthScale + 1.0f));
        zDepth = mix(minZ, 1.0f, zRandom); // Range: minZ (far) to 1.0 (close)
        zDepth = clamp(zDepth, 0.01f, 1.0f);
        // Store z-depth in userScalar
        state.userScalar = zDepth;
    } else {
        // Store length multiplier in userScalar (>10.0 indicates no z-depth)
        state.userScalar = 10.0f + params.lengthMultiplier;
    }
    
    // Generate velocity and scale by z-depth for perspective effect
    // Further drops (lower z-depth) move slower to create depth illusion
    state.velocity = generateVelocity(id, params);
    if (params.zDepthEnabled != 0u) {
        // Scale velocity by z-depth: far drops (0.1) move 10% speed, close drops (1.0) move 100% speed
        // This creates the perspective illusion where distant objects appear to move slower
        state.velocity *= zDepth;
    }
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
    
    // Apply z-depth darkening to color if enabled (further = darker)
    if (params.zDepthEnabled != 0u) {
        float darkenFactor = 0.3f + zDepth * 0.7f; // Far = 30% brightness, close = 100%
        state.color.rgb *= darkenFactor;
    }
    state.baseColor = state.color;
    
    // Generate rotation velocity
    float rotVelRnd = hashRandom(id * 7919 + 67890);
    state.rotationVelocity = mix(params.rotationVelocityRange.x, params.rotationVelocityRange.y, rotVelRnd);
    
    // Generate damping
    float dampingRnd = hashRandom(id * 7919 + 78901);
    state.damping = mix(params.dampingRange.x, params.dampingRange.y, dampingRnd);
    
    // Set behavior options
    state.behaviorFlags = params.behaviorOptions;

    // Generate end color for gradient behavior
    float4 endColorRnd = hashRandom4(id * 7919 + 89012);
    float4 endColor = mix(params.endColorMin, params.endColorMax, endColorRnd);
    packEndColor(endColor, state.endColor_rg, state.endColor_ba);

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

// --- Trail persistence fade kernel ---

kernel void trailFadeKernel(texture2d<float, access::read_write> trail [[texture(0)]],
                            constant float &fadeRate [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= trail.get_width() || gid.y >= trail.get_height()) {
        return;
    }
    float4 color = trail.read(gid);
    color *= (1.0f - fadeRate);
    trail.write(color, gid);
}

// --- GPU-side instance buffer building for indirect rendering ---

// userScalar mode thresholds — must match constants in SSKMetalParticlePass.m.
constant float kUserScalarDirectMultiplierThreshold = 10.0f;
constant float kUserScalarZDepthMin = 0.1f;
constant float kUserScalarZDepthMax = 1.0f;
constant float kDefaultLengthMultiplier = 8.0f;

kernel void buildInstanceData(device ParticleState *particles [[buffer(0)]],
                              device InstanceData *instances [[buffer(1)]],
                              device atomic_uint *counter [[buffer(2)]],
                              constant uint &capacity [[buffer(3)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= capacity) { return; }

    ParticleState state = particles[id];
    if (state.alive == 0u) { return; }

    // Allocate instance slot atomically
    uint instanceIndex = atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);

    // Build instance data (same logic as CPU side in SSKMetalParticlePass)
    InstanceData data;
    data.position = state.position;

    // Direction from normalized velocity
    float2 dir = state.userVector;
    float len = length(dir);
    if (len < 0.0001f) {
        dir = float2(1.0f, 0.0f);
    } else {
        dir /= len;
    }
    data.direction = dir;

    // Size
    float width = max(1.0f, state.size);
    data.width = width;

    // Length calculation - three modes based on userScalar (see threshold constants above)
    float userScalar = state.userScalar;
    if (userScalar > kUserScalarDirectMultiplierThreshold) {
        float lengthMultiplier = userScalar - kUserScalarDirectMultiplierThreshold;
        data.length = width * lengthMultiplier;
    } else if (userScalar >= kUserScalarZDepthMin && userScalar <= kUserScalarZDepthMax) {
        float zDepth = userScalar;
        data.length = width * kDefaultLengthMultiplier * zDepth;
    } else {
        data.length = width * kDefaultLengthMultiplier;
    }

    data.color = state.color;

    // Softness (edge blur) - only for non-z-depth particles
    float softness = (userScalar > kUserScalarDirectMultiplierThreshold || userScalar < kUserScalarZDepthMin) ? userScalar : 0.0f;
    if (!isfinite(softness) || softness < 0.0f) {
        softness = 0.0f;
    }
    data.softness = softness;
    data.rotation = state.rotation;

    instances[instanceIndex] = data;
}

// --- Ribbon mode: connect adjacent alive particles into elongated quad strips ---

// Pass 1: Compact alive particle indices into a sorted list.
kernel void compactAliveIndices(device ParticleState *particles [[buffer(0)]],
                                device uint *aliveIndices [[buffer(1)]],
                                device atomic_uint *aliveCounter [[buffer(2)]],
                                constant uint &capacity [[buffer(3)]],
                                uint id [[thread_position_in_grid]]) {
    if (id >= capacity) { return; }
    if (particles[id].alive == 0u) { return; }
    uint slot = atomic_fetch_add_explicit(aliveCounter, 1u, memory_order_relaxed);
    aliveIndices[slot] = id;
}

// Pass 2a: Prepare indirect draw arguments for ribbon rendering.
// Reads the alive counter (from pass 1) and writes (aliveCount - 1) as instanceCount.
kernel void prepareRibbonIndirectArgs(device atomic_uint *aliveCounter [[buffer(0)]],
                                       device uint *indirectArgs [[buffer(1)]],
                                       uint id [[thread_position_in_grid]]) {
    if (id != 0) { return; }
    uint aliveCount = atomic_load_explicit(aliveCounter, memory_order_relaxed);
    uint segments = (aliveCount > 1u) ? (aliveCount - 1u) : 0u;
    indirectArgs[0] = 4u;       // vertexCount (triangle strip quad)
    indirectArgs[1] = segments; // instanceCount
    indirectArgs[2] = 0u;       // vertexStart
    indirectArgs[3] = 0u;       // baseInstance
}

// Pass 2b: Build ribbon instance data connecting adjacent particles.
// Reads aliveCount from the atomic counter buffer (populated by pass 1).
kernel void buildRibbonInstanceData(device ParticleState *particles [[buffer(0)]],
                                     device InstanceData *instances [[buffer(1)]],
                                     device uint *aliveIndices [[buffer(2)]],
                                     device atomic_uint *aliveCounter [[buffer(3)]],
                                     uint id [[thread_position_in_grid]]) {
    uint aliveCount = atomic_load_explicit(aliveCounter, memory_order_relaxed);
    if (id + 1 >= aliveCount) { return; }

    uint idxA = aliveIndices[id];
    uint idxB = aliveIndices[id + 1];
    ParticleState stateA = particles[idxA];
    ParticleState stateB = particles[idxB];

    float2 delta = stateB.position - stateA.position;
    float segmentLength = length(delta);
    if (segmentLength < 0.001f) { return; }

    float2 midpoint = (stateA.position + stateB.position) * 0.5f;
    float2 dir = delta / segmentLength;

    // Width tapers based on average lifetime fraction (thick at head, thin at tail)
    float normA = (stateA.maxLife > 0.0f) ? clamp(stateA.life / stateA.maxLife, 0.0f, 1.0f) : 0.0f;
    float normB = (stateB.maxLife > 0.0f) ? clamp(stateB.life / stateB.maxLife, 0.0f, 1.0f) : 0.0f;
    float avgNorm = (normA + normB) * 0.5f;
    float taper = 1.0f - avgNorm * 0.7f; // Taper to 30% at end of life
    float width = max(1.0f, (stateA.size + stateB.size) * 0.5f) * taper;

    // Interpolate color
    float4 color = mix(stateA.color, stateB.color, 0.5f);

    InstanceData data;
    data.position = midpoint;
    data.direction = dir;
    data.width = width;
    data.length = segmentLength;
    data.color = color;
    data.softness = 0.0f;
    data.rotation = 0.0f;

    instances[id] = data;
}
