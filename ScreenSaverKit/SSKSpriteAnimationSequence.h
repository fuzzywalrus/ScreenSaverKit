#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * SSKAnimationLoopMode - Loop behavior for animation sequences
 * 
 * Controls how an animation sequence repeats (or doesn't repeat) when it reaches
 * the end. This affects both the frameIndexForTime: method and the totalDuration
 * calculation.
 */
typedef NS_ENUM(NSInteger, SSKAnimationLoopMode) {
    /**
     * Play once, stop at last frame
     * 
     * The animation plays from frame 0 to the last frame, then stops. When finished,
     * frameIndexForTime: returns the last frame index and sets outFinished to YES.
     * 
     * totalDuration = sum of all frame durations
     */
    SSKAnimationLoopModeOnce,
    
    /**
     * Loop forever
     * 
     * The animation plays from frame 0 to the last frame, then immediately loops
     * back to frame 0 and continues. This repeats indefinitely.
     * 
     * totalDuration = sum of all frame durations (one cycle)
     */
    SSKAnimationLoopModeLoop,
    
    /**
     * Reverse at ends (ping-pong)
     * 
     * The animation plays forward (0, 1, 2, ..., N-1), then backward (N-2, ..., 1),
     * then forward again, repeating forever. Endpoints (0 and N-1) are not repeated
     * in the backward phase.
     * 
     * For N frames, the cycle is: 0, 1, 2, ..., N-1, N-2, ..., 1, 0, 1, ...
     * Cycle length = 2*N - 2 frames (for N > 1)
     * 
     * Special case: For N=2 frames, ping-pong behaves like loop (0, 1, 0, 1, ...)
     * 
     * totalDuration = sum(forward) + sum(backward) where backward = frames N-2 down to 1
     */
    SSKAnimationLoopModePingPong,
};

/**
 * SSKAnimationFrame - Represents a single frame in an animation sequence
 * 
 * This struct defines the texture coordinates and timing for one frame of animation.
 * It's used to build animation sequences from sprite sheets/atlases.
 * 
 * Uses CGPoint/CGSize for portability (works on both macOS and iOS if needed).
 */
typedef struct {
    /**
     * UV offset (normalized 0-1)
     * 
     * The top-left corner of this frame in the texture, in normalized UV coordinates.
     * (0, 0) = top-left of texture, (1, 1) = bottom-right of texture.
     */
    CGPoint textureOffset;
    
    /**
     * UV size (normalized 0-1)
     * 
     * The width and height of this frame in the texture, in normalized UV coordinates.
     * (1, 1) = entire texture, (0.25, 0.25) = 25% of texture width and height.
     */
    CGSize textureSize;
    
    /**
     * Frame duration in seconds (0 = use sequence default)
     * 
     * How long this frame should be displayed. If set to 0, the sequence's
     * defaultFrameDuration is used instead. This allows per-frame timing control
     * while still having a sensible default for most frames.
     */
    NSTimeInterval duration;
} SSKAnimationFrame;

/**
 * SSKSpriteAnimationSequence - Immutable animation sequence data
 * 
 * This class stores animation frame data for sprite sheet animations. It's immutable
 * after creation - you create it with a set of frames, loop mode, and timing, and
 * then query it for frame data based on playback time.
 * 
 * Typical Usage:
 *   1. Create sequence from sprite sheet (grid or custom rects)
 *   2. Assign to sprite.animation property
 *   3. Call sprite.advanceAnimationByTime: each frame
 *   4. Sprite automatically updates textureOffset/textureSize
 * 
 * Loop Modes:
 *   - Once: Plays once and stops
 *   - Loop: Repeats forever (0,1,2,...,N-1,0,1,2,...)
 *   - PingPong: Reverses at ends (0,1,2,...,N-1,N-2,...,1,0,1,2,...)
 * 
 * Frame Timing:
 *   - Each frame can have its own duration (frame.duration)
 *   - If frame.duration is 0, uses defaultFrameDuration
 *   - totalDuration is precomputed for efficient time wrapping
 * 
 * Thread Safety:
 *   - Immutable after creation, so safe to use from multiple threads for reading
 *   - However, typically used from a single thread (your rendering thread)
 * 
 * Example:
 *   // Create from 4x4 grid sprite sheet
 *   SSKSpriteAnimationSequence *walkAnim = [SSKSpriteAnimationSequence
 *       sequenceWithGridColumns:4 rows:4 frameCount:16
 *       duration:0.1 loopMode:SSKAnimationLoopModeLoop];
 *   
 *   sprite.animation = walkAnim;
 *   // In render loop:
 *   [sprite advanceAnimationByTime:deltaTime];
 */
@interface SSKSpriteAnimationSequence : NSObject

/// Number of frames in the sequence.
@property (nonatomic, readonly) NSUInteger frameCount;

/// Default duration per frame (used when frame.duration == 0).
@property (nonatomic, readonly) NSTimeInterval defaultFrameDuration;

/// Loop mode for the sequence.
@property (nonatomic, readonly) SSKAnimationLoopMode loopMode;

/// Total duration of one complete cycle.
/// For Loop: sum of all frame durations.
/// For PingPong: sum of forward + backward (endpoints not repeated).
@property (nonatomic, readonly) NSTimeInterval totalDuration;

#pragma mark - Factory Methods

/// Creates a sequence with explicit frames. Frames array is copied.
/// @param frames Array of SSKAnimationFrame structs
/// @param count Number of frames (must be > 0)
/// @param duration Default frame duration (used when frame.duration == 0)
/// @param loopMode Loop behavior
/// @return New sequence, or nil if count == 0
+ (nullable instancetype)sequenceWithFrames:(const SSKAnimationFrame *)frames
                                      count:(NSUInteger)count
                            defaultDuration:(NSTimeInterval)duration
                                   loopMode:(SSKAnimationLoopMode)loopMode;

/**
 * Creates a sequence from a grid-based sprite sheet.
 * 
 * This is the most common way to create animations from sprite sheets. It assumes
 * your sprite sheet is laid out as a uniform grid where each cell is the same size.
 * 
 * Frame reading order:
 *   - Frames are read left-to-right, top-to-bottom
 *   - Frame 0 = top-left cell
 *   - Frame 1 = second cell in top row
 *   - Frame (cols-1) = last cell in top row
 *   - Frame cols = first cell in second row
 *   - And so on...
 * 
 * Grid layout example (4 columns, 3 rows):
 *   [ 0] [ 1] [ 2] [ 3]
 *   [ 4] [ 5] [ 6] [ 7]
 *   [ 8] [ 9] [10] [11]
 * 
 * If frameCount is less than cols*rows, only the first frameCount frames are used.
 * This is useful if your sprite sheet has empty cells or you want a shorter animation.
 * 
 * @param cols Number of columns in the grid (must be > 0)
 * @param rows Number of rows in the grid (must be > 0)
 * @param count Total number of frames to use (must be > 0 and <= cols*rows)
 * @param duration Duration per frame in seconds (all frames use this duration)
 * @param loopMode Loop behavior (Once, Loop, or PingPong)
 * @return New sequence, or nil if count == 0 or count > cols*rows or cols/rows == 0
 * 
 * Example:
 *   // 4x4 grid sprite sheet, use all 16 frames, 0.1 seconds per frame, loop forever
 *   SSKSpriteAnimationSequence *anim = [SSKSpriteAnimationSequence
 *       sequenceWithGridColumns:4 rows:4 frameCount:16
 *       duration:0.1 loopMode:SSKAnimationLoopModeLoop];
 * 
 * Example (partial grid):
 *   // 8x8 grid but only use first 32 frames (first 4 rows)
 *   SSKSpriteAnimationSequence *anim = [SSKSpriteAnimationSequence
 *       sequenceWithGridColumns:8 rows:8 frameCount:32
 *       duration:0.1 loopMode:SSKAnimationLoopModeLoop];
 */
+ (nullable instancetype)sequenceWithGridColumns:(NSUInteger)cols
                                            rows:(NSUInteger)rows
                                      frameCount:(NSUInteger)count
                                        duration:(NSTimeInterval)duration
                                        loopMode:(SSKAnimationLoopMode)loopMode;

/// Creates a sequence from non-uniform atlas rects (pixel coordinates).
/// For atlases that are not uniform grids.
/// @param rects Array of frame rects in texture pixel coordinates
/// @param count Number of frames (must be > 0)
/// @param textureSize Full texture size in pixels (for normalization)
/// @param durations Array of per-frame durations (can be NULL for uniform timing)
/// @param defaultDuration Default duration when durations is NULL or duration[i] == 0
/// @param loopMode Loop behavior
/// @return New sequence, or nil if count == 0
+ (nullable instancetype)sequenceWithTextureRectsInPixels:(const CGRect *)rects
                                                    count:(NSUInteger)count
                                              textureSize:(CGSize)textureSize
                                                durations:(nullable const NSTimeInterval *)durations
                                          defaultDuration:(NSTimeInterval)defaultDuration
                                                 loopMode:(SSKAnimationLoopMode)loopMode;

#pragma mark - Frame Access

/// Returns the frame at the given index (clamped to valid range).
/// @param index Frame index
/// @return Frame data
- (SSKAnimationFrame)frameAtIndex:(NSUInteger)index;

/**
 * Returns the frame index for a given time, accounting for loop mode.
 * 
 * This is the core method for animation playback. Given a playback time, it returns
 * which frame should be displayed. The time is automatically wrapped based on the
 * loop mode:
 * 
 *   - Once: Clamps to [0, totalDuration], returns last frame when finished
 *   - Loop: Wraps at totalDuration (time % totalDuration)
 *   - PingPong: Wraps at totalDuration, maps to forward or backward phase
 * 
 * Negative time is supported (for reverse playback):
 *   - Wraps correctly for Loop and PingPong modes
 *   - Clamps to 0 for Once mode
 * 
 * The outFinished parameter is set to YES when:
 *   - LoopModeOnce animation has finished (time >= totalDuration)
 * 
 * This method is called automatically by SSKSprite.advanceAnimationByTime:, but
 * you can call it directly if you need frame index lookup without updating the sprite.
 * 
 * @param time Playback time in seconds (can be negative for reverse)
 * @param outFinished If non-NULL, set to YES when LoopModeOnce completes
 * @return Frame index to display (always in valid range [0, frameCount-1])
 * 
 * Example:
 *   NSTimeInterval t = 0.5;  // 0.5 seconds into animation
 *   BOOL finished = NO;
 *   NSUInteger frameIdx = [anim frameIndexForTime:t finished:&finished];
 *   // frameIdx = which frame to show at time 0.5
 *   // finished = YES if Once mode and animation is done
 */
- (NSUInteger)frameIndexForTime:(NSTimeInterval)time
                       finished:(nullable BOOL *)outFinished;

/// Returns the frame for a given time, accounting for loop mode.
/// @param time Playback time in seconds
/// @param outFinished If non-NULL, set to YES when LoopModeOnce completes
/// @return Frame data to display
- (SSKAnimationFrame)frameForTime:(NSTimeInterval)time
                         finished:(nullable BOOL *)outFinished;

@end

NS_ASSUME_NONNULL_END
