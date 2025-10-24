#import "RibbonFlowView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#import "RibbonFlowPalettes.h"

#import "ScreenSaverKit/SSKColorUtilities.h"
#import "ScreenSaverKit/SSKConfigurationWindowController.h"
#import "ScreenSaverKit/SSKDiagnostics.h"
#import "ScreenSaverKit/SSKPaletteManager.h"
#import "ScreenSaverKit/SSKParticleSystem.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"
#import "ScreenSaverKit/SSKVectorMath.h"

static NSString * const kPrefEmitterCount  = @"ribbonFlowEmitterCount";
static NSString * const kPrefSpeed         = @"ribbonFlowSpeed";
static NSString * const kPrefPalette       = @"ribbonFlowPalette";
static NSString * const kPrefTrailWidth    = @"ribbonFlowTrailWidth";
static NSString * const kPrefAdditiveBlend = @"ribbonFlowAdditiveBlend";

typedef struct {
    NSPoint position;
    NSPoint velocity;
    NSPoint target;
    CGFloat colorPhase;
    CGFloat intrinsicSpeed;
} RibbonFlowEmitter;

@interface RibbonFlowView ()
@property (nonatomic, strong) SSKConfigurationWindowController *configController;
@property (nonatomic, strong) SSKParticleSystem *particleSystem;
@property (nonatomic, strong) NSMutableArray<NSValue *> *emitters;
@property (nonatomic) NSUInteger emitterCount;
@property (nonatomic) CGFloat speedMultiplier;
@property (nonatomic) CGFloat trailWidth;
@property (nonatomic) BOOL additiveBlend;
@property (nonatomic, copy) NSString *paletteIdentifier;
@end

@implementation RibbonFlowView

- (NSDictionary<NSString *,id> *)defaultPreferences {
    RibbonFlowRegisterPalettes();
    return @{
        kPrefEmitterCount: @(5),
        kPrefSpeed: @(1.0),
        kPrefTrailWidth: @(1.0),
        kPrefAdditiveBlend: @(YES),
        kPrefPalette: RibbonFlowDefaultPaletteIdentifier()
    };
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 30.0;
        RibbonFlowRegisterPalettes();
        _emitters = [NSMutableArray array];
        _particleSystem = [[SSKParticleSystem alloc] initWithCapacity:2048];
        __weak typeof(self) weakSelf = self;
        _particleSystem.updateHandler = ^(SSKParticle *particle, NSTimeInterval dt) {
            (void)dt;
            CGFloat t = particle.life / MAX(0.0001, particle.maxLife);
            CGFloat fade = 1.0 - t;
            CGFloat baseSize = particle.userScalar;
            particle.size = baseSize * (0.35 + 0.65 * fade);
            NSColor *color = particle.color ?: [NSColor whiteColor];
            particle.color = [color colorWithAlphaComponent:color.alphaComponent * fade];
            if (weakSelf.additiveBlend) {
                particle.damping = 0.18;
            }
        };
        _particleSystem.renderHandler = ^(CGContextRef ctx, SSKParticle *particle) {
            CGFloat t = particle.life / MAX(0.0001, particle.maxLife);
            CGFloat fade = 1.0 - t;
            CGFloat width = MAX(1.0, particle.size);
            CGFloat length = width * (6.0 + 12.0 * fade);
            NSPoint dir = particle.userVector;
            if (SSKVectorLength(dir) < 0.0001) {
                dir = NSMakePoint(1.0, 0.0);
            }
            CGFloat angle = atan2(dir.y, dir.x);

            NSColor *color = particle.color ?: [NSColor whiteColor];
            CGFloat alpha = color.alphaComponent * fade;
            NSColor *core = [color colorWithAlphaComponent:alpha];

            CGColorRef glow = CGColorCreateCopyWithAlpha(core.CGColor, alpha * 0.75);
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, particle.position.x, particle.position.y);
            CGContextRotateCTM(ctx, angle);
            if (glow) {
                CGContextSetShadowWithColor(ctx, CGSizeZero, width * 0.9, glow);
            }
            CGRect rect = CGRectMake(-length * 0.5, -width * 0.5, length, width);
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddRoundedRect(path, NULL, rect, width * 0.5, width * 0.5);
            CGContextAddPath(ctx, path);
            CGContextSetFillColorWithColor(ctx, core.CGColor);
            CGContextFillPath(ctx);
            CGPathRelease(path);
            if (glow) {
                CGContextSetShadowWithColor(ctx, CGSizeZero, 0.0, NULL);
                CGColorRelease(glow);
            }
            CGContextRestoreGState(ctx);
        };

        NSDictionary *prefs = [self currentPreferences];
        NSSet *keys = [NSSet setWithArray:prefs.allKeys];
        [self applyPreferences:prefs changedKeys:keys];
        [self rebuildEmitters];
    }
    return self;
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self clampEmittersToBounds];
}

