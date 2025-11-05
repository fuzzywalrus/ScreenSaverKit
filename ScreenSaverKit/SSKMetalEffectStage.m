#import "SSKMetalEffectStage.h"

@interface SSKMetalEffectStage ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, strong, readwrite) SSKMetalPass *pass;
@property (nonatomic, copy, readwrite) SSKMetalEffectStageHandler handler;
@end

@implementation SSKMetalEffectStage

- (instancetype)initWithIdentifier:(NSString *)identifier
                              pass:(SSKMetalPass *)pass
                           handler:(SSKMetalEffectStageHandler)handler {
    NSParameterAssert(identifier.length > 0);
    NSParameterAssert(pass);
    NSParameterAssert(handler);
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _pass = pass;
        _handler = [handler copy];
    }
    return self;
}

@end
