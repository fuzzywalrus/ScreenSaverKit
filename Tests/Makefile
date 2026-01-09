CURRENT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
KIT_DIR := $(abspath $(CURRENT_DIR)/..)
KIT_SOURCE_DIR := $(KIT_DIR)/ScreenSaverKit
KIT_INCLUDE := -I$(KIT_DIR)
SDKROOT := $(shell xcrun --sdk macosx --show-sdk-path)
DEVELOPER_DIR := $(shell xcode-select -p)
FRAMEWORK_DIRS := -F$(SDKROOT)/System/Library/Frameworks -F$(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks

BUILD_DIR ?= $(CURRENT_DIR)/Build
MODULE_CACHE_DIR := $(BUILD_DIR)/ModuleCache
TEST_BUNDLE := $(BUILD_DIR)/ScreenSaverKitTests.xctest
TEST_BINARY := $(BUILD_DIR)/ScreenSaverKitTests
XCTEST := $(shell xcrun --find xctest)

CC := xcrun --sdk macosx clang
CFLAGS := -Wall -Wextra -O2 -fobjc-arc -fmodules -arch arm64 -arch x86_64 \
	-fmodules-cache-path=$(MODULE_CACHE_DIR) $(KIT_INCLUDE) -isysroot $(SDKROOT) $(FRAMEWORK_DIRS)
LDFLAGS := -Wl,-dead_strip $(FRAMEWORK_DIRS)
FRAMEWORKS := -framework Foundation -framework XCTest -framework Cocoa -framework QuartzCore -framework CoreVideo -framework Metal -framework ScreenSaver

TEST_SOURCES := \
	$(CURRENT_DIR)/TestHelpers.m \
	$(CURRENT_DIR)/SSKVectorMathTests.m \
	$(CURRENT_DIR)/SSKColorPaletteTests.m \
	$(CURRENT_DIR)/SSKParticleSystemTests.m \
	$(CURRENT_DIR)/SSKMetalRendererTests.m \
	$(CURRENT_DIR)/SSKMetalPassTests.m \
	$(CURRENT_DIR)/SSKSpriteTests.m

KIT_SOURCES := \
	$(KIT_SOURCE_DIR)/SSKColorPalette.m \
	$(KIT_SOURCE_DIR)/SSKPaletteManager.m \
	$(KIT_SOURCE_DIR)/SSKParticleSystem.m \
	$(KIT_SOURCE_DIR)/SSKMetalRenderer.m \
	$(KIT_SOURCE_DIR)/SSKMetalTextureCache.m \
	$(KIT_SOURCE_DIR)/SSKMetalPass.m \
	$(KIT_SOURCE_DIR)/SSKMetalParticlePass.m \
	$(KIT_SOURCE_DIR)/SSKMetalSpritePass.m \
	$(KIT_SOURCE_DIR)/SSKSprite.m \
	$(KIT_SOURCE_DIR)/SSKSpriteAnimationSequence.m \
	$(KIT_SOURCE_DIR)/SSKMetalBloomPass.m \
	$(KIT_SOURCE_DIR)/SSKMetalBlurPass.m \
	$(KIT_SOURCE_DIR)/SSKMetalEffectStage.m \
	$(KIT_SOURCE_DIR)/SSKMetalScreenSaverView.m \
	$(KIT_SOURCE_DIR)/SSKScreenSaverView.m \
	$(KIT_SOURCE_DIR)/SSKMetalParticleRenderer.m \
	$(KIT_SOURCE_DIR)/SSKDiagnostics.m \
	$(KIT_SOURCE_DIR)/SSKAnimationClock.m \
	$(KIT_SOURCE_DIR)/SSKScreenUtilities.m \
	$(KIT_SOURCE_DIR)/SSKEntityPool.m \
	$(KIT_SOURCE_DIR)/SSKAssetManager.m

.PHONY: all clean test

all: $(TEST_BUNDLE)

$(TEST_BUNDLE): $(TEST_SOURCES) $(KIT_SOURCES) | $(BUILD_DIR)
	@mkdir -p $(MODULE_CACHE_DIR)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(FRAMEWORKS) -bundle -o $(TEST_BINARY) $(TEST_SOURCES) $(KIT_SOURCES)
	@rm -rf "$(TEST_BUNDLE)"
	@mkdir -p "$(TEST_BUNDLE)/Contents/MacOS"
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ScreenSaverKitTests" "$(TEST_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.screensaverkit.tests" "$(TEST_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundleName string ScreenSaverKitTests" "$(TEST_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" "$(TEST_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@cp "$(TEST_BINARY)" "$(TEST_BUNDLE)/Contents/MacOS/ScreenSaverKitTests"
	@echo "Test bundle created: $(TEST_BUNDLE)"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

test: $(TEST_BUNDLE)
	@echo "Running ScreenSaverKit tests..."
	@if [ -x "$(XCTEST)" ]; then \
		"$(XCTEST)" $(TEST_BUNDLE); \
	else \
		echo "xctest not found; run via Xcode (xcodebuild test) or ensure Command Line Tools are installed."; \
	fi

clean:
	rm -rf "$(BUILD_DIR)"
