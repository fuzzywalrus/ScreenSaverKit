# ScreenSaverKit Unit Tests

This directory contains unit tests for ScreenSaverKit using the XCTest framework.

## Running Tests

### Build Tests
```bash
cd Tests
make
```

### Run Tests
```bash
make test
```

Or run directly with xctest:
```bash
xctest Build/ScreenSaverKitTests.xctest
```

### Run Tests in Xcode
1. Open the project in Xcode
2. Create a test scheme if needed
3. Press Cmd+U to run all tests

## Test Coverage

### SSKVectorMathTests
Tests vector math operations:
- Vector addition, subtraction, scaling
- Vector length and normalization
- Dot product
- Vector clamping and reflection
- Edge cases (zero vectors, very small vectors)

### SSKColorPaletteTests
Tests color palette functionality:
- Palette creation
- Factory methods
- Empty and single-color palettes

### SSKParticleSystemTests
Comprehensive tests for the particle system:
- Initialization and capacity limits
- Particle spawning (single, multiple, beyond capacity)
- Particle lifecycle (spawn, update, expire)
- Index management and reuse
- Reset functionality
- Behavior options (fade alpha, fade size)
- Metal simulation vs CPU simulation
- Batch operations
- GPU spawn parameters

### SSKMetalRendererTests
Tests Metal renderer initialization:
- Device creation
- Texture cache
- Frame begin/end
- Graceful fallback when Metal unavailable

## Writing New Tests

1. Create a new test file: `SSKComponentTests.m`
2. Import XCTest and the component:
   ```objc
   #import <XCTest/XCTest.h>
   #import "ScreenSaverKit/SSKComponent.h"
   ```
3. Create a test class:
   ```objc
   @interface SSKComponentTests : XCTestCase
   @end
   
   @implementation SSKComponentTests
   - (void)testSomething {
       // Your test code
   }
   @end
   ```
4. Add the test file to `Tests/Makefile` in `TEST_SOURCES`

## Test Helpers

`TestHelpers.h` provides utility functions:
- `createTempDirectory` - Create temporary directories for test artifacts
- `assertPoint:approximatelyEquals:epsilon:` - Compare NSPoints with tolerance
- `waitForCondition:timeout:` - Wait for async conditions

## Continuous Integration

Tests can be integrated into CI/CD pipelines:
```bash
make test
# Parse xctest output for pass/fail
```

