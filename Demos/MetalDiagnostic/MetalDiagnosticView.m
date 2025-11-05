#import "MetalDiagnosticView.h"

#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

#import "ScreenSaverKit/SSKDiagnostics.h"

static NSString * const kDiagnosticBuildString = @"Build #1";

@interface MetalDiagnosticView ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) CATextLayer *textLayer;

@property (nonatomic, copy) NSString *deviceStatus;
@property (nonatomic, copy) NSString *layerStatus;
@property (nonatomic, copy) NSString *drawableStatus;
@property (nonatomic, copy) NSString *commandStatus;
@property (nonatomic, copy) NSString *overlayString;

@property (nonatomic) NSUInteger drawableSuccesses;
@property (nonatomic) NSUInteger drawableFailures;
@property (nonatomic) NSUInteger frameCount;

@property (nonatomic) BOOL attemptedDevice;
@property (nonatomic) BOOL loggedNoDevice;
@property (nonatomic) BOOL loggedLayerCreation;
@property (nonatomic) BOOL loggedRendererFailure;
@property (nonatomic) BOOL loggedDrawableFailure;
@property (nonatomic) BOOL loggedDrawableSuccess;
@end

@implementation MetalDiagnosticView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;
        _deviceStatus = @"Device: not requested";
        _layerStatus = @"Layer: waiting for device";
        _drawableStatus = @"Drawable: not requested";
        _commandStatus = @"Command: idle";
        _overlayString = @"Metal Diagnostic – awaiting status…";
        [SSKDiagnostics setEnabled:YES];
    }
    return self;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self ensureMetalLayer];
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self updateMetalGeometry];
}

- (void)layout {
    [super layout];
    [self updateMetalGeometry];
    [self layoutTextLayer];
}

- (void)animateOneFrame {
    self.frameCount += 1;
    [self ensureMetalDevice];
    [self ensureMetalLayer];
    [self updateMetalGeometry];
    [self renderMetalFrame];
    [self updateOverlayText];
    if (!self.metalLayer) {
        [self setNeedsDisplay:YES];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0]
    };
    CGFloat lineHeight = 17.0;
    NSArray<NSString *> *lines = [self.overlayString componentsSeparatedByString:@"\n"];
    CGFloat totalHeight = lineHeight * lines.count;
    CGFloat y = NSMaxY(self.bounds) - totalHeight - 24.0;
    CGFloat x = NSMinX(self.bounds) + 18.0;

    [[NSColor colorWithCalibratedWhite:0 alpha:0.6] setFill];
    NSRect panel = NSMakeRect(x - 10.0,
                              y - 10.0,
                              420.0,
                              totalHeight + 20.0);
    [[NSBezierPath bezierPathWithRoundedRect:panel xRadius:10 yRadius:10] fill];

    for (NSString *line in lines) {
        [line drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
        y += lineHeight;
    }
}

#pragma mark - Metal set-up

- (void)ensureMetalDevice {
    if (self.device) { return; }
    if (self.attemptedDevice) { return; }
    self.attemptedDevice = YES;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        self.deviceStatus = @"Device: unavailable (MTLCreateSystemDefaultDevice returned nil)";
        if (!self.loggedNoDevice) {
            self.loggedNoDevice = YES;
            [SSKDiagnostics log:@"MetalDiagnostic: no Metal device available (MTLCreateSystemDefaultDevice returned nil)."];
        }
        return;
    }

    self.device = device;
    self.deviceStatus = [NSString stringWithFormat:@"Device: %@ (lowPower=%@ removable=%@)",
                         device.name,
                         device.isLowPower ? @"YES" : @"NO",
                         device.isRemovable ? @"YES" : @"NO"];
    [SSKDiagnostics log:@"MetalDiagnostic: obtained device '%@'.", device.name];
}

- (void)ensureMetalLayer {
    if (!self.device) {
        self.layerStatus = @"Layer: waiting for Metal device";
        return;
    }

    if (!self.window) {
        self.layerStatus = @"Layer: waiting for window attachment";
        return;
    }

    if (self.metalLayer) { return; }

    self.wantsLayer = YES;
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = self.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    layer.needsDisplayOnBoundsChange = YES;
    if ([layer respondsToSelector:@selector(setPresentsWithTransaction:)]) {
        layer.presentsWithTransaction = NO;
    }
#if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 101300
    if (@available(macOS 10.13, *)) {
        layer.displaySyncEnabled = YES;
    }
#endif

    self.layer = layer;
    if ([self respondsToSelector:@selector(setLayerContentsRedrawPolicy:)]) {
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    }
    self.metalLayer = layer;
    self.layerStatus = @"Layer: created and attached";

    [self ensureTextLayer];

    if (!self.loggedLayerCreation) {
        self.loggedLayerCreation = YES;
        [SSKDiagnostics log:@"MetalDiagnostic: created CAMetalLayer and attached to view."];
    }
}

- (void)ensureTextLayer {
    if (!self.metalLayer || self.textLayer) { return; }
    CATextLayer *text = [CATextLayer layer];
    text.alignmentMode = kCAAlignmentLeft;
    text.foregroundColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0].CGColor;
    text.backgroundColor = [NSColor colorWithCalibratedWhite:0 alpha:0.55].CGColor;
    text.cornerRadius = 8.0;
    text.masksToBounds = YES;
    text.contentsScale = [self currentContentsScale];
    text.font = (__bridge CFTypeRef)[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    text.fontSize = 12.0;
    [self.metalLayer addSublayer:text];
    self.textLayer = text;
    [self layoutTextLayer];
}

