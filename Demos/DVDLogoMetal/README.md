# DVD Logo Metal Demo

A Metal-accelerated DVD logo bouncing screensaver that demonstrates the 2D sprite rendering capabilities of ScreenSaverKit.

## Overview

This demo showcases how to create classic sprite-based screensavers using Metal hardware acceleration. The iconic DVD logo bounces around the screen, changing color on each bounce and flipping on edge collisions - a faithful recreation of the beloved DVD player idle screen with modern enhancements.

## Features

- **Metal-Accelerated Sprite Rendering**: Uses `SSKMetalSpritePass` for GPU-accelerated 2D sprite rendering
- **Color Cycling**: Smooth hue transitions with instant color changes on bounce
- **Bounce Physics**: Classic edge collision detection with perfect corner hit potential
- **Flip on Bounce**: Sprite flips horizontally/vertically when hitting edges (demonstrates flip feature)
- **Retina Support**: Pixel-accurate positioning that works correctly on high-DPI displays
- **CPU Fallback**: Automatic fallback to CoreGraphics rendering when Metal is unavailable

## How It Works

### 1. Subclassing SSKMetalScreenSaverView

The demo inherits from `SSKMetalScreenSaverView`, which handles all Metal infrastructure setup:

```objc
@interface DVDLogoMetalView : SSKMetalScreenSaverView
@end
```

This base class provides:
- Automatic `CAMetalLayer` setup
- `SSKMetalRenderer` initialization
- Frame timing via `SSKAnimationClock`
- Automatic CPU fallback when Metal is unavailable

### 2. Creating a Sprite

Sprites are represented by `SSKSprite` objects with properties for position, size, rotation, scale, color tinting, and opacity:

```objc
SSKSprite *logoSprite = [[SSKSprite alloc] init];
logoSprite.size = NSMakeSize(180.0, 100.0);  // Size in pixels
logoSprite.scale = CGSizeMake(1.0, 1.0);     // Scale multiplier
logoSprite.colorTint = [NSColor redColor];
logoSprite.opacity = 1.0;

// Use pixel coordinates (convert from points for Retina)
CGFloat scale = self.window.backingScaleFactor ?: 1.0;
[logoSprite setPositionInPoints:NSMakePoint(centerX, centerY) scale:scale];
```

### 3. Loading Textures

Sprites can display textures loaded from images. The `SSKSprite` class provides convenient texture caching:

```objc
// Set the source image
logoSprite.image = [[NSImage alloc] initWithContentsOfFile:imagePath];

// Get or create the Metal texture (cached automatically)
id<MTLTexture> texture = [logoSprite textureForDevice:renderer.device];
```

### 4. Rendering Sprites

In your `renderMetalFrame:deltaTime:` override, draw sprites using the renderer:

```objc
- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    // Clear the background
    [renderer clearWithColor:renderer.clearColor];
    
    // Update sprite position/animation
    [self updateAnimation:dt];
    
    // Draw the sprite (renderer handles pixel coordinate conversion)
    [renderer drawSprites:@[self.logoSprite]
                  texture:self.logoTexture
                blendMode:SSKParticleBlendModeAlpha
             viewportSize:self.bounds.size];
}
```

### 5. Bounce Logic with Flip

The classic bounce animation checks if the sprite has hit an edge, with added flip on bounce:

```objc
- (void)updatePositionWithDeltaTime:(NSTimeInterval)dt {
    CGFloat halfWidth = self.logoSprite.size.width / 2.0;
    
    // Update position
    position.x += velocity.x * dt;
    
    // Bounce off edges
    if (position.x - halfWidth < 0 || position.x + halfWidth > bounds.width) {
        velocity.x = -velocity.x;         // Reverse direction
        self.logoSprite.flipX = !self.logoSprite.flipX;  // Flip horizontally
        [self cycleToNextColor];          // Change color on bounce
    }
}
```

## Coordinate System

**Important**: All sprite coordinates and sizes are in **pixels**, not points. On Retina displays:

- Use `setPositionInPoints:scale:` to convert from points to pixels
- The `scale` parameter should be `window.backingScaleFactor` or `layer.contentsScale`
- The `viewportSize` passed to `drawSprites:` is in points; the renderer converts internally

```objc
// Setup
CGFloat scale = self.window.backingScaleFactor ?: 1.0;
[sprite setPositionInPoints:NSMakePoint(100, 200) scale:scale];

// Update
position.x += velocity.x * dt;  // velocity is in points/second
[sprite setPositionInPoints:position scale:scale];
```

## Building and Running

```bash
cd Demos/DVDLogoMetal
make clean && make
make install  # Installs to ~/Library/Screen Savers/
make run      # Installs and launches Screen Saver Engine
```

