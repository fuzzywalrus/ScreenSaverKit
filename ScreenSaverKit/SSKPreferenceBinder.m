#import "SSKPreferenceBinder.h"

@interface SSKPreferenceBinding : NSObject
@property (nonatomic, weak) NSControl *control;
@property (nonatomic, weak) NSTextField *valueLabel;
@property (nonatomic, copy) NSString *format;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) SSKPreferenceControlKind kind;
@end

@implementation SSKPreferenceBinding
@end

@interface SSKPreferenceBinder ()
@property (nonatomic, strong) ScreenSaverDefaults *defaults;
@property (nonatomic, strong) NSMutableArray<SSKPreferenceBinding *> *bindings;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *initialValues;
@end

@implementation SSKPreferenceBinder

- (instancetype)initWithDefaults:(ScreenSaverDefaults *)defaults {
    NSParameterAssert(defaults);
    if ((self = [super init])) {
        _defaults = defaults;
        _bindings = [NSMutableArray array];
        _initialValues = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)captureInitialValues {
    [self.initialValues removeAllObjects];
    for (SSKPreferenceBinding *binding in self.bindings) {
        id value = [self.defaults objectForKey:binding.key];
        if (value) {
            self.initialValues[binding.key] = [value copy];
        } else {
            self.initialValues[binding.key] = NSNull.null;
        }
    }
}

- (void)restoreInitialValues {
    for (NSString *key in self.initialValues) {
        id value = self.initialValues[key];
        if (value == NSNull.null) {
            [self.defaults removeObjectForKey:key];
        } else {
            [self.defaults setObject:value forKey:key];
        }
    }
    [self.defaults synchronize];
    [self refreshControls];
}

- (void)synchronize {
    [self.defaults synchronize];
}

- (void)bindSlider:(NSSlider *)slider key:(NSString *)key valueLabel:(NSTextField *)label format:(NSString *)format {
    if (!slider || key.length == 0) { return; }
    SSKPreferenceBinding *binding = [SSKPreferenceBinding new];
    binding.control = slider;
    binding.valueLabel = label;
    binding.format = format ?: @"%.0f";
    binding.key = key;
    binding.kind = SSKPreferenceControlKindSlider;
    
    slider.target = self;
    slider.action = @selector(_controlValueChanged:);
    [self.bindings addObject:binding];
    [self refreshControl:binding];
}

- (void)bindCheckbox:(NSButton *)checkbox key:(NSString *)key {
    if (!checkbox || key.length == 0) { return; }
    SSKPreferenceBinding *binding = [SSKPreferenceBinding new];
    binding.control = checkbox;
    binding.key = key;
    binding.kind = SSKPreferenceControlKindCheckbox;
    
    checkbox.target = self;
    checkbox.action = @selector(_controlValueChanged:);
    [self.bindings addObject:binding];
    [self refreshControl:binding];
}

- (void)bindColorWell:(NSColorWell *)colorWell key:(NSString *)key {
    if (!colorWell || key.length == 0) { return; }
    SSKPreferenceBinding *binding = [SSKPreferenceBinding new];
    binding.control = colorWell;
    binding.key = key;
    binding.kind = SSKPreferenceControlKindColorWell;
    
    colorWell.target = self;
    colorWell.action = @selector(_controlValueChanged:);
    [self.bindings addObject:binding];
    [self refreshControl:binding];
}

- (void)bindPopUpButton:(NSPopUpButton *)popUp key:(NSString *)key {
    if (!popUp || key.length == 0) { return; }
    SSKPreferenceBinding *binding = [SSKPreferenceBinding new];
    binding.control = popUp;
    binding.key = key;
    binding.kind = SSKPreferenceControlKindPopUp;

    popUp.target = self;
    popUp.action = @selector(_controlValueChanged:);
    [self.bindings addObject:binding];
    [self refreshControl:binding];
}

- (void)refreshControls {
    for (SSKPreferenceBinding *binding in self.bindings) {
        [self refreshControl:binding];
    }
}

- (void)_controlValueChanged:(NSControl *)control {
    for (SSKPreferenceBinding *binding in self.bindings) {
        if (binding.control == control) {
            [self updatePreferenceForBinding:binding];
            break;
        }
    }
}

- (void)refreshControl:(SSKPreferenceBinding *)binding {
    if (!binding.control) { return; }
    id value = [self.defaults objectForKey:binding.key];
    switch (binding.kind) {
        case SSKPreferenceControlKindSlider: {
            double doubleValue = value ? [value doubleValue] : [binding.control doubleValue];
            [(NSSlider *)binding.control setDoubleValue:doubleValue];
            if (binding.valueLabel) {
                binding.valueLabel.stringValue = [NSString stringWithFormat:binding.format ?: @"%.0f", doubleValue];
            }
            break;
        }
        case SSKPreferenceControlKindCheckbox: {
            BOOL state = value ? [value boolValue] : NO;
            [(NSButton *)binding.control setState:state ? NSControlStateValueOn : NSControlStateValueOff];
            break;
        }
        case SSKPreferenceControlKindColorWell: {
            NSColor *color = nil;
            if ([value isKindOfClass:[NSData class]]) {
                if (@available(macOS 10.13, *)) {
                    color = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class]
                                                                  fromData:value
                                                                     error:nil];
                } else {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    color = [NSKeyedUnarchiver unarchiveObjectWithData:value];
                    #pragma clang diagnostic pop
                }
            } else if ([value isKindOfClass:[NSColor class]]) {
                color = value;
            }
            if (!color) {
                color = [NSColor whiteColor];
            }
            [(NSColorWell *)binding.control setColor:color];
            break;
        }
        case SSKPreferenceControlKindPopUp: {
            NSPopUpButton *popUp = (NSPopUpButton *)binding.control;
            NSString *stringValue = [value isKindOfClass:[NSString class]] ? value : nil;
            NSInteger index = -1;
            if (stringValue.length > 0) {
                index = [popUp indexOfItemWithRepresentedObject:stringValue];
                if (index == -1) {
                    index = [popUp indexOfItemWithTitle:stringValue];
                }
            }
            if (index == -1 && popUp.numberOfItems > 0) {
                index = 0;
            }
            if (index >= 0 && index < popUp.numberOfItems) {
                [popUp selectItemAtIndex:index];
            }
            break;
        }
    }
}

