#import "DVDLogoView.h"

#import <AppKit/AppKit.h>
#import <AppKit/NSImageRep.h>
#import <objc/message.h>

#import "ScreenSaverKit/SSKColorUtilities.h"
#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKPaletteManager.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKVectorMath.h"

#import "DVDLogoConfigurationBuilder.h"
#import "DVDLogoPalettes.h"
#import "DVDLogoPreferences.h"

typedef NS_ENUM(NSUInteger, DVDBrandColorMode) {
    DVDBrandColorModeSolid,
    DVDBrandColorModePalette
};

@interface DVDLogoView ()
@property (nonatomic, strong) NSImage *logoImage;
@property (nonatomic) NSSize logoBaseSize;
@property (nonatomic) NSPoint position; // centre position in view coordinates
@property (nonatomic) NSPoint velocity; // units per second at speed multiplier 1.0
@property (nonatomic) CGFloat speedMultiplier;
@property (nonatomic) CGFloat sizeMultiplier;
@property (nonatomic) CGFloat colorRate;
@property (nonatomic) CGFloat colorPhase;
@property (nonatomic) DVDBrandColorMode colorMode;
@property (nonatomic, strong) NSColor *solidColor;
@property (nonatomic, copy) NSString *paletteIdentifier;
@property (nonatomic, strong) SSKConfigurationWindowController *configController;
@property (nonatomic) BOOL randomStartPositionEnabled;
@property (nonatomic) BOOL randomStartVelocityEnabled;
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic) BOOL bounceParticlesEnabled;
@end

@implementation DVDLogoView

- (NSString *)paletteModuleIdentifier {
    NSString *module = DVDPaletteModuleIdentifier();
    return module.length ? module : @"RetroDVDLogo";
}

- (NSColor *)fallbackSolidColor {
    return [NSColor colorWithHue:0.6 saturation:0.6 brightness:1.0 alpha:1.0];
}

- (NSDictionary<NSString *,id> *)defaultPreferences {
    DVDRegisterRetroPalettes();
    NSString *defaultPalette = DVDDefaultPaletteIdentifier() ?: @"neon";
    return @{
        DVDLogoPreferenceKeySpeed: @(1.0),
        DVDLogoPreferenceKeySize: @(0.35),
        DVDLogoPreferenceKeyColorMode: DVDLogoColorModePalette,
        DVDLogoPreferenceKeyColorRate: @(0.25),
        DVDLogoPreferenceKeyPalette: defaultPalette,
        DVDLogoPreferenceKeySolidColor: SSKSerializeColor([self fallbackSolidColor]),
        DVDLogoPreferenceKeyRandomStartPosition: @(YES),
        DVDLogoPreferenceKeyRandomStartVelocity: @(YES),
        DVDLogoPreferenceKeyBounceParticles: @(NO)
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        DVDRegisterRetroPalettes();
        NSDictionary *defaults = [self defaultPreferences];
        _speedMultiplier = MAX(0.2, [defaults[DVDLogoPreferenceKeySpeed] doubleValue]);
        _sizeMultiplier = MAX(0.1, [defaults[DVDLogoPreferenceKeySize] doubleValue]);
        _colorRate = MAX(0.0, [defaults[DVDLogoPreferenceKeyColorRate] doubleValue]);
        NSString *modeString = [defaults[DVDLogoPreferenceKeyColorMode] isKindOfClass:[NSString class]] ? defaults[DVDLogoPreferenceKeyColorMode] : DVDLogoColorModePalette;
        _colorMode = [modeString isEqualToString:DVDLogoColorModeSolid] ? DVDBrandColorModeSolid : DVDBrandColorModePalette;
        NSString *paletteValue = [defaults[DVDLogoPreferenceKeyPalette] isKindOfClass:[NSString class]] ? defaults[DVDLogoPreferenceKeyPalette] : DVDDefaultPaletteIdentifier();
        _paletteIdentifier = paletteValue.length ? paletteValue : DVDDefaultPaletteIdentifier();
        _solidColor = SSKDeserializeColor(defaults[DVDLogoPreferenceKeySolidColor], [self fallbackSolidColor]);
        _randomStartPositionEnabled = [defaults[DVDLogoPreferenceKeyRandomStartPosition] boolValue];
        _randomStartVelocityEnabled = [defaults[DVDLogoPreferenceKeyRandomStartVelocity] boolValue];
        _bounceParticlesEnabled = [defaults[DVDLogoPreferenceKeyBounceParticles] boolValue];
        _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:256];
        _particleSystem.blendMode = SSKParticleBlendModeAdditive;
        [self loadLogoImage];
        [self resetInitialState];
        NSDictionary *prefs = [self currentPreferences];
        NSSet *allKeys = [NSSet setWithArray:prefs.allKeys];
        [self applyPreferences:prefs changedKeys:allKeys];
    }
    return self;
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self clampPositionToBounds];
}