- (void)rebuildEmitters {
    [self.emitters removeAllObjects];
    NSRect bounds = self.bounds;
    for (NSUInteger i = 0; i < self.emitterCount; i++) {
        RibbonFlowEmitter emitter;
        emitter.position = [self randomPointInRect:bounds];
        emitter.velocity = NSZeroPoint;
        emitter.target = [self randomPointInRect:bounds];
        emitter.colorPhase = (CGFloat)arc4random() / (CGFloat)UINT32_MAX;
        emitter.intrinsicSpeed = 0.6 + ((CGFloat)arc4random() / UINT32_MAX) * 0.9;
        [self.emitters addObject:[NSValue valueWithBytes:&emitter objCType:@encode(RibbonFlowEmitter)]];
    }
}

- (void)clampEmittersToBounds {
    NSRect bounds = self.bounds;
    for (NSUInteger i = 0; i < self.emitters.count; i++) {
        RibbonFlowEmitter emitter;
        [self.emitters[i] getValue:&emitter];
        emitter.position.x = MIN(MAX(emitter.position.x, NSMinX(bounds)), NSMaxX(bounds));
        emitter.position.y = MIN(MAX(emitter.position.y, NSMinY(bounds)), NSMaxY(bounds));
        self.emitters[i] = [NSValue valueWithBytes:&emitter objCType:@encode(RibbonFlowEmitter)];
    }
}

- (void)animateOneFrame {
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0.0) { dt = 1.0 / 60.0; }

    [self updateEmittersWithDelta:dt];

    self.particleSystem.blendMode = self.additiveBlend ? SSKParticleBlendModeAdditive : SSKParticleBlendModeAlpha;
    [self.particleSystem advanceBy:dt];

    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) { return; }

    [self.particleSystem drawInContext:ctx];

    [SSKDiagnostics drawOverlayInView:self
                                text:@"Ribbon Flow Demo"
                     framesPerSecond:self.animationClock.framesPerSecond];
}

- (void)updateEmittersWithDelta:(NSTimeInterval)dt {
    if (self.emitters.count == 0) { return; }
    RibbonFlowRegisterPalettes();
    SSKPaletteManager *manager = [SSKPaletteManager sharedManager];
    NSString *module = RibbonFlowPaletteModuleIdentifier();
    SSKColorPalette *palette = [manager paletteWithIdentifier:self.paletteIdentifier module:module];
    if (!palette) {
        NSString *fallback = RibbonFlowDefaultPaletteIdentifier();
        palette = [manager paletteWithIdentifier:fallback module:module];
    }

    NSRect bounds = NSInsetRect(self.bounds, 40.0, 40.0);
    if (bounds.size.width <= 0 || bounds.size.height <= 0) {
        bounds = self.bounds;
    }

    for (NSUInteger i = 0; i < self.emitters.count; i++) {
        RibbonFlowEmitter emitter;
        [self.emitters[i] getValue:&emitter];

        emitter.colorPhase += dt * 0.12;

        NSPoint toTarget = SSKVectorSubtract(emitter.target, emitter.position);
        CGFloat distance = SSKVectorLength(toTarget);
        if (distance < 50.0) {
            emitter.target = [self randomPointInRect:bounds];
            toTarget = SSKVectorSubtract(emitter.target, emitter.position);
            distance = SSKVectorLength(toTarget);
        }

        NSPoint direction = distance > 0.001 ? SSKVectorNormalize(toTarget) : [self randomUnitVector];
        NSPoint acceleration = SSKVectorScale(direction, emitter.intrinsicSpeed * 180.0 * dt);
        emitter.velocity = SSKVectorAdd(emitter.velocity, acceleration);
        emitter.velocity = SSKVectorClampLength(emitter.velocity, 40.0, 260.0);

        NSPoint step = SSKVectorScale(emitter.velocity, dt * self.speedMultiplier);
        emitter.position = SSKVectorAdd(emitter.position, step);

        if (!NSPointInRect(emitter.position, bounds)) {
            if (emitter.position.x < NSMinX(bounds) || emitter.position.x > NSMaxX(bounds)) {
                emitter.velocity.x *= -1.0;
            }
            if (emitter.position.y < NSMinY(bounds) || emitter.position.y > NSMaxY(bounds)) {
                emitter.velocity.y *= -1.0;
            }
            emitter.position.x = MIN(MAX(emitter.position.x, NSMinX(bounds)), NSMaxX(bounds));
            emitter.position.y = MIN(MAX(emitter.position.y, NSMinY(bounds)), NSMaxY(bounds));
            emitter.target = [self randomPointInRect:bounds];
        }

        [self emitParticlesForEmitter:&emitter palette:palette manager:manager module:module];

        self.emitters[i] = [NSValue valueWithBytes:&emitter objCType:@encode(RibbonFlowEmitter)];
    }
}