- (void)updatePreferenceForBinding:(SSKPreferenceBinding *)binding {
    if (!binding.control) { return; }
    switch (binding.kind) {
        case SSKPreferenceControlKindSlider: {
            double value = [(NSSlider *)binding.control doubleValue];
            [self.defaults setDouble:value forKey:binding.key];
            if (binding.valueLabel) {
                binding.valueLabel.stringValue = [NSString stringWithFormat:binding.format ?: @"%.0f", value];
            }
            break;
        }
        case SSKPreferenceControlKindCheckbox: {
            BOOL state = ([(NSButton *)binding.control state] == NSControlStateValueOn);
            [self.defaults setBool:state forKey:binding.key];
            break;
        }
        case SSKPreferenceControlKindColorWell: {
            NSColor *color = [(NSColorWell *)binding.control color];
            NSData *data = nil;
            if (@available(macOS 10.13, *)) {
                data = [NSKeyedArchiver archivedDataWithRootObject:color
                                             requiringSecureCoding:NO
                                                             error:nil];
            } else {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Wdeprecated-declarations"
                data = [NSKeyedArchiver archivedDataWithRootObject:color];
                #pragma clang diagnostic pop
            }
            if (data) {
                [self.defaults setObject:data forKey:binding.key];
            }
            break;
        }
        case SSKPreferenceControlKindPopUp: {
            NSPopUpButton *popUp = (NSPopUpButton *)binding.control;
            NSMenuItem *selected = popUp.selectedItem;
            NSString *value = nil;
            if ([selected.representedObject isKindOfClass:[NSString class]]) {
                value = selected.representedObject;
            } else if (selected.title.length > 0) {
                value = selected.title;
            }
            if (value) {
                [self.defaults setObject:value forKey:binding.key];
            }
            break;
        }
    }
    [self.defaults synchronize];
}

@end
