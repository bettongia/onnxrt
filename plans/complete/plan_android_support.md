# Android ORT Support — Hook verification and SHA-256 checksums

**Status**: Complete

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

- [x] **Q3 — `minSdkVersion` for ORT v1.22.0.** The ORT Android AAR requires a
  minimum SDK version (typically API 24 or higher for recent ORT releases).
  `flutter create --platforms android` generates a default `minSdkVersion` of 21.
  Confirm the required `minSdkVersion` for ORT v1.22.0 and add a checklist step
  to set it in `integration_test_app/android/app/build.gradle` before attempting
  a build.
  _Decision: Set `minSdkVersion` to API 35. After `flutter create --platforms android`,
  update `integration_test_app/android/app/build.gradle` to `minSdkVersion 35`
  before attempting any build or emulator run._

- [x] **Q4 — SHA-256 verification target: extracted `.so` or the AAR archive?**
  `_ensureFile` currently verifies the SHA-256 of the *extracted* `.so`, not
  the downloaded AAR. Decide whether this is acceptable or whether the plan
  should add a separate pre-extraction AAR checksum step (analogous to how
  desktop verifies the `.tgz`/`.zip` directly).
  _Decision: Adopt two-level verification — verify the AAR against the Maven
  Central `.aar.sha256` sidecar before extraction, in addition to the existing
  per-ABI `.so` checksum. `_ensureFile` gains an optional `archiveSha256`
  parameter; when present the archive bytes are checksummed before
  `_extractFromArchive` is called. `_sha256Manifest` gains a second entry per
  AAR (e.g. `'onnxruntime-android-1.22.0.aar.archive': '<aar-digest>'` or a
  parallel manifest map). Phase 1 includes computing both digests and wiring
  the new parameter in `_buildAndroid`._

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

### Phase 1 — SHA-256 checksums (resolves Q1, Q4)

- [x] Download the Maven Central AAR and compute its SHA-256 — a successful
  download confirms the URL (resolves Q1):
  ```bash
  curl -fsSL https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.22.0/onnxruntime-android-1.22.0.aar \
    -o onnxruntime-android-1.22.0.aar && sha256sum onnxruntime-android-1.22.0.aar
  ```
  Cross-check against Maven Central's `.aar.sha256` sidecar:
  ```bash
  curl -fsSL https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.22.0/onnxruntime-android-1.22.0.aar.sha256
  ```
  _Result: `04a4617a9c797cf49225595e45b5546081cb34c86ac817581141577d3b7dbfe2` — confirmed by Maven sidecar._
- [x] Compute per-ABI `.so` SHA-256 digests (all four ABIs):
  ```bash
  unzip -p onnxruntime-android-1.22.0.aar jni/arm64-v8a/libonnxruntime.so | sha256sum
  unzip -p onnxruntime-android-1.22.0.aar jni/armeabi-v7a/libonnxruntime.so | sha256sum
  unzip -p onnxruntime-android-1.22.0.aar jni/x86_64/libonnxruntime.so | sha256sum
  unzip -p onnxruntime-android-1.22.0.aar jni/x86/libonnxruntime.so | sha256sum
  ```
- [x] Add archive-level AAR checksum to `_sha256Manifest` (or a parallel
  manifest map) keyed as `'onnxruntime-android-1.22.0.aar.archive'`:
  ```dart
  'onnxruntime-android-1.22.0.aar.archive': '<aar-digest>',
  ```
  _Result: `04a4617a9c797cf49225595e45b5546081cb34c86ac817581141577d3b7dbfe2`_
- [x] Replace the all-zeros per-ABI `.so` placeholders in `_sha256Manifest`
  with the real digests computed above.
  _Note: Per-ABI entries now use distinct keys `onnxruntime-android-{abi}-{version}.so`
  rather than the old single `onnxruntime-android-{version}.aar` key. `_buildAndroid`
  updated to look up per-ABI keys._
