APP_NAME = HomebrewUpdateNotifier
BUNDLE_NAME = Homebrew Update Notifier.app
BUILD_DIR = .build
BUNDLE_DIR = $(BUILD_DIR)/$(BUNDLE_NAME)
SWIFT_FLAGS = -O -swift-version 6
SWIFT_FLAGS_MOCK = $(SWIFT_FLAGS) -DDEBUG_MOCK

SOURCES = $(wildcard Sources/*.swift)
TESTABLE_SOURCES = Sources/Constants.swift Sources/Localization.swift Sources/UpdateState.swift Sources/Settings.swift Sources/KeychainHelper.swift Sources/BrewManager.swift
TEST_SOURCES = Tests/Tests.swift

.PHONY: all clean run test install uninstall mock run-mock

all: $(BUILD_DIR)/.bundle_stamp

$(BUILD_DIR)/$(APP_NAME): $(SOURCES) | $(BUILD_DIR)
	swiftc $(SWIFT_FLAGS) -o $@ $(SOURCES)

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
	swiftc $(SWIFT_FLAGS_MOCK) -o $(BUILD_DIR)/$(APP_NAME) $(SOURCES)
	mkdir -p "$(BUNDLE_DIR)/Contents/MacOS"
	cp $(BUILD_DIR)/$(APP_NAME) "$(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Info.plist "$(BUNDLE_DIR)/Contents/Info.plist"
	codesign --force --sign - "$(BUNDLE_DIR)"
	xattr -cr "$(BUNDLE_DIR)"

run-mock: mock
	open "$(BUNDLE_DIR)"

install: $(BUILD_DIR)/.bundle_stamp
	cp -R "$(BUNDLE_DIR)" "/Applications/$(BUNDLE_NAME)"

uninstall:
	rm -rf "/Applications/$(BUNDLE_NAME)"
