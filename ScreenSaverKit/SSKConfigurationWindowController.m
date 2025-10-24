#import "SSKConfigurationWindowController.h"

#import "SSKPreferenceBinder.h"
#import "SSKScreenSaverView.h"

@interface SSKConfigurationWindowController ()
@property (nonatomic, weak) SSKScreenSaverView *saverView;
@property (nonatomic, strong, readwrite) NSStackView *contentStack;
@property (nonatomic, strong, readwrite) SSKPreferenceBinder *preferenceBinder;
@property (nonatomic, strong) NSButton *okButton;
@property (nonatomic, strong) NSButton *cancelButton;
@end

@implementation SSKConfigurationWindowController

- (instancetype)initWithSaverView:(SSKScreenSaverView *)saverView
                              title:(NSString *)title
                           subtitle:(NSString *)subtitle {
    NSAssert(saverView, @"Saver view required");
    NSRect frame = NSMakeRect(0, 0, 420, 520);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.releasedWhenClosed = NO;
    if ((self = [super initWithWindow:window])) {
        _saverView = saverView;
        _preferenceBinder = [[SSKPreferenceBinder alloc] initWithDefaults:saverView.preferences];
        [self setupContentWithTitle:title subtitle:subtitle];
    }
    return self;
}

- (void)setupContentWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    NSView *contentView = [[NSView alloc] initWithFrame:self.window.contentView.bounds];
    contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = contentView;
    CGFloat margin = 24.0;

    NSTextField *titleField = [NSTextField labelWithString:title ?: @"Screen Saver Options"];
    titleField.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    titleField.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:titleField];

    NSTextField *subtitleField = nil;
    if (subtitle.length) {
        subtitleField = [NSTextField labelWithString:subtitle];
        subtitleField.textColor = [NSColor secondaryLabelColor];
        subtitleField.font = [NSFont systemFontOfSize:12];
        subtitleField.translatesAutoresizingMaskIntoConstraints = NO;
        [contentView addSubview:subtitleField];
    }

    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(0, margin, 0, margin);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:stack];
    self.contentStack = stack;

    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(handleOK:)];
    ok.bezelStyle = NSBezelStyleRounded;
    self.okButton = ok;

    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(handleCancel:)];
    cancel.bezelStyle = NSBezelStyleRounded;
    self.cancelButton = cancel;

    ok.translatesAutoresizingMaskIntoConstraints = NO;
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:ok];
    [contentView addSubview:cancel];

    NSView *topAnchorView = subtitleField ?: titleField;

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    [constraints addObject:[titleField.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:margin]];
    [constraints addObject:[titleField.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:margin]];
    [constraints addObject:[titleField.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-margin]];

    if (subtitleField) {
        [constraints addObject:[subtitleField.topAnchor constraintEqualToAnchor:titleField.bottomAnchor constant:4]];
        [constraints addObject:[subtitleField.leadingAnchor constraintEqualToAnchor:titleField.leadingAnchor]];
        [constraints addObject:[subtitleField.trailingAnchor constraintEqualToAnchor:titleField.trailingAnchor]];
    }

    [constraints addObject:[stack.topAnchor constraintEqualToAnchor:topAnchorView.bottomAnchor constant:16]];
    [constraints addObject:[stack.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor]];
    [constraints addObject:[stack.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor]];

    [constraints addObject:[ok.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-margin]];
    [constraints addObject:[ok.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-margin]];
    [constraints addObject:[cancel.trailingAnchor constraintEqualToAnchor:ok.leadingAnchor constant:-12]];
    [constraints addObject:[cancel.bottomAnchor constraintEqualToAnchor:ok.bottomAnchor]];
    [constraints addObject:[stack.bottomAnchor constraintLessThanOrEqualToAnchor:ok.topAnchor constant:-margin]];

    [NSLayoutConstraint activateConstraints:constraints];
}

- (void)prepareForPresentation {
    [self.preferenceBinder captureInitialValues];
    [self.preferenceBinder refreshControls];
    [self.window setDefaultButtonCell:self.okButton.cell];
}

- (void)handleOK:(id)sender {
    [self.preferenceBinder synchronize];
    [NSApp endSheet:self.window returnCode:NSModalResponseOK];
    [self.window orderOut:nil];
}

- (void)handleCancel:(id)sender {
    [self.preferenceBinder restoreInitialValues];
    [NSApp endSheet:self.window returnCode:NSModalResponseCancel];
    [self.window orderOut:nil];
}

@end
