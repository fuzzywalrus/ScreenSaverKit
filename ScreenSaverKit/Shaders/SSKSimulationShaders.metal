#include <metal_stdlib>
using namespace metal;

// ParticleState must match SSKParticleState in SSKParticleSystem.m (128 bytes, 16-byte aligned)
struct ParticleState {
    float2 position;
    float2 velocity;
    float2 userVector;
    float2 sizeRange;       // start, end multipliers for FadeSize
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

// SimulationUniforms — 256 bytes, replaces the old 20-byte SSKParticleSimulationUniforms.
// Legacy fields at offsets 0-19 match the old layout so existing metallibs remain compatible.
struct SimulationUniforms {
    // Legacy fields (offset 0-19)
    float2 gravity;             // 0
    float dt;                   // 8
    float globalDamping;        // 12
    uint particleCount;         // 16

    // Feature flags bitmask (offset 20)
    uint featureFlags;          // bit0=curlNoise, bit1=attractors, bit2=colorGradient, bit3=velocityHue

    // Curl noise parameters (offset 24-39)
    float noiseScale;           // Spatial frequency
    float noiseStrength;        // Force magnitude
    float noiseSpeed;           // Animation speed
    float noiseTime;            // Current animated time

    // Attractor points (offset 40-103)
    float2 attractors[4];       // Positions
    float attractorStrengths[4];// Per-attractor strength
    uint attractorCount;        // Active count (0-4)

    // Global time (offset 108)
    float globalTime;           // Total elapsed time

