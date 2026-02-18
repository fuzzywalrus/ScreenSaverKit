CURRENT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
KIT_DIR := $(abspath $(CURRENT_DIR)/../..)
KIT_SOURCE_DIR := $(KIT_DIR)/ScreenSaverKit

SCREENSAVER_NAME ?= RainSaver
BUNDLE_ID ?= com.example.screenSaverKit.rain
PRINCIPAL_CLASS ?= RainView
BUILD_DIR ?= $(CURRENT_DIR)/Build

BUNDLE_DIR := $(BUILD_DIR)/$(SCREENSAVER_NAME).saver
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
MODULE_CACHE_DIR := $(BUILD_DIR)/ModuleCache

CC := clang
CFLAGS := -Wall -Wextra -O2 -fobjc-arc -fmodules -arch arm64 -arch x86_64 \
	-fmodules-cache-path=$(MODULE_CACHE_DIR) -I$(KIT_DIR)
LDFLAGS := -Wl,-dead_strip
FRAMEWORKS := -framework Cocoa -framework ScreenSaver -framework QuartzCore -framework Metal

SOURCES := \
	$(CURRENT_DIR)/RainView.m \
	$(KIT_SOURCE_DIR)/SSKMetalScreenSaverView.m \
	$(KIT_SOURCE_DIR)/SSKScreenSaverView.m \
	$(KIT_SOURCE_DIR)/SSKMetalRenderer.m \
	$(KIT_SOURCE_DIR)/SSKMetalTextureCache.m \
	$(KIT_SOURCE_DIR)/SSKMetalPass.m \
	$(KIT_SOURCE_DIR)/SSKMetalParticlePass.m \
	$(KIT_SOURCE_DIR)/SSKMetalBloomPass.m \
	$(KIT_SOURCE_DIR)/SSKMetalBlurPass.m \
	$(KIT_SOURCE_DIR)/SSKMetalEffectStage.m \
	$(KIT_SOURCE_DIR)/SSKMetalSpritePass.m \
	$(KIT_SOURCE_DIR)/SSKMetalRenderDiagnostics.m \
	$(KIT_SOURCE_DIR)/SSKMetalParticleRenderer.m \
	$(KIT_SOURCE_DIR)/SSKSprite.m \
	$(KIT_SOURCE_DIR)/SSKSpriteAnimationSequence.m \
	$(KIT_SOURCE_DIR)/SSKAssetManager.m \
	$(KIT_SOURCE_DIR)/SSKAnimationClock.m \
	$(KIT_SOURCE_DIR)/SSKEntityPool.m \
	$(KIT_SOURCE_DIR)/SSKScreenUtilities.m \
	$(KIT_SOURCE_DIR)/SSKDiagnostics.m \
	$(KIT_SOURCE_DIR)/SSKPreferenceBinder.m \
	$(KIT_SOURCE_DIR)/SSKConfigurationWindowController.m \
	$(KIT_SOURCE_DIR)/SSKColorPalette.m \
	$(KIT_SOURCE_DIR)/SSKPaletteManager.m \
	$(KIT_SOURCE_DIR)/SSKColorUtilities.m \
	$(KIT_SOURCE_DIR)/SSKParticleSystem.m \
	$(KIT_SOURCE_DIR)/SSKShaderLoader.m

INFO_PLIST := $(CURRENT_DIR)/Info.plist
EXECUTABLE := $(MACOS_DIR)/$(SCREENSAVER_NAME)

.PHONY: all clean install run

all: $(EXECUTABLE)

$(EXECUTABLE): $(SOURCES) $(CONTENTS_DIR)/Info.plist | $(MACOS_DIR)
	@mkdir -p $(MODULE_CACHE_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) $(FRAMEWORKS) -bundle -o $@ $(SOURCES)

$(CONTENTS_DIR)/Info.plist: $(INFO_PLIST) | $(MACOS_DIR)
	cp "$<" "$@"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $(SCREENSAVER_NAME)" "$@"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$@"
	/usr/libexec/PlistBuddy -c "Set :NSPrincipalClass $(PRINCIPAL_CLASS)" "$@"

$(MACOS_DIR):
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)

clean:
	rm -rf "$(BUILD_DIR)"

install: all
	cp -R "$(BUNDLE_DIR)" ~/Library/Screen\ Savers/
	open ~/Library/Screen\ Savers/

run: install
	open -a ScreenSaverEngine "$(BUNDLE_DIR)"


