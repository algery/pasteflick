export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

BUILD_DIR := .build
APP := $(BUILD_DIR)/Build/Products/Debug/Shuntie.app

.PHONY: build run

build:
	xcodebuild -project PasteFlick/Shuntie.xcodeproj -scheme Shuntie \
		-configuration Debug -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath "$(BUILD_DIR)" build

run: build
	open -g "$(APP)"
