#import "DVDLogoMetalView.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

#import "ScreenSaverKit/SSKMetalRenderer.h"
#import "ScreenSaverKit/SSKSprite.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKDiagnostics.h"

/// Default logo size in pixels
static const CGFloat kLogoWidth = 180.0;
static const CGFloat kLogoHeight = 100.0;

/// Default movement speed in points per second
static const CGFloat kDefaultSpeed = 150.0;

/// Color cycling rate (hue change per second)
static const CGFloat kColorCycleRate = 0.15;

@interface DVDLogoMetalView ()

/// The sprite representing the DVD logo
@property (nonatomic, strong) SSKSprite *logoSprite;

/// Current position in POINTS (for correct animation math)
/// The sprite's position property is in pixels; this is our source of truth for movement
@property (nonatomic) NSPoint positionInPoints;

/// Current velocity in POINTS per second
@property (nonatomic) CGPoint velocity;

/// Current hue for color cycling (0.0 - 1.0)
@property (nonatomic) CGFloat currentHue;

/// Metal texture for the DVD logo
@property (nonatomic, strong) id<MTLTexture> logoTexture;

/// Flag to track if we've loaded the logo
@property (nonatomic) BOOL logoLoaded;

@end

@implementation DVDLogoMetalView

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        
        // Initialize sprite (size set in setupMetalRenderer once scale is known)
        _logoSprite = [[SSKSprite alloc] init];
        _logoSprite.opacity = 1.0;
        
        // Random starting direction
        CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * M_PI * 2.0;
        _velocity = CGPointMake(cos(angle) * kDefaultSpeed, sin(angle) * kDefaultSpeed);
        
        // Random starting hue
        _currentHue = (CGFloat)arc4random() / UINT32_MAX;
        [self updateLogoColor];
    }
    return self;
}

#pragma mark - Metal Lifecycle

- (void)setupMetalRenderer:(SSKMetalRenderer *)renderer {
    [super setupMetalRenderer:renderer];
    
    // Set a dark background color
    renderer.clearColor = MTLClearColorMake(0.05, 0.05, 0.1, 1.0);
    
    // Load the DVD logo texture
    [self loadLogoTextureWithDevice:renderer.device];
    
    // Position sprite at center initially (in points)
    CGSize bounds = self.bounds.size;
    self.positionInPoints = NSMakePoint(bounds.width / 2.0, bounds.height / 2.0);

    // Convert position to pixels for the sprite; size is already in pixels
    CGFloat scale = self.backingScaleFactor;
    [self.logoSprite setPositionInPoints:self.positionInPoints scale:scale];
    self.logoSprite.size = NSMakeSize(kLogoWidth, kLogoHeight);
    
    // Set initial scale (can be adjusted via preferences)
    self.logoSprite.scale = CGSizeMake(1.0, 1.0);
}

- (void)loadLogoTextureWithDevice:(id<MTLDevice>)device {
    if (self.logoLoaded || !device) {
        return;
    }
    
    // Try to load from bundle resources first (DVD_logo.svg or PNG)
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSImage *logoImage = nil;
    
    // Try PNG first (easier to load)
    NSString *pngPath = [bundle pathForResource:@"DVD_logo" ofType:@"png"];
    if (pngPath) {
        logoImage = [[NSImage alloc] initWithContentsOfFile:pngPath];
    }
    
    // Try SVG if PNG not found
    if (!logoImage) {
        NSString *svgPath = [bundle pathForResource:@"DVD_logo" ofType:@"svg"];
        if (svgPath) {
            logoImage = [[NSImage alloc] initWithContentsOfFile:svgPath];
        }
    }
    
    // Fallback: create a simple DVD logo programmatically
    if (!logoImage) {
        logoImage = [self createFallbackLogoImage];
    }
    
    if (logoImage) {
        self.logoSprite.image = logoImage;
        self.logoTexture = [self.logoSprite textureForDevice:device];
        self.logoLoaded = YES;
        
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"DVDLogoMetal: Logo texture loaded successfully."];
        }
    } else if ([SSKDiagnostics isEnabled]) {
        [SSKDiagnostics log:@"DVDLogoMetal: Failed to load logo image."];
    }
}

