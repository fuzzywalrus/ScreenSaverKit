#import "SSKAnimationClock.h"

static const NSTimeInterval kSSKMaxDelta = 1.0 / 10.0;   // floor around 10fps to avoid huge jumps
static const double kSSKSmoothingFactor = 0.15;          // exponential moving average

@interface SSKAnimationClock ()
@property (nonatomic) NSTimeInterval minimumDelta;
@property (nonatomic) NSTimeInterval lastTimestamp;
@property (nonatomic, readwrite) NSTimeInterval deltaTime;
@property (nonatomic) double smoothedDelta;
@property (nonatomic, readwrite) double framesPerSecond;
@end

@implementation SSKAnimationClock

- (instancetype)init {
    if ((self = [super init])) {
        _maximumFramesPerSecond = 240.0;
        _minimumDelta = 1.0 / _maximumFramesPerSecond;
        _lastTimestamp = 0;
        _deltaTime = 1.0 / 60.0;
        _smoothedDelta = _deltaTime;
        _framesPerSecond = 60.0;
    }
    return self;
}

- (void)resetWithTimestamp:(NSTimeInterval)timestamp {
    self.lastTimestamp = timestamp;
    self.deltaTime = 1.0 / 60.0;
    self.smoothedDelta = self.deltaTime;
    self.framesPerSecond = 60.0;
}

- (void)setMaximumFramesPerSecond:(double)maximumFramesPerSecond {
    if (maximumFramesPerSecond < 1.0) {
        maximumFramesPerSecond = 1.0;
    }
    _maximumFramesPerSecond = maximumFramesPerSecond;
    self.minimumDelta = 1.0 / maximumFramesPerSecond;
}

- (NSTimeInterval)stepWithTimestamp:(NSTimeInterval)timestamp {
    if (self.isPaused) {
        self.lastTimestamp = timestamp;
        self.deltaTime = 0;
        return 0;
    }
    
    if (self.lastTimestamp <= 0) {
        [self resetWithTimestamp:timestamp];
        return self.deltaTime;
    }
    
    NSTimeInterval raw = timestamp - self.lastTimestamp;
    self.lastTimestamp = timestamp;
    
    NSTimeInterval clamped = MAX(self.minimumDelta, MIN(raw, kSSKMaxDelta));
    self.deltaTime = clamped;
    
    // Exponential smoothing for FPS readout
    self.smoothedDelta = kSSKSmoothingFactor * clamped + (1.0 - kSSKSmoothingFactor) * self.smoothedDelta;
    if (self.smoothedDelta > 0) {
        self.framesPerSecond = 1.0 / self.smoothedDelta;
    }
    
    return clamped;
}

- (void)pause {
    self.paused = YES;
}

- (void)resumeWithTimestamp:(NSTimeInterval)timestamp {
    self.paused = NO;
    self.lastTimestamp = timestamp;
}

@end
