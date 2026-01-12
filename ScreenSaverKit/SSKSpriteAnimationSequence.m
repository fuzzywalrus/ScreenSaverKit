/**
 * SSKSpriteAnimationSequence Implementation
 * 
 * This file implements animation sequence data for sprite sheet animations. It provides:
 * 
 * Animation Sequences:
 *   - Grid-based sequences: Uniform grid sprite sheets (most common)
 *   - Custom rect sequences: Non-uniform atlas layouts
 *   - Explicit frame sequences: Full control over each frame
 * 
 * Loop Modes:
 *   - Once: Play once and stop at last frame
 *   - Loop: Repeat forever (0,1,2,...,N-1,0,1,2,...)
 *   - PingPong: Reverse at ends (0,1,2,...,N-1,N-2,...,1,0,1,2,...)
 * 
 * Timing:
 *   - Per-frame durations: Each frame can have its own duration
 *   - Default duration: Used when frame.duration is 0
 *   - Total duration: Precomputed for efficient time wrapping
 *   - Cumulative times: Precomputed for fast frame lookup
 * 
 * Frame Lookup:
 *   - frameIndexForTime: Maps playback time to frame index
 *   - Handles time wrapping based on loop mode
 *   - Supports negative time (reverse playback)
 *   - Linear search for frame lookup (fine for typical frame counts)
 * 
 * Performance:
 *   - Immutable after creation (safe for reading from multiple threads)
 *   - Precomputed cumulative times for O(n) frame lookup
 *   - No allocations during frame lookup
 */

#import "SSKSpriteAnimationSequence.h"
#import <math.h>  // fmod

@interface SSKSpriteAnimationSequence ()
@property (nonatomic, readwrite) NSUInteger frameCount;
@property (nonatomic, readwrite) NSTimeInterval defaultFrameDuration;
@property (nonatomic, readwrite) SSKAnimationLoopMode loopMode;
@property (nonatomic, readwrite) NSTimeInterval totalDuration;
@end

@implementation SSKSpriteAnimationSequence {
    SSKAnimationFrame *_frames;
    NSTimeInterval *_cumulativeTimes;  // Cumulative time at end of each frame
}

- (void)dealloc {
    free(_frames);
    free(_cumulativeTimes);
}

#pragma mark - Factory Methods

+ (instancetype)sequenceWithFrames:(const SSKAnimationFrame *)frames
                             count:(NSUInteger)count
                   defaultDuration:(NSTimeInterval)duration
                          loopMode:(SSKAnimationLoopMode)loopMode {
    if (count == 0 || !frames) {
        NSAssert(count > 0, @"Animation sequence requires at least 1 frame");
        return nil;
    }
    
    SSKSpriteAnimationSequence *seq = [[SSKSpriteAnimationSequence alloc] init];
    seq.frameCount = count;
    seq.defaultFrameDuration = duration;
    seq.loopMode = loopMode;
    
    // Copy frames
    seq->_frames = malloc(count * sizeof(SSKAnimationFrame));
    if (!seq->_frames) return nil;
    memcpy(seq->_frames, frames, count * sizeof(SSKAnimationFrame));
    
    // Compute cumulative times and total duration
    [seq computeCumulativeTimes];
    
    return seq;
}

+ (instancetype)sequenceWithGridColumns:(NSUInteger)cols
                                   rows:(NSUInteger)rows
                             frameCount:(NSUInteger)count
                               duration:(NSTimeInterval)duration
                               loopMode:(SSKAnimationLoopMode)loopMode {
    if (count == 0 || count > cols * rows || cols == 0 || rows == 0) {
        NSAssert(count > 0 && count <= cols * rows, @"Invalid frame count for grid");
        return nil;
    }
    
    // Build frames from grid
    SSKAnimationFrame *frames = malloc(count * sizeof(SSKAnimationFrame));
    if (!frames) return nil;
    
    CGFloat frameW = 1.0 / (CGFloat)cols;
    CGFloat frameH = 1.0 / (CGFloat)rows;
    
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger col = i % cols;
        NSUInteger row = i / cols;
        
        frames[i].textureOffset = CGPointMake(col * frameW, row * frameH);
        frames[i].textureSize = CGSizeMake(frameW, frameH);
        frames[i].duration = 0;  // Use default
    }
    
    SSKSpriteAnimationSequence *seq = [self sequenceWithFrames:frames
                                                         count:count
                                               defaultDuration:duration
                                                      loopMode:loopMode];
    free(frames);
    return seq;
}

