// SSKMetalSpritePass+Testing.h - Test-only header, do not ship
// Exposes private methods for unit testing

#import "ScreenSaverKit/SSKMetalSpritePass.h"

@interface SSKMetalSpritePass (Testing)

/// Returns sorted indices for sprites, ordered ascending by z.
/// Deterministic ordering: equal-z sprites retain original order via index tie-break.
/// Non-finite z values (NaN, infinity) are treated as 0.
/// Returned pointer is owned by the pass instance; valid until next sort call.
/// @param sprites Array of sprites to sort
/// @param outCount If non-NULL, receives the count of indices returned
/// @return Pointer to sorted indices, or NULL if sprites is empty or allocation fails
- (const NSUInteger *)sortedIndicesForSprites:(NSArray<SSKSprite *> *)sprites
                                        count:(NSUInteger *)outCount;

/// Returns YES if sprite is potentially visible in viewport.
- (BOOL)isSpriteVisible:(SSKSprite *)sprite viewportPixels:(CGSize)viewport;

@end
