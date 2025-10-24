#import "DVDLogoConfigurationBuilder.h"

#import "DVDLogoPalettes.h"
#import "DVDLogoPreferences.h"
#import "ScreenSaverKit/SSKPaletteManager.h"
#import "ScreenSaverKit/SSKPreferenceBinder.h"

@implementation DVDLogoConfigurationBuilder

+ (void)populateStack:(NSStackView *)stack withBinder:(SSKPreferenceBinder *)binder {
    if (!stack || !binder) { return; }
    DVDRegisterRetroPalettes();

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Speed"
                                             minValue:0.2
                                             maxValue:3.5
                                                  key:DVDLogoPreferenceKeySpeed
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Logo Size"
                                             minValue:0.1
                                             maxValue:2.0
                                                  key:DVDLogoPreferenceKeySize
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self sliderRowWithTitle:@"Colour Change Speed"
                                             minValue:0.0
                                             maxValue:1.5
                                                  key:DVDLogoPreferenceKeyColorRate
                                               format:@"%.2fx"
                                                binder:binder]];

    [stack addArrangedSubview:[self colourModeRowWithBinder:binder]];
    [stack addArrangedSubview:[self paletteRowWithBinder:binder]];

    [stack addArrangedSubview:[self solidColourRowWithBinder:binder]];

    NSButton *randomPositionToggle = [NSButton checkboxWithTitle:@"Randomize start position" target:nil action:nil];
    [binder bindCheckbox:randomPositionToggle key:DVDLogoPreferenceKeyRandomStartPosition];
    [stack addArrangedSubview:randomPositionToggle];

    NSButton *randomVelocityToggle = [NSButton checkboxWithTitle:@"Randomize start direction" target:nil action:nil];
    [binder bindCheckbox:randomVelocityToggle key:DVDLogoPreferenceKeyRandomStartVelocity];
    [stack addArrangedSubview:randomVelocityToggle];

    NSButton *bloomToggle = [NSButton checkboxWithTitle:@"Enable bounce glow" target:nil action:nil];
    [binder bindCheckbox:bloomToggle key:DVDLogoPreferenceKeyBounceParticles];
    [stack addArrangedSubview:bloomToggle];
}

#pragma mark - Helpers

+ (NSView *)sliderRowWithTitle:(NSString *)title
                      minValue:(double)min
                      maxValue:(double)max
                           key:(NSString *)key
                        format:(NSString *)format
                         binder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    slider.minValue = min;
    slider.maxValue = max;
    slider.continuous = YES;

    NSTextField *valueLabel = [NSTextField labelWithString:@"--"];
    valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:slider];
    [row addArrangedSubview:valueLabel];

    [binder bindSlider:slider key:key valueLabel:valueLabel format:format];
    return row;
}

+ (NSView *)colourModeRowWithBinder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:@"Colour Mode"];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popUp addItemWithTitle:@"Rotating Palette"];
    popUp.lastItem.representedObject = DVDLogoColorModePalette;
    [popUp addItemWithTitle:@"Solid Colour"];
    popUp.lastItem.representedObject = DVDLogoColorModeSolid;

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:popUp];

    [binder bindPopUpButton:popUp key:DVDLogoPreferenceKeyColorMode];
    return row;
}

+ (NSView *)paletteRowWithBinder:(SSKPreferenceBinder *)binder {
    NSTextField *label = [NSTextField labelWithString:@"Colour Palette"];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popUp removeAllItems];

    NSArray<SSKColorPalette *> *palettes = [[SSKPaletteManager sharedManager] palettesForModule:DVDPaletteModuleIdentifier()];
    for (SSKColorPalette *palette in palettes) {
        NSString *title = palette.displayName.length ? palette.displayName : @"Palette";
        [popUp addItemWithTitle:title];
        NSMenuItem *item = [popUp itemAtIndex:popUp.numberOfItems - 1];
        item.representedObject = palette.identifier;
    }
    if (popUp.numberOfItems == 0) {
        NSString *fallback = DVDDefaultPaletteIdentifier();
        [popUp addItemWithTitle:fallback];
        popUp.lastItem.representedObject = fallback;
    }

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:popUp];

    [binder bindPopUpButton:popUp key:DVDLogoPreferenceKeyPalette];
    return row;
}

+ (NSView *)solidColourRowWithBinder:(SSKPreferenceBinder *)binder {
    NSColorWell *colorWell = [[NSColorWell alloc] initWithFrame:NSZeroRect];
    [binder bindColorWell:colorWell key:DVDLogoPreferenceKeySolidColor];

    NSTextField *label = [NSTextField labelWithString:@"Solid Colour"];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8.0;
    row.alignment = NSLayoutAttributeCenterY;
    [row addArrangedSubview:label];
    [row addArrangedSubview:colorWell];

    return row;
}

@end
