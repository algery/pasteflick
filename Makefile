export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

BUILD_DIR := .build
APP := $(BUILD_DIR)/Build/Products/Debug/PasteFlick.app

.PHONY: build run

build:
	xcodebuild -project PasteFlick/PasteFlick.xcodeproj -scheme PasteFlick \
		-configuration Debug -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath "$(BUILD_DIR)" build

run: build
	open -g "$(APP)"
