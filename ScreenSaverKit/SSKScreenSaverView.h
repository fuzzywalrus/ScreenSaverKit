#import <ScreenSaver/ScreenSaver.h>
#import "SSKAssetManager.h"
#import "SSKAnimationClock.h"
#import "SSKEntityPool.h"

NS_ASSUME_NONNULL_BEGIN

/**
 ScreenSaverKit base view that folds common macOS ScreenSaver boilerplate into a
 single subclass. It registers defaults, polls for preference changes, exposes
 helper utilities, and handles host lifecycle differences (preview, wallpaper,
 ScreenSaverEngine).

 ## Lifecycle highlights
 - Preferences are registered from `-defaultPreferences` during init.
 - `-preferencesDidChange:changedKeys:` is called immediately after init with
   all keys (initial `changedKeys` contains every registered key) and thereafter
   only when a value actually differs. Preferences are polled every 0.5s on the
   main run loop, so no custom observers are required.
 - Animation helpers (`advanceAnimationClock`, `deltaTime`) are paused/resumed
   automatically when the saver starts and stops animating.
 - Entity pools created via `makeEntityPoolWithCapacity:factory:` are owned by
   the saver and drained when the view is deallocated.

 The class assumes you interact with it on the main thread, matching AppKit’s
 drawing model. Preference helpers, timers, and utilities are not thread-safe.

 ### Usage example
 ```
 @interface MySaverView : SSKScreenSaverView
 @property (nonatomic) CGFloat speed;
 @end

 @implementation MySaverView
 - (NSDictionary *)defaultPreferences { return @{ @"speed" : @(1.0) }; }

 - (void)preferencesDidChange:(NSDictionary *)prefs changedKeys:(NSSet<NSString *> *)keys {
     self.speed = [prefs[@"speed"] doubleValue];
 }

 - (void)animateOneFrame {
     NSTimeInterval dt = [self advanceAnimationClock];
     // Update your world using dt for frame independent animation.
     [self setNeedsDisplay:YES];
 }
 @end
 ```
 */
@interface SSKScreenSaverView : ScreenSaverView

/// Shared asset loader for bundle resources (images/data with extension fallbacks and caching).
@property (nonatomic, strong, readonly) SSKAssetManager *assetManager;

/// Animation clock that tracks delta time and smoothed FPS. Call
/// `advanceAnimationClock` once per frame to update it.
@property (nonatomic, strong, readonly) SSKAnimationClock *animationClock;

/// Returns the identifier used to read/write ScreenSaverDefaults.
/// Defaults to the bundle identifier for the module bundle.
+ (NSString *)preferencesDomain;

/// Register default key/value pairs here. Called once during init before any reads.
- (NSDictionary<NSString *, id> *)defaultPreferences;

/// Called whenever persisted preferences change (including initial load).
/// `changedKeys` contains the keys whose values differ from the previous call.
/// - First invocation happens immediately after init and includes all registered keys.
/// - Subsequent invocations only list keys whose value actually changed.
/// - Subclasses do not need to call `super`.
- (void)preferencesDidChange:(NSDictionary<NSString *, id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys;

/// Returns the current ScreenSaverDefaults for this module.
/// Caller is responsible for any subsequent `synchronize` calls after modifying values.
- (ScreenSaverDefaults *)preferences;

/// Convenience for reading current preference values as an immutable dictionary.
/// Includes defaults for keys that have not yet been persisted.
- (NSDictionary<NSString *, id> *)currentPreferences;

/// Persist a value to ScreenSaverDefaults and synchronise immediately. Values are written on the
/// main thread and become visible to other processes via the polling cycle.
- (void)setPreferenceValue:(nullable id)value forKey:(NSString *)key;

/// Removes the stored value for a key and synchronises immediately.
- (void)removePreferenceForKey:(NSString *)key;

/// Resets preferences to the registered defaults and immediately invokes
/// `preferencesDidChange:changedKeys:` with all keys.
- (void)resetPreferencesToDefaults;

/// Advances the internal animation clock and returns the elapsed seconds since the previous call.
/// Call exactly once inside `-animateOneFrame` to keep animations frame-rate independent.
- (NSTimeInterval)advanceAnimationClock;

/// Returns the most recent delta time without advancing the clock. Handy when multiple systems need
/// the current frame’s delta without double stepping.
- (NSTimeInterval)deltaTime;

/// Convenience factory for entity/object pools tied to the saver lifecycle. The returned pool reuses
/// objects created by `factory` and is automatically drained when the saver view is deallocated.
/// Example: `self.spritePool = [self makeEntityPoolWithCapacity:64 factory:^{ return [Sprite new]; }];`
- (SSKEntityPool *)makeEntityPoolWithCapacity:(NSUInteger)capacity
                                      factory:(SSKEntityFactoryBlock)factory;

@end

NS_ASSUME_NONNULL_END
