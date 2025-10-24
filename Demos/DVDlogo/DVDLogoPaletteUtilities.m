#import "DVDLogoPaletteUtilities.h"

NSArray<NSDictionary<NSString *, id> *> *DVDLogoPaletteDefinitions(void) {
    static NSArray<NSDictionary<NSString *, id> *> *palettes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        palettes = @[
            @{
                @"title": @"Classic Neon",
                @"value": @"neon",
                @"colors": @[
                    [NSColor colorWithHue:0.60 saturation:0.75 brightness:1.00 alpha:1.0],
                    [NSColor colorWithHue:0.82 saturation:0.80 brightness:1.00 alpha:1.0],
                    [NSColor colorWithHue:0.13 saturation:0.85 brightness:1.00 alpha:1.0]
                ]
            },
            @{
                @"title": @"Sunset",
                @"value": @"sunset",
                @"colors": @[
                    [NSColor colorWithHue:0.02 saturation:0.88 brightness:0.96 alpha:1.0],
                    [NSColor colorWithHue:0.08 saturation:0.78 brightness:0.93 alpha:1.0],
                    [NSColor colorWithHue:0.63 saturation:0.45 brightness:0.92 alpha:1.0]
                ]
            },
            @{
                @"title": @"Crystal",
                @"value": @"crystal",
                @"colors": @[
                    [NSColor colorWithHue:0.52 saturation:0.30 brightness:1.00 alpha:1.0],
                    [NSColor colorWithHue:0.54 saturation:0.55 brightness:0.95 alpha:1.0],
                    [NSColor colorWithHue:0.58 saturation:0.65 brightness:0.90 alpha:1.0]
                ]
            },
            @{
                @"title": @"Arcade",
                @"value": @"arcade",
                @"colors": @[
                    [NSColor colorWithHue:0.97 saturation:0.80 brightness:0.95 alpha:1.0],
                    [NSColor colorWithHue:0.10 saturation:0.85 brightness:0.98 alpha:1.0],
                    [NSColor colorWithHue:0.65 saturation:0.85 brightness:0.95 alpha:1.0]
                ]
            }
        ];
    });
    return palettes;
}

NSArray<NSColor *> *DVDLogoColorsForIdentifier(NSString *identifier) {
    for (NSDictionary<NSString *, id> *palette in DVDLogoPaletteDefinitions()) {
        if ([palette[@"value"] isEqualToString:identifier]) {
            return palette[@"colors"];
        }
    }
    NSDictionary<NSString *, id> *fallback = DVDLogoPaletteDefinitions().firstObject;
    return fallback ? fallback[@"colors"] : @[ [NSColor whiteColor] ];
}

NSString *DVDLogoPaletteFallbackIdentifier(void) {
    NSDictionary<NSString *, id> *palette = DVDLogoPaletteDefinitions().firstObject;
    return palette[@"value"] ?: @"neon";
}

NSColor *DVDLogoColorForProgress(NSArray<NSColor *> *colors, CGFloat progress) {
    if (colors.count == 0) {
        return [NSColor whiteColor];
    }
    if (colors.count == 1) {
        return colors.firstObject;
    }
    CGFloat wrapped = progress - floor(progress);
    CGFloat scaled = wrapped * (CGFloat)colors.count;
    NSInteger index = (NSInteger)floor(scaled);
    CGFloat blend = scaled - (CGFloat)index;
    NSColor *first = colors[(NSUInteger)index % colors.count];
    NSColor *second = colors[(NSUInteger)(index + 1) % colors.count];
    return [first blendedColorWithFraction:blend ofColor:second];
}

NSData *DVDLogoSerializeColor(NSColor *color) {
    if (!color) { return NSData.data; }
    NSData *data = nil;
    if (@available(macOS 10.13, *)) {
        data = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:NO error:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        data = [NSKeyedArchiver archivedDataWithRootObject:color];
#pragma clang diagnostic pop
    }
    return data ?: NSData.data;
}

NSColor *DVDLogoColorFromPreferenceValue(id value, NSColor *fallback) {
    if ([value isKindOfClass:[NSData class]]) {
        if (@available(macOS 10.13, *)) {
            NSColor *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:value error:nil];
            return decoded ?: fallback;
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSColor *decoded = [NSKeyedUnarchiver unarchiveObjectWithData:value];
#pragma clang diagnostic pop
            return decoded ?: fallback;
        }
    } else if ([value isKindOfClass:[NSColor class]]) {
        return value;
    }
    return fallback;
}

NSColor *DVDLogoFallbackSolidColor(void) {
    return [NSColor colorWithHue:0.6 saturation:0.6 brightness:1.0 alpha:1.0];
}
