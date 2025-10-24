#import "SSKScreenSaverView.h"

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>

static const NSTimeInterval kSSKPreferencePollInterval = 0.5;

@interface SSKScreenSaverView ()
@property (nonatomic, strong) NSTimer *ssk_preferenceWatchTimer;
@property (nonatomic, copy) NSDictionary<NSString *, id> *ssk_lastKnownPreferences;
@property (nonatomic, strong) SSKAssetManager *ssk_assetManager;
@property (nonatomic, strong) SSKAnimationClock *ssk_animationClock;
@property (nonatomic, strong) NSMutableArray<SSKEntityPool *> *ssk_ownedPools;
@end

@implementation SSKScreenSaverView

+ (NSString *)preferencesDomain {
    static NSString *resolvedDomain = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle bundleForClass:self];
        NSString *bundleIdentifier = bundle.bundleIdentifier;
        NSString *bundleName = [bundle objectForInfoDictionaryKey:(__bridge NSString *)kCFBundleNameKey];
        NSString *className = NSStringFromClass(self);

        NSString *preferred = bundleIdentifier.length ? bundleIdentifier : (bundleName.length ? bundleName : className);
        NSMutableArray<NSString *> *legacyDomains = [NSMutableArray array];
        if (bundleName.length && ![bundleName isEqualToString:preferred]) {
            [legacyDomains addObject:bundleName];
        }
        if (className.length && ![className isEqualToString:preferred]) {
            [legacyDomains addObject:className];
        }

        [self ssk_migrateLegacyPreferencesIfNeededFromDomains:legacyDomains toDomain:preferred];
        resolvedDomain = preferred;
    });
    return resolvedDomain;
}

/**
 Attempts to migrate stored preferences from previous domain names (e.g. legacy
 bundle identifiers) into the current canonical domain. Migration only occurs
 when the target domain has no stored values yet.
 */
+ (void)ssk_migrateLegacyPreferencesIfNeededFromDomains:(NSArray<NSString *> *)legacyDomains
                                              toDomain:(NSString *)targetDomain {
    if (targetDomain.length == 0) { return; }

    ScreenSaverDefaults *targetDefaults = [ScreenSaverDefaults defaultsForModuleWithName:targetDomain];
    [targetDefaults synchronize];
    if (targetDefaults.dictionaryRepresentation.count > 0) {
        // Target already has stored values; no migration necessary.
        return;
    }

    for (NSString *legacyDomain in legacyDomains) {
        if (legacyDomain.length == 0) { continue; }
        ScreenSaverDefaults *legacyDefaults = [ScreenSaverDefaults defaultsForModuleWithName:legacyDomain];
        [legacyDefaults synchronize];
        NSDictionary<NSString *, id> *legacyValues = legacyDefaults.dictionaryRepresentation;
        if (legacyValues.count == 0) { continue; }

        [legacyValues enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
            (void)stop;
            if (!key.length || !obj) { return; }
            [targetDefaults setObject:obj forKey:key];
        }];
        [targetDefaults synchronize];
        break;
    }
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    if ((self = [super initWithFrame:frame isPreview:isPreview])) {
        _ssk_assetManager = [[SSKAssetManager alloc] initWithBundle:[NSBundle bundleForClass:self.class]];
        _ssk_animationClock = [SSKAnimationClock new];
        _ssk_ownedPools = [NSMutableArray array];
        [self ssk_registerDefaultsIfNeeded];
        NSDictionary *prefs = [self currentPreferences];
        self.ssk_lastKnownPreferences = prefs;
        if (prefs.count > 0) {
            [self preferencesDidChange:prefs changedKeys:[NSSet setWithArray:prefs.allKeys]];
        }
    }
    return self;
}

- (void)dealloc {
    [self ssk_stopPreferenceMonitoring];
    [self.ssk_ownedPools makeObjectsPerformSelector:@selector(drain)];
}

- (void)startAnimation {
    [super startAnimation];
    [self.animationClock resetWithTimestamp:[NSDate timeIntervalSinceReferenceDate]];
    self.animationClock.paused = NO;
    [self ssk_startPreferenceMonitoring];
}

- (void)stopAnimation {
    [self ssk_stopPreferenceMonitoring];
    [self.animationClock pause];
    [super stopAnimation];
}

- (void)ssk_registerDefaultsIfNeeded {
    NSDictionary *defaults = [self defaultPreferences];
    if (defaults.count == 0) {
        return;
    }
    ScreenSaverDefaults *prefs = [self preferences];
    [prefs registerDefaults:defaults];
    [prefs synchronize];
}