    // Padding to 256 bytes
    uint _pad[36];
};

// Feature flag constants
constant uint kFeatureCurlNoise     = (1u << 0);
constant uint kFeatureAttractors    = (1u << 1);
constant uint kFeatureColorGradient = (1u << 2);
constant uint kFeatureVelocityHue   = (1u << 3);

// Behavior flag constants (must match SSKParticleBehaviorOptions in SSKParticleSystem.h)
constant uint kBehaviorFadeAlpha = 1u;
constant uint kBehaviorFadeSize  = 2u;
constant uint kBehaviorColorGradient = 4u;

// --- Half-float color packing utilities ---

static inline float4 unpackEndColor(float rg_packed, float ba_packed) {
    // Reinterpret float bits as two half-floats each
    uint rg_bits = as_type<uint>(rg_packed);
    uint ba_bits = as_type<uint>(ba_packed);
    half r = as_type<half>(ushort(rg_bits >> 16));
    half g = as_type<half>(ushort(rg_bits & 0xFFFF));
    half b = as_type<half>(ushort(ba_bits >> 16));
    half a = as_type<half>(ushort(ba_bits & 0xFFFF));
    return float4(float(r), float(g), float(b), float(a));
}

// --- 2D Simplex Noise (Ashima Arts) ---

static inline float3 mod289(float3 x) { return x - floor(x * (1.0f / 289.0f)) * 289.0f; }
static inline float2 mod289(float2 x) { return x - floor(x * (1.0f / 289.0f)) * 289.0f; }
static inline float3 permute(float3 x) { return mod289(((x * 34.0f) + 1.0f) * x); }

static inline float snoise(float2 v) {
    const float4 C = float4(0.211324865405187f,  // (3.0-sqrt(3.0))/6.0
                             0.366025403784439f,  // 0.5*(sqrt(3.0)-1.0)
                            -0.577350269189626f,  // -1.0 + 2.0 * C.x
                             0.024390243902439f); // 1.0/41.0
    // First corner
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    // Other corners
    float2 i1 = (x0.x > x0.y) ? float2(1.0f, 0.0f) : float2(0.0f, 1.0f);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    // Permutations
    i = mod289(i);
    float3 p = permute(permute(i.y + float3(0.0f, i1.y, 1.0f))
                        + i.x + float3(0.0f, i1.x, 1.0f));
    float3 m = max(0.5f - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0f);
    m = m * m;
    m = m * m;
    // Gradients
    float3 x_ = 2.0f * fract(p * C.www) - 1.0f;
    float3 h = abs(x_) - 0.5f;
    float3 ox = floor(x_ + 0.5f);
    float3 a0 = x_ - ox;
    m *= 1.79284291400159f - 0.85373472095314f * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.y = a0.y * x12.x + h.y * x12.y;
    g.z = a0.z * x12.z + h.z * x12.w;
    return 130.0f * dot(m, g);
}

/// 2D curl noise: divergence-free velocity from the gradient of a scalar noise field.
/// Uses finite differences of snoise to compute the curl (rotated gradient).
static inline float2 curlNoise(float2 p, float time) {
    float eps = 0.001f;
    float n0 = snoise(p + float2(eps, 0.0f) + float2(time, 0.0f));
    float n1 = snoise(p - float2(eps, 0.0f) + float2(time, 0.0f));
    float n2 = snoise(p + float2(0.0f, eps) + float2(time, 0.0f));
    float n3 = snoise(p - float2(0.0f, eps) + float2(time, 0.0f));
    float dndx = (n0 - n1) / (2.0f * eps);
    float dndy = (n2 - n3) / (2.0f * eps);
    return float2(dndy, -dndx); // curl = rotated gradient → divergence-free
}

// --- Simulation kernel ---

kernel void simulateParticles(device ParticleState *particles [[buffer(0)]],
                              constant SimulationUniforms &uniforms [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uniforms.particleCount) { return; }

    ParticleState state = particles[id];
    if (state.alive == 0u) { return; }

    float dt = uniforms.dt;

    // Advance lifetime
    state.life += dt;
    if (state.life >= state.maxLife) {
        state.alive = 0u;
        particles[id] = state;
        return;
    }

    // Gravity
    if (uniforms.gravity.x != 0.0f || uniforms.gravity.y != 0.0f) {
        state.velocity += uniforms.gravity * dt;
    }

    // Curl noise force field (Phase 4)
    if ((uniforms.featureFlags & kFeatureCurlNoise) != 0u) {
        float2 samplePos = state.position * uniforms.noiseScale;
        float2 curl = curlNoise(samplePos, uniforms.noiseTime);
        state.velocity += curl * uniforms.noiseStrength * dt;
    }

    // Attractor points (Phase 5)
    if ((uniforms.featureFlags & kFeatureAttractors) != 0u) {
        for (uint i = 0u; i < uniforms.attractorCount && i < 4u; i++) {
            float2 toAttractor = uniforms.attractors[i] - state.position;
            float dist = max(length(toAttractor), 1.0f);
            state.velocity += normalize(toAttractor) * (uniforms.attractorStrengths[i] / (dist * dist)) * dt;
        }
    }

    // Per-particle + global damping
    float damping = max(0.0f, state.damping + uniforms.globalDamping);
    if (damping > 0.0f) {
        float factor = pow(max(0.0f, 1.0f - damping), dt);
        state.velocity *= factor;
    }

    // Position integration
    state.position += state.velocity * dt;

    // Rotation
    state.rotation += state.rotationVelocity * dt;

    // Size velocity
    if (fabs(state.sizeVelocity) > 0.0001f) {
        state.size = max(0.0f, state.size + state.sizeVelocity * dt);
    }

    // Lifetime-normalized value for behaviors
    float normalized = (state.maxLife > 0.0f) ? clamp(state.life / state.maxLife, 0.0f, 1.0f) : 0.0f;

    // FadeAlpha behavior
    if ((state.behaviorFlags & kBehaviorFadeAlpha) != 0u) {
        float fade = 1.0f - normalized;
        state.color = float4(state.baseColor.rgb, state.baseColor.a * fade);
    } else {
        state.color = float4(state.color.rgb, state.color.a);
    }

    // FadeSize behavior
    if ((state.behaviorFlags & kBehaviorFadeSize) != 0u) {
        float multiplier = mix(state.sizeRange.x, state.sizeRange.y, normalized);
        state.size = max(0.0f, state.baseSize * multiplier);
    }

    // ColorGradient behavior (Phase 2) — interpolate baseColor → endColor
    if ((state.behaviorFlags & kBehaviorColorGradient) != 0u) {
        float4 endColor = unpackEndColor(state.endColor_rg, state.endColor_ba);
        float4 blended = mix(state.baseColor, endColor, normalized);
        // Preserve FadeAlpha if also active
        if ((state.behaviorFlags & kBehaviorFadeAlpha) != 0u) {
            float fade = 1.0f - normalized;
            blended.a *= fade;
        }
        state.color = blended;
    }

    // Normalize velocity → userVector (direction for rendering)
    float velLenSq = length_squared(state.velocity);
    if (velLenSq > 0.0001f) {
        state.userVector = state.velocity * rsqrt(velLenSq);
    }

    particles[id] = state;
}
