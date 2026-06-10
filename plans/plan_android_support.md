# Android ORT Support — Hook verification and SHA-256 checksums

**Status**: Questions

**PR link**: _(pending)_

## Problem statement

`_buildAndroid` in `hook/build.dart` is fully implemented: it downloads the ORT
Android AAR from Maven Central, extracts the per-ABI `.so` (`arm64-v8a`,
`x86_64`, `armeabi-v7a`, `x86`), and emits a `CodeAsset` with
`DynamicLoadingBundled`. Unlike iOS, Android ORT ships as a real `.so` (dynamic
library), so no architectural workaround is needed — native-assets
`DynamicLoadingBundled` should work directly.

Two gaps remain before Android support can be considered verified:

1. **SHA-256 checksums are all-zeros placeholders.** `_sha256Manifest` in
   `hook/build.dart` has `'onnxruntime-android-1.22.0.aar': '0000…'`. The hook
   allows development to proceed with placeholder checksums, but they must be
   computed and filled in before the Android path can be trusted.

2. **No Android integration test.** `make ios_test` and `make macos_test` verify
   those paths end-to-end via the `integration_test_app`. There is no equivalent
   `make android_test`. The `integration_test_app` also has no Android platform
   directory.

Android testing is developer-run via the Makefile, not CI (consistent with
`ios_test`).

## Open questions

- [ ] **Q1 — Maven Central AAR URL for v1.22.0.** The hook uses:
  `https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.22.0/onnxruntime-android-1.22.0.aar`
  Confirm this URL resolves and the AAR is present at Maven Central for v1.22.0
  before computing the SHA-256. (The equivalent GitHub Releases artifact is
  absent from the v1.22.0 asset list, per the comment in `hook/build.dart`.)

- [ ] **Q2 — Which ABI to target for the emulator integration test.** The
  standard Android emulator on an Apple Silicon Mac runs `arm64-v8a`. An x86_64
  emulator can also be used. Confirm the target ABI and record it in the Makefile
  variable (analogous to `EMULATOR_IOS` / `EMULATOR_IOS_DEVICE`).

- [ ] **Q3 — `minSdkVersion` for ORT v1.22.0.** The ORT Android AAR requires a
  minimum SDK version (typically API 24 or higher for recent ORT releases).
  `flutter create --platforms android` generates a default `minSdkVersion` of 21.
  Confirm the required `minSdkVersion` for ORT v1.22.0 and add a checklist step
  to set it in `integration_test_app/android/app/build.gradle` before attempting
  a build.

- [ ] **Q4 — SHA-256 verification target: extracted `.so` or the AAR archive?**
  `_ensureFile` currently verifies the SHA-256 of the *extracted* `.so`, not
  the downloaded AAR. Decide whether this is acceptable or whether the plan
  should add a separate pre-extraction AAR checksum step (analogous to how
  desktop verifies the `.tgz`/`.zip` directly).

## Investigation

### Hook implementation status

`_buildAndroid` is complete:
- Reads `VERSION_ONNX` for the version string.
- Constructs the Maven Central URL for the versioned AAR.
- Calls `_ensureFile` which handles download, SHA-256 verification (bypassed for
  all-zeros placeholder), and atomic temp-rename.
- Extracts `jni/{abi}/libonnxruntime.so` from the AAR (ZIP format, handled by
  `_extractFromZip`).
- Emits the `.so` as a `CodeAsset` with `DynamicLoadingBundled` and asset name
  `src/ort_library.dart` (same as desktop).

`runtime.dart` should require no changes for Android — `DynamicLoadingBundled`
means the Flutter build system places the `.so` in `jniLibs/` and the
native-assets runtime opens it via the standard code-asset mechanism.

### SHA-256 computation

Run once after confirming Q1:

```bash
curl -fsSL \
  https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.22.0/onnxruntime-android-1.22.0.aar \
  | sha256sum
```

Update `_sha256Manifest` in `hook/build.dart` with the result.

### `integration_test_app` Android setup

`integration_test_app` currently has macOS and iOS platform directories. Android
needs to be added with:

```bash
cd integration_test_app
flutter create --platforms android .
```

The existing `integration_test/onnxrt_test.dart` should run unchanged on Android
since it uses `OnnxRuntime.load()` and the identity-graph `.onnx` fixture — no
platform-specific code.

### `make android_test` target

