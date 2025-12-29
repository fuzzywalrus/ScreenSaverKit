#import <XCTest/XCTest.h>
#import "ScreenSaverKit/SSKColorPalette.h"
#import "ScreenSaverKit/SSKPaletteManager.h"

@interface SSKColorPaletteTests : XCTestCase
@end

@implementation SSKColorPaletteTests

- (void)setUp {
    [super setUp];
}

- (void)tearDown {
    [super tearDown];
}

- (void)testColorPaletteCreation {
    NSArray<NSColor *> *colors = @[
        [NSColor redColor],
        [NSColor greenColor],
        [NSColor blueColor]
    ];
    
    SSKColorPalette *palette = [[SSKColorPalette alloc] initWithIdentifier:@"test"
                                                                 displayName:@"Test Palette"
                                                                      colors:colors];
    
    XCTAssertNotNil(palette);
    XCTAssertEqualObjects(palette.identifier, @"test");
    XCTAssertEqualObjects(palette.displayName, @"Test Palette");
    XCTAssertEqual(palette.colors.count, 3);
}

- (void)testColorPaletteFactoryMethod {
    NSArray<NSColor *> *colors = @[[NSColor redColor]];
    
    SSKColorPalette *palette = [SSKColorPalette paletteWithIdentifier:@"factory"
                                                          displayName:@"Factory"
                                                               colors:colors];
    
    XCTAssertNotNil(palette);
    XCTAssertEqualObjects(palette.identifier, @"factory");
    XCTAssertEqual(palette.colors.count, 1);
}

- (void)testColorPaletteEmptyColors {
    SSKColorPalette *palette = [[SSKColorPalette alloc] initWithIdentifier:@"empty"
                                                                 displayName:@"Empty"
                                                                      colors:@[]];
    
    XCTAssertNotNil(palette);
    XCTAssertEqual(palette.colors.count, 0);
}

- (void)testColorPaletteSingleColor {
    NSArray<NSColor *> *colors = @[[NSColor whiteColor]];
    
    SSKColorPalette *palette = [[SSKColorPalette alloc] initWithIdentifier:@"single"
                                                                 displayName:@"Single"
                                                                      colors:colors];
    
    XCTAssertEqual(palette.colors.count, 1);
    XCTAssertEqualObjects(palette.colors.firstObject, [NSColor whiteColor]);
}

@end