- (void)emitParticlesForEmitter:(RibbonFlowEmitter *)emitter
                        palette:(SSKColorPalette *)palette
                        manager:(SSKPaletteManager *)manager
                         module:(NSString *)module {
    if (!emitter) { return; }

    NSUInteger spawnCount = 6;
    NSPoint dir = emitter->velocity;
    if (SSKVectorLength(dir) < 0.001) {
        dir = [self randomUnitVector];
    }
    NSPoint unitDir = SSKVectorNormalize(dir);
    CGFloat baseSpeed = SSKVectorLength(dir);

    [self.particleSystem spawnParticles:spawnCount initializer:^(SSKParticle *particle) {
        CGFloat variation = ((CGFloat)arc4random() / UINT32_MAX) * 0.08;
        CGFloat progress = emitter->colorPhase + variation;
        NSColor *color = palette ?
            [manager colorForPalette:palette progress:progress interpolationMode:SSKPaletteInterpolationModeLoop] :
            [NSColor whiteColor];

        particle.position = emitter->position;
        particle.velocity = SSKVectorScale(unitDir, baseSpeed * 0.25);
        particle.maxLife = 1.6 + ((CGFloat)arc4random() / UINT32_MAX) * 0.3;
        particle.life = 0.0;
        particle.color = color;
        CGFloat sizeBase = self.trailWidth * (10.0 + ((CGFloat)arc4random() / UINT32_MAX) * 6.0);
        particle.size = sizeBase;
        particle.userScalar = sizeBase;
        particle.userVector = unitDir;
        particle.damping = 0.15;
    }];
}

- (NSPoint)randomPointInRect:(NSRect)rect {
    CGFloat x = rect.origin.x + ((CGFloat)arc4random() / UINT32_MAX) * rect.size.width;
    CGFloat y = rect.origin.y + ((CGFloat)arc4random() / UINT32_MAX) * rect.size.height;
    return NSMakePoint(x, y);
}

- (NSPoint)randomUnitVector {
    CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * (CGFloat)(M_PI * 2.0);
    return NSMakePoint(cos(angle), sin(angle));
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
                                                                                   title:@"Ribbon Flow"
                                                                                subtitle:@"Flowing ribbons inspired by the classic Apple screensaver."];
    SSKPreferenceBinder *binder = self.configController.preferenceBinder;
    NSStackView *stack = self.configController.contentStack;

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Emitter Count"
                                             minValue:1
                                             maxValue:12
                                                  key:kPrefEmitterCount
                                               format:@"%.0f"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Speed"
                                             minValue:0.4
                                             maxValue:3.0
                                                  key:kPrefSpeed
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Trail Width"
                                             minValue:0.4
                                             maxValue:3.0
                                                  key:kPrefTrailWidth
                                               format:@"%.2f"
                                                binder:binder]];

    [stack addArrangedSubview:[self paletteRowWithBinder:binder]];

    NSButton *blendToggle = [NSButton checkboxWithTitle:@"Use additive glow" target:nil action:nil];
    [binder bindCheckbox:blendToggle key:kPrefAdditiveBlend];
    [stack addArrangedSubview:blendToggle];
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
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:slider];
    [row addArrangedSubview:valueLabel];

    [binder bindSlider:slider key:key valueLabel:valueLabel format:format];
    return row;
}