Follows the `ios_test` pattern. The Android emulator device ID is typically
`emulator-5554` when one emulator is running; expose it as a Makefile variable
for flexibility.

```make
export EMULATOR_ANDROID ?= emulator-5554

android_test:
	cd integration_test_app && \
	  flutter pub get && \
	  flutter test integration_test/onnxrt_test.dart --device-id $(EMULATOR_ANDROID)
.PHONY: android_test
```

The developer must have an Android emulator running before invoking the target
(same expectation as `ios_test` with the iOS simulator).

## Implementation plan

### Phase 1 — SHA-256 checksums (resolves Q1)

- [ ] Confirm the Maven Central AAR URL resolves for v1.22.0 (Q1)
- [ ] Compute SHA-256: `curl -fsSL <url> | sha256sum`
- [ ] Replace the all-zeros placeholder in `_sha256Manifest` with the real digest
- [ ] Run `make pre_commit` to confirm no regressions

### Phase 2 — Android integration test (resolves Q2)

- [ ] `flutter create --platforms android .` inside `integration_test_app/`
- [ ] Confirm `integration_test/onnxrt_test.dart` requires no Android-specific changes
- [ ] Add `EMULATOR_ANDROID` variable and `android_test` target to `Makefile`
  (after the `ios_test` block, following the same pattern)
- [ ] Add `emulators_stop_android` / `emulator_android_create` helper targets if needed
- [ ] Run `make android_test` on an arm64-v8a emulator; confirm hook downloads
  the AAR, extracts `jni/arm64-v8a/libonnxruntime.so`, and the integration
  test passes

### Phase 3 — Documentation

- [ ] Update `CLAUDE.md` Android status note (currently absent — CLAUDE.md only
  mentions iOS as unsupported; Android should be noted as supported once verified)
- [ ] Update `README.md` with Android usage notes if any consumer setup is needed
- [ ] Open PR

## Summary

_To be completed after implementation._

## Reviews

### Review 1: 2026-06-10

**Problem Statement Assessment**

The problem is real and correctly scoped. Two concrete, well-defined gaps block Android from being production-ready: absent SHA-256 checksums and no integration test. The plan correctly identifies that the hook implementation itself (`_buildAndroid`) is complete and that the Android `.so` distribution model (Maven AAR with `DynamicLoadingBundled`) is architecturally sound — unlike iOS, no workaround is needed. The scope is tight and the work is proportionate.

**Proposed Solution Assessment**

The three-phase structure (checksums → integration test → docs) is logical and the phasing is correct — you cannot run the integration test meaningfully until real checksums exist. The Makefile target proposed closely mirrors `ios_test`, which is the right pattern to follow.

However, there are four issues that need resolution before this can be marked `Investigated`:

1. **SHA-256 is verified on the extracted `.so`, not the AAR.** For desktop, `_ensureFile` verifies SHA-256 of the extracted dylib (the post-extraction content). The AAR itself is not checksum-verified — only the inner `.so` is. This diverges from the typical supply-chain model where you verify what you downloaded, not just what you extracted. The investigation section presents the SHA-256 command as `curl -fsSL <url> | sha256sum` (piping the download directly, never writing the AAR to disk), which means only the `.so` digest can be computed via the hook's extraction path. This is worth a deliberate decision rather than an oversight — added as Q4.

2. **`_isValid` fast-path silently skips re-verification when checksums change.** When the all-zeros placeholder is replaced with a real digest in `_sha256Manifest`, any developer who already has a cached `.so` file (downloaded under the placeholder regime) will hit the fast path at `hook/build.dart` line 478: `if (expectedHex == '0' * 64) return true`. After the placeholder is replaced, the fast path no longer applies and the file *will* be re-verified — this is actually correct behaviour. But the issue is the reverse: a developer with a cached file from a zero-placeholder run who *never* deletes the cache will have their existing `.so` accepted without re-verification only until checksums are filled in. Once checksums are real, `_isValid` will re-check. This means the transition from placeholder to real checksums is safe but relies on deleting or re-downloading the cache, and the implementation checklist should make this explicit (add a cache-clearing step after filling in checksums so that real verification is exercised end-to-end).

3. **`flutter create --platforms android` will set `minSdkVersion` to 21 by default, but ORT v1.22.0 requires API ≥ 24 (and may require higher).** If the integration test is run against a mismatched `minSdkVersion`, the APK will fail to build or the `.so` will fail to load at runtime with a misleading error. The plan has no checklist item to confirm or set the correct `minSdkVersion`. This is a real blocker that will surface during Phase 2 — added as Q3.

