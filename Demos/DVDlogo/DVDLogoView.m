#import "DVDLogoView.h"

#import <AppKit/AppKit.h>
#import <AppKit/NSImageRep.h>
#import <objc/message.h>

#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"

#import "DVDLogoConfigurationBuilder.h"
#import "DVDLogoPaletteUtilities.h"
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
@end

@implementation DVDLogoView

- (NSDictionary<NSString *,id> *)defaultPreferences {
    return @{
        DVDLogoPreferenceKeySpeed: @(1.0),
        DVDLogoPreferenceKeySize: @(0.35),
        DVDLogoPreferenceKeyColorMode: DVDLogoColorModePalette,
        DVDLogoPreferenceKeyColorRate: @(0.25),
        DVDLogoPreferenceKeyPalette: DVDLogoPaletteFallbackIdentifier(),
        DVDLogoPreferenceKeySolidColor: DVDLogoSerializeColor(DVDLogoFallbackSolidColor()),
        DVDLogoPreferenceKeyRandomStartPosition: @(YES),
        DVDLogoPreferenceKeyRandomStartVelocity: @(YES)
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        NSDictionary *defaults = [self defaultPreferences];
        _speedMultiplier = MAX(0.2, [defaults[DVDLogoPreferenceKeySpeed] doubleValue]);
        _sizeMultiplier = MAX(0.1, [defaults[DVDLogoPreferenceKeySize] doubleValue]);
        _colorRate = MAX(0.0, [defaults[DVDLogoPreferenceKeyColorRate] doubleValue]);
        NSString *modeString = [defaults[DVDLogoPreferenceKeyColorMode] isKindOfClass:[NSString class]] ? defaults[DVDLogoPreferenceKeyColorMode] : DVDLogoColorModePalette;
        _colorMode = [modeString isEqualToString:DVDLogoColorModeSolid] ? DVDBrandColorModeSolid : DVDBrandColorModePalette;
        NSString *paletteValue = [defaults[DVDLogoPreferenceKeyPalette] isKindOfClass:[NSString class]] ? defaults[DVDLogoPreferenceKeyPalette] : DVDLogoPaletteFallbackIdentifier();
        _paletteIdentifier = paletteValue.length ? paletteValue : DVDLogoPaletteFallbackIdentifier();
        _solidColor = DVDLogoColorFromPreferenceValue(defaults[DVDLogoPreferenceKeySolidColor], DVDLogoFallbackSolidColor());
        _randomStartPositionEnabled = [defaults[DVDLogoPreferenceKeyRandomStartPosition] boolValue];
        _randomStartVelocityEnabled = [defaults[DVDLogoPreferenceKeyRandomStartVelocity] boolValue];
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

    position.x += velocity.x * self.speedMultiplier * dt;
    position.y += velocity.y * self.speedMultiplier * dt;

    NSRect bounds = NSInsetRect(self.bounds, halfWidth, halfHeight);
    if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
        bounds = self.bounds;
    }

    BOOL bounced = NO;
    if (position.x < NSMinX(bounds)) {
        position.x = NSMinX(bounds);
        velocity.x = fabs(velocity.x);
        bounced = YES;
    } else if (position.x > NSMaxX(bounds)) {
        position.x = NSMaxX(bounds);
        velocity.x = -fabs(velocity.x);
        bounced = YES;
    }

    if (position.y < NSMinY(bounds)) {
        position.y = NSMinY(bounds);
        velocity.y = fabs(velocity.y);
        bounced = YES;
    } else if (position.y > NSMaxY(bounds)) {
        position.y = NSMaxY(bounds);
        velocity.y = -fabs(velocity.y);
        bounced = YES;
    }

    if (bounced) {
        self.colorPhase += 0.12;
        self.colorPhase -= floor(self.colorPhase);
    }

    self.position = position;
    self.velocity = velocity;

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

    [SSKDiagnostics drawOverlayInView:self
                                text:@"DVD Logo Demo"
                     framesPerSecond:self.animationClock.framesPerSecond];
}

- (NSColor *)currentTintColor {
    if (self.colorMode == DVDBrandColorModeSolid) {
        NSColor *base = [self.solidColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: DVDLogoFallbackSolidColor();
        if (self.colorRate <= 0.0) {
            return base;
        }
        CGFloat hue = 0, sat = 0, bri = 0, alpha = 1;
        [[base colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] getHue:&hue saturation:&sat brightness:&bri alpha:&alpha];
        CGFloat animatedHue = hue + self.colorPhase;
        animatedHue = animatedHue - floor(animatedHue);
        return [NSColor colorWithHue:animatedHue saturation:sat brightness:bri alpha:alpha];
    } else {
        NSArray<NSColor *> *colors = DVDLogoColorsForIdentifier(self.paletteIdentifier);
        return DVDLogoColorForProgress(colors, self.colorPhase);
    }
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferences:preferences changedKeys:changedKeys];
}

- (void)applyPreferences:(NSDictionary<NSString *,id> *)preferences
             changedKeys:(nullable NSSet<NSString *> *)changedKeys {
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
        paletteValue = DVDLogoPaletteFallbackIdentifier();
    }
    self.paletteIdentifier = paletteValue;

    id colorValue = preferences[DVDLogoPreferenceKeySolidColor] ?: defaults[DVDLogoPreferenceKeySolidColor];
    self.solidColor = DVDLogoColorFromPreferenceValue(colorValue, DVDLogoFallbackSolidColor());

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