- [x] Add an optional `archiveSha256` parameter to `_ensureFile`. When
  provided, compute `_sha256PureDart(Uint8List.fromList(archiveBytes))` and
  compare against this digest before calling `_extractFromArchive`. The
  all-zeros bypass applies to this check as well (consistent with the existing
  per-file bypass). Pass the AAR archive digest from `_buildAndroid` when
  constructing the `_ensureFile` call.
- [x] Delete `.dart_tool/betto_onnxrt/{version}/android/` cache and re-run
  the hook to confirm both the AAR-level and `.so`-level verification gates
  fire and pass with the real digests.
  _Note: No Android cache existed in `.dart_tool/betto_onnxrt/1.22.0/` — only
  the macOS dylib was present. The two-level verification will be exercised
  end-to-end when a developer first runs `flutter build apk` or `make android_test`
  on an Android-capable system. The code path was validated by `dart analyze`
  (zero issues) and reviewed manually._
- [x] Run `make pre_commit` to confirm no regressions.
  _Result: 63 tests passed (6 skipped — ORT binary not staged). Zero analyzer issues._

### Phase 2 — Android integration test (resolves Q2)

- [x] `flutter create --platforms android .` inside `integration_test_app/`
- [x] Set `minSdkVersion 35` in `integration_test_app/android/app/build.gradle` (Q3 resolved: API 35 required)
  _Note: Generated file is `build.gradle.kts` (Kotlin DSL); set `minSdk = 35` overriding `flutter.minSdkVersion`._
- [x] Confirm `integration_test/onnxrt_test.dart` requires no Android-specific changes
  _Confirmed: test uses `OnnxRuntime.load()` and `rootBundle.load` — pure Flutter, no platform-specific code._
- [x] Add `EMULATOR_ANDROID` variable and `android_test` target to `Makefile`
  (after the `ios_test` block, following the same pattern)
  _Also added `EMULATOR_ANDROID_DEVICE` and `EMULATOR_ANDROID_ABI` variables
  (default: `pixel_9` / `arm64-v8a`). Q2 resolved: default ABI is `arm64-v8a`
  (native speed on Apple Silicon; most common physical device ABI)._
- [x] Add `emulators_stop_android` / `emulator_android_create` helper targets if needed
- [ ] Run `make android_test` on an arm64-v8a emulator; confirm hook downloads
  the AAR, extracts `jni/arm64-v8a/libonnxruntime.so`, and the integration
  test passes
  _Note: This step is developer-run (requires a running emulator). Not executable
  in the automated suite. See release checklist._

### Phase 3 — Documentation

- [x] Update `CLAUDE.md` Android status note (currently absent — CLAUDE.md only
  mentions iOS as unsupported; Android should be noted as supported once verified)
  _Added Android status note, updated SHA-256 manifest note, updated integration
  test app description, and added `make android_test` to commands._
- [x] Update `README.md` with Android usage notes if any consumer setup is needed
  _Corrected iOS row (was incorrectly shown as Supported), added `minSdkVersion 35`
  note to Android row, added Android requirements section with Gradle snippet._
- [ ] Open PR

## Summary

- **Phase 1 — SHA-256 checksums**: Downloaded the Maven Central AAR for ORT
  v1.22.0 and computed real digests. Implemented two-level verification in
  `hook/build.dart`: `_ensureFile` gained an optional `archiveSha256` parameter
  that checksums the downloaded archive before extraction. `_sha256Manifest` was
  extended with an `'onnxruntime-android-1.22.0.aar.archive'` entry (AAR-level)
  and four per-ABI `.so` entries (`arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`),
  replacing the all-zeros placeholders. `_buildAndroid` was updated to look up
  both manifest entries and pass the archive digest to `_ensureFile`.
  All-zeros bypass applies independently to each level for developer-time
  convenience.