4. **Q1 framing is backwards.** The plan says "confirm the URL resolves before computing SHA-256." In practice you confirm the URL by downloading the artifact, which is the same step as computing the SHA-256. There is no separate confirmation step needed. The implementation checklist item "Confirm the Maven Central AAR URL resolves" is redundant — replace it with "Download and compute SHA-256 of the Maven Central AAR; confirm download succeeds (implicitly confirms URL)." This is minor but keeps the checklist clean.

**Architecture Fit**

**Library Architecture** — this plan touches only `hook/build.dart`, `integration_test_app/`, and `Makefile`. No `lib/` changes are proposed. The library-architecture skill is not applicable: `betto_onnxrt` is a pure-Dart library with no Flutter dependency in `lib/`, no presentation layer, and no public API surface changes in this plan. The plan correctly avoids touching `runtime.dart` for Android (no changes needed because `DynamicLoadingBundled` handles placement transparently). Architecture fit is good.

**Design/Inclusivity** — not applicable; this plan has no UI component.

**Risk & Edge Cases**

- **Cache-clearing after checksum fill-in** (mentioned above under point 2): the test validating real checksum verification requires a clean cache. Without an explicit cache-clear step, a developer could unknowingly validate the hook against a previously-accepted file rather than freshly verifying the downloaded artifact.

- **`integration_test_app/android/app/build.gradle` `minSdkVersion`** (mentioned above under point 3): no checklist item exists for this. Builds will fail silently or with a confusing error.

- **`emulator_android_create` and `emulators_stop_android` left as "if needed".** The `ios_test` section of the Makefile has both `emulator_ios_create` and `emulators_stop_ios` as concrete `.PHONY` targets. Android consistency demands the same. The plan's phrasing "if needed" will lead to a half-complete Makefile. Make them mandatory additions, not optional.

- **x86_64 vs arm64-v8a on Apple Silicon.** Apple Silicon Macs run arm64-v8a emulators natively but can also run x86_64 emulators in slow emulation. The plan notes this but leaves Q2 unresolved. For the Makefile variable to be meaningful, a default must be established.

- **No CI path for Android.** The plan explicitly states Android testing is developer-run (consistent with `ios_test`), which is fine. However CLAUDE.md should reflect this explicitly: currently CLAUDE.md does not mention Android at all. Phase 3 covers this.

- **AAR ZIP64 edge case.** The custom `_extractFromZip` implementation uses 32-bit central directory offset fields (`_readUint32LE`). The Maven Central ORT AAR is approximately 600 MB uncompressed. If the AAR uses ZIP64 extensions (required when file sizes exceed 4 GB or offsets exceed 4 GB), `_extractFromZip` will misread the EOCD. For a ~600 MB AAR this is unlikely but worth a smoke test — if the AAR already uses ZIP64, the extractor will throw `StateError('Invalid ZIP archive ... EOCD not found')`. Not a blocker for this plan, but worth noting in the investigation section so a future reviewer is aware.

**Recommendations**

1. Add Q3 and Q4 to `## Open questions` before marking `Investigated`. Both are blockers: Q3 (minSdkVersion) will cause a build failure during Phase 2, and Q4 (verification target) is a supply-chain decision that should be deliberate.

2. Add an explicit checklist step to Phase 1: "Delete `.dart_tool/betto_onnxrt/{version}/android/` cache directory and re-run the hook to confirm real checksum verification fires and passes." Without this, the implementation never exercises the actual SHA-256 gate.

3. Tighten Phase 1, step 1: change "Confirm the Maven Central AAR URL resolves for v1.22.0 (Q1)" to "Download the Maven Central AAR and compute its SHA-256 — a successful download confirms the URL." The current wording implies a separate out-of-band confirmation step that doesn't add value.

4. Make `emulators_stop_android` and `emulator_android_create` mandatory checklist items in Phase 2, not "if needed."

5. Record a specific `minSdkVersion` requirement in the investigation section once Q3 is resolved.

**Open questions**

- [ ] Q3 — `minSdkVersion` required by ORT v1.22.0 AAR. See Q3 in `## Open questions` above.
- [ ] Q4 — SHA-256 verification target (extracted `.so` vs. AAR). See Q4 in `## Open questions` above.