- (void)resetInitialState {
    if (self.logoBaseSize.width <= 0.0 || self.logoBaseSize.height <= 0.0) {
        self.logoBaseSize = NSMakeSize(160.0, 90.0);
    }

    NSRect bounds = self.bounds;
    CGFloat scale = MAX(0.1, self.sizeMultiplier);
    CGFloat halfWidth = (self.logoBaseSize.width * scale) * 0.5;
    CGFloat halfHeight = (self.logoBaseSize.height * scale) * 0.5;
    NSRect safeBounds = NSInsetRect(bounds, halfWidth, halfHeight);
    if (safeBounds.size.width <= 0.0 || safeBounds.size.height <= 0.0) {
        safeBounds = bounds;
    }

    if (self.randomStartPositionEnabled && safeBounds.size.width > 1.0 && safeBounds.size.height > 1.0) {
        CGFloat randX = safeBounds.origin.x + ((CGFloat)arc4random() / UINT32_MAX) * safeBounds.size.width;
        CGFloat randY = safeBounds.origin.y + ((CGFloat)arc4random() / UINT32_MAX) * safeBounds.size.height;
        self.position = NSMakePoint(randX, randY);
    } else {
        self.position = NSMakePoint(NSMidX(safeBounds), NSMidY(safeBounds));
    }

    CGFloat baseSpeed = 220.0;
    CGFloat angle = self.randomStartVelocityEnabled ?
        (((CGFloat)arc4random() / UINT32_MAX) * (CGFloat)M_PI * 2.0) :
        (CGFloat)M_PI_4;
    self.velocity = NSMakePoint(cos(angle) * baseSpeed, sin(angle) * baseSpeed);
    self.colorPhase = 0.0;
    [self.particleSystem reset];
}

- (void)loadLogoImage {
    NSData *data = [self.assetManager dataNamed:@"DVD_logo" fallbackExtensions:@[@"svg"]];
    if (data.length > 0) {
        Class svgRepClass = NSClassFromString(@"NSSVGImageRep");
        if (svgRepClass && [svgRepClass respondsToSelector:@selector(imageRepWithData:)]) {
            NSImageRep *rep = ((NSImageRep *(*)(Class, SEL, NSData *))objc_msgSend)(svgRepClass, @selector(imageRepWithData:), data);
            if ([rep isKindOfClass:svgRepClass]) {
                NSImage *image = [[NSImage alloc] initWithSize:rep.size];
                [image addRepresentation:rep];
                self.logoImage = image;
                self.logoBaseSize = rep.size;
                return;
            }
        }
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (image) {
            self.logoImage = image;
            self.logoBaseSize = image.size;
            return;
        }
    }
    // Fallback: simple text-based logo if resource missing.
    NSFont *font = [NSFont boldSystemFontOfSize:96.0];
    NSDictionary *attrs = @{ NSFontAttributeName: font,
                             NSForegroundColorAttributeName: NSColor.whiteColor };
    NSSize textSize = [@"DVD" sizeWithAttributes:attrs];
    NSImage *fallback = [[NSImage alloc] initWithSize:textSize];
    [fallback lockFocus];
    [@"DVD" drawAtPoint:NSZeroPoint withAttributes:attrs];
    [fallback unlockFocus];
    self.logoImage = fallback;
    self.logoBaseSize = textSize;
}

