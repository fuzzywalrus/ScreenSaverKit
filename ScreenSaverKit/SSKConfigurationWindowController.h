#import <AppKit/AppKit.h>

@class SSKScreenSaverView, SSKPreferenceBinder;

NS_ASSUME_NONNULL_BEGIN

/// Provides a pre-built configuration sheet with a header, vertical stack
/// layout, and standard OK/Cancel buttons. Subclass or use directly to build
/// screensaver options with minimal boilerplate.
@interface SSKConfigurationWindowController : NSWindowController

- (instancetype)initWithSaverView:(SSKScreenSaverView *)saverView
                              title:(NSString *)title
                           subtitle:(nullable NSString *)subtitle;

/// Stack view where clients can add arranged subviews (rows, custom controls).
@property (nonatomic, strong, readonly) NSStackView *contentStack;

/// Simple convenience binder wired to the saver view's defaults.
@property (nonatomic, strong, readonly) SSKPreferenceBinder *preferenceBinder;

/// Call before returning the sheet to ensure controls are in sync and
/// defaults snapshot is captured for cancellation.
- (void)prepareForPresentation;

@end

NS_ASSUME_NONNULL_END
