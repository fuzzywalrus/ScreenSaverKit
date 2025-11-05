#import "SSKMetalRenderDiagnostics.h"

#import <AppKit/AppKit.h>

@interface SSKMetalRenderDiagnostics ()
@property (nonatomic, weak, nullable) CAMetalLayer *metalLayer;
@property (nonatomic, strong, nullable) CATextLayer *overlayLayer;
@property (nonatomic) NSUInteger metalSuccessCountInternal;
@property (nonatomic) NSUInteger metalFailureCountInternal;
@property (nonatomic) BOOL lastAttemptSucceededInternal;
@end

@implementation SSKMetalRenderDiagnostics

- (instancetype)init {
    if ((self = [super init])) {
        _overlayEnabled = YES;
    }
    return self;
}

- (void)attachToMetalLayer:(CAMetalLayer *)layer {
    if (self.overlayLayer.superlayer) {
        [self.overlayLayer removeFromSuperlayer];
    }
    self.metalLayer = layer;
    if (!layer || !self.overlayEnabled) {
        return;
    }

    CATextLayer *overlay = self.overlayLayer;
    if (!overlay) {
        overlay = [CATextLayer layer];
        overlay.alignmentMode = kCAAlignmentLeft;
        overlay.foregroundColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0].CGColor;
        overlay.backgroundColor = [NSColor colorWithCalibratedWhite:0 alpha:0.55].CGColor;
        overlay.cornerRadius = 8.0;
        overlay.masksToBounds = YES;
        overlay.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        overlay.fontSize = 12.0;
        self.overlayLayer = overlay;
    }
    overlay.contentsScale = MAX(layer.contentsScale, 1.0);
    [layer addSublayer:overlay];
    [self layoutOverlayLayer];
}

- (void)setOverlayEnabled:(BOOL)overlayEnabled {
    if (_overlayEnabled == overlayEnabled) {
        return;
    }
    _overlayEnabled = overlayEnabled;
    if (!overlayEnabled && self.overlayLayer.superlayer) {
        [self.overlayLayer removeFromSuperlayer];
    } else if (overlayEnabled && self.metalLayer) {
        [self attachToMetalLayer:self.metalLayer];
    }
}

- (NSUInteger)metalSuccessCount {
    return self.metalSuccessCountInternal;
}

- (NSUInteger)metalFailureCount {
    return self.metalFailureCountInternal;
}

- (BOOL)lastAttemptSucceeded {
    return self.lastAttemptSucceededInternal;
}

- (void)recordMetalAttemptWithSuccess:(BOOL)success {
    if (success) {
        self.metalSuccessCountInternal += 1;
        self.metalFailureCountInternal = 0;
    } else {
        self.metalFailureCountInternal += 1;
    }
    self.lastAttemptSucceededInternal = success;
}

- (void)reset {
    self.metalSuccessCountInternal = 0;
    self.metalFailureCountInternal = 0;
    self.lastAttemptSucceededInternal = NO;
    self.deviceStatus = nil;
    self.layerStatus = nil;
    self.rendererStatus = nil;
    self.drawableStatus = nil;
    [self updateOverlayWithTitle:@"" extraLines:nil framesPerSecond:0];
}

- (NSArray<NSString *> *)statusLines {
    NSString *device = self.deviceStatus.length ? self.deviceStatus : @"Device: (unset)";
    NSString *layer = self.layerStatus.length ? self.layerStatus : @"Layer: (unset)";
    NSString *renderer = self.rendererStatus.length ? self.rendererStatus : @"Renderer: (unset)";
    NSString *drawable = self.drawableStatus.length ? self.drawableStatus : @"Drawable: (unset)";
    NSString *metalStats = [NSString stringWithFormat:@"Metal successes: %lu | Metal fallbacks: %lu",
                            (unsigned long)self.metalSuccessCountInternal,
                            (unsigned long)self.metalFailureCountInternal];
    return @[device, layer, renderer, drawable, metalStats];
}

- (NSString *)overlayStringWithTitle:(NSString *)title
                          extraLines:(NSArray<NSString *> *)extraLines
                     framesPerSecond:(double)fps {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (title.length) {
        [lines addObject:title];
    }
    [lines addObjectsFromArray:[self statusLines]];
    if (extraLines.count) {
        [lines addObjectsFromArray:extraLines];
    }
    NSString *fpsLine = [NSString stringWithFormat:@"FPS: %.1f", fps];
    [lines addObject:fpsLine];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)updateOverlayWithTitle:(NSString *)title
                    extraLines:(NSArray<NSString *> *)extraLines
               framesPerSecond:(double)fps {
    if (!self.overlayEnabled || !self.metalLayer) {
        return;
    }
    if (!self.overlayLayer.superlayer) {
        [self attachToMetalLayer:self.metalLayer];
    }
    self.overlayLayer.contentsScale = MAX(self.metalLayer.contentsScale, 1.0);
    NSString *overlayString = [self overlayStringWithTitle:title
                                                extraLines:extraLines
                                           framesPerSecond:fps];
    self.overlayLayer.string = overlayString;
    [self layoutOverlayLayerWithString:overlayString];
}

- (void)layoutOverlayLayer {
    [self layoutOverlayLayerWithString:[self.overlayLayer.string isKindOfClass:NSString.class] ? (NSString *)self.overlayLayer.string : nil];
}

- (void)layoutOverlayLayerWithString:(NSString *)string {
    if (!self.overlayLayer || !self.metalLayer) {
        return;
    }
    CGFloat inset = 18.0;
    CGFloat maxWidth = MAX(MIN(self.metalLayer.bounds.size.width - inset * 2.0, 520.0), 120.0);
    NSFont *font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSDictionary *attributes = @{
        NSFontAttributeName: font
    };
    CGSize textSize = CGSizeZero;
    if (string.length) {
        CGRect bounds = [string boundingRectWithSize:CGSizeMake(maxWidth - 16.0, CGFLOAT_MAX)
                                             options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                          attributes:attributes];
        textSize = bounds.size;
    }
    CGFloat height = MAX(textSize.height + 12.0, 40.0);
    self.overlayLayer.frame = CGRectMake(inset,
                                         self.metalLayer.bounds.size.height - height - inset,
                                         maxWidth,
                                         height);
}

@end