+ (instancetype)sequenceWithTextureRectsInPixels:(const CGRect *)rects
                                           count:(NSUInteger)count
                                     textureSize:(CGSize)textureSize
                                       durations:(const NSTimeInterval *)durations
                                 defaultDuration:(NSTimeInterval)defaultDuration
                                        loopMode:(SSKAnimationLoopMode)loopMode {
    if (count == 0 || !rects || textureSize.width <= 0 || textureSize.height <= 0) {
        NSAssert(count > 0, @"Animation sequence requires at least 1 frame");
        return nil;
    }
    
    // Build normalized frames from pixel rects
    SSKAnimationFrame *frames = malloc(count * sizeof(SSKAnimationFrame));
    if (!frames) return nil;
    
    for (NSUInteger i = 0; i < count; i++) {
        CGRect rect = rects[i];
        frames[i].textureOffset = CGPointMake(rect.origin.x / textureSize.width,
                                               rect.origin.y / textureSize.height);
        frames[i].textureSize = CGSizeMake(rect.size.width / textureSize.width,
                                            rect.size.height / textureSize.height);
        frames[i].duration = durations ? durations[i] : 0;
    }
    
    SSKSpriteAnimationSequence *seq = [self sequenceWithFrames:frames
                                                         count:count
                                               defaultDuration:defaultDuration
                                                      loopMode:loopMode];
    free(frames);
    return seq;
}

#pragma mark - Internal

- (void)computeCumulativeTimes {
    NSUInteger count = self.frameCount;
    if (count == 0) {
        self.totalDuration = 0;
        return;
    }
    
    _cumulativeTimes = malloc(count * sizeof(NSTimeInterval));
    if (!_cumulativeTimes) {
        // OOM fallback: approximate totalDuration assuming equal frame durations
        // For PingPong, we need to include backward phase: forward + backward
        // Forward = N frames, Backward = N-2 frames (endpoints not repeated)
        // Total = N + (N-2) = 2N-2 frames for N > 2
        NSTimeInterval forwardDuration = count * self.defaultFrameDuration;
        if (self.loopMode == SSKAnimationLoopModePingPong && count > 2) {
            NSTimeInterval backwardDuration = (count - 2) * self.defaultFrameDuration;
            self.totalDuration = forwardDuration + backwardDuration;
        } else {
            self.totalDuration = forwardDuration;
        }
        return;
    }
    
    NSTimeInterval cumulative = 0;
    for (NSUInteger i = 0; i < count; i++) {
        NSTimeInterval frameDur = _frames[i].duration > 0 ? _frames[i].duration : self.defaultFrameDuration;
        cumulative += frameDur;
        _cumulativeTimes[i] = cumulative;
    }
    
    // Compute total duration based on loop mode
    // 
    // For PingPong mode, the cycle includes:
    //   - Forward phase: frames 0, 1, 2, ..., N-1 (all frames)
    //   - Backward phase: frames N-2, N-3, ..., 1 (endpoints not repeated)
    //   
    //   So for N=4 frames: 0, 1, 2, 3, 2, 1, 0, 1, 2, 3, ...
    //   Forward: frames 0,1,2,3 (duration = sum of all 4 frames)
    //   Backward: frames 2,1 (duration = sum of frames 1 and 2, excluding endpoints)
    //   Total = forward + backward
    //
    // Special case: N=2 frames
    //   PingPong with 2 frames: 0, 1, 0, 1, ... (same as Loop)
    //   Backward phase is empty (N-2..1 = 0..1 is empty range)
    //   So totalDuration = forward only (same as Loop)
    if (self.loopMode == SSKAnimationLoopModePingPong && count > 2) {
        // PingPong: forward (0..N-1) + backward (N-2..1)
        // Total = sum(all frames) + sum(frames 1..N-2)
        NSTimeInterval backwardSum = 0;
        for (NSUInteger i = 1; i < count - 1; i++) {
            NSTimeInterval frameDur = _frames[i].duration > 0 ? _frames[i].duration : self.defaultFrameDuration;
            backwardSum += frameDur;
        }
        self.totalDuration = cumulative + backwardSum;
    } else {
        // Loop or Once or PingPong with N<=2 (same as Loop)
        // For these modes, totalDuration is just the sum of all frame durations
        self.totalDuration = cumulative;
    }
}

