#import "SSKMetalTextureCache.h"

#import <TargetConditionals.h>

@interface SSKMetalTextureCache ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<id<MTLTexture>> *> *textureBuckets;
@property (nonatomic, strong) NSMutableArray<id<MTLTexture>> *allTexturesInInsertionOrder;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation SSKMetalTextureCache

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    NSParameterAssert(device);
    if ((self = [super init])) {
        _device = device;
        _textureBuckets = [NSMutableDictionary dictionary];
        _allTexturesInInsertionOrder = [NSMutableArray array];
        _lock = [NSLock new];
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

    NSString *key = [self bucketKeyForWidth:width height:height format:pixelFormat usage:usage];

    [self.lock lock];
    NSMutableArray<id<MTLTexture>> *bucket = self.textureBuckets[key];
    id<MTLTexture> texture = bucket.lastObject;
    if (texture) {
        [bucket removeLastObject];
        [self.allTexturesInInsertionOrder removeObject:texture];
    }
    [self.lock unlock];

    if (texture) {
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

- (void)releaseTexture:(id<MTLTexture>)texture {
    if (!texture) { return; }
    NSUInteger width = texture.width;
    NSUInteger height = texture.height;
    if (width == 0 || height == 0) { return; }

    NSString *key = [self bucketKeyForWidth:width
                                     height:height
                                     format:texture.pixelFormat
                                      usage:texture.usage];

    [self.lock lock];
    NSMutableArray<id<MTLTexture>> *bucket = self.textureBuckets[key];
    if (!bucket) {
        bucket = [NSMutableArray array];
        self.textureBuckets[key] = bucket;
    }
    [bucket addObject:texture];
    [self.allTexturesInInsertionOrder addObject:texture];
    [self.lock unlock];
}

- (void)clearCache {
    [self.lock lock];
    [self.textureBuckets removeAllObjects];
    [self.allTexturesInInsertionOrder removeAllObjects];
    [self.lock unlock];
}

- (void)trimToSize:(NSUInteger)maxCount {
    [self.lock lock];
    if (maxCount == 0) {
        [self.textureBuckets removeAllObjects];
        [self.allTexturesInInsertionOrder removeAllObjects];
        [self.lock unlock];
        return;
    }

    while (self.allTexturesInInsertionOrder.count > maxCount) {
        id<MTLTexture> texture = self.allTexturesInInsertionOrder.firstObject;
        [self.allTexturesInInsertionOrder removeObjectAtIndex:0];
        if (!texture) { continue; }

        NSString *key = [self bucketKeyForWidth:texture.width
                                         height:texture.height
                                         format:texture.pixelFormat
                                          usage:texture.usage];
        NSMutableArray<id<MTLTexture>> *bucket = self.textureBuckets[key];
        [bucket removeObject:texture];
        if (bucket.count == 0) {
            [self.textureBuckets removeObjectForKey:key];
        }
    }
    [self.lock unlock];
}

#pragma mark - Helpers

- (NSString *)bucketKeyForWidth:(NSUInteger)width
                         height:(NSUInteger)height
                         format:(MTLPixelFormat)format
                          usage:(MTLTextureUsage)usage {
    return [NSString stringWithFormat:@"%lu-%lu-%lu-%lu",
            (unsigned long)width,
            (unsigned long)height,
            (unsigned long)format,
            (unsigned long)usage];
}

@end