## Performance Comparison

| Approach | CPU Usage | GPU Usage | Frame Time |
|----------|-----------|-----------|------------|
| Metal (this demo) | ~1% | ~2% | <1ms |
| CoreGraphics fallback | ~5-8% | N/A | ~3-5ms |

Metal acceleration provides smoother rendering with significantly lower CPU usage, especially when scaling to multiple sprites.

## Key Classes Used

- **SSKMetalScreenSaverView**: Base class for Metal-accelerated screensavers
- **SSKMetalRenderer**: Unified Metal renderer with sprite and particle support
- **SSKMetalSpritePass**: Render pass for 2D sprite batching with culling and z-sorting
- **SSKSprite**: Simple sprite object with transform and texture properties
- **SSKSpriteAnimationSequence**: Animation data for sprite sheet playback

## Sprite Properties Reference

| Property | Type | Description |
|----------|------|-------------|
| `position` | `NSPoint` | Anchor point position in **pixels** |
| `size` | `NSSize` | Width and height in **pixels** |
| `scale` | `CGSize` | Scale multiplier; negative values flip the sprite |
| `flipX` | `BOOL` | Convenience for horizontal flip (modifies scale sign) |
| `flipY` | `BOOL` | Convenience for vertical flip (modifies scale sign) |
| `rotation` | `CGFloat` | Rotation angle in radians |
| `anchor` | `NSPoint` | Anchor point (0,0 = bottom-left, 0.5,0.5 = center) |
| `colorTint` | `NSColor` | Color multiplied with texture (premultiplied alpha) |
| `opacity` | `CGFloat` | Alpha multiplier (0.0-1.0) |
| `z` | `float` | Z-order for depth sorting (higher = in front) |
| `image` | `NSImage` | Source image for texture |
| `textureOffset` | `NSPoint` | UV offset for sprite sheets (normalized 0-1) |
| `textureSize` | `NSSize` | UV size for sprite sheets (normalized 0-1) |
| `animation` | `SSKSpriteAnimationSequence` | Animation sequence for sprite sheets |
| `animationPlaying` | `BOOL` | Whether animation is currently playing |
| `animationRate` | `CGFloat` | Playback speed (1.0 = normal, -1.0 = reverse) |

## Advanced: Multiple Sprites with Z-Sorting

For effects like "flying toasters", create multiple sprites and use z-sorting for proper depth:

```objc
NSMutableArray<SSKSprite *> *sprites = [NSMutableArray array];

for (int i = 0; i < 10; i++) {
    SSKSprite *sprite = [[SSKSprite alloc] init];
    sprite.position = randomPosition();
    sprite.z = (float)i * 0.1f;  // Higher z = rendered in front
    [sprites addObject:sprite];
}

// Render all sprites with z-sorting (lower z drawn first)
[renderer drawSprites:sprites
              texture:toasterTexture
            blendMode:SSKParticleBlendModeAlpha
         viewportSize:self.bounds.size
              sortByZ:YES];
```

## Advanced: Sprite Sheet Animation

Use `SSKSpriteAnimationSequence` for animated sprites:

```objc
// Create animation from a 4x2 sprite sheet grid
SSKSpriteAnimationSequence *anim = [SSKSpriteAnimationSequence 
    sequenceWithGridColumns:4 rows:2 frameCount:8 
    duration:0.1 loopMode:SSKAnimationLoopModeLoop];

// Assign to sprite
sprite.animation = anim;
sprite.animationRate = 1.0;  // Normal speed

// In update loop
[sprite advanceAnimationByTime:dt];
```

## Advanced: Viewport Culling

Enable culling to skip off-screen sprites (improves performance with many sprites):

```objc
renderer.spritePass.cullingEnabled = YES;

// Sprites far outside viewport are automatically skipped during encoding
[renderer drawSprites:manySprites
              texture:texture
            blendMode:SSKParticleBlendModeAlpha
         viewportSize:self.bounds.size];
```

## Blend Modes

The sprite pass supports two blend modes:

- **SSKParticleBlendModeAlpha**: Standard alpha blending for opaque/transparent sprites (uses premultiplied alpha)
- **SSKParticleBlendModeAdditive**: Additive blending for glow effects

## Related Documentation

- [EFFECT_IMPLEMENTATION_GUIDE.md](../../architecture-docs/EFFECT_IMPLEMENTATION_GUIDE.md) - General guide for creating screensaver effects
- [SSKParticleSystem.md](../../ScreenSaverKit/SSKParticleSystem.md) - Particle system documentation
- [tutorial.md](../../tutorial.md) - Getting started tutorial