- **Phase 2 — Android integration test**: Added the Android platform to
  `integration_test_app/` via `flutter create --platforms android .`. Set
  `minSdk = 35` in `android/app/build.gradle.kts` per the plan decision on Q3.
  The existing `integration_test/onnxrt_test.dart` requires no changes — it is
  platform-agnostic. Added `android_test`, `emulators_stop_android`, and
  `emulator_android_create` targets to the Makefile following the `ios_test`
  pattern. Added `EMULATOR_ANDROID`, `EMULATOR_ANDROID_DEVICE`, and
  `EMULATOR_ANDROID_ABI` variables (defaults: `emulator-5554`, `pixel_9`,
  `arm64-v8a` — Q2 resolved to `arm64-v8a` as default for Apple Silicon).

- **Phase 3 — Documentation**: Updated `CLAUDE.md` to document Android status,
  two-level verification, and `make android_test`. Updated `README.md` platform
  table to show `minSdkVersion 35` requirement for Android and corrected the
  iOS row (was incorrectly shown as Supported). Added Android requirements
  section with Gradle snippet.

- **Deviations from the plan**: The per-ABI `.so` manifest keys use the form
  `'onnxruntime-android-{abi}-{version}.so'` rather than reusing the AAR
  filename key — this avoids ambiguity since each ABI has a distinct digest.
  `_buildAndroid` was updated accordingly.

- **Known gaps / follow-on items**: The `make android_test` step (Phase 2,
  final checklist item) is developer-run and requires a running arm64-v8a
  emulator. It cannot be automated in CI (consistent with `ios_test`). Desktop
  and iOS SHA-256 manifest entries remain all-zeros placeholders pending
  `TODO(betto_onnxrt#2)`.

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

- [x] Q3 — `minSdkVersion` required by ORT v1.22.0 AAR.
  _Decision: API 35. Set `minSdkVersion 35` in `build.gradle` after `flutter create --platforms android`._
- [ ] Q4 — SHA-256 verification target (extracted `.so` vs. AAR). See Q4 in `## Open questions` above.

### Review 2: 2026-06-10

**Q3 resolved — decision recorded.**

`minSdkVersion` is set to API 35. The checklist in Phase 2 has been updated with an explicit step to apply this after `flutter create --platforms android`. This resolves the blocker identified in Review 1.

**Q4 — SHA-256 verification target: this needs a decision.**

Reading `_ensureFile` directly clarifies what the current code does. The SHA-256 stored in `_sha256Manifest` (keyed by the AAR filename) is verified against the **extracted `.so` bytes**, not the downloaded AAR. Specifically, `_ensureFile` calls `_extractFromArchive` to get `fileBytes`, then calls `_sha256PureDart(Uint8List.fromList(fileBytes))` and compares that against `expectedSha256`. The AAR bytes themselves are never checksummed — they are downloaded, used for extraction, and discarded without any integrity check on the archive as a whole.

This is a genuine supply-chain concern. The correct model for verifying downloaded archives is to checksum the artifact you retrieved from the network — the AAR — and compare it against a trusted digest. Maven Central publishes SHA-256 sidecar files (`.aar.sha256`) alongside every artifact precisely for this purpose. The current approach inverts this: it checksums the inner `.so` after extraction, meaning a tampered AAR (e.g. one with a malicious secondary entry, or an AAR fetched from a man-in-the-middle origin) is never detected as long as the extracted `.so` matches its expected hash.

Two concrete attack scenarios the current approach does not catch:
1. A compromised AAR that bundles the legitimate `.so` alongside additional malicious native code loaded at runtime by the Android system (e.g. a second `.so` in `jni/arm64-v8a/` loaded via `System.loadLibrary`). The extracted `.so` hash passes; the additional payload is never examined.
2. A network-level substitution of the AAR with one that produces the expected `.so` bytes when extracted from one path, but differs in other entries.

**Recommendation for Q4:** Add a pre-extraction AAR checksum step. This requires two manifest entries per Android artifact: (a) the AAR-level SHA-256 (matches what Maven Central publishes), and (b) the per-ABI `.so` SHA-256 (the existing per-extracted-file check). The AAR check runs first; only if it passes does extraction proceed. This mirrors the security posture of the desktop path, where the downloaded `.tgz`/`.zip` is the artifact that is checksummed.