- (NSView *)paletteRowWithBinder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:@"Colour Palette"];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popUp removeAllItems];

    RibbonFlowRegisterPalettes();
    NSArray<SSKColorPalette *> *palettes = [[SSKPaletteManager sharedManager] palettesForModule:RibbonFlowPaletteModuleIdentifier()];
    for (SSKColorPalette *palette in palettes) {
        NSString *title = palette.displayName.length ? palette.displayName : @"Palette";
        [popUp addItemWithTitle:title];
        NSMenuItem *item = [popUp itemAtIndex:popUp.numberOfItems - 1];
        item.representedObject = palette.identifier;
    }
    if (popUp.numberOfItems == 0) {
        NSString *fallback = RibbonFlowDefaultPaletteIdentifier();
        [popUp addItemWithTitle:fallback];
        popUp.lastItem.representedObject = fallback;
    }

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:popUp];

    [binder bindPopUpButton:popUp key:kPrefPalette];
    return row;
}

- (SSKColorPalette *)currentPalette {
    SSKPaletteManager *manager = [SSKPaletteManager sharedManager];
    NSString *module = RibbonFlowPaletteModuleIdentifier();
    SSKColorPalette *palette = [manager paletteWithIdentifier:self.paletteIdentifier module:module];
    if (!palette) {
        palette = [manager paletteWithIdentifier:RibbonFlowDefaultPaletteIdentifier() module:module];
    }
    if (!palette) {
        palette = [[manager palettesForModule:module] firstObject];
    }
    return palette;
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    [self applyPreferences:preferences changedKeys:changedKeys];
}

- (void)applyPreferences:(NSDictionary<NSString *,id> *)preferences
             changedKeys:(NSSet<NSString *> *)changedKeys {
    RibbonFlowRegisterPalettes();
    NSDictionary *defaults = [self defaultPreferences];

    NSUInteger newEmitterCount = [preferences[kPrefEmitterCount] respondsToSelector:@selector(unsignedIntegerValue)] ?
        [preferences[kPrefEmitterCount] unsignedIntegerValue] :
        [defaults[kPrefEmitterCount] unsignedIntegerValue];
    newEmitterCount = MIN(MAX(newEmitterCount, 1u), 24u);

    double speed = [preferences[kPrefSpeed] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefSpeed] doubleValue] :
        [defaults[kPrefSpeed] doubleValue];
    self.speedMultiplier = MAX(0.2, speed);

    double width = [preferences[kPrefTrailWidth] respondsToSelector:@selector(doubleValue)] ?
        [preferences[kPrefTrailWidth] doubleValue] :
        [defaults[kPrefTrailWidth] doubleValue];
    self.trailWidth = MAX(0.1, width);

    NSString *paletteValue = [preferences[kPrefPalette] isKindOfClass:[NSString class]] ?
        preferences[kPrefPalette] : defaults[kPrefPalette];
    if (![paletteValue isKindOfClass:[NSString class]] || paletteValue.length == 0) {
        paletteValue = RibbonFlowDefaultPaletteIdentifier();
    }
    self.paletteIdentifier = paletteValue;

    BOOL additive = [preferences[kPrefAdditiveBlend] respondsToSelector:@selector(boolValue)] ?
        [preferences[kPrefAdditiveBlend] boolValue] :
        [defaults[kPrefAdditiveBlend] boolValue];
    self.additiveBlend = additive;

    if (newEmitterCount != self.emitterCount || (changedKeys && [changedKeys containsObject:kPrefEmitterCount])) {
        self.emitterCount = newEmitterCount;
        [self rebuildEmitters];
    }
}

@end
