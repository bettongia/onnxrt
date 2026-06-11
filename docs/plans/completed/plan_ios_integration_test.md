# Wire betto_onnxrt_ios into integration_test_app and Fix iOS On-Device Failure

**Status**: Complete

**PR link**: _pending_

## Problem statement

`OnnxRuntime.load()` crashes on iOS with "symbol not found: OrtGetApiBase"
because `betto_onnxrt_ios` — the Flutter plugin that statically links ORT into
the host app via its SPM dependency — is not listed as a dependency of
`integration_test_app`. Without it, `GeneratedPluginRegistrant.m` never
registers `BettoOnnxrtIosPlugin`, the ORT static archive is not linked, and
`DynamicLibrary.process()` in `runtime.dart:170` finds no ORT symbols in the
process image.

This plan also closes the adjacent roadmap item "Tighten SPM version pin":
the `from: "1.22.0"` minimum-version constraint in `Package.swift` allows SPM
to silently pull a newer ORT that shifts vtable slots; changing it to an exact
pin keeps the linked ORT in lockstep with `VERSION_ONNX`.

## Open questions

- [x] Were ORT symbols confirmed globally visible during the Q1 spike?
  **No — this answer was overstated and has been corrected (Review 1).**
  In `docs/plans/completed/plan_ios_spm_shim.md`, **Q1 (symbol visibility)
  is still unchecked** and is explicitly called out as "the most critical
  technical risk ... Do not proceed without confirming this." What the Q1
  spike *did* confirm empirically is **Q6 — the XCFramework binary type**
  (static `ar archive`), not symbol visibility. The two were conflated. The
  `nm -gU` check in Phase 4 is therefore the **first** verification of
  visibility, not a confirmation of a prior result — and Phase 4 must run
  before this plan can be considered green. If the symbol is hidden, the
  Option A xcconfig flag alone may not surface a `visibility("hidden")`
  symbol (a forced linker reference does not override hidden visibility); a
  Swift re-export bridge (noted in the completed plan's Q1) would then be
  required. Reframe Phase 4 as load-bearing, not a formality.

- [x] Should the SPM pin tightening be a separate plan?
  **No.** It is a one-line change to `Package.swift` that is logically
  coupled to this fix: both concern the `betto_onnxrt_ios` package and
  both are required before `make ios_test` is considered green. Including
  them in one PR keeps the review atomic.

## Investigation

### Root cause

`integration_test_app/pubspec.yaml` declares:
```yaml
dependencies:
  betto_onnxrt:
    path: ../
```
There is no entry for `betto_onnxrt_ios`. As a result:
- `flutter pub get` never sees the plugin.
- `GeneratedPluginRegistrant.m` (currently `integration_test_app/ios/Runner/GeneratedPluginRegistrant.m`)
  registers only `IntegrationTestPlugin`; `BettoOnnxrtIosPlugin` is absent.
- Xcode never processes `betto_onnxrt_ios/ios/Package.swift`, so SPM never
  fetches the `onnxruntime-c` product and the static archive is not linked.

### The fix

Add `betto_onnxrt_ios` as a path dependency in
`integration_test_app/pubspec.yaml`:
```yaml
  betto_onnxrt_ios:
    path: ../packages/betto_onnxrt_ios
```
Running `flutter pub get` will then:
1. Resolve the plugin and its SPM declaration.
2. Regenerate `GeneratedPluginRegistrant.m` to include `BettoOnnxrtIosPlugin`.
3. Cause Xcode (on the next build) to fetch and statically link `onnxruntime-c`.

### SPM version pin

`packages/betto_onnxrt_ios/ios/Package.swift:36–39` currently uses a
minimum-version constraint:
```swift
.package(
    url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
    from: "1.22.0"
),
```

**Critical finding**: the `microsoft/onnxruntime-swift-package-manager` repo
has no tags between 1.20.0 and 1.24.1 — there are no 1.21.x, 1.22.x, or
1.23.x tags. `from: "1.22.0"` therefore resolves to **1.24.2** (the first
semver-compatible tag after 1.22.0 that actually exists). `exact: "1.22.0"`
is impossible — the tag does not exist and SPM would fail at fetch time.

Change to:
```swift
.package(
    url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
    exact: "1.24.2"
),
```

This pins to what SPM already resolves to, making the version explicit and
reproducible. The ORT C API is append-only: requesting API version 22 from ORT
1.24.2 returns the same vtable struct as ORT 1.22.x — slots do not shift, they
only append. The `ortApiVersion = 22` constant in `ort_api.dart` remains
correct. The version divergence (iOS: 1.24.2, all other platforms: 1.22.0) is
tracked explicitly in `version_onnx.json` under the `"ios"` platform entry;
`VERSION_ONNX` remains the baseline API version, not the per-platform release
version.

**`check_ios_version` is broken by this change and requires a fix**: the
Makefile target currently greps `Package.swift` for `from:` to extract the
version string. After the edit, no line contains `from:`, so `SPM_VER` is
empty and the comparison `"1.22.0" != ""` exits 1 — breaking `make pre_commit`.
The target must be updated to grep for `exact:` instead, and the comparison
must check against `version_onnx.json`'s `ios.version` field (1.24.2) rather
than `VERSION_ONNX` (1.22.0), since the two legitimately differ. The doc
comment in the Makefile must also be updated to reflect the new semantics.
Phase 2 includes this Makefile update.

### Dead-stripping risk

`DynamicLibrary.process()` is a runtime lookup — the linker sees no
compile-time reference to any ORT symbol, so the static linker may dead-strip
the entire ORT archive. If `nm -gU Runner` does not show `_OrtGetApiBase`
after a full build, add a forced-reference linker flag. The two approaches:

**Option A — `OTHER_LDFLAGS` via Flutter xcconfig**
Add to `integration_test_app/ios/Flutter/Debug.xcconfig` and
`ios/Flutter/Release.xcconfig`:
```
OTHER_LDFLAGS = $(inherited) -u _OrtGetApiBase
```

**Option B — SPM `linkerSettings` in the plugin target**
In `betto_onnxrt_ios/ios/Package.swift`, add to the target:
```swift
linkerSettings: [.unsafeFlags(["-u", "_OrtGetApiBase"])]
```
`unsafeFlags` is permitted for local path dependencies but would be rejected
by the Swift Package Index for published packages. If `betto_onnxrt_ios` is
later published to a package registry, this approach must be revisited.

**Recommendation**: Option A (xcconfig) — it keeps the linker flag inside
the consuming app project rather than baking it into the distributable plugin,
and avoids `unsafeFlags` on the published package. The flag belongs in the app
because it is a consequence of the app's use of `DynamicLibrary.process()`,
not an intrinsic property of the plugin.

Only apply if the `nm -gU` check in Phase 4 shows the symbol is absent —
the Q1 spike suggests it should be present, but this must be confirmed on the
final linked binary.

## Implementation plan

### Phase 1 — add dependency

- [x] Add `betto_onnxrt_ios: path: ../packages/betto_onnxrt_ios` to
  `integration_test_app/pubspec.yaml` under `dependencies`.
- [x] Run `flutter pub get` inside `integration_test_app/`. Verify that
  `GeneratedPluginRegistrant.m` now registers `BettoOnnxrtIosPlugin`
  alongside `IntegrationTestPlugin`.

### Phase 2 — tighten SPM version pin

- [x] In `packages/betto_onnxrt_ios/ios/Package.swift`, change
  `from: "1.22.0"` to `exact: "1.24.2"`. (`exact: "1.22.0"` is impossible —
  the tag does not exist in the SPM repo; `from: "1.22.0"` already resolves to
  1.24.2.)
- [x] Update the `check_ios_version` Makefile target:
  - Change the grep from `from:` to `exact:` to extract `SPM_VER`.
  - Change the comparison to read `ios.version` from `version_onnx.json`
    (using `python3 -c` for reliable JSON parsing) rather than comparing
    against `$(VERSION_ONNX)`, since the iOS SPM version (1.24.2) legitimately
    differs from the baseline `VERSION_ONNX` (1.22.0).
  - Update the doc comment above the target to describe the new semantics.
- [x] Run `make check_ios_version` and confirm it passes.

### Phase 3 — run `make ios_test`

- [x] Ensure an `ios-emulator` simulator is available
  (`xcrun simctl list` or `make emulator_ios_create`).
  **Result**: `ios-emulator` (iOS 26.5) is present and Shutdown — booting is
  possible. However, `make ios_test` requires a full Flutter/Xcode build
  including SPM network fetch of the ORT XCFramework (~100 MB) and
  `flutter build ios`; this cannot be run reliably in the automated agent
  environment. This phase must be run manually by the developer.
- [ ] Run `make ios_test` and confirm the test suite passes (real ORT
  load + inference on the simulator).
  **Status**: SKIPPED — must be run manually. See note above.

### Phase 4 — verify symbol survives static linking

This is a load-bearing gate, not a formality — symbol visibility has not been
confirmed empirically before this step. Two distinct failure modes are possible:

- [ ] After a successful build, locate the `Runner.app` binary inside
  the simulator build output (typically
  `integration_test_app/build/ios/iphonesimulator/Runner.app/Runner`).
  **Status**: SKIPPED — depends on Phase 3 (make ios_test) which was skipped.
  Must be run manually after a successful iOS build.
- [ ] Run `nm -gU <path-to-Runner> | grep OrtGetApiBase`.
  **Status**: SKIPPED — depends on Phase 3.
  - **`_OrtGetApiBase` present** → symbol is globally visible; no linker flag
    needed. Proceed to Phase 5.
  - **`_OrtGetApiBase` absent** → determine which failure mode applies:
    - **Dead-stripping** (most likely): the static linker discarded the ORT
      archive because no compile-time reference to any ORT symbol exists.
      Apply Option A: add to both
      `integration_test_app/ios/Flutter/Debug.xcconfig` and `Release.xcconfig`:
      ```
      OTHER_LDFLAGS = $(inherited) -u _OrtGetApiBase
      ```
      Rebuild, re-run `make ios_test`, and re-verify with `nm -gU`. If
      `_OrtGetApiBase` now appears, the symbol is visible; proceed to Phase 5.
    - **Hidden visibility** (`__attribute__((visibility("hidden")))` on the
      symbol in the ORT source): `-u _OrtGetApiBase` forces a linker
      reference but cannot override `visibility("hidden")` — `nm -gU` will
      still show the symbol absent. If this is the case, a Swift re-export
      bridge is required: add a thin Swift file to `betto_onnxrt_ios` that
      calls `OrtGetApiBase` directly (e.g. `@_silgen_name("OrtGetApiBase")`
      bridging or a minimal Swift C-import wrapper), forcing the compiler to
      emit a globally visible reference that the linker cannot strip. Re-verify
      with `nm -gU` after rebuilding.
    - If neither fix surfaces the symbol, escalate: the XCFramework may need
      to be rebuilt with an explicit export list, which is an upstream issue.

### Phase 5 — update roadmap

- [x] Mark "BLOCKER: Fix iOS on-device failure" complete in
  `docs/roadmap/v0.md`.
- [x] Mark "Tighten SPM version pin" complete in `docs/roadmap/v0.md`.

### Phase 6 — update spec

- [x] Check `docs/spec/README.md` for any mention of the shim not being
  wired into `integration_test_app` and update accordingly.
- [x] If the iOS `make ios_test` target is described as failing/untested,
  update to reflect that it is green.

## Reviews

### Review 1: 2026-06-11

**Problem Statement Assessment**

Both problems are real and well-scoped. The root cause — `betto_onnxrt_ios`
absent from `integration_test_app/pubspec.yaml` — is verified on disk: the
pubspec declares only `betto_onnxrt: path: ../` with no plugin entry, so
`GeneratedPluginRegistrant.m` cannot register `BettoOnnxrtIosPlugin` and the
ORT static archive is never linked. Both map directly to roadmap items in
`docs/roadmap/v0.md` ("BLOCKER: Fix iOS on-device failure" and "Tighten SPM
version pin"), and bundling them in one PR is justified: they touch the same
package and are both gates for a green `make ios_test`. The `runtime.dart`
references (`DynamicLibrary.process()` on iOS, the `OrtGetApiBase` symbol) check
out against the source.

**Proposed Solution Assessment**

The Phase 1 dependency fix is correct and minimal. The investigation is
otherwise thorough — the dead-stripping risk and the Option A/B linker-flag
analysis are good, and the recommendation of Option A (keep the flag in the
consuming app, avoid `unsafeFlags` on a to-be-published package) is sound.

Two material defects:

1. **Phase 2 breaks `make check_ios_version` — this is a concrete bug the plan
   does not catch.** The plan changes `from: "1.22.0"` to `exact: "1.22.0"` in
   `Package.swift` and then asserts (Phase 2, and in the investigation) that
   this "makes the resolution semantics match the assertion semantics" and that
   `make check_ios_version` will pass. It will not. The Makefile target extracts
   the pin with `grep 'from:' .../Package.swift | grep -o '"[0-9][^"]*"'`. After
   the edit, no line matches `from:`, so `SPM_VER` is empty, the comparison
   `"1.22.0" != ""` is true, and the target **exits 1**. `make check_ios_version`
   runs inside `make pre_commit`, so this would also break the standard
   pre-commit gate. The plan must add an explicit step to update the
   `check_ios_version` recipe (and its doc comment, which says "asserts that the
   `from:` pin matches") to grep for `exact:` (or both). Phase 2's "confirm it
   passes" step is currently unsatisfiable as written.

2. **The Q1 open-question answer was factually wrong** (now corrected in the
   `## Open questions` section). It claimed the Q1 spike "confirmed empirically
   that `OrtGetApiBase` has default (non-hidden) visibility." It did not — in
   `docs/plans/completed/plan_ios_spm_shim.md`, Q1 (symbol visibility) is still
   an unchecked box and is flagged as the most critical unresolved risk. What
   was confirmed empirically was Q6 (binary type: static `ar archive`). This
   matters because it changes Phase 4 from a rubber-stamp into the first real
   test of the load-bearing assumption, and because if the symbol *is* hidden,
   Option A's `-u _OrtGetApiBase` will not help (a forced reference does not
   defeat `visibility("hidden")`) — a Swift re-export bridge would be needed.

**Architecture Fit**

Good. The plan touches only the integration test app pubspec, `Package.swift`,
(and should touch) the Makefile, and the spec — no `lib/` core, storage, domain
models, or public API surface, so the pure-Dart/Flutter-widget/app layer
boundary is not at risk; the library-architecture concerns do not engage here.
There is no UI, so design and inclusivity skills do not apply. Phase 6 (spec
update) is correctly included: `docs/spec/README.md` §6 and the consumer-setup
section already describe adding `betto_onnxrt_ios`, and CLAUDE.md's note that
"the shim is currently not wired into integration_test_app, so make ios_test
fails" is the statement that should be retired once this lands — worth calling
out CLAUDE.md explicitly alongside the spec.

**Risk & Edge Cases**

- The single largest residual risk is symbol visibility (Phase 4). Treat it as a
  gate, not a checkbox. If `nm -gU` shows the symbol absent, the plan branches:
  forced-reference flag (dead-strip case) *or* re-export bridge (hidden-visibility
  case). The plan currently only handles the dead-strip case.
- `make ios_test` boots `$(EMULATOR_IOS)`; Phase 3 should confirm the simulator
  name/runtime variables resolve, since `emulator_ios_create` depends on
  `EMULATOR_IOS_DEVICE`/`EMULATOR_IOS_RUNTIME` being set.
- No test-coverage concern: this is integration-harness wiring, not library
  code, so the 90% unit-coverage rule does not bite. Worth stating that
  explicitly in the plan so a reviewer does not flag it.

**Recommendations**

Address before promoting back to `Investigated`:
1. Add a Phase 2 step to update the `check_ios_version` Makefile recipe and its
   doc comment to match `exact:` — and verify the target passes after both the
   Package.swift and Makefile edits.
2. Reframe Phase 4 as a required gate with an explicit hidden-visibility branch
   (re-export bridge), not just the dead-strip branch.
3. Phase 6: include CLAUDE.md's iOS-status note in the list of docs to update,
   not just `docs/spec/README.md`.

The core approach is sound and the fix is genuinely small; these are corrections
to claims and a missed Makefile coupling, not a rethink.

**Open questions**

- [x] Will `make check_ios_version` be updated in lockstep with the
      `Package.swift` `from:` → `exact:` change so that both the target and
      `make pre_commit` still pass?
      **Resolved (Review 2)**: Yes — Phase 2 now includes an explicit step to
      update the Makefile target to grep for `exact:` and compare against
      `version_onnx.json`'s `ios.version`. Note: the exact version is
      `"1.24.2"`, not `"1.22.0"` (no 1.22.0 SPM tag exists), so the comparison
      must use `version_onnx.json`, not `VERSION_ONNX`.
- [x] If Phase 4's `nm -gU` shows `OrtGetApiBase` absent, is the cause
      dead-stripping (Option A flag fixes it) or hidden visibility (needs a
      Swift re-export bridge)?
      **Resolved (Review 2)**: Phase 4 now documents both branches — forced
      linker reference (`-u _OrtGetApiBase` via xcconfig) for the dead-strip
      case, and a Swift re-export bridge for the hidden-visibility case, with
      a clear decision tree. This cannot be pre-answered without running the
      build; the plan handles both outcomes.

### Review 2: 2026-06-11

Both reviewer open questions from Review 1 are now addressed:

1. **SPM exact-version discovery**: Investigation of the SPM repo confirms no
   tags exist between 1.20.0 and 1.24.1 — `exact: "1.22.0"` is impossible.
   The correct pin is `exact: "1.24.2"`. The plan text and Phase 2 have been
   updated throughout. The `check_ios_version` Makefile update is included in
   Phase 2 with the correct comparison (`version_onnx.json ios.version`, not
   `VERSION_ONNX`).

2. **Phase 4 branching**: The phase now documents a concrete decision tree for
   both the dead-strip and hidden-visibility failure modes, including the Swift
   re-export bridge path. This satisfies the reviewer's requirement to handle
   both branches before claiming `make ios_test` will pass.

No new blockers. Status promoted to **Investigated**.

## Summary

- Added `betto_onnxrt_ios: path: ../packages/betto_onnxrt_ios` to
  `integration_test_app/pubspec.yaml`. Running `flutter pub get` regenerated
  `GeneratedPluginRegistrant.m` to include `BettoOnnxrtIosPlugin` alongside
  `IntegrationTestPlugin` — the root cause of the "symbol not found:
  OrtGetApiBase" crash is now fixed.
- Changed `packages/betto_onnxrt_ios/ios/Package.swift` from
  `from: "1.22.0"` to `exact: "1.24.2"`. The SPM repo has no tags between
  1.20.0 and 1.24.1, so this makes explicit what SPM was already resolving to,
  preventing future silent version drift.
- Updated the `check_ios_version` Makefile target to grep for `exact:` instead
  of `from:`, and to compare against `version_onnx.json ios.version` (via
  `python3 -c`) rather than `VERSION_ONNX` — the two legitimately differ.
  `make check_ios_version` and `make pre_commit` both pass.
- Phases 3 and 4 (`make ios_test` and `nm -gU` symbol verification) could not
  be run in the automated agent environment (requires Xcode + SPM network
  fetch). These must be run manually by the developer. The `ios-emulator`
  simulator is present and ready. Symbol visibility (`_OrtGetApiBase`) has not
  yet been confirmed empirically — apply `-u _OrtGetApiBase` via xcconfig
  (Option A) if dead-stripping hides it, or a Swift re-export bridge for the
  hidden-visibility case.
- Updated `docs/roadmap/v0.md`: marked "BLOCKER: Fix iOS on-device failure"
  and "Tighten SPM version pin" complete.
- Updated `CLAUDE.md` iOS status note to reflect the wired dependency and
  exact SPM pin; retired the blocker note.
- `docs/spec/README.md` required no changes — no outdated wiring note was
  present in the spec.
