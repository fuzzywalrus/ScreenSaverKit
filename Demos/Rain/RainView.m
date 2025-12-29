#import "RainView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

#import "ScreenSaverKit/SSKMetalScreenSaverView.h"
#import "ScreenSaverKit/SSKMetalRenderer.h"
#import "ScreenSaverKit/SSKMetalParticlePass.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"

static NSString * const kPrefRainAngle = @"rainAngle";
static NSString * const kPrefRainSpeed = @"rainSpeed";
static NSString * const kPrefRainDensity = @"rainDensity";
static NSString * const kPrefRainBrightness = @"rainBrightness";
static NSString * const kPrefRainWidth = @"rainWidth";
static NSString * const kPrefRainLength = @"rainLength";
static NSString * const kPrefRainZDepth = @"rainZDepth";
static NSString * const kPrefRainZDepthScale = @"rainZDepthScale";
static NSString * const kPrefShowFPS = @"rainShowFPS";

@interface RainView ()
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic) CGFloat rainAngle; // In degrees, 0 = straight down, positive = angled right
@property (nonatomic) CGFloat rainSpeed;
@property (nonatomic) NSUInteger rainDensity; // Particles per second
@property (nonatomic) CGFloat rainBrightness; // 0.0 = dark grey, 1.0 = light/white
@property (nonatomic) CGFloat rainWidth; // Width of rain drops (1-1000)
@property (nonatomic) CGFloat rainLength; // Length of rain drops (1-100)
@property (nonatomic) BOOL rainZDepth; // Enable z-depth effect
@property (nonatomic) CGFloat rainZDepthScale; // Scale of z-depth effect (0.1-10.0)
@property (nonatomic) BOOL showFPS; // Show FPS counter
@property (nonatomic) NSTimeInterval lastSpawnTime;
@property (nonatomic, strong) SSKConfigurationWindowController *configController;
@property (nonatomic, strong) CATextLayer *fpsLayer; // For displaying FPS in Metal mode
@end

@implementation RainView

- (NSDictionary<NSString *,id> *)defaultPreferences {
    return @{
        kPrefRainAngle: @(0.0),      // Straight down
        kPrefRainSpeed: @(2000.0),   // Pixels per second (faster)
        kPrefRainDensity: @(100),     // Particles per second
        kPrefRainBrightness: @(0.7),  // Medium brightness
        kPrefRainWidth: @(2.0),       // Default width (1-20 range)
        kPrefRainLength: @(8.0),      // Default length multiplier
        kPrefRainZDepth: @(NO),       // Z-depth disabled by default
        kPrefRainZDepthScale: @(1.0), // Default z-depth scale
        kPrefShowFPS: @(NO)            // FPS counter disabled by default
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        
        // Initialize particle system with capacity for up to 1000 particles
        _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:1000];
        _particleSystem.blendMode = SSKParticleBlendModeAlpha;
        _particleSystem.metalSimulationEnabled = YES;
        _particleSystem.synchronizesMetalSimulation = YES;
        
        // Set gravity to make rain fall
        // In AppKit/NSView, Y increases upward, so negative Y gravity = downward
        _particleSystem.gravity = NSMakePoint(0.0, -200.0); // Downward gravity
        
        // Initialize preferences from defaults (will be updated by preferencesDidChange:)
        NSDictionary *defaults = [self defaultPreferences];
        _rainAngle = [defaults[kPrefRainAngle] doubleValue];
        _rainSpeed = [defaults[kPrefRainSpeed] doubleValue];
        _rainDensity = [defaults[kPrefRainDensity] unsignedIntegerValue];
        _rainBrightness = [defaults[kPrefRainBrightness] doubleValue];
        _rainWidth = [defaults[kPrefRainWidth] doubleValue];
        _rainLength = [defaults[kPrefRainLength] doubleValue];
        _rainZDepth = [defaults[kPrefRainZDepth] boolValue];
        _rainZDepthScale = [defaults[kPrefRainZDepthScale] doubleValue];
        _showFPS = [defaults[kPrefShowFPS] boolValue];
        _lastSpawnTime = 0.0;
    }
    return self;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)startAnimation {
    [super startAnimation];
    
    // Force reload preferences when animation starts (important for full screen mode)
    NSDictionary *prefs = [self currentPreferences];
    [self preferencesDidChange:prefs changedKeys:[NSSet setWithArray:prefs.allKeys]];
    
    // Update FPS layer visibility
    if (self.fpsLayer) {
        self.fpsLayer.hidden = !self.showFPS;
    }
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences changedKeys:(NSSet<NSString *> *)changedKeys {
    [super preferencesDidChange:preferences changedKeys:changedKeys];
    
    // Reload all preferences to ensure they're up to date
    self.rainAngle = [preferences[kPrefRainAngle] doubleValue];
    self.rainSpeed = [preferences[kPrefRainSpeed] doubleValue];
    self.rainDensity = [preferences[kPrefRainDensity] unsignedIntegerValue];
    self.rainBrightness = [preferences[kPrefRainBrightness] doubleValue];
    self.rainWidth = [preferences[kPrefRainWidth] doubleValue];
    self.rainLength = [preferences[kPrefRainLength] doubleValue];
    self.rainZDepth = [preferences[kPrefRainZDepth] boolValue];
    self.rainZDepthScale = [preferences[kPrefRainZDepthScale] doubleValue];
    self.showFPS = [preferences[kPrefShowFPS] boolValue];
    
    // Reset spawn timer to immediately apply new settings
    self.lastSpawnTime = 0.0;
}


- (void)setupMetalRenderer:(SSKMetalRenderer *)renderer {
    [super setupMetalRenderer:renderer];
    
    // Setup FPS text layer for Metal mode
    if (!self.fpsLayer) {
        self.fpsLayer = [CATextLayer layer];
        self.fpsLayer.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium];
        self.fpsLayer.fontSize = 14;
        self.fpsLayer.foregroundColor = CGColorGetConstantColor(kCGColorWhite);
        self.fpsLayer.alignmentMode = kCAAlignmentLeft;
        self.fpsLayer.contentsScale = 2.0; // Retina support
        self.fpsLayer.opacity = 0.8;
        [self.layer addSublayer:self.fpsLayer];
    }
}

- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    // Clear with black background
    renderer.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    
    // Update length multiplier in particle pass if z-depth is enabled
    // This ensures the renderer uses the correct length multiplier for z-depth calculations
    if (self.rainZDepth && renderer.particlePass) {
        renderer.particlePass.lengthMultiplier = self.rainLength;
    }
    
    // Render particles
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    [renderer drawParticles:particles
                  blendMode:self.particleSystem.blendMode
               viewportSize:self.bounds.size];
    
    // Update FPS counter if enabled
    if (self.showFPS && self.fpsLayer) {
        double fps = self.animationClock.framesPerSecond;
        self.fpsLayer.string = [NSString stringWithFormat:@"%.1f FPS", fps];
        self.fpsLayer.hidden = NO;
        self.fpsLayer.frame = CGRectMake(10, 10, 100, 20);
    } else if (self.fpsLayer) {
        self.fpsLayer.hidden = YES;
    }
}

- (void)renderCPUFrameWithDeltaTime:(NSTimeInterval)dt {
    // CPU fallback - draw with Core Graphics
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    // CPU fallback rendering - black background
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);
    
    // Draw FPS counter if enabled
    if (self.showFPS) {
        double fps = self.animationClock.framesPerSecond;
        NSString *fpsString = [NSString stringWithFormat:@"%.1f FPS", fps];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.8 alpha:1.0]
        };
        [fpsString drawAtPoint:NSMakePoint(10, 10) withAttributes:attrs];
    }
    
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    if (particles.count == 0) { return; }
    
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(ctx);
    
    for (SSKParticle *particle in particles) {
        NSPoint pos = particle.position;
        CGFloat size = particle.size;
        NSColor *color = particle.color;
        
        // Determine length multiplier and z-depth
        CGFloat lengthMultiplier = self.rainLength;
        CGFloat zDepth = 1.0;
        if (self.rainZDepth) {
            // userScalar contains z-depth (0.1-1.0)
            zDepth = particle.userScalar;
            // Validate z-depth range
            if (!isfinite(zDepth) || zDepth < 0.1 || zDepth > 1.0) {
                zDepth = 1.0; // Fallback if invalid
            }
            // Further drops (lower z-depth) are shorter
            lengthMultiplier = self.rainLength * zDepth;
            
            // Apply z-depth darkening to color (further = darker)
            CGFloat darkenFactor = 0.3 + zDepth * 0.7; // Far = 30% brightness, close = 100%
            // Safely get white component (color should be grayscale)
            CGFloat white = 0.5; // Default fallback
            // Convert to grayscale color space to get white component
            NSColor *grayColor = [color colorUsingColorSpace:[NSColorSpace genericGrayColorSpace]];
            if (grayColor) {
                white = grayColor.whiteComponent;
            } else {
                // Fallback: try to get white component directly
                @try {
                    white = color.whiteComponent;
                } @catch (NSException *exception) {
                    white = 0.5; // Default fallback
                }
            }
            color = [NSColor colorWithCalibratedWhite:white * darkenFactor alpha:color.alphaComponent];
        } else {
            // userScalar > 10.0 means it's a length multiplier
            if (particle.userScalar > 10.0) {
                lengthMultiplier = particle.userScalar - 10.0;
            }
        }
        
        // Draw simple line for retro rain effect
        [color setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        
        // Calculate line direction based on velocity or angle
        // Use particle's userVector if available, otherwise calculate from angle
        NSPoint direction = particle.userVector;
        if (direction.x == 0.0 && direction.y == 0.0) {
            // Fallback to angle calculation
            CGFloat angleRad = self.rainAngle * M_PI / 180.0;
            direction = NSMakePoint(sin(angleRad), -cos(angleRad)); // Negative Y = downward (AppKit Y increases upward)
        }
        
        CGFloat length = size * lengthMultiplier; // Line length based on preference and z-depth
        CGFloat dx = direction.x * length;
        CGFloat dy = direction.y * length;
        
        [line moveToPoint:pos];
        [line lineToPoint:NSMakePoint(pos.x + dx, pos.y + dy)];
        [line setLineWidth:MAX(1.0, size * 0.5)];
        [line setLineCapStyle:NSLineCapStyleRound];
        [line stroke];
    }
    
    CGContextRestoreGState(ctx);
}

