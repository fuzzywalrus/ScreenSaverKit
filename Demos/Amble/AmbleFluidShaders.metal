#include <metal_stdlib>
using namespace metal;

// --- Uniforms ---

struct FluidUniforms {
    float2 gridSize;
    float2 inverseGridSize;
    float dt;
    float viscosity;
    float noiseMultiplier;
    float noiseTime;
    float2 noiseScales[3];
    float dissipation;
};

// --- Simplex Noise (Ashima Arts, adapted from SSKSimulationShaders.metal) ---

static inline float3 mod289f3(float3 x) { return x - floor(x * (1.0f / 289.0f)) * 289.0f; }
static inline float2 mod289f2(float2 x) { return x - floor(x * (1.0f / 289.0f)) * 289.0f; }
static inline float3 permutef3(float3 x) { return mod289f3(((x * 34.0f) + 1.0f) * x); }

static inline float snoise(float2 v) {
    const float4 C = float4(0.211324865405187f,
                             0.366025403784439f,
                            -0.577350269189626f,
                             0.024390243902439f);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0f, 0.0f) : float2(0.0f, 1.0f);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289f2(i);
    float3 p = permutef3(permutef3(i.y + float3(0.0f, i1.y, 1.0f))
                          + i.x + float3(0.0f, i1.x, 1.0f));
    float3 m = max(0.5f - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0f);
    m = m * m;
    m = m * m;
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

// Curl noise from scalar noise: returns divergence-free 2D velocity.
static inline float2 curlNoise2D(float2 p) {
    float eps = 0.01f;
    float n0 = snoise(p + float2(eps, 0.0f));
    float n1 = snoise(p - float2(eps, 0.0f));
    float n2 = snoise(p + float2(0.0f, eps));
    float n3 = snoise(p - float2(0.0f, eps));
    float dndx = (n0 - n1) / (2.0f * eps);
    float dndy = (n2 - n3) / (2.0f * eps);
    return float2(dndy, -dndx);
}

// --- Helper: boundary-safe texel read ---

static inline float2 readVelocity(texture2d<float, access::read> tex, uint2 pos, uint2 gridSize) {
    uint2 clamped = clamp(pos, uint2(0), gridSize - uint2(1));
    return tex.read(clamped).xy;
}

static inline float readScalar(texture2d<float, access::read> tex, uint2 pos, uint2 gridSize) {
    uint2 clamped = clamp(pos, uint2(0), gridSize - uint2(1));
    return tex.read(clamped).x;
}

// ==========================================================================
// Kernel 1: MacCormack Advection
// ==========================================================================

kernel void advect(texture2d<float, access::sample> velocityIn [[texture(0)]],
                   texture2d<float, access::write> velocityOut [[texture(1)]],
                   constant FluidUniforms &u [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.gridSize.x) || gid.y >= uint(u.gridSize.y)) return;

    constexpr sampler bilinear(coord::normalized, filter::linear, address::clamp_to_edge);

    float2 texelSize = u.inverseGridSize;
    float2 uv = (float2(gid) + 0.5f) * texelSize;

    // Current velocity at this cell
    float2 vel = velocityIn.sample(bilinear, uv).xy;

    // Forward trace: where did the fluid come from?
    float2 backPos = uv - vel * texelSize * u.dt;
    float2 phi_hat = velocityIn.sample(bilinear, backPos).xy;

    // Reverse trace from forward result
    float2 fwdPos = backPos + phi_hat * texelSize * u.dt;
    float2 phi_rev = velocityIn.sample(bilinear, fwdPos).xy;

    // MacCormack correction
    float2 corrected = phi_hat + 0.5f * (vel - phi_rev);

    // Clamp to min/max of neighbors to prevent oscillation
    float2 minVal = vel, maxVal = vel;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 neighborUV = uv + float2(dx, dy) * texelSize;
            float2 neighborVel = velocityIn.sample(bilinear, neighborUV).xy;
            minVal = min(minVal, neighborVel);
            maxVal = max(maxVal, neighborVel);
        }
    }
    corrected = clamp(corrected, minVal, maxVal);

    velocityOut.write(float4(corrected, 0.0f, 0.0f), gid);
}

// ==========================================================================
// Kernel 2: Jacobi Diffusion
// ==========================================================================

