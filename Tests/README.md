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
Comprehensive tests for the particle system (51 tests):
- Initialization and capacity limits
- Particle spawning (single, multiple, beyond capacity)
- Particle lifecycle (spawn, update, expire)
- Index management and reuse
- Reset functionality
- Behavior options (fade alpha, fade size, color gradient, bitmask combinations)
- Color gradient behavior and CPU/GPU parity
- Color gradient with nil endColor fallback
- Color gradient GPU spawn with endColorMin/endColorMax
- Curl noise force field deflection
- Curl noise default properties and configuration
- Curl noise zero-strength produces no force
- Attractor point forces (single, multiple, max count)
- Attractor strength effect on displacement
- Attractor clearing
- Curl noise and attractors combined
- Per-particle rotation velocity integration
- Rotation property preservation (zero velocity)
- Ribbon mode enabled property
- Metal simulation vs CPU simulation
- Batch operations
- GPU spawn parameters

### SSKMetalRendererTests
Tests Metal renderer initialization and configuration (8 tests):
- Device creation (with and without pre-set device)
- Texture cache availability
- Frame begin/end lifecycle
- Effect stage registration and unregistration
- Trail persistence defaults (disabled, fade rate 0.05)
- Trail persistence configuration (enable, custom fade rate)
- Indirect rendering property toggle
- Graceful fallback when Metal unavailable

### SSKMetalPassTests
Tests for FX passes (12 tests):
- Trail pass initialization with device and library
- Trail texture creation, reuse (same size), and recreation (different size)
- Trail texture zero-size returns nil
- Trail fade compute kernel encoding
- Trail blit encoder
- Particle pass ribbon mode property
- Particle pass length multiplier property
- Noop pass setup/encode (base class contract)

### SSKSpriteTests
Tests sprite and sprite pass:
- SSKSprite defaults, properties, texture creation/invalidation
- SSKMetalSpriteData and SSKMetalSpritePass setup/encode
- Z-sorting, culling, scale/flip, animation sequence
- Texture rect helpers and viewportPixels API (current API; deprecated viewportSize variants are not used in tests)

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