- (void)animateOneFrame {
    // Call super first to handle Metal rendering setup
    [super animateOneFrame];
    
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0.0) { dt = 1.0 / 60.0; }
    
    // Spawn new rain drops
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (self.lastSpawnTime == 0.0) {
        self.lastSpawnTime = currentTime;
        // Spawn initial batch immediately
        NSUInteger initialSpawn = MIN(self.rainDensity, 100);
        if (initialSpawn > 0) {
            [self spawnRainParticles:initialSpawn];
        }
    }
    
    NSTimeInterval timeSinceLastSpawn = currentTime - self.lastSpawnTime;
    NSUInteger particlesToSpawn = (NSUInteger)(self.rainDensity * timeSinceLastSpawn);
    
    if (particlesToSpawn > 0 && self.particleSystem.aliveParticleCount < 1000) {
        [self spawnRainParticles:particlesToSpawn];
        self.lastSpawnTime = currentTime;
    }
    
    // Advance simulation
    [self.particleSystem advanceBy:dt];
    
    // Remove particles that have fallen off screen
    NSRect bounds = self.bounds;
    NSArray<SSKParticle *> *particles = [self.particleSystem aliveParticlesSnapshot];
    for (SSKParticle *particle in particles) {
        // In AppKit, Y increases downward, so bottom is bounds.origin.y
        // Remove particles that have fallen below the bottom
        if (particle.position.y < bounds.origin.y - 50.0) {
            // Particle has fallen off bottom, mark for removal
            particle.life = particle.maxLife; // Will be removed on next advance
        }
    }
}