- (void)ssk_startPreferenceMonitoring {
    [self.ssk_preferenceWatchTimer invalidate];
    self.ssk_preferenceWatchTimer = [NSTimer timerWithTimeInterval:kSSKPreferencePollInterval
                                                            target:self
                                                          selector:@selector(ssk_checkPreferenceChanges:)
                                                          userInfo:nil
                                                           repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.ssk_preferenceWatchTimer forMode:NSRunLoopCommonModes];
}

- (void)ssk_stopPreferenceMonitoring {
    [self.ssk_preferenceWatchTimer invalidate];
    self.ssk_preferenceWatchTimer = nil;
}

- (void)ssk_checkPreferenceChanges:(NSTimer *)timer {
    NSDictionary *current = [self currentPreferences];
    if (!self.ssk_lastKnownPreferences) {
        self.ssk_lastKnownPreferences = current;
        [self preferencesDidChange:current changedKeys:[NSSet setWithArray:current.allKeys]];
        return;
    }
    
    if ([current isEqualToDictionary:self.ssk_lastKnownPreferences]) {
        return;
    }
    
    NSMutableSet *changed = [NSMutableSet set];
    [current enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        (void)stop;
        id previous = self.ssk_lastKnownPreferences[key];
        if ((obj && ![obj isEqual:previous]) || (previous && ![previous isEqual:obj])) {
            [changed addObject:key];
        }
    }];
    
    // Include keys that were removed.
    [self.ssk_lastKnownPreferences enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        (void)obj;
        (void)stop;
        if (!current[key]) {
            [changed addObject:key];
        }
    }];
    
    self.ssk_lastKnownPreferences = current;
    [self preferencesDidChange:current changedKeys:changed];
}

- (ScreenSaverDefaults *)preferences {
    return [ScreenSaverDefaults defaultsForModuleWithName:self.class.preferencesDomain];
}

- (NSDictionary<NSString *,id> *)defaultPreferences {
    return @{};
}

- (NSDictionary<NSString *,id> *)currentPreferences {
    ScreenSaverDefaults *prefs = [self preferences];
    [prefs synchronize];
    NSMutableDictionary *snapshot = [[self defaultPreferences] mutableCopy] ?: [NSMutableDictionary dictionary];
    
    NSDictionary *stored = prefs.dictionaryRepresentation;
    [stored enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (value) {
            snapshot[key] = value;
        } else {
            [snapshot removeObjectForKey:key];
        }
    }];
    
    return snapshot;
}

- (void)preferencesDidChange:(NSDictionary<NSString *,id> *)preferences
                 changedKeys:(NSSet<NSString *> *)changedKeys {
    // Subclasses can override to react to preference mutations.
}

- (void)setPreferenceValue:(id)value forKey:(NSString *)key {
    if (!key.length) { return; }
    ScreenSaverDefaults *prefs = [self preferences];
    if (value) {
        [prefs setObject:value forKey:key];
    } else {
        [prefs removeObjectForKey:key];
    }
    [prefs synchronize];
}

- (void)removePreferenceForKey:(NSString *)key {
    if (!key.length) { return; }
    ScreenSaverDefaults *prefs = [self preferences];
    [prefs removeObjectForKey:key];
    [prefs synchronize];
}

- (void)resetPreferencesToDefaults {
    ScreenSaverDefaults *prefs = [self preferences];
    NSString *domain = self.class.preferencesDomain;
    if (domain.length) {
        [prefs removePersistentDomainForName:domain];
    }
    [self ssk_registerDefaultsIfNeeded];
    NSDictionary *current = [self currentPreferences];
    self.ssk_lastKnownPreferences = current;
    [self preferencesDidChange:current changedKeys:[NSSet setWithArray:current.allKeys]];
}

- (SSKAssetManager *)assetManager {
    return self.ssk_assetManager;
}

- (SSKAnimationClock *)animationClock {
    return self.ssk_animationClock;
}

- (NSTimeInterval)advanceAnimationClock {
    return [self.animationClock stepWithTimestamp:[NSDate timeIntervalSinceReferenceDate]];
}

- (NSTimeInterval)deltaTime {
    return self.animationClock.deltaTime;
}

- (SSKEntityPool *)makeEntityPoolWithCapacity:(NSUInteger)capacity factory:(SSKEntityFactoryBlock)factory {
    SSKEntityPool *pool = [[SSKEntityPool alloc] initWithCapacity:capacity factory:factory];
    [self.ssk_ownedPools addObject:pool];
    return pool;
}

@end
