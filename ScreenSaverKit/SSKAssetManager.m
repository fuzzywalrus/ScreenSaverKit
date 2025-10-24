#import "SSKAssetManager.h"

static NSArray<NSString *> *SSKDefaultImageExtensions(void) {
    static NSArray<NSString *> *exts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exts = @[@"png", @"jpg", @"jpeg", @"gif", @"tiff"];
    });
    return exts;
}

@interface SSKAssetManager ()
@property (nonatomic, strong) NSCache<NSString *, id> *cache;
@property (nonatomic, strong, readwrite) NSBundle *bundle;
@end

@implementation SSKAssetManager

- (instancetype)initWithBundle:(NSBundle *)bundle {
    NSParameterAssert(bundle);
    if ((self = [super init])) {
        _bundle = bundle;
        _cache = [NSCache new];
        _cachingEnabled = YES;
    }
    return self;
}

- (void)setCachingEnabled:(BOOL)cachingEnabled {
    _cachingEnabled = cachingEnabled;
    if (!cachingEnabled) {
        [self.cache removeAllObjects];
    }
}

- (void)clearCache {
    [self.cache removeAllObjects];
}

- (NSImage *)imageNamed:(NSString *)name {
    return [self imageNamed:name fallbackExtensions:SSKDefaultImageExtensions()];
}

- (NSImage *)imageNamed:(NSString *)name fallbackExtensions:(NSArray<NSString *> *)extensions {
    if (name.length == 0) { return nil; }
    NSString *cacheKey = [NSString stringWithFormat:@"img:%@", name];
    NSImage *cached = self.isCachingEnabled ? [self.cache objectForKey:cacheKey] : nil;
    if (cached) { return cached; }
    
    NSURL *url = [self urlForResource:name fallbackExtensions:extensions];
    if (!url) { return nil; }
    
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
    if (image && self.isCachingEnabled) {
        [self.cache setObject:image forKey:cacheKey];
    }
    return image;
}

- (NSData *)dataNamed:(NSString *)name fallbackExtensions:(NSArray<NSString *> *)extensions {
    if (name.length == 0) { return nil; }
    NSString *cacheKey = [NSString stringWithFormat:@"data:%@", name];
    NSData *cached = self.isCachingEnabled ? [self.cache objectForKey:cacheKey] : nil;
    if (cached) { return cached; }
    
    NSURL *url = [self urlForResource:name fallbackExtensions:extensions];
    if (!url) { return nil; }
    
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
    if (data && self.isCachingEnabled) {
        [self.cache setObject:data forKey:cacheKey];
    }
    return data;
}

- (NSURL *)urlForResource:(NSString *)name fallbackExtensions:(NSArray<NSString *> *)extensions {
    if (name.length == 0) { return nil; }
    
    NSString *base = name;
    NSString *providedExtension = nil;
    NSString *lastComponent = name.lastPathComponent;
    NSRange dotRange = [lastComponent rangeOfString:@"." options:NSBackwardsSearch];
    if (dotRange.location != NSNotFound) {
        providedExtension = [lastComponent substringFromIndex:dotRange.location + 1];
        base = [name stringByDeletingPathExtension];
    }
    
    NSArray<NSString *> *searchExtensions = providedExtension ?
        @[providedExtension] :
        (extensions.count ? extensions : @[@""]);
    
    for (NSString *ext in searchExtensions) {
        NSURL *url = [self.bundle URLForResource:base withExtension:ext];
        if (url) { return url; }
    }
    return nil;
}

+ (NSArray<NSString *> *)defaultImageExtensions {
    return SSKDefaultImageExtensions();
}

@end