- (void)animateOneFrame {
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0.0) {
        dt = 1.0 / 60.0;
    }

    self.colorPhase += self.colorRate * dt;
    if (self.colorPhase >= 1.0 || self.colorPhase <= -1.0) {
        self.colorPhase -= floor(self.colorPhase);
    }

    NSPoint position = self.position;
    NSPoint velocity = self.velocity;
    CGFloat scale = MAX(0.1, self.sizeMultiplier);
    CGFloat halfWidth = (self.logoBaseSize.width * scale) * 0.5;
    CGFloat halfHeight = (self.logoBaseSize.height * scale) * 0.5;

    NSPoint step = SSKVectorScale(velocity, self.speedMultiplier * dt);
    position = SSKVectorAdd(position, step);

    NSRect bounds = NSInsetRect(self.bounds, halfWidth, halfHeight);
    if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
        bounds = self.bounds;
    }

    BOOL bounced = NO;
    if (position.x < NSMinX(bounds)) {
        position.x = NSMinX(bounds);
        velocity = SSKVectorReflect(velocity, NSMakePoint(1.0, 0.0));
        bounced = YES;
    } else if (position.x > NSMaxX(bounds)) {
        position.x = NSMaxX(bounds);
        velocity = SSKVectorReflect(velocity, NSMakePoint(-1.0, 0.0));
        bounced = YES;
    }

    if (position.y < NSMinY(bounds)) {
        position.y = NSMinY(bounds);
        velocity = SSKVectorReflect(velocity, NSMakePoint(0.0, 1.0));
        bounced = YES;
    } else if (position.y > NSMaxY(bounds)) {
        position.y = NSMaxY(bounds);
        velocity = SSKVectorReflect(velocity, NSMakePoint(0.0, -1.0));
        bounced = YES;
    }

    if (bounced) {
        self.colorPhase += 0.12;
        self.colorPhase -= floor(self.colorPhase);
        [self emitBounceParticlesAtPosition:position];
    }

    self.position = position;
    self.velocity = velocity;

    self.particleSystem.blendMode = (self.colorMode == DVDBrandColorModeSolid) ? SSKParticleBlendModeAlpha : SSKParticleBlendModeAdditive;
    [self.particleSystem advanceBy:dt];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    if (!self.logoImage) { return; }

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) { return; }

    CGFloat scale = MAX(0.1, self.sizeMultiplier);
    CGFloat width = self.logoBaseSize.width * scale;
    CGFloat height = self.logoBaseSize.height * scale;
    CGRect drawRect = CGRectMake(self.position.x - width * 0.5,
                                 self.position.y - height * 0.5,
                                 width,
                                 height);

    NSColor *tint = [self currentTintColor];
    CGImageRef cgImage = [self.logoImage CGImageForProposedRect:NULL
                                                        context:[NSGraphicsContext currentContext]
                                                          hints:nil];

    if (cgImage) {
        CGContextSaveGState(ctx);
        CGContextClipToMask(ctx, drawRect, cgImage);
        CGContextSetFillColorWithColor(ctx, tint.CGColor);
        CGContextFillRect(ctx, drawRect);
        CGContextRestoreGState(ctx);
    } else {
        NSImage *image = [self.logoImage copy];
        [image lockFocus];
        [tint set];
        NSRect imageRect = NSMakeRect(0, 0, image.size.width, image.size.height);
        NSRectFillUsingOperation(imageRect, NSCompositingOperationSourceAtop);
        [image unlockFocus];
        [image drawInRect:NSRectFromCGRect(drawRect)];
    }

    [self.particleSystem drawInContext:ctx];

    [SSKDiagnostics drawOverlayInView:self
                                text:@"DVD Logo Demo"
                     framesPerSecond:self.animationClock.framesPerSecond];
}