- (NSImage *)createFallbackLogoImage {
    // Create a simple "DVD" text logo as fallback
    CGFloat width = kLogoWidth * 2.0;  // Higher resolution
    CGFloat height = kLogoHeight * 2.0;
    
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image lockFocus];
    
    // Clear background (transparent)
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, width, height));
    
    // Draw "DVD" text
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:height * 0.6],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    
    NSString *text = @"DVD";
    NSSize textSize = [text sizeWithAttributes:attrs];
    CGFloat x = (width - textSize.width) / 2.0;
    CGFloat y = (height - textSize.height) / 2.0;
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
    
    // Draw "VIDEO" underneath
    NSDictionary *smallAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:height * 0.2],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    
    NSString *videoText = @"VIDEO";
    NSSize videoSize = [videoText sizeWithAttributes:smallAttrs];
    CGFloat videoX = (width - videoSize.width) / 2.0;
    [videoText drawAtPoint:NSMakePoint(videoX, y - videoSize.height * 1.2) withAttributes:smallAttrs];
    
    [image unlockFocus];
    
    return image;
}

#pragma mark - Animation

- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    // Clear the screen
    [renderer clearWithColor:renderer.clearColor];
    
    // Update position based on velocity
    [self updatePositionWithDeltaTime:dt];
    
    // Update color cycling
    [self updateColorWithDeltaTime:dt];
    
    // Ensure texture is loaded
    if (!self.logoTexture && renderer.device) {
        [self loadLogoTextureWithDevice:renderer.device];
    }
    
    // Draw the sprite
    if (self.logoSprite && renderer.spritePass) {
        [renderer drawSprites:@[self.logoSprite]
                      texture:self.logoTexture
                    blendMode:SSKParticleBlendModeAlpha];
    }
}

- (void)updatePositionWithDeltaTime:(NSTimeInterval)dt {
    // All position/velocity math is done in POINTS
    // Only the sprite's position property is in pixels
    
    CGSize bounds = self.bounds.size;  // View bounds in points
    if (bounds.width <= 0 || bounds.height <= 0) {
        return;
    }
    
    // Logo size in points (for edge detection)
    // The sprite.size is in pixels, so we use the constant logo size for point-based math
    CGFloat halfWidth = kLogoWidth / 2.0;
    CGFloat halfHeight = kLogoHeight / 2.0;
    
    // Update position in points
    NSPoint position = self.positionInPoints;
    position.x += self.velocity.x * dt;
    position.y += self.velocity.y * dt;
    
    // Bounce off edges (all math in points)
    BOOL bounced = NO;
    BOOL bouncedX = NO;
    BOOL bouncedY = NO;
    
    // Left/right edges
    if (position.x - halfWidth < 0) {
        position.x = halfWidth;
        self.velocity = CGPointMake(-self.velocity.x, self.velocity.y);
        bounced = YES;
        bouncedX = YES;
    } else if (position.x + halfWidth > bounds.width) {
        position.x = bounds.width - halfWidth;
        self.velocity = CGPointMake(-self.velocity.x, self.velocity.y);
        bounced = YES;
        bouncedX = YES;
    }
    
    // Top/bottom edges
    if (position.y - halfHeight < 0) {
        position.y = halfHeight;
        self.velocity = CGPointMake(self.velocity.x, -self.velocity.y);
        bounced = YES;
        bouncedY = YES;
    } else if (position.y + halfHeight > bounds.height) {
        position.y = bounds.height - halfHeight;
        self.velocity = CGPointMake(self.velocity.x, -self.velocity.y);
        bounced = YES;
        bouncedY = YES;
    }
    
    // Store position in points and convert to pixels for sprite
    self.positionInPoints = position;
    CGFloat scale = self.backingScaleFactor;
    [self.logoSprite setPositionInPoints:position scale:scale];
    self.logoSprite.size = NSMakeSize(kLogoWidth, kLogoHeight);
    
    // Flip sprite on bounce (demonstrates new flip feature)
    if (bouncedX) {
        self.logoSprite.flipX = !self.logoSprite.flipX;
    }
    if (bouncedY) {
        self.logoSprite.flipY = !self.logoSprite.flipY;
    }
    
    // Change color on bounce (classic DVD behavior)
    if (bounced) {
        [self cycleToNextColor];
    }
}