- (CGFloat)currentContentsScale {
    if (self.window) { return self.window.backingScaleFactor; }
    if (NSScreen.mainScreen) { return NSScreen.mainScreen.backingScaleFactor; }
    return 1.0;
}

- (void)updateMetalGeometry {
    if (!self.metalLayer) { return; }
    CGFloat scale = [self currentContentsScale];
    self.metalLayer.contentsScale = scale;
    self.metalLayer.frame = self.bounds;
    self.metalLayer.drawableSize = CGSizeMake(NSWidth(self.bounds) * scale,
                                              NSHeight(self.bounds) * scale);
    self.layerStatus = [NSString stringWithFormat:@"Layer: attached (drawable %.0fx%.0f @ scale %.2f)",
                        self.metalLayer.drawableSize.width,
                        self.metalLayer.drawableSize.height,
                        scale];
    if (self.textLayer) {
        self.textLayer.contentsScale = scale;
        [self layoutTextLayer];
    }
}

- (void)layoutTextLayer {
    if (!self.textLayer) { return; }
    CGFloat scale = MAX(self.textLayer.contentsScale, 1.0);
    CGFloat width = MIN(self.bounds.size.width - 32.0, 520.0);
    CGFloat height = 140.0;
    self.textLayer.frame = CGRectMake(18.0,
                                      self.bounds.size.height - height - 18.0,
                                      width,
                                      height);
    self.textLayer.contentsScale = scale;
}

- (void)renderMetalFrame {
    if (!self.device || !self.metalLayer) {
        self.drawableStatus = @"Drawable: skipped (no device/layer)";
        self.commandStatus = @"Command: skipped";
        return;
    }

    if (!self.commandQueue) {
        self.commandQueue = [self.device newCommandQueue];
        if (!self.commandQueue) {
            self.commandStatus = @"Command: failed to create command queue";
            if (!self.loggedRendererFailure) {
                self.loggedRendererFailure = YES;
                [SSKDiagnostics log:@"MetalDiagnostic: failed to create command queue on device '%@'.", self.device.name];
            }
            return;
        }
    }

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) {
        self.drawableFailures += 1;
        self.drawableStatus = [NSString stringWithFormat:@"Drawable: nil (%lu consecutive failures)",
                               (unsigned long)self.drawableFailures];
        if (!self.loggedDrawableFailure || (self.drawableFailures % 60 == 0)) {
            self.loggedDrawableFailure = YES;
            [SSKDiagnostics log:@"MetalDiagnostic: nextDrawable returned nil (failure count %lu).",
             (unsigned long)self.drawableFailures];
        }
        self.commandStatus = @"Command: skipped (no drawable)";
        return;
    }

    self.drawableSuccesses += 1;
    self.drawableFailures = 0;
    self.drawableStatus = [NSString stringWithFormat:@"Drawable: ok (total successes %lu)",
                           (unsigned long)self.drawableSuccesses];
    if (!self.loggedDrawableSuccess) {
        self.loggedDrawableSuccess = YES;
        [SSKDiagnostics log:@"MetalDiagnostic: received first drawable (success count %lu).",
         (unsigned long)self.drawableSuccesses];
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    double t = fmod(self.frameCount * 0.02, 1.0);
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.2 + 0.6 * sin(t * M_PI),
                                                            0.2 + 0.6 * sin((t + 0.33) * M_PI),
                                                            0.2 + 0.6 * sin((t + 0.66) * M_PI),
                                                            1.0);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    commandBuffer.label = @"MetalDiagnosticClear";

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];

    self.commandStatus = @"Command: submitted";
    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) { return; }
            switch (buffer.status) {
                case MTLCommandBufferStatusCompleted:
                    weakSelf.commandStatus = @"Command: completed";
                    break;
                case MTLCommandBufferStatusError:
                    weakSelf.commandStatus = [NSString stringWithFormat:@"Command: error (%@)",
                                              buffer.error.localizedDescription ?: @"unknown"];
                    break;
                case MTLCommandBufferStatusScheduled:
                    weakSelf.commandStatus = @"Command: scheduled";
                    break;
                case MTLCommandBufferStatusCommitted:
                    weakSelf.commandStatus = @"Command: committed";
                    break;
                default:
                    weakSelf.commandStatus = [NSString stringWithFormat:@"Command: status %ld",
                                              (long)buffer.status];
                    break;
            }
            [weakSelf updateOverlayText];
        });
    }];
    [commandBuffer commit];
}

- (void)updateOverlayText {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Metal Diagnostic – %@ – frame %lu",
                      kDiagnosticBuildString,
                      (unsigned long)self.frameCount]];
    [lines addObject:self.deviceStatus ?: @"Device: (unset)"];
    [lines addObject:self.layerStatus ?: @"Layer: (unset)"];
    [lines addObject:self.drawableStatus ?: @"Drawable: (unset)"];
    [lines addObject:self.commandStatus ?: @"Command: (unset)"];
    [lines addObject:[NSString stringWithFormat:@"Drawable successes: %lu | failures: %lu",
                      (unsigned long)self.drawableSuccesses,
                      (unsigned long)self.drawableFailures]];
    self.overlayString = [lines componentsJoinedByString:@"\n"];

    if (self.textLayer) {
        self.textLayer.string = self.overlayString;
    }
}

@end