- (void)emitBounceParticlesAtPosition:(NSPoint)position {
    if (!self.particleSystem || !self.bounceParticlesEnabled) { return; }
    NSColor *baseColor = [self currentTintColor];
    NSUInteger count = 36;
    SSKParticleSystem *system = self.particleSystem;
    [system spawnParticles:count initializer:^(SSKParticle *particle) {
        particle.position = position;
        particle.maxLife = 0.35 + ((CGFloat)arc4random() / UINT32_MAX) * 0.2;
        CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * (CGFloat)(M_PI * 2.0);
        CGFloat speed = 90.0 + ((CGFloat)arc4random() / UINT32_MAX) * 140.0;
        particle.velocity = NSMakePoint(cos(angle) * speed, sin(angle) * speed);
        particle.size = 3.0 + ((CGFloat)arc4random() / UINT32_MAX) * 4.0;
        particle.sizeVelocity = 20.0;
        particle.color = baseColor;
        particle.damping = 0.45;
        particle.rotationVelocity = (((CGFloat)arc4random() / UINT32_MAX) - 0.5f) * 3.0f;
    }];
}

- (NSColor *)currentTintColor {
    DVDRegisterRetroPalettes();
    if (self.colorMode == DVDBrandColorModeSolid) {
        NSColor *base = [self.solidColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: [self fallbackSolidColor];
        if (self.colorRate <= 0.0) {
            return base;
        }
        CGFloat hue = 0, sat = 0, bri = 0, alpha = 1;
        [[base colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] getHue:&hue saturation:&sat brightness:&bri alpha:&alpha];
        CGFloat animatedHue = hue + self.colorPhase;
        animatedHue = animatedHue - floor(animatedHue);
        return [NSColor colorWithHue:animatedHue saturation:sat brightness:bri alpha:alpha];
    } else {
        SSKPaletteManager *manager = [SSKPaletteManager sharedManager];
        NSString *module = [self paletteModuleIdentifier];
        SSKColorPalette *palette = [manager paletteWithIdentifier:self.paletteIdentifier module:module];
        NSArray<SSKColorPalette *> *palettes = [manager palettesForModule:module];
        if (!palette) {
            palette = palettes.firstObject;
        }
        if (!palette) {
            return [self fallbackSolidColor];
        }
        return [manager colorForPalette:palette
                               progress:self.colorPhase
                       interpolationMode:SSKPaletteInterpolationModeLoop];
    }
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferences:preferences changedKeys:changedKeys];
}

