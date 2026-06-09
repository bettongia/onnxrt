.DEFAULT_GOAL := default

export EMULATOR_IOS ?= ios-emulator
export EMULATOR_IOS_DEVICE ?= iPhone\ 17
export EMULATOR_IOS_RUNTIME ?= iOS26.5

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

# END: Primary tasks

# START: Mobile emulators

emulators_stop_ios:
	xcrun simctl shutdown $(EMULATOR_IOS) || true
.PHONY: emulators_stop_ios

emulator_ios_create:
	xcrun simctl create $(EMULATOR_IOS) $(EMULATOR_IOS_DEVICE) $(EMULATOR_IOS_RUNTIME)
.PHONY: emulator_ios_create

# END: Mobile emulators

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
