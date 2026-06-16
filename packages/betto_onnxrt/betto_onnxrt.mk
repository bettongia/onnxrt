# betto_onnxrt.mk — Makefile fragment for the betto_onnxrt Dart package.
# Included from the repo-root Makefile via `include packages/betto_onnxrt/betto_onnxrt.mk`.
# All targets that run Dart tooling cd into the package directory first so that
# pubspec.yaml, analysis_options.yaml, and the native-assets cache are resolved
# relative to the package root, not the repo root.

BETTO_PKG := packages/betto_onnxrt
BETTO_ITA := packages/betto_onnxrt/integration_test_app

# prepare_dart: Dart-only setup — safe on CI runners that lack Flutter.
prepare_dart:
	cd $(BETTO_PKG) && dart pub global activate coverage && dart pub get
.PHONY: prepare_dart

# prepare_flutter: Full setup including Flutter project pub-get.
prepare_flutter: prepare_dart
	cd $(BETTO_ITA) && flutter pub get
.PHONY: prepare_flutter

# prepare: Full local setup (delegates to prepare_flutter + iOS companion).
prepare: prepare_flutter prepare_ios
.PHONY: prepare

# clean_dart: removes generated artefacts that don't require Flutter.
clean_dart:
	rm -rf $(BETTO_PKG)/coverage
	rm -rf $(BETTO_PKG)/doc
	rm -rf $(BETTO_PKG)/site
.PHONY: clean_dart

format:
	cd $(BETTO_PKG) && dart format lib/ test/ hook/ tool/
.PHONY: format

format_check:
	cd $(BETTO_PKG) && dart format --output=none --set-exit-if-changed lib/ test/ hook/ tool/
.PHONY: format_check

analyze:
	cd $(BETTO_PKG) && dart analyze
.PHONY: analyze

test:
	cd $(BETTO_PKG) && dart test
.PHONY: test

doc:
	cd $(BETTO_PKG) && dart doc
.PHONY: doc

coverage:
	cd $(BETTO_PKG) && dart test --coverage-path=coverage/lcov.info
	rm -rf $(BETTO_PKG)/site/coverage
	mkdir -p $(BETTO_PKG)/site/coverage
	genhtml $(BETTO_PKG)/coverage/lcov.info -o $(BETTO_PKG)/site/coverage
.PHONY: coverage

license_check:
	cd $(BETTO_PKG) && cat addlicense_config.txt | xargs addlicense --check
.PHONY: license_check

license_add:
	cd $(BETTO_PKG) && cat addlicense_config.txt | xargs addlicense
.PHONY: license_add

# cicd_linux is self-contained: downloads the ORT binary, creates the
# unversioned symlink that dlopen('libonnxruntime.so') needs in JIT mode, then
# runs dart test and coverage DIRECTLY in the same shell that exported
# LD_LIBRARY_PATH — avoiding a sub-make boundary that does not reliably
# propagate the variable to dart test on all platforms.
# Run locally with:
#   make container_test   (executes inside a Podman Linux container)
#   make cicd_linux       (runs directly on a Linux host with Dart installed)
cicd_linux:
	cd $(BETTO_PKG) && dart pub global activate coverage
	cd $(BETTO_PKG) && dart pub get
	$(MAKE) --no-print-directory license_check format_check analyze
	@cd $(BETTO_PKG) && \
	  ORT_VER=$$(python3 -c "import json,platform; m=platform.machine(); k='linux-aarch64' if m=='aarch64' else 'linux-x64'; print(json.load(open('version_onnx.json'))['platforms'][k]['version'])"); \
	  ORT_CACHE=".dart_tool/betto_onnxrt/$$ORT_VER"; \
	  mkdir -p "$$ORT_CACHE"; \
	  ln -sf "libonnxruntime.so.$$ORT_VER" "$$ORT_CACHE/libonnxruntime.so"; \
	  export LD_LIBRARY_PATH="$$(pwd)/$$ORT_CACHE$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}"; \
	  dart test && \
	  dart test --coverage-path=coverage/lcov.info && \
	  rm -rf site/coverage && \
	  mkdir -p site/coverage && \
	  genhtml coverage/lcov.info -o site/coverage
.PHONY: cicd_linux

cicd_macos: prepare_flutter test doc macos_test
.PHONY: cicd_macos

cicd_windows: prepare_dart test
.PHONY: cicd_windows

# Run ORT inference tests on Linux (pure Dart — does not require Flutter).
# Requires dart pub get to have been run (ORT binary staged in cache).
# Strips the leading 'v' from VERSION_ONNX to match the cache directory name
# (e.g. v1.22.0 → 1.22.0), identical to the strip done in cicd_linux.
# In CI, cicd_linux already exercises real ORT inference — this target is for
# local developer use and isolated inference-only runs.
# Usage: make linux_test
linux_test:
	@cd $(BETTO_PKG) && \
	  ORT_VER=$$(cat VERSION_ONNX); \
	  ORT_VER=$${ORT_VER#v}; \
	  ORT_CACHE=".dart_tool/betto_onnxrt/$$ORT_VER"; \
	  ln -sf "libonnxruntime.so.$$ORT_VER" "$$ORT_CACHE/libonnxruntime.so"; \
	  export LD_LIBRARY_PATH="$$(pwd)/$$ORT_CACHE$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}"; \
	  dart test test/onnx_session_test.dart
.PHONY: linux_test

# Run ORT inference tests on Windows (pure Dart — does not require Flutter).
# Requires dart pub get to have been run and .dart_tool/betto_onnxrt/{ver}/
# to be on PATH so DynamicLibrary.open('onnxruntime.dll') succeeds.
# Usage: make windows_test
windows_test:
	cd $(BETTO_PKG) && dart test test/onnx_session_test.dart
.PHONY: windows_test

# Run integration tests on macOS (requires the ORT dylib to be staged by the
# native-assets hook — run `dart pub get` first to trigger it).
# Usage: make macos_test
macos_test:
	cd $(BETTO_ITA) && \
	  flutter pub get && \
	  flutter test integration_test/onnxrt_test.dart --device-id macos
.PHONY: macos_test

# Run integration tests on a connected iOS simulator.
# This is the primary tool for the Phase 1 iOS XCFramework spike (Q1).
# Requires Xcode and a simulator reachable via `flutter devices`.
# Usage: make ios_test
ios_test:
	cd $(BETTO_ITA) && \
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
	cd $(BETTO_ITA) && \
	  flutter pub get && \
	  flutter emulators --launch $(EMULATOR_ANDROID) ||true && \
	  $(ADB_BINARY_PATH)/adb wait-for-device && \
	  flutter test integration_test/onnxrt_test.dart --device-id emulator-5554
.PHONY: android_test
