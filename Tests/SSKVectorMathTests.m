#import <XCTest/XCTest.h>
#import "ScreenSaverKit/SSKVectorMath.h"
#import "TestHelpers.h"

@interface SSKVectorMathTests : XCTestCase
@end

@implementation SSKVectorMathTests

- (void)setUp {
    [super setUp];
}

- (void)tearDown {
    [super tearDown];
}

#pragma mark - Vector Addition

- (void)testVectorAdd {
    NSPoint a = NSMakePoint(1.0, 2.0);
    NSPoint b = NSMakePoint(3.0, 4.0);
    NSPoint result = SSKVectorAdd(a, b);
    XCTAssertEqual(result.x, 4.0);
    XCTAssertEqual(result.y, 6.0);
}

- (void)testVectorAddWithZero {
    NSPoint a = NSMakePoint(5.0, 7.0);
    NSPoint b = NSZeroPoint;
    NSPoint result = SSKVectorAdd(a, b);
    XCTAssertEqual(result.x, 5.0);
    XCTAssertEqual(result.y, 7.0);
}

#pragma mark - Vector Subtraction

- (void)testVectorSubtract {
    NSPoint a = NSMakePoint(5.0, 7.0);
    NSPoint b = NSMakePoint(2.0, 3.0);
    NSPoint result = SSKVectorSubtract(a, b);
    XCTAssertEqual(result.x, 3.0);
    XCTAssertEqual(result.y, 4.0);
}

- (void)testVectorSubtractWithZero {
    NSPoint a = NSMakePoint(5.0, 7.0);
    NSPoint b = NSZeroPoint;
    NSPoint result = SSKVectorSubtract(a, b);
    XCTAssertEqual(result.x, 5.0);
    XCTAssertEqual(result.y, 7.0);
}

#pragma mark - Vector Scaling

- (void)testVectorScale {
    NSPoint a = NSMakePoint(2.0, 3.0);
    NSPoint result = SSKVectorScale(a, 2.0);
    XCTAssertEqual(result.x, 4.0);
    XCTAssertEqual(result.y, 6.0);
}

- (void)testVectorScaleWithZero {
    NSPoint a = NSMakePoint(2.0, 3.0);
    NSPoint result = SSKVectorScale(a, 0.0);
    XCTAssertEqual(result.x, 0.0);
    XCTAssertEqual(result.y, 0.0);
}

- (void)testVectorScaleWithNegative {
    NSPoint a = NSMakePoint(2.0, 3.0);
    NSPoint result = SSKVectorScale(a, -1.0);
    XCTAssertEqual(result.x, -2.0);
    XCTAssertEqual(result.y, -3.0);
}

#pragma mark - Vector Length

- (void)testVectorLength {
    NSPoint a = NSMakePoint(3.0, 4.0);
    CGFloat length = SSKVectorLength(a);
    XCTAssertEqualWithAccuracy(length, 5.0, 0.0001);
}

- (void)testVectorLengthZero {
    NSPoint a = NSZeroPoint;
    CGFloat length = SSKVectorLength(a);
    XCTAssertEqual(length, 0.0);
}

#pragma mark - Vector Normalize

- (void)testVectorNormalize {
    NSPoint a = NSMakePoint(3.0, 4.0);
    NSPoint result = SSKVectorNormalize(a);
    CGFloat length = SSKVectorLength(result);
    XCTAssertEqualWithAccuracy(length, 1.0, 0.0001);
}

- (void)testVectorNormalizeZero {
    NSPoint a = NSZeroPoint;
    NSPoint result = SSKVectorNormalize(a);
    XCTAssertEqual(result.x, 0.0);
    XCTAssertEqual(result.y, 0.0);
}

- (void)testVectorNormalizeVerySmall {
    NSPoint a = NSMakePoint(0.00001, 0.00001);
    NSPoint result = SSKVectorNormalize(a);
    // Should return zero for very small vectors
    XCTAssertEqual(result.x, 0.0);
    XCTAssertEqual(result.y, 0.0);
}

#pragma mark - Vector Dot Product

- (void)testVectorDot {
    NSPoint a = NSMakePoint(1.0, 2.0);
    NSPoint b = NSMakePoint(3.0, 4.0);
    CGFloat result = SSKVectorDot(a, b);
    XCTAssertEqual(result, 11.0); // 1*3 + 2*4 = 11
}

- (void)testVectorDotPerpendicular {
    NSPoint a = NSMakePoint(1.0, 0.0);
    NSPoint b = NSMakePoint(0.0, 1.0);
    CGFloat result = SSKVectorDot(a, b);
    XCTAssertEqual(result, 0.0);
}

#pragma mark - Vector Clamp Length

- (void)testVectorClampLengthWithinRange {
    NSPoint a = NSMakePoint(3.0, 4.0); // length = 5
    NSPoint result = SSKVectorClampLength(a, 1.0, 10.0);
    CGFloat length = SSKVectorLength(result);
    XCTAssertEqualWithAccuracy(length, 5.0, 0.0001);
}

- (void)testVectorClampLengthTooLong {
    NSPoint a = NSMakePoint(30.0, 40.0); // length = 50
    NSPoint result = SSKVectorClampLength(a, 1.0, 10.0);
    CGFloat length = SSKVectorLength(result);
    XCTAssertEqualWithAccuracy(length, 10.0, 0.0001);
}

- (void)testVectorClampLengthTooShort {
    NSPoint a = NSMakePoint(0.3, 0.4); // length = 0.5
    NSPoint result = SSKVectorClampLength(a, 1.0, 10.0);
    CGFloat length = SSKVectorLength(result);
    XCTAssertEqualWithAccuracy(length, 1.0, 0.0001);
}

#pragma mark - Vector Reflect

- (void)testVectorReflect {
    NSPoint incident = NSMakePoint(1.0, -1.0); // Coming from top-right
    NSPoint normal = NSMakePoint(0.0, 1.0); // Normal pointing up
    NSPoint result = SSKVectorReflect(incident, normal);
    // Should reflect to (1.0, 1.0)
    XCTAssertEqualWithAccuracy(result.x, 1.0, 0.0001);
    XCTAssertEqualWithAccuracy(result.y, 1.0, 0.0001);
}

@end

