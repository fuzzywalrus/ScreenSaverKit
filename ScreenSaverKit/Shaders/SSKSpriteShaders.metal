#include <metal_stdlib>
using namespace metal;

// Per-sprite instance data - must match SSKMetalSpriteData in SSKMetalSpritePass.h
struct SpriteInstanceData {
    float2 position;      // Center position in screen coordinates
    float2 size;          // Width, height in pixels
    float2 sinCos;        // Precomputed [cos(rotation), sin(rotation)]
    float2 anchor;        // Anchor point (0,0 = bottom-left, 0.5,0.5 = center)
    float4 colorTint;     // RGBA tint (multiplied with texture color)
    float2 textureCoord;  // UV offset (for sprite sheets)
    float2 textureSize;   // UV size (for sprite sheets)
    float opacity;        // Overall alpha multiplier (0.0-1.0)
    float z;              // Z-order for sorting (higher = in front)
    uint textureIndex;    // Index into texture array
    float padding[1];     // Alignment
};

// Vertex output from sprite vertex shader
struct SpriteVertexOut {
    float4 position [[position]];  // Clip space position
    float2 texCoord;               // Texture coordinates
    float4 colorTint;              // Color tint to apply
    float opacity;                 // Alpha multiplier
};

// Sprite vertex shader
// Takes quad vertices (-0.5 to 0.5) and instance data, outputs transformed vertices
vertex SpriteVertexOut spriteVertex(uint vertexID [[vertex_id]],
                                    uint instanceID [[instance_id]],
                                    constant float2 *quadVertices [[buffer(0)]],
                                    constant SpriteInstanceData *instances [[buffer(1)]],
                                    constant float2 &viewport [[buffer(2)]]) {
    SpriteInstanceData sprite = instances[instanceID];
    
    // Get quad vertex (-0.5 to 0.5 range)
    float2 quad = quadVertices[vertexID];
    
    // Apply anchor offset (shift so anchor is at origin before rotation)
    // quad goes from -0.5 to 0.5, anchor is 0-1
    // For anchor 0.5,0.5 (center): offset = 0
    // For anchor 0,0 (bottom-left): offset = 0.5
    // For anchor 1,1 (top-right): offset = -0.5
    float2 anchorOffset = float2(0.5, 0.5) - sprite.anchor;
    float2 anchored = quad + anchorOffset;
    
    // Apply rotation using precomputed sin/cos
    float cosR = sprite.sinCos.x;
    float sinR = sprite.sinCos.y;
    float2 rotated = float2(
        anchored.x * cosR - anchored.y * sinR,
        anchored.x * sinR + anchored.y * cosR
    );
    
    // Scale by sprite size
    float2 scaled = rotated * sprite.size;
    
    // Translate to world position
    float2 world = sprite.position + scaled;
    
    // Convert to clip space (-1 to 1)
    // In Metal/AppKit coordinate system, Y increases upward in view space
    // but clip space has Y increasing downward, so we flip Y
    float2 clip = float2(
        (world.x / viewport.x) * 2.0 - 1.0,
        -((world.y / viewport.y) * 2.0 - 1.0)  // Flip Y for Metal
    );
    
    // Calculate texture coordinates
    // Map quad from (-0.5 to 0.5) to (0 to 1), then apply sprite sheet offset/size
    float2 uv = (quad + 0.5);  // Convert to 0-1 range
    uv = sprite.textureCoord + uv * sprite.textureSize;
    
    SpriteVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    out.texCoord = uv;
    out.colorTint = sprite.colorTint;
    out.opacity = sprite.opacity;
    
    return out;
}

// Sprite fragment shader - textured (premultiplied alpha output)
// Samples texture (already premultiplied) and applies color tint
//
// IMPORTANT: For correct blending with premultiplied alpha, when colorTint.a < 1.0,
// we must premultiply the RGB by colorTint.a. Otherwise tinted sprites with alpha < 1
// will appear too bright ("halo" effect) because the RGB values aren't properly scaled.
//
// The math for premultiplied alpha tinting:
//   - Input texture is already premultiplied: tex.rgb = original.rgb * original.a
//   - We want output: out.rgb = tex.rgb * tint.rgb * tint.a, out.a = tex.a * tint.a
//   - This correctly scales the color when the tint has transparency
fragment float4 spriteFragment(SpriteVertexOut in [[stage_in]],
                               texture2d<float> spriteTexture [[texture(0)]],
                               sampler textureSampler [[sampler(0)]]) {
    // Sample texture (premultiplied alpha)
    float4 texColor = spriteTexture.sample(textureSampler, in.texCoord);
    
    // Apply color tint with proper premultiplication:
    // - RGB: multiply by tint RGB AND tint alpha (premultiply the tint)
    // - Alpha: multiply by tint alpha only
    float4 tinted;
    tinted.rgb = texColor.rgb * in.colorTint.rgb * in.colorTint.a;
    tinted.a = texColor.a * in.colorTint.a;
    
    // Apply opacity - multiply both RGB and A since output is premultiplied
    tinted *= in.opacity;
    
    return tinted;
}

// Sprite fragment shader - solid color (premultiplied alpha output)
// Uses color tint directly, outputs premultiplied
fragment float4 spriteSolidFragment(SpriteVertexOut in [[stage_in]]) {
    float4 color = in.colorTint;
    float alpha = color.a * in.opacity;
    // Output premultiplied: RGB * alpha
    return float4(color.rgb * alpha, alpha);
}

