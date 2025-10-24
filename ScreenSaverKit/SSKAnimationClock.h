#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Tracks frame-to-frame timing with optional smoothing and pause support.
@interface SSKAnimationClock : NSObject

/// Last computed delta (seconds).
@property (nonatomic, readonly) NSTimeInterval deltaTime;

/// Rolling average frames-per-second calculated from recent deltas.
@property (nonatomic, readonly) double framesPerSecond;

/// Indicates whether the clock is currently paused.
@property (nonatomic, getter=isPaused) BOOL paused;

/// Resets internal state and optionally seeds the initial timestamp.
- (void)resetWithTimestamp:(NSTimeInterval)timestamp;

/// Steps the clock forward using the supplied wall-clock timestamp and
/// returns the calculated delta.
- (NSTimeInterval)stepWithTimestamp:(NSTimeInterval)timestamp;

/// Convenience to pause without losing accumulated timing.
- (void)pause;

/// Resumes using the supplied timestamp as the new baseline.
- (void)resumeWithTimestamp:(NSTimeInterval)timestamp;

@end

NS_ASSUME_NONNULL_END