- (void)applyPreferences:(NSDictionary<NSString *,id> *)preferences
             changedKeys:(nullable NSSet<NSString *> *)changedKeys {
    DVDRegisterRetroPalettes();
    NSDictionary *defaults = [self defaultPreferences];

    double speed = [preferences[DVDLogoPreferenceKeySpeed] respondsToSelector:@selector(doubleValue)] ?
        [preferences[DVDLogoPreferenceKeySpeed] doubleValue] :
        [defaults[DVDLogoPreferenceKeySpeed] doubleValue];
    self.speedMultiplier = MAX(0.2, speed);

    double size = [preferences[DVDLogoPreferenceKeySize] respondsToSelector:@selector(doubleValue)] ?
        [preferences[DVDLogoPreferenceKeySize] doubleValue] :
        [defaults[DVDLogoPreferenceKeySize] doubleValue];
    self.sizeMultiplier = MAX(0.1, size);

    double rate = [preferences[DVDLogoPreferenceKeyColorRate] respondsToSelector:@selector(doubleValue)] ?
        [preferences[DVDLogoPreferenceKeyColorRate] doubleValue] :
        [defaults[DVDLogoPreferenceKeyColorRate] doubleValue];
    self.colorRate = MAX(0.0, rate);

    NSString *modeString = [preferences[DVDLogoPreferenceKeyColorMode] isKindOfClass:[NSString class]] ?
        preferences[DVDLogoPreferenceKeyColorMode] : defaults[DVDLogoPreferenceKeyColorMode];
    if ([modeString isEqualToString:DVDLogoColorModeSolid]) {
        self.colorMode = DVDBrandColorModeSolid;
    } else {
        self.colorMode = DVDBrandColorModePalette;
    }

    NSString *paletteValue = [preferences[DVDLogoPreferenceKeyPalette] isKindOfClass:[NSString class]] ?
        preferences[DVDLogoPreferenceKeyPalette] : defaults[DVDLogoPreferenceKeyPalette];
    if (![paletteValue isKindOfClass:[NSString class]] || paletteValue.length == 0) {
        paletteValue = DVDDefaultPaletteIdentifier();
    }
    SSKPaletteManager *paletteManager = [SSKPaletteManager sharedManager];
    NSString *module = [self paletteModuleIdentifier];
    if (![paletteManager paletteWithIdentifier:paletteValue module:module]) {
        paletteValue = DVDDefaultPaletteIdentifier();
    }
    self.paletteIdentifier = paletteValue;

    id colorValue = preferences[DVDLogoPreferenceKeySolidColor] ?: defaults[DVDLogoPreferenceKeySolidColor];
    self.solidColor = SSKDeserializeColor(colorValue, [self fallbackSolidColor]);

    BOOL shouldReset = NO;
    BOOL newRandomPosition = [preferences[DVDLogoPreferenceKeyRandomStartPosition] respondsToSelector:@selector(boolValue)] ?
        [preferences[DVDLogoPreferenceKeyRandomStartPosition] boolValue] :
        [defaults[DVDLogoPreferenceKeyRandomStartPosition] boolValue];
    if (self.randomStartPositionEnabled != newRandomPosition) {
        shouldReset = YES;
    }
    self.randomStartPositionEnabled = newRandomPosition;

    BOOL newRandomVelocity = [preferences[DVDLogoPreferenceKeyRandomStartVelocity] respondsToSelector:@selector(boolValue)] ?
        [preferences[DVDLogoPreferenceKeyRandomStartVelocity] boolValue] :
        [defaults[DVDLogoPreferenceKeyRandomStartVelocity] boolValue];
    if (self.randomStartVelocityEnabled != newRandomVelocity) {
        shouldReset = YES;
    }
    self.randomStartVelocityEnabled = newRandomVelocity;

    BOOL newBounceParticles = [preferences[DVDLogoPreferenceKeyBounceParticles] respondsToSelector:@selector(boolValue)] ?
        [preferences[DVDLogoPreferenceKeyBounceParticles] boolValue] :
        [defaults[DVDLogoPreferenceKeyBounceParticles] boolValue];
    self.bounceParticlesEnabled = newBounceParticles;

    if (shouldReset) {
        [self resetInitialState];
    } else {
        [self clampPositionToBounds];
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
                                                                                   title:@"Retro DVD Logo"
                                                                                subtitle:@"Classic bouncing logo with colour cycling options."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;

    [DVDLogoConfigurationBuilder populateStack:stack withBinder:binder];
}

- (void)clampPositionToBounds {
    CGFloat scale = MAX(0.1, self.sizeMultiplier);
    CGFloat halfWidth = (self.logoBaseSize.width * scale) * 0.5;
    CGFloat halfHeight = (self.logoBaseSize.height * scale) * 0.5;
    NSRect bounds = NSInsetRect(self.bounds, halfWidth, halfHeight);
    if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
        return;
    }
    NSPoint position = self.position;
    position.x = MIN(MAX(position.x, NSMinX(bounds)), NSMaxX(bounds));
    position.y = MIN(MAX(position.y, NSMinY(bounds)), NSMaxY(bounds));
    self.position = position;
}

@end
