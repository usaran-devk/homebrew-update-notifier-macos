APP_NAME = Koebes
BUNDLE_NAME = Koebes.app
BUILD_DIR = .build
BUNDLE_DIR = $(BUILD_DIR)/$(BUNDLE_NAME)
SWIFT_FLAGS = -O -swift-version 6
SWIFT_FLAGS_MOCK = $(SWIFT_FLAGS) -DDEBUG_MOCK

# Stamp file that records the last build mode (normal vs mock).
# If the mode changes, the binary is removed to force a clean recompile.
BUILD_MODE_STAMP = $(BUILD_DIR)/.build_mode

SOURCES = $(wildcard Sources/*.swift)
TESTABLE_SOURCES = \
	Sources/Constants.swift \
	Sources/Localization.swift \
	Sources/UpdateState.swift \
	Sources/Settings.swift \
	Sources/KeychainHelper.swift \
	Sources/BrewParser.swift \
	Sources/DependencyResolver.swift \
	Sources/ProcessRunner.swift \
	Sources/BrewManager.swift
TEST_SOURCES = Tests/Tests.swift

.PHONY: all clean run test install uninstall mock run-mock

all: $(BUILD_DIR)/.bundle_stamp

# Detect a mode switch (normal → mock or mock → normal) and force rebuild.
$(BUILD_DIR)/$(APP_NAME): $(SOURCES) | $(BUILD_DIR)
	@if [ -f "$(BUILD_MODE_STAMP)" ] && [ "$$(cat $(BUILD_MODE_STAMP))" != "normal" ]; then \
		echo "Build mode changed (was mock, now normal) — forcing rebuild..."; \
		rm -f $@; \
	fi
	swiftc $(SWIFT_FLAGS) -o $@ $(SOURCES)
	@echo "normal" > $(BUILD_MODE_STAMP)

$(BUILD_DIR)/.bundle_stamp: $(BUILD_DIR)/$(APP_NAME) Info.plist
	mkdir -p "$(BUNDLE_DIR)/Contents/MacOS"
	cp $(BUILD_DIR)/$(APP_NAME) "$(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Info.plist "$(BUNDLE_DIR)/Contents/Info.plist"
	codesign --force --sign - "$(BUNDLE_DIR)"
	xattr -cr "$(BUNDLE_DIR)"
	touch $@

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

run: $(BUILD_DIR)/.bundle_stamp
	open "$(BUNDLE_DIR)"

test: $(TEST_SOURCES) $(TESTABLE_SOURCES) | $(BUILD_DIR)
	swiftc $(SWIFT_FLAGS) -o $(BUILD_DIR)/Tests $(TESTABLE_SOURCES) $(TEST_SOURCES)
	$(BUILD_DIR)/Tests

clean:
	rm -rf $(BUILD_DIR)

mock: $(SOURCES) | $(BUILD_DIR)
	@if [ -f "$(BUILD_MODE_STAMP)" ] && [ "$$(cat $(BUILD_MODE_STAMP))" != "mock" ]; then \
		echo "Build mode changed (was normal, now mock) — forcing rebuild..."; \
		rm -f $(BUILD_DIR)/$(APP_NAME); \
	fi
	swiftc $(SWIFT_FLAGS_MOCK) -o $(BUILD_DIR)/$(APP_NAME) $(SOURCES)
	@echo "mock" > $(BUILD_MODE_STAMP)
	mkdir -p "$(BUNDLE_DIR)/Contents/MacOS"
	cp $(BUILD_DIR)/$(APP_NAME) "$(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Info.plist "$(BUNDLE_DIR)/Contents/Info.plist"
	codesign --force --sign - "$(BUNDLE_DIR)"
	xattr -cr "$(BUNDLE_DIR)"

run-mock: mock
	open "$(BUNDLE_DIR)"

install: $(BUILD_DIR)/.bundle_stamp
	rm -rf "/Applications/$(BUNDLE_NAME)"
	cp -R "$(BUNDLE_DIR)" "/Applications/$(BUNDLE_NAME)"

uninstall:
	rm -rf "/Applications/$(BUNDLE_NAME)"
