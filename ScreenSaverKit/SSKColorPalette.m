#import "SSKColorPalette.h"

@implementation SSKColorPalette

- (instancetype)initWithIdentifier:(NSString *)identifier
                       displayName:(NSString *)displayName
                            colors:(NSArray<NSColor *> *)colors {
    NSParameterAssert(identifier.length > 0);
    NSParameterAssert(displayName.length > 0);
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _displayName = [displayName copy];
        _colors = [colors copy] ?: @[];
    }
    return self;
}

+ (instancetype)paletteWithIdentifier:(NSString *)identifier
                          displayName:(NSString *)displayName
                               colors:(NSArray<NSColor *> *)colors {
    return [[self alloc] initWithIdentifier:identifier displayName:displayName colors:colors];
}

@end
