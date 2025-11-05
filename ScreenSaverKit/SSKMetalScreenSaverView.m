#import "SSKMetalScreenSaverView.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#import "SSKDiagnostics.h"
#import "SSKMetalRenderer.h"

@interface SSKMetalScreenSaverView ()
@property (nonatomic, strong, readwrite, nullable) SSKMetalRenderer *metalRenderer;
@property (nonatomic, strong, readwrite, nullable) CAMetalLayer *metalLayer;
@property (nonatomic, readwrite, getter=isMetalAvailable) BOOL metalAvailable;
@end

@implementation SSKMetalScreenSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        _useMetalPipeline = YES;
        [self ensureMetalInfrastructureIfNeeded];
    }
    return self;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self ensureMetalInfrastructureIfNeeded];
    [self updateMetalDrawableSize];
}

- (void)setFrame:(NSRect)frameRect {
    [super setFrame:frameRect];
    [self updateMetalDrawableSize];
}

- (void)layout {
    [super layout];
    [self updateMetalDrawableSize];
}

- (void)setUseMetalPipeline:(BOOL)useMetalPipeline {
    if (_useMetalPipeline == useMetalPipeline) {
        return;
    }
    _useMetalPipeline = useMetalPipeline;
    if (useMetalPipeline) {
        [self ensureMetalInfrastructureIfNeeded];
    } else {
        self.metalRenderer = nil;
        self.metalLayer = nil;
        self.metalAvailable = NO;
        if (!self.layer) {
            self.wantsLayer = YES;
            self.layer = [CALayer layer];
        }
    }
}

- (void)animateOneFrame {
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0.0) {
        dt = 1.0 / 60.0;
    }

    BOOL renderedWithMetal = NO;
    if (self.useMetalPipeline) {
        renderedWithMetal = [self renderMetalFrameIfPossibleWithDelta:dt];
        if (!renderedWithMetal && !self.metalRenderer) {
            // Retry initialisation on failure (e.g. device became available later).
            [self ensureMetalInfrastructureIfNeeded];
            renderedWithMetal = [self renderMetalFrameIfPossibleWithDelta:dt];
        }
    }

    if (!renderedWithMetal) {
        [self renderCPUFrameWithDeltaTime:dt];
    }
}

- (void)setupMetalRenderer:(SSKMetalRenderer *)renderer {
    NSParameterAssert(renderer);
    (void)renderer;
}

- (void)renderMetalFrame:(SSKMetalRenderer *)renderer deltaTime:(NSTimeInterval)dt {
    (void)dt;
    [renderer clearWithColor:renderer.clearColor];
}

- (void)renderCPUFrameWithDeltaTime:(NSTimeInterval)dt {
    (void)dt;
    [self setNeedsDisplay:YES];
}

#pragma mark - Private helpers

- (BOOL)renderMetalFrameIfPossibleWithDelta:(NSTimeInterval)dt {
    if (!self.metalRenderer || !self.metalLayer) {
        return NO;
    }
    [self updateMetalDrawableSize];
    if (![self.metalRenderer beginFrame]) {
        return NO;
    }

    [self renderMetalFrame:self.metalRenderer deltaTime:dt];
    [self.metalRenderer endFrame];
    return YES;
}

- (void)ensureMetalInfrastructureIfNeeded {
    if (self.metalRenderer || !self.useMetalPipeline) {
        return;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        self.metalAvailable = NO;
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalScreenSaverView: Metal unavailable on this system – falling back to CPU."];
        }
        return;
    }

    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;
    layer.opaque = YES;
    layer.device = device;
    layer.contentsScale = [self currentBackingScaleFactor];

    SSKMetalRenderer *renderer = [[SSKMetalRenderer alloc] initWithLayer:layer];
    if (!renderer) {
        self.metalAvailable = NO;
        if ([SSKDiagnostics isEnabled]) {
            [SSKDiagnostics log:@"SSKMetalScreenSaverView: failed to initialise SSKMetalRenderer – using CPU path."];
        }
        return;
    }

    self.wantsLayer = YES;
    self.layer = layer;

    self.metalLayer = layer;
    self.metalRenderer = renderer;
    self.metalAvailable = YES;
    [self setupMetalRenderer:renderer];
    [self updateMetalDrawableSize];
}

- (void)updateMetalDrawableSize {
    if (!self.metalLayer) { return; }
    CGFloat scale = [self currentBackingScaleFactor];
    if (scale <= 0.0) {
        scale = 1.0;
    }
    self.metalLayer.contentsScale = scale;
    CGSize boundsSize = self.bounds.size;
    self.metalLayer.drawableSize = CGSizeMake(MAX(boundsSize.width * scale, 1.0),
                                              MAX(boundsSize.height * scale, 1.0));
}

- (CGFloat)currentBackingScaleFactor {
    if (self.window) {
        return self.window.backingScaleFactor;
    }
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    return screen ? screen.backingScaleFactor : 1.0;
}

@end
