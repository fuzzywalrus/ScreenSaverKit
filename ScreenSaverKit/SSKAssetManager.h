#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight bundle asset loader with optional in-memory caching and
/// fallback extension handling for images and arbitrary data resources.
@interface SSKAssetManager : NSObject

- (instancetype)initWithBundle:(NSBundle *)bundle;

/// Bundle used for lookup. Defaults to the module bundle when created from
/// within a saver.
@property (nonatomic, strong, readonly) NSBundle *bundle;

/// When enabled (default YES) successfully resolved assets are cached in
/// memory to avoid repeated disk IO.
@property (nonatomic, getter=isCachingEnabled) BOOL cachingEnabled;

/// Clears any cached assets.
- (void)clearCache;

/// Convenience image lookup that tries common image extensions in priority
/// order (`png`, `jpg`, `jpeg`, `gif`, `tiff`).
- (nullable NSImage *)imageNamed:(NSString *)name;

/// Image lookup that tries the provided extensions in order until a hit is
/// found. Extensions should not include the leading dot.
- (nullable NSImage *)imageNamed:(NSString *)name
               fallbackExtensions:(NSArray<NSString *> *)extensions;

/// Fetches data for a resource, trying the provided extensions in order.
- (nullable NSData *)dataNamed:(NSString *)name
            fallbackExtensions:(NSArray<NSString *> *)extensions;

/// Returns the resolved file URL for the resource if one exists.
- (nullable NSURL *)urlForResource:(NSString *)name
               fallbackExtensions:(NSArray<NSString *> *)extensions;

/// Default list of image extensions used by `imageNamed:`.
+ (NSArray<NSString *> *)defaultImageExtensions;

@end

NS_ASSUME_NONNULL_END
