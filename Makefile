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

# CI targets — invoked by GitHub Actions, not intended for direct local use.
#
# Linux/Windows CI runners have only Dart installed (no Flutter), so they use
# prepare_dart instead of prepare and clean_dart instead of clean.  The macOS
# runner installs Flutter and can run the full on-device integration test.
#
cicd: default
.PHONY: cicd

# cicd_linux is self-contained: downloads the ORT binary, creates the
# unversioned symlink that dlopen('libonnxruntime.so') needs in JIT mode, then
# runs dart test and coverage DIRECTLY in the same shell that exported
# LD_LIBRARY_PATH — avoiding a sub-make boundary that does not reliably
# propagate the variable to dart test on all platforms.
# Run locally with:
#   make container_test   (executes inside a Podman Linux container)
#   make cicd_linux       (runs directly on a Linux host with Dart installed)
cicd_linux:
	dart pub global activate coverage
	dart pub get
	$(MAKE) --no-print-directory license_check format_check analyze
	@ORT_VER=$$(cat VERSION_ONNX); \
	  ORT_VER=$${ORT_VER#v}; \
	  ORT_CACHE=".dart_tool/betto_onnxrt/$$ORT_VER"; \
	  mkdir -p "$$ORT_CACHE"; \
	  ln -sf "libonnxruntime.so.$$ORT_VER" "$$ORT_CACHE/libonnxruntime.so"; \
	  export LD_LIBRARY_PATH="$$(pwd)/$$ORT_CACHE$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}"; \
	  dart test && \
	  dart test --coverage-path=coverage/lcov.info && \
	  rm -rf site/coverage && \
	  mkdir -p site/coverage && \
	  genhtml coverage/lcov.info -o site/coverage
	dart doc
.PHONY: cicd_linux

cicd_macos: prepare_flutter license_check format_check analyze test coverage doc macos_test
.PHONY: cicd_macos

cicd_windows: prepare_dart license_check format_check analyze test coverage doc
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

pre_commit: format_check analyze license_check test check_ios_version
.PHONY: pre_commit

# Assert that the SPM exact-version pin in packages/betto_onnxrt_ios/ios/Package.swift
# matches the "ios.version" field in version_onnx.json.
#
# The iOS SPM version (currently 1.24.2) legitimately differs from VERSION_ONNX
# (1.22.0) because the microsoft/onnxruntime-swift-package-manager repo has no
# tags between 1.20.0 and 1.24.1.  The two values are tracked independently:
# VERSION_ONNX is the ORT C API baseline version; version_onnx.json "ios.version"
# is the earliest available SPM tag >= VERSION_ONNX.
# Run manually: make check_ios_version
check_ios_version:
	@IOS_VER=$$(python3 -c "import json,sys; d=json.load(open('version_onnx.json')); print(d['platforms']['ios']['version'])"); \
	SPM_VER=$$(grep 'exact:' packages/betto_onnxrt_ios/ios/betto_onnxrt_ios/Package.swift | grep -o '"[0-9][^"]*"' | tr -d '"'); \
	if [ "$$IOS_VER" != "$$SPM_VER" ]; then \
	  echo "ERROR: version_onnx.json ios.version ($$IOS_VER) does not match Package.swift exact: ($$SPM_VER)"; \
	  echo "       Update packages/betto_onnxrt_ios/ios/betto_onnxrt_ios/Package.swift to exact: \"$$IOS_VER\""; \
	  exit 1; \
	fi; \
	echo "check_ios_version: OK ($$IOS_VER)"
.PHONY: check_ios_version

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

	rm -rf site/coverage
	mkdir -p site/coverage
	genhtml coverage/lcov.info -o site/coverage

.PHONY: coverage

# BEGIN: Documentation site tasks
site/:
	mkdir -p site

site: styles site/index.html site/spec.html site/roadmap.html site/api/index.html coverage | site/
.PHONY: site

styles: site/styles/styles.css
.PHONY: styles

site/index.html:  docs/index.md README.md docs/.pandoc docs/template/header.html | site/
	pandoc --defaults="docs/.pandoc" docs/index.md README.md -o "site/index.html";

site/spec.html:  docs/spec/*.md docs/spec/.pandoc docs/template/header.html | site/
	pandoc --defaults="docs/spec/.pandoc" --mathml docs/spec/*.md -o "site/spec.html";

site/roadmap.html: docs/roadmap/*.md docs/.pandoc docs/template/header.html | site/
	pandoc --defaults="docs/.pandoc" docs/roadmap/v*.md -o "site/roadmap.html";

site/styles/styles.css: docs/styles/styles.css | site/
	mkdir -p site/styles/
	cp docs/styles/styles.css site/styles/styles.css

site/api/index.html:
	dart doc -o site/api/index.html

# END: Documentation site tasks

# prepare_dart: Dart-only setup — safe on CI runners that lack Flutter.
# prepare_flutter: Full setup including Flutter project pub-gets.
# prepare: Full local setup (delegates to prepare_flutter).
prepare_dart:
	dart pub global activate coverage
	dart pub get
.PHONY: prepare_dart

prepare_flutter: prepare_dart
	cd integration_test_app && flutter pub get
	cd packages/betto_onnxrt_ios && flutter pub get
.PHONY: prepare_flutter

prepare: prepare_flutter
.PHONY: prepare

# clean_dart: removes generated artefacts that don't require Flutter.
# clean: full clean including Flutter build outputs.
clean_dart:
	rm -rf coverage
	rm -rf doc
	rm -rf site
.PHONY: clean_dart

clean: clean_dart
	cd integration_test_app && flutter clean
	cd packages/betto_onnxrt_ios && flutter clean
.PHONY: clean