- (NSTimeInterval)durationForFrame:(NSUInteger)index {
    if (index >= self.frameCount) return self.defaultFrameDuration;
    NSTimeInterval dur = _frames[index].duration;
    return dur > 0 ? dur : self.defaultFrameDuration;
}

#pragma mark - Frame Access

- (SSKAnimationFrame)frameAtIndex:(NSUInteger)index {
    if (index >= self.frameCount) {
        index = self.frameCount > 0 ? self.frameCount - 1 : 0;
    }
    if (self.frameCount == 0) {
        SSKAnimationFrame empty = {CGPointZero, CGSizeMake(1, 1), 0};
        return empty;
    }
    return _frames[index];
}

- (NSUInteger)frameIndexForTime:(NSTimeInterval)time finished:(BOOL *)outFinished {
    // Handle edge cases first
    NSUInteger count = self.frameCount;
    if (count == 0) {
        if (outFinished) *outFinished = YES;
        return 0;  // No frames, return 0 (invalid but safe)
    }
    
    if (count == 1) {
        // Single frame: always return frame 0
        // Finished only if Once mode (Loop/PingPong never finish)
        if (outFinished) *outFinished = (self.loopMode == SSKAnimationLoopModeOnce);
        return 0;
    }
    
    NSTimeInterval totalDur = self.totalDuration;
    if (totalDur <= 0) {
        // Zero or negative duration: invalid, return first frame
        if (outFinished) *outFinished = YES;
        return 0;
    }
    
    // ========================================================================
    // Handle loop mode time normalization
    // ========================================================================
    //
    // Different loop modes handle time differently:
    //   - Once: Clamp time to [0, totalDuration], stop at end
    //   - Loop: Wrap time modulo totalDuration (infinite loop)
    //   - PingPong: Wrap time modulo totalDuration (includes forward + backward)
    if (self.loopMode == SSKAnimationLoopModeOnce) {
        // Once mode: clamp time, don't wrap
        if (time < 0) time = 0;  // Clamp negative time to 0
        if (time >= totalDur) {
            // Past the end: return last frame and mark as finished
            if (outFinished) *outFinished = YES;
            return count - 1;  // Clamp to last frame
        }
        if (outFinished) *outFinished = NO;  // Still playing
    } else {
        // Loop/PingPong: wrap time into [0, totalDuration)
        // This creates the infinite loop behavior
        time = fmod(time, totalDur);
        if (time < 0) time += totalDur;  // Handle negative time (reverse playback)
        if (outFinished) *outFinished = NO;  // Never finished (infinite loop)
    }
    
    // ========================================================================
    // Determine frame index based on loop mode
    // ========================================================================
    //
    // For PingPong with more than 2 frames, we need to determine if we're in
    // the forward phase (0 to N-1) or backward phase (N-2 down to 1).
    //
    // For Loop or Once, all frames are in the forward phase.
    if (self.loopMode == SSKAnimationLoopModePingPong && count > 2) {
        // PingPong mode: check if we're in forward or backward phase
        //
        // Handle OOM case: if _cumulativeTimes is NULL, use totalDuration / 2
        // as an approximation for the forward phase duration (assumes symmetric timing)
        NSTimeInterval forwardDuration;
        if (_cumulativeTimes) {
            forwardDuration = _cumulativeTimes[count - 1];
        } else {
            // OOM fallback: approximate forward duration as half of total
            // (accurate only if forward and backward phases have equal duration)
            forwardDuration = self.totalDuration / 2.0;
        }
        
        if (time < forwardDuration) {
            // Forward phase: frames 0, 1, 2, ..., N-1
            return [self frameIndexInForwardPhase:time];
        } else {
            // Backward phase: frames N-2, N-3, ..., 1
            NSTimeInterval backwardTime = time - forwardDuration;
            return [self frameIndexInBackwardPhase:backwardTime];
        }
    }
    
    // Loop or Once: simple forward lookup (all frames in forward phase)
    return [self frameIndexInForwardPhase:time];
}

