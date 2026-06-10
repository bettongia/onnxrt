.DEFAULT_GOAL := default

export EMULATOR_IOS ?= ios-emulator
export EMULATOR_IOS_DEVICE ?= iPhone\ 17
export EMULATOR_IOS_RUNTIME ?= iOS26.5

# Android emulator device ID — typically emulator-5554 when one emulator is
# running. arm64-v8a is the default ABI on Apple Silicon Macs (native speed);
# x86_64 emulators can be used but run under translation.
export ADB_BINARY_PATH ?= ~/Library/Android/sdk/platform-tools
export EMULATOR_ANDROID ?= android-emulator
export EMULATOR_ANDROID_DEVICE ?= pixel_9
export EMULATOR_ANDROID_ABI ?= arm64-v8a

# BEGIN: Primary tasks

default: clean prepare license_check format analyze test coverage doc
.PHONY: default

cicd: default
.PHONY: cicd

cicd_macos: prepare test
.PHONY: cicd_macos

cicd_linux: prepare test
.PHONY: cicd_linux

cicd_windows: prepare test
.PHONY: cicd_windows

# Run integration tests on macOS (requires the ORT dylib to be staged by the
# native-assets hook — run `dart pub get` first to trigger it).
# Usage: make macos_test
macos_test:
	cd integration_test_app && \
	  flutter pub get && \
	  flutter test integration_test/onnxrt_test.dart --device-id macos
.PHONY: macos_test

# Run integration tests on a connected iOS simulator.
# This is the primary tool for the Phase 1 iOS XCFramework spike (Q1).
# Requires Xcode and a simulator reachable via `flutter devices`.
# Usage: make ios_test
ios_test:
	cd integration_test_app && \
	  flutter pub get && \
	  xcrun simctl list | grep "$(EMULATOR_IOS)" | grep -q "Booted" || xcrun simctl boot $(EMULATOR_IOS) && \
	  open -a Simulator && \
	  flutter test integration_test/onnxrt_test.dart --device-id $(EMULATOR_IOS)
.PHONY: ios_test

# Run integration tests on a connected Android emulator.
# Requires an Android emulator to be running and reachable via `flutter devices`.
# Default device ID is emulator-5554 (the first emulator when one is running).
# On Apple Silicon Macs, use an arm64-v8a system image for native speed.
# Usage: make android_test
android_test:
	cd integration_test_app && \
	  flutter pub get && \
	  flutter emulators --launch $(EMULATOR_ANDROID) ||true && \
	  $(ADB_BINARY_PATH)/adb wait-for-device && \
	  flutter test integration_test/onnxrt_test.dart --device-id emulator-5554
.PHONY: android_test

# END: Primary tasks

# START: Mobile emulators
emulators_stop: emulators_stop_android emulators_stop_ios

emulators_stop_ios:
	xcrun simctl shutdown $(EMULATOR_IOS) || true
.PHONY: emulators_stop_ios

emulator_ios_create:
	xcrun simctl create $(EMULATOR_IOS) $(EMULATOR_IOS_DEVICE) $(EMULATOR_IOS_RUNTIME)
.PHONY: emulator_ios_create

emulators_stop_android:
	$(ADB_BINARY_PATH)/adb emu kill || true
.PHONY: emulators_stop_android

emulator_android_create:
	avdmanager create avd --name $(EMULATOR_ANDROID_DEVICE) --package "system-images;android-35;google_apis;$(EMULATOR_ANDROID_ABI)" --device "pixel_9" --force
.PHONY: emulator_android_create

# END: Mobile emulators

# START: Container tests
container_test:
	podman build -t betto-onnxrt-cicd .
	podman run --rm betto-onnxrt-cicd

# END: Container tests

pre_commit: format_check analyze license_check test
.PHONY: pre_commit

format:
	dart format lib/ test/ hook/ tool/
.PHONY: format

format_check:
	dart format --output=none --set-exit-if-changed lib/ test/ hook/ tool/
.PHONY: format_check

analyze:
	dart analyze
.PHONY: analyze

test:
	dart test
.PHONY: test

doc:
	dart doc
.PHONY: doc

license_check:
	cat addlicense_config.txt | xargs addlicense --check
.PHONY: license_check

license_add:
	cat addlicense_config.txt | xargs addlicense
.PHONY: license_add

coverage:
	dart test --coverage-path=coverage/lcov.info
	genhtml coverage/lcov.info --output-dir coverage/html
.PHONY: coverage

prepare:
	dart pub global activate coverage
	dart pub get
.PHONY: prepare

clean:
	rm -rf coverage
	rm -rf doc
.PHONY: clean
