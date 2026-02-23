#include <metal_stdlib>
using namespace metal;

// --- Uniforms ---

struct LineUniforms {
    float2 screenSize;       // in pixels
    float2 gridOrigin;       // pixel offset for centering the grid
    float gridSpacing;       // pixels between grid points (e.g. 15)
    uint2 gridDimensions;    // (cols, rows)
    float lineLength;        // base half-length in pixels
    float lineWidth;         // base half-width in pixels
    float4 color;            // base line color (from palette)
};

// --- Vertex Output ---

struct LineVertexOut {
    float4 position [[position]];
    float2 localUV;          // [-1,1] along length, [0,1] across width
    float4 color;
};

// --- Vertex Shader ---
// Instanced: each instance is one grid cell.
// vertex_id 0-3 expands to a quad aligned with the local velocity.

vertex LineVertexOut ambleLineVertex(uint vertex_id [[vertex_id]],
                                     uint instance_id [[instance_id]],
                                     constant LineUniforms &u [[buffer(0)]],
                                     texture2d<float, access::sample> velocityTex [[texture(0)]]) {
    // Grid position from instance ID
    uint col = instance_id % u.gridDimensions.x;
    uint row = instance_id / u.gridDimensions.x;

    // Screen-space position of this grid point
    float2 screenPos = u.gridOrigin + float2(float(col), float(row)) * u.gridSpacing;

    // Sample velocity at this grid point (normalized UV into velocity texture)
    constexpr sampler bilinear(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 velUV = float2(float(col) / float(u.gridDimensions.x - 1),
                           float(row) / float(u.gridDimensions.y - 1));
    float2 vel = velocityTex.sample(bilinear, velUV).xy;

    // Velocity magnitude for alpha scaling
    float speed = length(vel);
    float alpha = clamp(speed * 2.0f, 0.05f, 1.0f);

    // Direction from velocity (default to rightward if near-zero)
    float2 dir;
    if (speed > 0.001f) {
        dir = vel / speed;
    } else {
        dir = float2(1.0f, 0.0f);
        alpha = 0.02f;
    }

    // Perpendicular
    float2 perp = float2(-dir.y, dir.x);

    // Scale length by speed
    float halfLen = u.lineLength * (0.5f + speed * 1.5f);
    float halfWid = u.lineWidth;

    // Quad corners: vertex_id 0-3 → triangle strip
    //   0: (-len, -wid)  1: (+len, -wid)
    //   2: (-len, +wid)  3: (+len, +wid)
    float lenSign = (vertex_id & 1u) ? 1.0f : -1.0f;
    float widSign = (vertex_id & 2u) ? 1.0f : -1.0f;

    float2 offset = dir * (halfLen * lenSign) + perp * (halfWid * widSign);
    float2 pixelPos = screenPos + offset;

    // Convert to normalized device coordinates [-1, 1]
    float2 ndc = (pixelPos / u.screenSize) * 2.0f - 1.0f;

    LineVertexOut out;
    out.position = float4(ndc, 0.0f, 1.0f);
    out.localUV = float2(lenSign, (widSign + 1.0f) * 0.5f); // [-1,1] x [0,1]
    out.color = float4(u.color.rgb, u.color.a * alpha);
    return out;
}

// --- Fragment Shader ---

fragment float4 ambleLineFragment(LineVertexOut in [[stage_in]]) {
    // Soft edge along width dimension
    float widthFade = 1.0f - abs(in.localUV.y * 2.0f - 1.0f);
    widthFade = smoothstep(0.0f, 0.4f, widthFade);

    // Soft taper at line ends
    float lengthFade = 1.0f - abs(in.localUV.x);
    lengthFade = smoothstep(0.0f, 0.3f, lengthFade);

    float fade = widthFade * lengthFade;
    float4 color = in.color;
    color.a *= fade;

    // Premultiplied alpha output for additive blending
    return float4(color.rgb * color.a, color.a);
}
