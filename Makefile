# Root Makefile — monorepo compositor.
# Composes per-package .mk fragments and owns cross-package targets.
# Per-package targets (dart, test, doc, license, etc.) are defined in:
#   packages/betto_onnxrt/betto_onnxrt.mk
#   packages/betto_onnxrt_ios/betto_onnxrt_ios.mk

.DEFAULT_GOAL := default

include site.mk
include packages/betto_onnxrt/betto_onnxrt.mk
include packages/betto_onnxrt_ios/betto_onnxrt_ios.mk

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

# BEGIN: Cross-package targets

default: clean prepare license_check format analyze analyze_ios test coverage doc_site
.PHONY: default

# CI top-level alias — delegates to the full default gate.
cicd: default
.PHONY: cicd

# clean: full clean including Flutter build outputs from both packages.
clean: clean_dart clean_ios
	cd $(BETTO_ITA) && flutter clean
.PHONY: clean

pre_commit: format_check analyze analyze_ios license_check test check_ios_version
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
	@IOS_VER=$$(python3 -c "import json,sys; d=json.load(open('packages/betto_onnxrt/version_onnx.json')); print(d['platforms']['ios']['version'])"); \
	SPM_VER=$$(grep 'exact:' packages/betto_onnxrt_ios/ios/betto_onnxrt_ios/Package.swift | grep -o '"[0-9][^"]*"' | tr -d '"'); \
	if [ "$$IOS_VER" != "$$SPM_VER" ]; then \
	  echo "ERROR: version_onnx.json ios.version ($$IOS_VER) does not match Package.swift exact: ($$SPM_VER)"; \
	  echo "       Update packages/betto_onnxrt_ios/ios/betto_onnxrt_ios/Package.swift to exact: \"$$IOS_VER\""; \
	  exit 1; \
	fi; \
	echo "check_ios_version: OK ($$IOS_VER)"
.PHONY: check_ios_version

# END: Cross-package targets

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
