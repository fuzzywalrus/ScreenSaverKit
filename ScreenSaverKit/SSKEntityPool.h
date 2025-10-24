#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef __kindof id _Nonnull (^SSKEntityFactoryBlock)(void);

/// Generic object pool designed for animation entities. Keeps a cache of
/// reusable objects to avoid allocation churn during heavy animation loops.
@interface SSKEntityPool<ObjectType> : NSObject

- (instancetype)initWithCapacity:(NSUInteger)capacity
                         factory:(SSKEntityFactoryBlock)factory NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Fetches an object from the pool, creating one via the factory if needed.
- (ObjectType)acquire;

/// Returns an object to the pool for reuse.
- (void)releaseObject:(ObjectType)object;

/// Removes all pooled objects.
- (void)drain;

/// Ensures at least `count` objects exist in the pool ready for immediate use.
- (void)preallocate:(NSUInteger)count;

@property (nonatomic, readonly) NSUInteger capacity;

@end

NS_ASSUME_NONNULL_END
