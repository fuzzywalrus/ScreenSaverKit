#import <AppKit/AppKit.h>

@class SSKPreferenceBinder;

NS_ASSUME_NONNULL_BEGIN

@interface DVDLogoConfigurationBuilder : NSObject

+ (void)populateStack:(NSStackView *)stack withBinder:(SSKPreferenceBinder *)binder;

@end

NS_ASSUME_NONNULL_END
