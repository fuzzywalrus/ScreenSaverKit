#import "SSKPaletteManager.h"

@interface SSKPaletteManager ()
@property (nonatomic, strong) NSMapTable<NSString *, NSMutableArray<SSKColorPalette *> *> *modulePalettes;
@property (nonatomic, strong) dispatch_queue_t isolationQueue;
@end

@implementation SSKPaletteManager

+ (instancetype)sharedManager {
    static SSKPaletteManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[SSKPaletteManager alloc] initPrivate];
    });
    return manager;
}

- (instancetype)initPrivate {
    if ((self = [super init])) {
        _modulePalettes = [NSMapTable strongToStrongObjectsMapTable];
        _isolationQueue = dispatch_queue_create("com.screensaverkit.paletteManager", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (instancetype)init {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"Use +[SSKPaletteManager sharedManager]"
                                 userInfo:nil];
}

- (void)registerPalettes:(NSArray<SSKColorPalette *> *)palettes
              forModule:(NSString *)moduleIdentifier {
    if (moduleIdentifier.length == 0 || palettes.count == 0) { return; }
    dispatch_barrier_async(self.isolationQueue, ^{
        NSMutableArray<SSKColorPalette *> *existing = [self.modulePalettes objectForKey:moduleIdentifier];
        if (!existing) {
            existing = [NSMutableArray array];
            [self.modulePalettes setObject:existing forKey:moduleIdentifier];
        }
        // Replace existing palettes with matching identifiers, append new ones.
        NSMutableDictionary<NSString *, NSNumber *> *lookup = [NSMutableDictionary dictionary];
        [existing enumerateObjectsUsingBlock:^(SSKColorPalette *palette, NSUInteger idx, BOOL *stop) {
            (void)stop;
            lookup[palette.identifier] = @(idx);
        }];
        for (SSKColorPalette *palette in palettes) {
            NSNumber *existingIndex = lookup[palette.identifier];
            if (existingIndex) {
                existing[existingIndex.unsignedIntegerValue] = palette;
            } else {
                [existing addObject:palette];
            }
        }
    });
}

- (NSArray<SSKColorPalette *> *)palettesForModule:(NSString *)moduleIdentifier {
    if (moduleIdentifier.length == 0) { return @[]; }
    __block NSArray<SSKColorPalette *> *result = nil;
    dispatch_sync(self.isolationQueue, ^{
        result = [[self.modulePalettes objectForKey:moduleIdentifier] copy] ?: @[];
    });
    return result;
}

- (SSKColorPalette *)paletteWithIdentifier:(NSString *)identifier
                                    module:(NSString *)moduleIdentifier {
    if (moduleIdentifier.length == 0 || identifier.length == 0) { return nil; }
    __block SSKColorPalette *found = nil;
    dispatch_sync(self.isolationQueue, ^{
        NSArray<SSKColorPalette *> *palettes = [self.modulePalettes objectForKey:moduleIdentifier];
        for (SSKColorPalette *palette in palettes) {
            if ([palette.identifier isEqualToString:identifier]) {
                found = palette;
                break;
            }
        }
    });
    return found;
}

- (NSColor *)colorForPalette:(SSKColorPalette *)palette
                    progress:(CGFloat)progress
            interpolationMode:(SSKPaletteInterpolationMode)mode {
    NSArray<NSColor *> *colors = palette.colors;
    if (colors.count == 0) {
        return [NSColor whiteColor];
    }
    if (colors.count == 1) {
        return colors.firstObject;
    }
    CGFloat wrappedProgress = progress;
    if (mode == SSKPaletteInterpolationModeLoop) {
        wrappedProgress = progress - floor(progress);
    } else {
        wrappedProgress = fmax(0.0, fmin(1.0, progress));
    }
    CGFloat scaled = wrappedProgress * (CGFloat)colors.count;
    NSInteger index = (NSInteger)floor(scaled);
    CGFloat fraction = scaled - (CGFloat)index;
    NSColor *first = colors[(NSUInteger)(index % colors.count)];
    NSColor *second = colors[(NSUInteger)((index + 1) % colors.count)];
    return [first blendedColorWithFraction:fraction ofColor:second];
}

@end
