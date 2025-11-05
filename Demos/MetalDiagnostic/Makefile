CURRENT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
KIT_DIR := $(abspath $(CURRENT_DIR)/../..)
KIT_SOURCE_DIR := $(KIT_DIR)/ScreenSaverKit
KIT_INCLUDE := -I$(KIT_DIR)

SCREENSAVER_NAME ?= MetalDiagnosticSaver
BUNDLE_ID ?= com.example.screenSaverKit.metalDiagnostic
PRINCIPAL_CLASS ?= MetalDiagnosticView
BUILD_DIR ?= $(CURRENT_DIR)/Build

BUNDLE_DIR := $(BUILD_DIR)/$(SCREENSAVER_NAME).saver
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
MODULE_CACHE_DIR := $(BUILD_DIR)/ModuleCache
THUMBNAIL_SRC := $(KIT_DIR)/documentation-src/thumbnail.png
THUMBNAIL_PNG := $(RESOURCES_DIR)/thumbnail.png
THUMBNAIL_PNG_2X := $(RESOURCES_DIR)/thumbnail@2x.png

CC := clang
CFLAGS := -Wall -Wextra -O2 -fobjc-arc -fmodules -arch arm64 -arch x86_64 \
	-fmodules-cache-path=$(MODULE_CACHE_DIR) $(KIT_INCLUDE)
LDFLAGS := -Wl,-dead_strip
FRAMEWORKS := -framework Cocoa -framework ScreenSaver -framework QuartzCore -framework Metal

SOURCES := \
	$(CURRENT_DIR)/MetalDiagnosticView.m \
	$(KIT_SOURCE_DIR)/SSKScreenSaverView.m \
	$(KIT_SOURCE_DIR)/SSKAssetManager.m \
	$(KIT_SOURCE_DIR)/SSKAnimationClock.m \
	$(KIT_SOURCE_DIR)/SSKEntityPool.m \
	$(KIT_SOURCE_DIR)/SSKScreenUtilities.m \
	$(KIT_SOURCE_DIR)/SSKDiagnostics.m

INFO_PLIST := $(CURRENT_DIR)/Info.plist
EXECUTABLE := $(MACOS_DIR)/$(SCREENSAVER_NAME)

.PHONY: all clean install run

all: $(EXECUTABLE) $(THUMBNAIL_PNG) $(THUMBNAIL_PNG_2X)

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

$(THUMBNAIL_PNG): $(THUMBNAIL_SRC) | $(MACOS_DIR)
	cp "$<" "$@"

$(THUMBNAIL_PNG_2X): $(THUMBNAIL_SRC) | $(MACOS_DIR)
	sips -s format png -Z 360 "$<" --out "$@" >/dev/null

clean:
	rm -rf "$(BUILD_DIR)"

install: all
	cp -R "$(BUNDLE_DIR)" ~/Library/Screen\ Savers/
	open ~/Library/Screen\ Savers/

run: install
	open -a ScreenSaverEngine "$(BUNDLE_DIR)"
