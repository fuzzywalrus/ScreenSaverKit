#import "SSKEntityPool.h"

@interface SSKEntityPool ()
@property (nonatomic) NSMutableArray *storage;
@property (nonatomic, copy) SSKEntityFactoryBlock factory;
@property (nonatomic, readwrite) NSUInteger capacity;
@end

@implementation SSKEntityPool

- (instancetype)initWithCapacity:(NSUInteger)capacity factory:(SSKEntityFactoryBlock)factory {
    NSParameterAssert(factory);
    if ((self = [super init])) {
        _capacity = MAX(1, capacity);
        _factory = [factory copy];
        _storage = [NSMutableArray array];
    }
    return self;
}

- (id)acquire {
    id object = self.storage.lastObject;
    if (object) {
        [self.storage removeLastObject];
        return object;
    }
    return self.factory();
}

- (void)releaseObject:(id)object {
    if (!object) { return; }
    if (self.storage.count < self.capacity) {
        [self.storage addObject:object];
    }
}

- (void)drain {
    [self.storage removeAllObjects];
}

- (void)preallocate:(NSUInteger)count {
    if (count == 0) { return; }
    NSUInteger target = MIN(count, self.capacity);
    while (self.storage.count < target) {
        id object = self.factory();
        if (!object) { break; }
        [self.storage addObject:object];
    }
}

@end
