#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SSKPreferenceControlKind) {
    SSKPreferenceControlKindSlider,
    SSKPreferenceControlKindCheckbox,
    SSKPreferenceControlKindColorWell,
    SSKPreferenceControlKindPopUp
};

/// Small helper that keeps NSControls in sync with ScreenSaverDefaults.
@interface SSKPreferenceBinder : NSObject

- (instancetype)initWithDefaults:(ScreenSaverDefaults *)defaults;

/// Refreshes bound controls from the latest persisted defaults.
- (void)refreshControls;

/// Capture current preference values so they can be restored on cancel.
- (void)captureInitialValues;

/// Restores the values captured by `captureInitialValues`.
- (void)restoreInitialValues;

/// Persists defaults to disk.
- (void)synchronize;

- (void)bindSlider:(NSSlider *)slider
               key:(NSString *)key
        valueLabel:(nullable NSTextField *)label
            format:(nullable NSString *)format;

- (void)bindCheckbox:(NSButton *)checkbox key:(NSString *)key;

- (void)bindColorWell:(NSColorWell *)colorWell key:(NSString *)key;

- (void)bindPopUpButton:(NSPopUpButton *)popUp key:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