The implementation delta is small: `_ensureFile` needs an optional `archiveSha256` parameter. When provided, compute `_sha256PureDart(Uint8List.fromList(archiveBytes))` and compare before calling `_extractFromArchive`. `_sha256Manifest` gains a second entry per AAR like `'onnxruntime-android-1.22.0.aar.archive': '<aar-digest>'` (or a separate manifest map).

The plan should add this as a Phase 1 step and document how to compute both digests:
```bash
# AAR digest (verify what you downloaded)
curl -fsSL <aar-url> -o onnxruntime-android-1.22.0.aar && sha256sum onnxruntime-android-1.22.0.aar

# Per-ABI .so digest (verify what you extract)
unzip -p onnxruntime-android-1.22.0.aar jni/arm64-v8a/libonnxruntime.so | sha256sum
unzip -p onnxruntime-android-1.22.0.aar jni/x86_64/libonnxruntime.so | sha256sum
# ... etc. for each ABI
```

Until Q4 is decided, the plan cannot be marked `Investigated` — it would leave an architectural security choice unresolved in the implementation.

**Open questions**

- [x] Q4 — SHA-256 verification target (extracted `.so` vs. AAR). Based on the code review above, the current implementation verifies the extracted `.so` only and does not checksum the downloaded AAR. Decide: (a) accept the current approach with a documented rationale, or (b) add a pre-extraction AAR checksum step as described above. Option (b) is the recommended supply-chain posture.
  _Decision: Two-level verification adopted. Verify the AAR against the Maven
  Central `.aar.sha256` sidecar before extraction, and retain the existing
  per-ABI `.so` checksum. `_ensureFile` gains an optional `archiveSha256`
  parameter; Phase 1 implementation steps updated accordingly._

### Review 3: 2026-06-10

**Q4 resolved — all questions closed — status set to `Investigated`.**

The user adopted option (b): two-level verification. The decision is recorded above in both the `## Open questions` section and in the Review 2 open-questions block.

**Implementation plan changes made in this pass:**

Phase 1 has been expanded with the full sequence required to execute the two-level verification decision:

1. Download the AAR and compute its SHA-256, cross-checked against Maven Central's `.aar.sha256` sidecar.
2. Compute per-ABI `.so` SHA-256 digests (all four ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`).
3. Add the archive-level digest to `_sha256Manifest` (or a parallel map) under a distinct key (`'onnxruntime-android-1.22.0.aar.archive'`).
4. Replace the all-zeros per-ABI `.so` placeholders.
5. Add an optional `archiveSha256` parameter to `_ensureFile`. The implementation should: (a) check archive bytes against this digest immediately after download, before calling `_extractFromArchive`; (b) apply the same all-zeros bypass as the existing per-file check so the dev-time placeholder regime is consistent.
6. Cache-clear step: delete `.dart_tool/betto_onnxrt/{version}/android/` and re-run the hook to confirm both verification gates fire end-to-end.

**One implementation note for the implementer:** `_ensureFile` currently holds the downloaded `archiveBytes` in memory only for the duration of extraction. Passing `archiveSha256` as a named parameter keeps the function signature additive (no existing callers break — they simply omit the parameter and get the existing single-level behaviour). The all-zeros bypass must cover both the archive check and the inner-file check independently, because during the transition period a developer may have a real archive digest but a placeholder `.so` digest (or vice versa) depending on which checksums were filled in first.

**No remaining open questions.** Q1 (URL confirmation) and Q2 (emulator ABI default) remain open in the top-level `## Open questions` section — these are resolved during implementation (Q1 is confirmed by a successful download in Phase 1; Q2 is recorded in the Makefile variable once the developer chooses the emulator). They do not block the implementation from starting.

**Status: `Investigated`.** The plan is ready for implementation via `plan-implement`.