/**
 * Finds the frame index in the forward phase (0 to N-1).
 * 
 * This method is used for:
 *   - Loop mode: All frames are in forward phase
 *   - Once mode: All frames are in forward phase
 *   - PingPong mode: Forward phase only (when time < forwardDuration)
 * 
 * Algorithm:
 *   - Uses binary search on cumulative times array for O(log n) lookup
 *   - Finds the first frame whose cumulative time exceeds the given time
 *   - Binary search is efficient for both small (8-32) and large (100+) sequences
 * 
 * OOM Fallback:
 *   - If _cumulativeTimes is NULL (allocation failed in init), we fall back to
 *     equal-duration distribution using totalDuration / count
 *   - This is less accurate for variable-duration frames but prevents crashes
 * 
 * @param time Playback time in seconds (already normalized to [0, forwardDuration))
 * @return Frame index in range [0, frameCount-1]
 */
- (NSUInteger)frameIndexInForwardPhase:(NSTimeInterval)time {
    NSUInteger count = self.frameCount;
    if (count == 0) return 0;
    
    // Handle OOM case: _cumulativeTimes allocation failed
    // Fall back to equal-duration distribution (less accurate but safe)
    if (!_cumulativeTimes) {
        // Approximate: assume equal duration per frame
        NSTimeInterval frameDuration = self.totalDuration / count;
        if (frameDuration <= 0) return 0;
        NSUInteger index = (NSUInteger)(time / frameDuration);
        return MIN(index, count - 1);
    }
    
    // Binary search: find smallest i where _cumulativeTimes[i] > time
    // This is the first frame whose cumulative end time exceeds our playback time
    // 
    // Invariant: answer is in range [lo, hi]
    // Loop terminates with lo == hi == answer
    NSUInteger lo = 0;
    NSUInteger hi = count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (_cumulativeTimes[mid] <= time) {
            lo = mid + 1;  // Answer is to the right
        } else {
            hi = mid;      // Answer is at mid or to the left
        }
    }
    
    // lo is now the first frame where cumulative time > playback time
    // Clamp to valid range (handles edge case where time >= total duration)
    return lo < count ? lo : count - 1;
}

/**
 * Finds the frame index in the backward phase of ping-pong (N-2 down to 1).
 * 
 * This method is only used for PingPong mode with more than 2 frames.
 * 
 * Ping-pong backward phase:
 *   - Visits frames in reverse order: N-2, N-3, ..., 1
 *   - Does NOT visit frame 0 or frame N-1 (endpoints not repeated)
 *   - For N=4: backward phase visits frames 2, 1 (not 0 or 3)
 * 
 * Special case: N=2 frames
 *   - Backward phase is empty (N-2..1 = 0..1 is empty)
 *   - Ping-pong behaves like loop (0, 1, 0, 1, ...)
 *   - This method should not be called for N<=2
 * 
 * @param backwardTime Time within the backward phase (0 to backwardDuration)
 * @return Frame index in range [1, frameCount-2]
 */
- (NSUInteger)frameIndexInBackwardPhase:(NSTimeInterval)backwardTime {
    NSUInteger count = self.frameCount;
    if (count <= 2) return 0;  // Safety check: should not happen
    
    // Backward phase visits frames N-2, N-3, ..., 1
    // We iterate backwards from N-2 down to 1, accumulating durations
    // until we find which frame the backwardTime falls into
    NSTimeInterval cumulative = 0;
    for (NSInteger i = (NSInteger)count - 2; i >= 1; i--) {
        NSTimeInterval frameDur = [self durationForFrame:(NSUInteger)i];
        cumulative += frameDur;
        if (backwardTime < cumulative) {
            return (NSUInteger)i;
        }
    }
    return 1;  // Should not reach here, but return frame 1 as fallback
}

- (SSKAnimationFrame)frameForTime:(NSTimeInterval)time finished:(BOOL *)outFinished {
    NSUInteger index = [self frameIndexForTime:time finished:outFinished];
    return [self frameAtIndex:index];
}

@end