kernel void diffuse(texture2d<float, access::read> velocityIn [[texture(0)]],
                    texture2d<float, access::write> velocityOut [[texture(1)]],
                    constant FluidUniforms &u [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    uint2 gs = uint2(u.gridSize);
    if (gid.x >= gs.x || gid.y >= gs.y) return;

    float alpha = (u.gridSize.x * u.gridSize.y) / max(u.viscosity * u.dt, 0.0001f);
    float rBeta = 1.0f / (4.0f + alpha);

    float2 center = readVelocity(velocityIn, gid, gs);
    float2 left   = readVelocity(velocityIn, uint2(gid.x - 1, gid.y), gs);
    float2 right  = readVelocity(velocityIn, uint2(gid.x + 1, gid.y), gs);
    float2 bottom = readVelocity(velocityIn, uint2(gid.x, gid.y - 1), gs);
    float2 top    = readVelocity(velocityIn, uint2(gid.x, gid.y + 1), gs);

    float2 result = (left + right + bottom + top + alpha * center) * rBeta;
    velocityOut.write(float4(result, 0.0f, 0.0f), gid);
}

// ==========================================================================
// Kernel 3: Noise Injection (3-layer curl noise)
// ==========================================================================

kernel void addNoise(texture2d<float, access::read> velocityIn [[texture(0)]],
                     texture2d<float, access::write> velocityOut [[texture(1)]],
                     constant FluidUniforms &u [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    uint2 gs = uint2(u.gridSize);
    if (gid.x >= gs.x || gid.y >= gs.y) return;

    float2 vel = velocityIn.read(gid).xy;
    float2 pos = float2(gid) * u.inverseGridSize;

    // 3-layer curl noise at different scales
    float2 noiseForce = float2(0.0f);
    for (int i = 0; i < 3; i++) {
        float2 samplePos = pos * u.noiseScales[i] + float2(u.noiseTime * 0.1f * float(i + 1));
        noiseForce += curlNoise2D(samplePos);
    }
    noiseForce *= u.noiseMultiplier;

    vel += noiseForce * u.dt;
    velocityOut.write(float4(vel, 0.0f, 0.0f), gid);
}

// ==========================================================================
// Kernel 4: Compute Divergence
// ==========================================================================

kernel void computeDivergence(texture2d<float, access::read> velocity [[texture(0)]],
                              texture2d<float, access::write> divergenceOut [[texture(1)]],
                              constant FluidUniforms &u [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    uint2 gs = uint2(u.gridSize);
    if (gid.x >= gs.x || gid.y >= gs.y) return;

    float2 vL = readVelocity(velocity, uint2(gid.x - 1, gid.y), gs);
    float2 vR = readVelocity(velocity, uint2(gid.x + 1, gid.y), gs);
    float2 vB = readVelocity(velocity, uint2(gid.x, gid.y - 1), gs);
    float2 vT = readVelocity(velocity, uint2(gid.x, gid.y + 1), gs);

    float div = 0.5f * ((vR.x - vL.x) + (vT.y - vB.y));
    divergenceOut.write(float4(div, 0.0f, 0.0f, 0.0f), gid);
}

// ==========================================================================
// Kernel 5: Jacobi Pressure Solve
// ==========================================================================

kernel void pressureSolve(texture2d<float, access::read> pressureIn [[texture(0)]],
                          texture2d<float, access::write> pressureOut [[texture(1)]],
                          texture2d<float, access::read> divergence [[texture(2)]],
                          constant FluidUniforms &u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint2 gs = uint2(u.gridSize);
    if (gid.x >= gs.x || gid.y >= gs.y) return;

    float pL = readScalar(pressureIn, uint2(gid.x - 1, gid.y), gs);
    float pR = readScalar(pressureIn, uint2(gid.x + 1, gid.y), gs);
    float pB = readScalar(pressureIn, uint2(gid.x, gid.y - 1), gs);
    float pT = readScalar(pressureIn, uint2(gid.x, gid.y + 1), gs);
    float div = divergence.read(gid).x;

    float p = (pL + pR + pB + pT - div) * 0.25f;
    pressureOut.write(float4(p, 0.0f, 0.0f, 0.0f), gid);
}

// ==========================================================================
// Kernel 6: Subtract Pressure Gradient (projection)
// ==========================================================================

kernel void subtractGradient(texture2d<float, access::read> velocityIn [[texture(0)]],
                             texture2d<float, access::write> velocityOut [[texture(1)]],
                             texture2d<float, access::read> pressure [[texture(2)]],
                             constant FluidUniforms &u [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint2 gs = uint2(u.gridSize);
    if (gid.x >= gs.x || gid.y >= gs.y) return;

    float pL = readScalar(pressure, uint2(gid.x - 1, gid.y), gs);
    float pR = readScalar(pressure, uint2(gid.x + 1, gid.y), gs);
    float pB = readScalar(pressure, uint2(gid.x, gid.y - 1), gs);
    float pT = readScalar(pressure, uint2(gid.x, gid.y + 1), gs);

    float2 vel = velocityIn.read(gid).xy;
    float2 grad = 0.5f * float2(pR - pL, pT - pB);
    vel -= grad;

    velocityOut.write(float4(vel, 0.0f, 0.0f), gid);
}

// ==========================================================================
// Kernel 7: Velocity Dissipation (fade)
// ==========================================================================

kernel void fadeVelocity(texture2d<float, access::read> velocityIn [[texture(0)]],
                         texture2d<float, access::write> velocityOut [[texture(1)]],
                         constant FluidUniforms &u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint2 gs = uint2(u.gridSize);
    if (gid.x >= gs.x || gid.y >= gs.y) return;

    float2 vel = velocityIn.read(gid).xy;
    vel *= u.dissipation;
    velocityOut.write(float4(vel, 0.0f, 0.0f), gid);
}