- (void)spawnRainParticles:(NSUInteger)count {
    if (count == 0) { return; }
    
    NSRect bounds = self.bounds;
    // Convert angle to radians: 0° = straight down, positive = angled right
    // In AppKit/NSView, Y increases upward, so for straight down we want negative Y velocity
    CGFloat angleRad = self.rainAngle * M_PI / 180.0;
    CGFloat vx = sin(angleRad) * self.rainSpeed;
    CGFloat vy = -cos(angleRad) * self.rainSpeed; // Negative for downward (AppKit Y increases upward)
    
    // Use GPU spawn for better performance
    SSKParticleSpawnParameters params = SSKParticleSpawnParametersMake();
    params.regionType = SSKParticleSpawnRegionTypeRectangle;
    
    // Spawn across the top of the screen
    // In AppKit, bounds.origin.y is at the bottom, so top is origin.y + size.height
    // But we want to spawn above the visible area, so we add extra height
    CGFloat spawnY = bounds.origin.y + bounds.size.height + 50.0;
    params.center = (vector_float2){(float)(bounds.origin.x + bounds.size.width / 2.0),
                                    (float)spawnY};
    params.size = (vector_float2){(float)bounds.size.width, 20.0f};
    
    params.velocityXRange = (vector_float2){(float)vx * 0.9f, (float)vx * 1.1f}; // Small variation
    params.velocityYRange = (vector_float2){(float)vy * 0.9f, (float)vy * 1.1f};
    
    // Calculate brightness-based color (dark grey to light/white)
    CGFloat brightness = self.rainBrightness;
    CGFloat minBrightness = 0.2 + brightness * 0.3; // Range: 0.2-0.5 for dark
    CGFloat maxBrightness = 0.5 + brightness * 0.5;  // Range: 0.5-1.0 for light
    
    // Use width preference for particle size
    CGFloat widthMin = MAX(1.0, self.rainWidth * 0.8);
    CGFloat widthMax = self.rainWidth * 1.2;
    params.sizeRange = (vector_float2){(float)widthMin, (float)widthMax};
    params.lifeRange = (vector_float2){2.0f, 3.0f}; // Shorter life for faster movement
    params.colorMin = (vector_float4){(float)minBrightness, (float)minBrightness, (float)minBrightness, 1.0f};
    params.colorMax = (vector_float4){(float)maxBrightness, (float)maxBrightness, (float)maxBrightness, 1.0f};
    params.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha;
    params.zDepthEnabled = self.rainZDepth ? 1u : 0u;
    params.zDepthScale = (float)self.rainZDepthScale;
    params.lengthMultiplier = (float)self.rainLength;
    
    // Always use GPU spawn now (z-depth is supported in GPU)
    // Try GPU spawn first, fallback to CPU if needed
    NSUInteger spawned = [self.particleSystem spawnParticlesGPU:count parameters:params];
    if (spawned == 0) {
        // Fallback to CPU spawn if GPU spawn failed
        BOOL useZDepth = self.rainZDepth;
        CGFloat zDepthScale = self.rainZDepthScale;
        [self.particleSystem spawnParticles:count initializer:^(SSKParticle *particle) {
            CGFloat x = bounds.origin.x + ((CGFloat)arc4random() / UINT32_MAX) * bounds.size.width;
            CGFloat y = bounds.origin.y + bounds.size.height + 50.0; // Spawn above top
            particle.position = NSMakePoint(x, y);
            
            // Calculate z-depth first (needed for velocity scaling)
            CGFloat zDepth = 1.0;
            if (useZDepth) {
                CGFloat zRandom = (CGFloat)arc4random() / UINT32_MAX;
                // Map scale to a nearer minimum, but keep a floor so far drops still move.
                // scale 1 -> ~0.5, scale 100 -> ~0.2
                CGFloat minZ = MAX(0.2, 1.0 / (zDepthScale + 1.0));
                zDepth = minZ + zRandom * (1.0 - minZ); // Range: minZ (far) to 1.0 (close)
                zDepth = MAX(0.01, MIN(1.0, zDepth)); // Clamp
                particle.userScalar = zDepth;
            } else {
                particle.userScalar = 10.0 + self.rainLength;
            }
            
            // Generate velocity and scale by z-depth for perspective effect
            // Further drops (lower z-depth) move slower to create depth illusion
            CGFloat velX = vx * (0.9 + ((CGFloat)arc4random() / UINT32_MAX) * 0.2);
            CGFloat velY = vy * (0.9 + ((CGFloat)arc4random() / UINT32_MAX) * 0.2);
            if (useZDepth) {
                // Scale velocity by z-depth: far drops (0.1) move 10% speed, close drops (1.0) move 100% speed
                velX *= zDepth;
                velY *= zDepth;
            }
            particle.velocity = NSMakePoint(velX, velY);
            
            // Set userVector to velocity direction for proper rendering
            CGFloat velLen = sqrt(velX * velX + velY * velY);
            if (velLen > 0.0001) {
                particle.userVector = NSMakePoint(velX / velLen, velY / velLen);
            } else {
                particle.userVector = NSMakePoint(0.0, -1.0); // Default downward (Y increases upward)
            }
            
            // Calculate brightness-based color
            CGFloat brightness = self.rainBrightness;
            CGFloat minBrightness = 0.2 + brightness * 0.3;
            CGFloat maxBrightness = 0.5 + brightness * 0.5;
            CGFloat grayValue = minBrightness + ((CGFloat)arc4random() / UINT32_MAX) * (maxBrightness - minBrightness);
            
            // Apply z-depth darkening if enabled
            if (useZDepth) {
                grayValue = grayValue * (0.3 + zDepth * 0.7); // Far drops are 30% brightness, close are 100%
            }
            
            // Use width preference for particle size
            CGFloat width = self.rainWidth * (0.8 + ((CGFloat)arc4random() / UINT32_MAX) * 0.4);
            particle.size = MAX(1.0, width);
            particle.maxLife = 2.0 + ((CGFloat)arc4random() / UINT32_MAX) * 1.0;
            particle.life = 0.0;
            particle.color = [NSColor colorWithCalibratedWhite:grayValue alpha:1.0];
            particle.behaviorOptions = SSKParticleBehaviorOptionFadeAlpha;
        }];
    }
}

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    [self ensureConfigController];
    [self.configController prepareForPresentation];
    return self.configController.window;
}

