#import "SSKColorUtilities.h"

NSData *SSKSerializeColor(NSColor *color) {
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

NSColor *SSKDeserializeColor(id value, NSColor *fallback) {
    if ([value isKindOfClass:[NSData class]]) {
        if (@available(macOS 10.13, *)) {
            NSColor *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class]
                                                                  fromData:value
                                                                     error:nil];
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