- (void)updateColorWithDeltaTime:(NSTimeInterval)dt {
    // Gradual color shift when not bouncing
    self.currentHue += kColorCycleRate * dt * 0.1;
    if (self.currentHue > 1.0) {
        self.currentHue -= 1.0;
    }
    [self updateLogoColor];
}

- (void)cycleToNextColor {
    // Jump to a new random hue on bounce
    self.currentHue += 0.15 + ((CGFloat)arc4random() / UINT32_MAX) * 0.2;
    if (self.currentHue > 1.0) {
        self.currentHue -= 1.0;
    }
    [self updateLogoColor];
}

- (void)updateLogoColor {
    self.logoSprite.colorTint = [NSColor colorWithCalibratedHue:self.currentHue
                                                     saturation:0.9
                                                     brightness:1.0
                                                          alpha:1.0];
}

#pragma mark - CPU Fallback

- (void)renderCPUFrameWithDeltaTime:(NSTimeInterval)dt {
    [self updatePositionWithDeltaTime:dt];
    [self updateColorWithDeltaTime:dt];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    // CPU fallback rendering
    if (self.metalAvailable && self.useMetalPipeline) {
        return; // Metal is handling rendering
    }
    
    // Draw dark background
    [[NSColor colorWithCalibratedRed:0.05 green:0.05 blue:0.1 alpha:1.0] setFill];
    NSRectFill(dirtyRect);
    
    // Draw the logo sprite using CoreGraphics
    NSImage *logoImage = self.logoSprite.image;
    if (!logoImage) {
        logoImage = [self createFallbackLogoImage];
    }
    
    if (logoImage) {
        // Use position in points (not pixels) for CPU rendering
        // CoreGraphics works in points, so use our stored point-based position
        NSPoint pos = self.positionInPoints;
        
        // Size in points (logoSprite.size is pixels but for CPU fallback we use constant)
        CGFloat width = kLogoWidth;
        CGFloat height = kLogoHeight;
        
        // Apply scale to size for CPU fallback
        CGFloat scaleX = fabs(self.logoSprite.scale.width);
        CGFloat scaleY = fabs(self.logoSprite.scale.height);
        NSRect destRect = NSMakeRect(pos.x - (width * scaleX) / 2.0,
                                     pos.y - (height * scaleY) / 2.0,
                                     width * scaleX,
                                     height * scaleY);
        
        // Apply color tint by drawing with composition
        NSColor *tint = self.logoSprite.colorTint;
        [logoImage drawInRect:destRect
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationSourceOver
                     fraction:self.logoSprite.opacity];
        
        // Draw tinted overlay
        [tint setFill];
        NSRectFillUsingOperation(destRect, NSCompositingOperationSourceAtop);
    }
}

#pragma mark - Lifecycle

- (void)stopAnimation {
    // Clean up Metal resources
    self.logoTexture = nil;
    [self.logoSprite invalidateTexture];
    self.logoLoaded = NO;
    
    [super stopAnimation];
}

#pragma mark - Configuration

- (BOOL)hasConfigureSheet {
    return NO;
}

- (NSWindow *)configureSheet {
    return nil;
}

@end