- (void)ensureConfigController {
    if (self.configController) { return; }
    self.configController = [[SSKConfigurationWindowController alloc] initWithSaverView:self
                                                                                   title:@"Rain"
                                                                                subtitle:@"Classic rain animation with adjustable angle and speed."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;
    
    [stack addArrangedSubview:[self sliderRowWithTitle:@"Rain Angle"
                                               minValue:-45.0
                                               maxValue:45.0
                                                    key:kPrefRainAngle
                                                 format:@"%.0f°"
                                                  binder:binder]];
    
    [stack addArrangedSubview:[self sliderRowWithTitle:@"Rain Speed"
                                               minValue:500.0
                                               maxValue:10000.0
                                                    key:kPrefRainSpeed
                                                 format:@"%.0f"
                                                  binder:binder]];
    
    [stack addArrangedSubview:[self sliderRowWithTitle:@"Rain Density"
                                               minValue:50
                                               maxValue:1000
                                                    key:kPrefRainDensity
                                                 format:@"%.0f"
                                                  binder:binder]];
    
    [stack addArrangedSubview:[self sliderRowWithTitle:@"Brightness"
                                               minValue:0.0
                                               maxValue:1.0
                                                    key:kPrefRainBrightness
                                                 format:@"%.2f"
                                                  binder:binder]];
    
    [stack addArrangedSubview:[self sliderRowWithTitle:@"Width"
                                               minValue:1.0
                                               maxValue:20.0
                                                    key:kPrefRainWidth
                                                 format:@"%.1f"
                                                  binder:binder]];
    
    [stack addArrangedSubview:[self sliderRowWithTitle:@"Length"
                                               minValue:1.0
                                               maxValue:100.0
                                                    key:kPrefRainLength
                                                 format:@"%.1f"
                                                  binder:binder]];
    
    // Z-depth checkbox
    NSButton *zDepthToggle = [NSButton checkboxWithTitle:@"Enable Z-Depth" target:nil action:nil];
    [binder bindCheckbox:zDepthToggle key:kPrefRainZDepth];
    [stack addArrangedSubview:zDepthToggle];
    
    [stack addArrangedSubview:[self sliderRowWithTitle:@"Z-Depth Scale"
                                               minValue:0.1
                                               maxValue:100.0
                                                    key:kPrefRainZDepthScale
                                                 format:@"%.1f"
                                                  binder:binder]];
    
    // FPS counter checkbox
    NSButton *fpsToggle = [NSButton checkboxWithTitle:@"Show FPS Counter" target:nil action:nil];
    [binder bindCheckbox:fpsToggle key:kPrefShowFPS];
    [stack addArrangedSubview:fpsToggle];
}

- (NSView *)sliderRowWithTitle:(NSString *)title
                      minValue:(double)min
                      maxValue:(double)max
                           key:(NSString *)key
                        format:(NSString *)format
                         binder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    slider.minValue = min;
    slider.maxValue = max;
    slider.continuous = YES;
    
    NSTextField *valueLabel = [NSTextField labelWithString:@"--"];
    valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:slider];
    [row addArrangedSubview:valueLabel];
    
    [binder bindSlider:slider key:key valueLabel:valueLabel format:format];
    return row;
}

@end
