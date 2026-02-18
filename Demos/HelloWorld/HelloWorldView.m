#import "HelloWorldView.h"

#import <AppKit/AppKit.h>

#import "ScreenSaverKit/SSKDiagnostics.h"

static const CGFloat kBubblePadH = 24.0;
static const CGFloat kBubblePadV = 14.0;
static const CGFloat kCornerRadius = 18.0;
static const CGFloat kBaseSpeed = 120.0;

@interface HelloWorldView ()
@property (nonatomic) NSPoint position;
@property (nonatomic) NSPoint velocity;
@property (nonatomic) CGFloat hue;
@end

@implementation HelloWorldView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        self.animationTimeInterval = 1.0 / 60.0;

        CGFloat angle = ((CGFloat)arc4random() / UINT32_MAX) * M_PI * 2.0;
        _velocity = NSMakePoint(cos(angle) * kBaseSpeed, sin(angle) * kBaseSpeed);
        _hue = (CGFloat)arc4random() / UINT32_MAX;
    }
    return self;
}

- (void)setFrame:(NSRect)frameRect {
    [super setFrame:frameRect];
    self.position = NSMakePoint(NSMidX(frameRect), NSMidY(frameRect));
}

- (BOOL)isOpaque { return YES; }

#pragma mark - Animation

- (void)animateOneFrame {
    NSTimeInterval dt = [self advanceAnimationClock];
    if (dt <= 0) { dt = 1.0 / 60.0; }

    // Scale font to view so it works in both preview and full screen.
    CGFloat fontSize = MAX(12.0, floor(self.bounds.size.height * 0.06));
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:fontSize weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    NSSize textSize = [@"Hello, World!" sizeWithAttributes:attrs];
    CGFloat halfW = (textSize.width  / 2.0) + kBubblePadH;
    CGFloat halfH = (textSize.height / 2.0) + kBubblePadV;

    NSRect bounds = self.bounds;
    NSPoint pos = self.position;
    NSPoint vel = self.velocity;

    pos.x += vel.x * dt;
    pos.y += vel.y * dt;

    BOOL bounced = NO;
    if (pos.x - halfW < NSMinX(bounds)) {
        pos.x = NSMinX(bounds) + halfW;
        vel.x = fabs(vel.x);
        bounced = YES;
    } else if (pos.x + halfW > NSMaxX(bounds)) {
        pos.x = NSMaxX(bounds) - halfW;
        vel.x = -fabs(vel.x);
        bounced = YES;
    }
    if (pos.y - halfH < NSMinY(bounds)) {
        pos.y = NSMinY(bounds) + halfH;
        vel.y = fabs(vel.y);
        bounced = YES;
    } else if (pos.y + halfH > NSMaxY(bounds)) {
        pos.y = NSMaxY(bounds) - halfH;
        vel.y = -fabs(vel.y);
        bounced = YES;
    }

    if (bounced) {
        self.hue += 0.15 + ((CGFloat)arc4random() / UINT32_MAX) * 0.2;
        if (self.hue > 1.0) { self.hue -= 1.0; }
    }

    self.position = pos;
    self.velocity = vel;

    [self setNeedsDisplay:YES];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    // Background
    [[NSColor blackColor] setFill];
    NSRectFill(self.bounds);

    // Scale font to view
    CGFloat fontSize = MAX(12.0, floor(self.bounds.size.height * 0.06));
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:fontSize weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };

    NSString *text = @"Hello, World!";
    NSSize textSize = [text sizeWithAttributes:attrs];
    NSRect textRect = NSMakeRect(self.position.x - textSize.width  / 2.0,
                                  self.position.y - textSize.height / 2.0,
                                  textSize.width,
                                  textSize.height);

    // Bubble
    NSColor *accent = [NSColor colorWithCalibratedHue:self.hue
                                           saturation:0.8
                                           brightness:1.0
                                                alpha:1.0];
    NSRect bubbleRect = NSInsetRect(textRect, -kBubblePadH, -kBubblePadV);
    NSBezierPath *bubble = [NSBezierPath bezierPathWithRoundedRect:bubbleRect
                                                           xRadius:kCornerRadius
                                                           yRadius:kCornerRadius];
    [[accent colorWithAlphaComponent:0.35] setFill];
    [bubble fill];

    // Text
    [text drawInRect:textRect withAttributes:attrs];

    // Diagnostics overlay
    [SSKDiagnostics drawOverlayInView:self
                                 text:@"HelloWorld Demo"
                      framesPerSecond:self.animationClock.framesPerSecond];
}

#pragma mark - Configuration

- (BOOL)hasConfigureSheet { return NO; }
- (NSWindow *)configureSheet { return nil; }

@end
