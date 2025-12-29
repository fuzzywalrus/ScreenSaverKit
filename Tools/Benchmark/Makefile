CURRENT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
KIT_DIR := $(abspath $(CURRENT_DIR)/../..)
KIT_SOURCE_DIR := $(KIT_DIR)/ScreenSaverKit
KIT_INCLUDE := -I$(KIT_DIR)

BUILD_DIR ?= $(CURRENT_DIR)/Build
EXECUTABLE := $(BUILD_DIR)/ssk-benchmark

CC := clang
CFLAGS := -Wall -Wextra -O2 -fobjc-arc -fmodules -arch arm64 -arch x86_64 \
	-fmodules-cache-path=$(BUILD_DIR)/ModuleCache $(KIT_INCLUDE)
LDFLAGS := -Wl,-dead_strip
FRAMEWORKS := -framework Foundation -framework Cocoa -framework QuartzCore -framework Metal

SOURCES := \
	$(CURRENT_DIR)/SSKBenchmarkRunner.m \
	$(CURRENT_DIR)/SSKBenchmarkTool.m \
	$(KIT_SOURCE_DIR)/SSKParticleSystem.m \
	$(KIT_SOURCE_DIR)/SSKDiagnostics.m \
	$(KIT_SOURCE_DIR)/SSKAnimationClock.m \
	$(KIT_SOURCE_DIR)/SSKScreenUtilities.m

.PHONY: all clean install

all: $(EXECUTABLE)

$(EXECUTABLE): $(SOURCES) | $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)/ModuleCache
	$(CC) $(CFLAGS) $(LDFLAGS) $(FRAMEWORKS) -o $@ $(SOURCES)
	@echo "Benchmark tool built: $(EXECUTABLE)"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

clean:
	rm -rf "$(BUILD_DIR)"

install: $(EXECUTABLE)
	cp "$(EXECUTABLE)" /usr/local/bin/ssk-benchmark 2>/dev/null || \
	echo "Note: Could not install to /usr/local/bin. Run from: $(EXECUTABLE)"

