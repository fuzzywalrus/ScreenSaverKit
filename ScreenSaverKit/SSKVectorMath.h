#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

NS_INLINE NSPoint SSKVectorAdd(NSPoint a, NSPoint b) {
    return NSMakePoint(a.x + b.x, a.y + b.y);
}

NS_INLINE NSPoint SSKVectorSubtract(NSPoint a, NSPoint b) {
    return NSMakePoint(a.x - b.x, a.y - b.y);
}

NS_INLINE NSPoint SSKVectorScale(NSPoint a, CGFloat scalar) {
    return NSMakePoint(a.x * scalar, a.y * scalar);
}

NS_INLINE CGFloat SSKVectorDot(NSPoint a, NSPoint b) {
    return a.x * b.x + a.y * b.y;
}

NS_INLINE CGFloat SSKVectorLength(NSPoint a) {
    return (CGFloat)hypot(a.x, a.y);
}

NS_INLINE NSPoint SSKVectorNormalize(NSPoint a) {
    CGFloat length = SSKVectorLength(a);
    if (length <= 0.0001) {
        return NSZeroPoint;
    }
    return NSMakePoint(a.x / length, a.y / length);
}

NS_INLINE NSPoint SSKVectorClampLength(NSPoint a, CGFloat minLength, CGFloat maxLength) {
    CGFloat length = SSKVectorLength(a);
    if (length < minLength) {
        return SSKVectorScale(SSKVectorNormalize(a), minLength);
    }
    if (length > maxLength) {
        return SSKVectorScale(SSKVectorNormalize(a), maxLength);
    }
    return a;
}

NS_INLINE NSPoint SSKVectorReflect(NSPoint incident, NSPoint normal) {
    NSPoint n = SSKVectorNormalize(normal);
    CGFloat dot = SSKVectorDot(incident, n);
    return SSKVectorSubtract(incident, SSKVectorScale(n, 2.0 * dot));
}

NS_ASSUME_NONNULL_END
