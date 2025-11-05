#import "SSKMetalTextureCache.h"

#import <TargetConditionals.h>

static inline NSNumber *SSKTextureCacheKey(NSUInteger width,
                                           NSUInteger height,
                                           MTLPixelFormat format,
                                           MTLTextureUsage usage) {
    uint64_t key = ((uint64_t)width << 32) ^
                   ((uint64_t)height << 16) ^
                   ((uint64_t)format << 8) ^
                   (uint64_t)usage;
    return @(key);
}

@interface SSKMetalTextureCache ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSHashTable<id<MTLTexture>> *> *textureBuckets;
@property (nonatomic, strong) NSMutableArray<id<MTLTexture>> *allTexturesInInsertionOrder;
@end

@implementation SSKMetalTextureCache

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    NSParameterAssert(device);
    if ((self = [super init])) {
        _device = device;
        _textureBuckets = [NSMutableDictionary dictionary];
        _allTexturesInInsertionOrder = [NSMutableArray array];
    }
    return self;
}

- (id<MTLTexture>)acquireTextureWithSize:(CGSize)size
                             pixelFormat:(MTLPixelFormat)pixelFormat
                                   usage:(MTLTextureUsage)usage {
    if (!self.device || size.width <= 0.0 || size.height <= 0.0) {
        return nil;
    }

    NSUInteger width = (NSUInteger)ceil(size.width);
    NSUInteger height = (NSUInteger)ceil(size.height);
    width = MAX(width, 1);
    height = MAX(height, 1);

    NSNumber *key = SSKTextureCacheKey(width, height, pixelFormat, usage);
    NSHashTable<id<MTLTexture>> *bucket = self.textureBuckets[key];
    id<MTLTexture> texture = bucket.anyObject;
    if (texture) {
        [bucket removeObject:texture];
        if (bucket.count == 0) {
            [self.textureBuckets removeObjectForKey:key];
        }
        [self.allTexturesInInsertionOrder removeObjectIdenticalTo:texture];
        return texture;
    }

    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    descriptor.usage = usage;
#if TARGET_OS_OSX
    descriptor.storageMode = MTLStorageModePrivate;
#endif
    descriptor.resourceOptions = MTLResourceStorageModePrivate;
    return [self.device newTextureWithDescriptor:descriptor];
}

- (id<MTLTexture>)acquireTextureMatchingTexture:(id<MTLTexture>)texture
                                                  usage:(MTLTextureUsage)usage {
    if (!texture) { return nil; }
    CGSize size = CGSizeMake(texture.width, texture.height);
    return [self acquireTextureWithSize:size pixelFormat:texture.pixelFormat usage:usage];
}

- (void)releaseTexture:(id<MTLTexture>)texture {
    if (!texture) { return; }
    NSUInteger width = texture.width;
    NSUInteger height = texture.height;
    if (width == 0 || height == 0) { return; }

    NSNumber *key = SSKTextureCacheKey(width, height, texture.pixelFormat, texture.usage);
    NSHashTable<id<MTLTexture>> *bucket = self.textureBuckets[key];
    if (!bucket) {
        bucket = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        self.textureBuckets[key] = bucket;
    }
    [bucket addObject:texture];
    [self.allTexturesInInsertionOrder addObject:texture];
}

- (void)clearCache {
    [self.textureBuckets removeAllObjects];
    [self.allTexturesInInsertionOrder removeAllObjects];
}

- (void)trimToSize:(NSUInteger)maxCount {
    if (maxCount == 0) {
        [self clearCache];
        return;
    }

    while (self.allTexturesInInsertionOrder.count > maxCount) {
        id<MTLTexture> texture = self.allTexturesInInsertionOrder.firstObject;
        [self.allTexturesInInsertionOrder removeObjectAtIndex:0];
        if (!texture) { continue; }

        NSNumber *key = SSKTextureCacheKey(texture.width, texture.height, texture.pixelFormat, texture.usage);
        NSHashTable<id<MTLTexture>> *bucket = self.textureBuckets[key];
        [bucket removeObject:texture];
        if (bucket.count == 0) {
            [self.textureBuckets removeObjectForKey:key];
        }
    }
}

@end
