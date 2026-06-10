# iOS ORT Support via SPM Plugin Shim

**Status**: Investigated

**PR link**: _(pending)_

## Problem statement

`OnnxRuntime.load()` throws `UnsupportedError` on iOS. The Q1 2026 spike
(documented in `plan_betto_onnxrt_extraction.md`) established why: the ORT iOS
XCFramework ships a **static** Mach-O universal binary (`ar archive`), but
Flutter's iOS native-assets system enforces `DynamicLoadingBundled` link mode
and rejects both `StaticLinking` and `DynamicLoadingBundled` when the supplied
artifact is not a dylib. `_buildIos` in `hook/build.dart` therefore emits a
warning and no `CodeAsset`.

The consequence is that `kmdb_inferencing` semantic search (BGE embeddings, vector
index) is entirely unavailable on iOS. The roadmap (`docs/roadmap/0_05.md`) lists
this as a remaining v0.05 blocker for iOS semantic search.

The chosen path (recorded in Q1) is an **SPM plugin shim**: a thin Flutter plugin
that declares a Swift Package Manager dependency on
`microsoft/onnxruntime-swift-package-manager` (product `onnxruntime-c`). This
pulls the ORT XCFramework into the Xcode build via SPM, statically linking ORT
into the app binary. On iOS, `OnnxRuntime.load()` then calls
`DynamicLibrary.process()` to access the statically-linked ORT C API symbols
(which are in the main executable after static link, and visible to `dlsym`).

Key constraints:
- `betto_onnxrt` must remain **pure Dart** (no Flutter SDK dependency in
  its own `pubspec.yaml`). The shim is a separate package.
- Use the full `onnxruntime-c` XCFramework — **not** `onnxruntime-mobile`
  (reduced opset, incompatible with the BGE model).
- Do **not** use CocoaPods (deprecated in Flutter as of 3.27).

## Open questions

- [ ] **Q1 — `DynamicLibrary.process()` symbol visibility on iOS.** When ORT
  is statically linked into the app via SPM, are all ORT C API entry points
  (especially `OrtGetApiBase`) visible to `dlsym` / `DynamicLibrary.process()`?
  Specifically: does the ORT XCFramework export symbols with default visibility,
  or are they hidden? A quick `nm -gU` on the `.a` from the XCFramework will
  confirm. If hidden, an alternative is a thin Swift bridging wrapper that
  re-exports `OrtGetApiBase` as a visible symbol.

- [x] **Q2 — Shim package location.**
  _Decision: option (a) — sub-package `packages/betto_onnxrt_ios/` inside this
  repo. Keeps the shim version-locked to `betto_onnxrt`, avoids requiring every
  consumer app to repeat the SPM wiring, and follows a recognisable Flutter
  plugin pattern. The plan's Investigation section already fully specifies the
  structure and `pubspec.yaml` content for this option._

- [ ] **Q3 — Minimum Flutter version for SPM plugin support.** Flutter SPM
  plugin support landed experimentally in 3.22 and stabilised in 3.27. What
  is the minimum Flutter version required by `kmdb_ui`? If 3.27+, SPM plugin
  `Package.swift` works without flags. If below 3.27, check whether
  `--enable-experiment=swift-package-manager` is needed.

- [x] **Q4 — `OnnxRuntime.load()` iOS branch in `runtime.dart`.**
  _Decision: option (a), `Platform.isIOS` check — already implemented.
  `_openLibrary()` in `runtime.dart` contains the `Platform.isIOS →
  DynamicLibrary.process()` branch as of the Q1 spike (2026-06-10). Phase 3
  checklist item 1 is complete. Note: the `_openLibrary()` doc comment still
  references `.framework` bundles staged by the hook — this is incorrect and
  must be corrected as part of Phase 3 cleanup (see Review 2)._

- [ ] **Q5 — iOS CI coverage.** The current CI matrix covers macOS, Linux, and
  Windows. Adding an iOS job requires `macos-latest` runner + iOS simulator.
  The `integration_test_app` already has `make ios_test` wired. Can the shim
  be tested via `make ios_test` in CI, or does real-device testing apply
  (documented as RC-15 in the release checklist)?

- [x] **Q6 — XCFramework binary type: static `.a` vs dynamic `.framework`.**
  **VERDICT (2026-06-10): The ORT iOS XCFramework ships static `ar archive`
  files, not dynamic `.framework` binaries.**
  Confirmed empirically by the Q1 2026 spike documented in
  `plan_betto_onnxrt_extraction.md`: both `StaticLinking` and
  `DynamicLoadingBundled` `CodeAsset` modes were tried against the actual
  pod-archive artifact and rejected by the Flutter toolchain with
  _"link mode 'static' is not allowed by the input link mode preference
  'dynamic'"_ and `parseOtoolArchitectureSections` failing on the `ar archive`.
  The hook doc comment describing `.framework` dynamic binaries was incorrect
  (see Q7). The SPM shim approach is confirmed correct; native-assets is not
  viable for iOS ORT.

- [x] **Q7 — Hook doc comment vs. implementation mismatch.**
  **RESOLVED.** The `hook/build.dart` iOS doc block has been corrected to match
  the `_buildIos` implementation: it now states that the XCFramework ships
  static `.a` archives, that both link modes were rejected by the Q1 spike, and
  that iOS support requires the `betto_onnxrt_ios` SPM plugin shim. The
  implementation (`_buildIos` logging a warning and emitting no CodeAsset) was
  always correct; only the doc comment was wrong.

## Investigation

### Why native-assets doesn't work for ORT iOS

The ORT iOS XCFramework (`onnxruntime-c-{version}-ios.tgz`) ships:

```
onnxruntime.xcframework/
  ios-arm64/
    onnxruntime.a          ← Mach-O universal binary / ar archive (STATIC)
  ios-arm64_x86_64-simulator/
    onnxruntime.a
```

Flutter's `flutter_tools` `parseOtoolArchitectureSections` expects load
commands from a dylib; the `.a` is an `ar archive` and has none. Both
`StaticLinking` and `DynamicLoadingBundled` `CodeAsset` modes were tried
during the Q1 spike and rejected by the toolchain.

### SPM shim approach

Swift Package Manager can declare a binary target from a remote XCFramework.
Microsoft publishes `microsoft/onnxruntime-swift-package-manager` which
provides a `Package.swift` with an `onnxruntime-c` binary target pointing to
the XCFramework zip. A Flutter plugin can declare an SPM dependency on this
product in its `ios/Package.swift`, which causes Xcode to pull and statically
link ORT into the host app.

The `onnxruntime-c` product is the full C API XCFramework — not the Swift
overlay and not `onnxruntime-mobile`. This is required: `onnxruntime-mobile`
is a reduced-opset build that does not support all operators used by the BGE
embedding model.

### Shim package structure (sub-package in this repo)

```
packages/
  betto_onnxrt_ios/            ← Flutter plugin (iOS only)
    pubspec.yaml               ← declares flutter plugin, no dart:ffi
    ios/
      Package.swift            ← SPM dependency on onnxruntime-c
      Classes/
        BettoOnnxrtIosPlugin.swift  ← no-op Flutter plugin class (registration only)
    lib/
      betto_onnxrt_ios.dart    ← empty (no-op Dart side)
    test/
```

`pubspec.yaml` for the shim:
```yaml
name: betto_onnxrt_ios
description: Flutter plugin shim that links ORT via SPM on iOS for betto_onnxrt.
version: 0.1.0
environment:
  sdk: ^3.12.0
  flutter: ">=3.27.0"
dependencies:
  flutter:
    sdk: flutter
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: BettoOnnxrtIosPlugin
```

`ios/Package.swift`:
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "betto_onnxrt_ios",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "betto-onnxrt-ios", targets: ["betto_onnxrt_ios"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            from: "1.22.0"   // pin to the VERSION_ONNX in the betto_onnxrt root
        )
    ],
    targets: [
        .target(
            name: "betto_onnxrt_ios",
            dependencies: [
                .product(name: "onnxruntime-c",
                         package: "onnxruntime-swift-package-manager")
            ],
            path: "."
        )
    ]
)
```

The Swift plugin class is a no-op registration shim:
```swift
// BettoOnnxrtIosPlugin.swift
import Flutter

public class BettoOnnxrtIosPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {}
}
```

### `OnnxRuntime.load()` iOS branch

With ORT statically linked, the C API entry point `OrtGetApiBase` is in the
main executable. `DynamicLibrary.process()` returns the dynamic linker view
of the running process and resolves symbols from all statically-linked
objects (subject to Q1 — symbol visibility must be confirmed).

The change to `lib/src/runtime.dart` is minimal:
```dart
static Future<OnnxRuntime> load() async {
  final DynamicLibrary lib;
  if (Platform.isIOS) {
    // ORT is statically linked via betto_onnxrt_ios SPM shim.
    lib = DynamicLibrary.process();
  } else {
    lib = /* existing CodeAsset path */;
  }
  ...
}
```

### `hook/build.dart` iOS branch

The `_buildIos` function currently logs a warning and emits no CodeAsset.
No change is required to the hook — static linking via SPM happens entirely
at the Xcode/Flutter build layer, outside the native-assets system.

The warning log in `_buildIos` should be updated to a more informative
message explaining that iOS support requires the `betto_onnxrt_ios` plugin.

### Consumer wiring (`kmdb_ui`)

`kmdb_ui/pubspec.yaml`:
```yaml
dependencies:
  betto_onnxrt_ios:
    git:
      url: git@github.com:bettongia/onnxrt.git
      path: packages/betto_onnxrt_ios
```

No `ios/Podfile` changes are needed (no CocoaPods). Flutter picks up the
SPM dependency via the plugin's `ios/Package.swift` automatically.

### Version pinning

The SPM `from: "1.22.0"` pin in `Package.swift` should track `VERSION_ONNX`
in the repo root. A `Makefile` target or CI check should assert that the
version in `Package.swift` matches `VERSION_ONNX` (analogous to the
`VERSION_ZSTD` assertion in `betto_zstd`).

## Implementation plan

### Phase 1 — Spike: symbol visibility and Flutter SPM version (resolves Q1, Q3)

- [ ] Download the ORT iOS XCFramework for `VERSION_ONNX` from
  `microsoft/onnxruntime-swift-package-manager` releases
- [ ] Run `nm -gU` on the `.a` (device and simulator slices) and confirm
  `OrtGetApiBase` is a globally-visible symbol
- [ ] If hidden: prototype a thin Swift bridging wrapper that re-exports
  `OrtGetApiBase` as a `@_cdecl` visible symbol
- [ ] Confirm Flutter version requirement for SPM plugin support (Q3); record
  minimum version in the shim `pubspec.yaml`

### Phase 2 — Shim package scaffold (resolves Q2)

- [ ] Create `packages/betto_onnxrt_ios/` directory structure
- [ ] Write `pubspec.yaml` (Flutter plugin, iOS-only, no dart:ffi)
- [ ] Write `ios/Package.swift` with `onnxruntime-c` SPM dependency pinned to
  `VERSION_ONNX`
- [ ] Write `Classes/BettoOnnxrtIosPlugin.swift` (no-op registration)
- [ ] Write `lib/betto_onnxrt_ios.dart` (empty Dart side)
- [ ] Add Apache 2.0 license headers to all source files
- [ ] Add `analysis_options.yaml`
- [ ] Confirm `flutter pub get` in `packages/betto_onnxrt_ios/` resolves cleanly

### Phase 3 — `betto_onnxrt` iOS branch in `runtime.dart` (resolves Q4)

- [ ] Add `Platform.isIOS` branch in `OnnxRuntime.load()` to call
  `DynamicLibrary.process()` when on iOS
- [ ] Update `_buildIos` warning in `hook/build.dart` to reference
  `betto_onnxrt_ios` as the required complement
- [ ] Add `VERSION_ONNX` ↔ `Package.swift` version consistency check to
  `Makefile` (e.g. `make check_ios_version`)
- [ ] All existing non-iOS tests continue to pass (`make test`)

### Phase 4 — Integration test (`make ios_test`)

- [ ] Wire `betto_onnxrt_ios` into `integration_test_app/pubspec.yaml`
- [ ] Add an iOS integration test to `integration_test_app/` that calls
  `OnnxRuntime.load()` and runs a session with the identity-graph fixture
- [ ] Run `make ios_test` on the iOS simulator; confirm no `UnsupportedError`
- [ ] Document real-device test as RC-16 in `docs/spec/28_release_checklist.md`
  (simulator confirms linkage; real device needed before first iOS App Store
  release)

### Phase 5 — CI and documentation (resolves Q5)

- [ ] Add `test-ios` job to `.github/workflows/ci.yml`:
  - `macos-latest` runner
  - `subosito/flutter-action`
  - `make ios_test` against the `integration_test_app`
- [ ] Update `README.md` with iOS setup instructions:
  - Add `betto_onnxrt_ios` to `pubspec.yaml`
  - No Podfile changes needed
- [ ] Update `CLAUDE.md` iOS status section to reflect shim availability
- [ ] Open PR; tag as iOS-support milestone in the `bettongia/onnxrt` repo

## Summary

_To be completed after implementation._

## Reviews

### Review 1: 2026-06-10

**Problem Statement Assessment**

The problem is real and correctly scoped. ORT on iOS is a genuine blocker for
semantic search in the Bettongia app suite, and the Q1 spike verdict that ruled
out the native-assets path is a reasonable basis for seeking an alternative.
The choice of the SPM shim pattern is well-aligned with the direction Flutter
has taken as it deprecates CocoaPods. The constraint to keep `betto_onnxrt`
pure Dart is correct and consistent with CLAUDE.md.

**Proposed Solution Assessment**

The general shape of the solution (a separate Flutter plugin package that pulls
in the ORT XCFramework via SPM, with `DynamicLibrary.process()` in
`runtime.dart`) is sound in principle and is a recognised Flutter pattern.
The plan is thorough, has a clear phase structure, and correctly identifies the
version-pinning requirement.

However, there are two critical issues that block investigation sign-off:

1. **The codebase already partially implements this plan, in a way that
   contradicts the plan's own investigation section.** `runtime.dart` already
   contains the `Platform.isIOS → DynamicLibrary.process()` branch (Phase 3,
   Q4). More importantly, the top-level doc comment of `hook/build.dart`
   (lines 38–52) describes a native-assets iOS path that downloads the
   pod-archive XCFramework, extracts a `.framework/onnxruntime` binary (no
   extension — the standard Apple dynamic framework format), and emits it as a
   `CodeAsset` with `DynamicLoadingBundled`. This is a completely different
   approach from the SPM shim. If that description is accurate, the SPM shim
   may not be necessary at all. If it is inaccurate, the doc comment is
   actively misleading.

2. **The XCFramework binary type is in dispute within the codebase.** The
   plan's Investigation section says the XCFramework ships `.a` static archives.
   The hook doc comment says the pod-archive contains
   `onnxruntime.framework/onnxruntime` — a Mach-O binary in a `.framework`
   bundle, which is Apple's dynamic library format. These are mutually exclusive
   claims. If the binary is actually dynamic, the Q1 spike conclusion may have
   been based on the wrong artifact (perhaps a different distribution URL or an
   older version), and a native-assets approach with `DynamicLoadingBundled`
   might work today — which would make the SPM shim unnecessary.

Until Q6 is answered by inspecting the actual pod-archive, the plan is
investigating the right problem but potentially proposing the wrong solution.

**Architecture Fit**

The SPM shim-as-sub-package approach (option a in Q2) is the right structural
call: it keeps the shim version-locked to `betto_onnxrt`, avoids requiring
every consumer to repeat the setup, and follows a recognisable Flutter plugin
pattern. The pure-Dart constraint on `betto_onnxrt` itself is correctly
maintained.

The `Platform.isIOS` branch in `runtime.dart` (Plan Phase 3 / Q4) is already
present in the codebase, so that piece of work is done. The plan's
implementation checklist does not acknowledge this; it will need to be updated
to reflect reality.

The library-architecture constraints do not apply here because `betto_onnxrt`
is pure Dart with no Flutter dependency and no barrel/widget layer — the shim
is a separate plugin package. There is nothing to check against the
library-architecture skill for this plan.

Design and inclusivity skills are not relevant — this plan has no UI surface.

**Risk and Edge Cases**

- **Symbol visibility (Q1):** This is the most critical technical unknown.
  `DynamicLibrary.process()` resolves symbols from the process image, but only
  those with default (global) visibility. ORT's Mach-O `.a` or `.framework`
  binary may hide symbols with `__attribute__((visibility("hidden")))`. If
  `OrtGetApiBase` is hidden, the call will throw at runtime. The `nm -gU`
  verification in Phase 1 is essential and must happen before any other phase.

- **`Package.swift` target path ambiguity:** The plan's `Package.swift` sets
  `path: "."` for the `betto_onnxrt_ios` target. Flutter SPM plugin support
  expects sources in a `Sources/<TargetName>/` directory by convention. A
  bare `path: "."` that includes the `Classes/` subdirectory may work, but
  is non-standard and may confuse Xcode's source indexing. Prefer
  `path: "Classes"` (or the Flutter-conventional `Sources/betto_onnxrt_ios/`)
  to be explicit.

- **No-op plugin Dart side:** The plan shows `lib/betto_onnxrt_ios.dart` as
  empty. This will cause `dart analyze` to warn about an empty library unless
  a `library;` directive or a doc comment is present. The implementation
  checklist should include adding an `analysis_options.yaml` (already listed)
  and a minimal doc comment explaining the package's role.

- **Version sync between `VERSION_ONNX` and `Package.swift`:** The plan
  correctly identifies this risk and proposes a Makefile check. This check
  should be included in `make pre_commit` (not just CI) so it catches drift
  locally before push.

- **`make ios_test` in CI:** GitHub Actions `macos-latest` runners do support
  iOS simulators, but simulator boot time adds 3–5 minutes to CI. The plan
  should explicitly state whether this is acceptable or whether the iOS job
  should run on a separate workflow with a `workflow_dispatch` trigger to
  avoid routine slowdowns.

- **Real-device testing gap:** The plan correctly defers this to a release
  checklist entry, but does not specify whether the existing `RC-15` entry
  covers it or a new `RC-16` entry is needed. The plan says `RC-16` — verify
  that `RC-15` does not already cover iOS real-device testing before
  allocating a new number (per the README guidance, spec section numbers must
  not be hard-coded in advance).

**Recommendations**

1. **Resolve Q6 first, before any implementation work.** Run `file` on both
   slices of the pod-archive XCFramework for `VERSION_ONNX`. If the binary
   is a Mach-O dynamic library (not an `ar archive`), prototype the
   native-assets approach directly in the hook before committing to the SPM
   shim. The SPM shim adds a second package, a version-sync obligation, and
   consumer setup burden — avoid it if native-assets can work.

2. **Fix the `hook/build.dart` doc comment** regardless of Q6's answer.
   The current top-level iOS doc block is contradicted by the `_buildIos`
   implementation. This is a correctness issue in existing code, not a
   planning question. If the plan proceeds with the SPM shim, update the
   comment to say the native-assets hook does not emit a CodeAsset on iOS and
   direct readers to the `betto_onnxrt_ios` package. If it pivots to
   native-assets, the comment is already close to correct but needs the spike
   outcome removed. Either way, fix it as part of Phase 1.

3. **Acknowledge the pre-existing `DynamicLibrary.process()` branch.** The
   Phase 3 checklist item for `runtime.dart` is already done. Update the plan
   to mark it complete (or remove the checklist item and note it was
   pre-implemented) so the implementer does not waste time re-examining it.

4. **Fix the `Package.swift` `path` field** to use `path: "Classes"` or the
   Flutter-conventional `Sources/` directory, not `"."`.

5. **Add the version-sync check to `make pre_commit`**, not only to CI.

**Open questions**

- [ ] **Q6 — XCFramework binary type.** See the `## Open questions` section
  above for the full statement. This is a blocker for the plan's core
  approach.
- [ ] **Q7 — Hook doc comment vs. implementation mismatch.** See `## Open
  questions`. The doc comment must be corrected to match the `_buildIos`
  implementation regardless of Q6's answer; the question is which direction
  the correction goes.

### Review 2: 2026-06-10

**Problem Statement Assessment**

No change from Review 1. The problem is real, correctly scoped, and confirmed
by empirical evidence from the Q1 spike. Q6 is now closed with the static `.a`
verdict, which removes the only blocker to the plan's core approach.

**Proposed Solution Assessment**

The SPM shim approach is confirmed correct. The plan now has a clear phase
structure, a concrete shim package layout, version-pinning strategy, and a
proposed consumer wiring. With Q2 and Q4 closed, the remaining open questions
(Q1, Q3, Q5) are genuine spike items that the Phase 1 work will resolve — they
do not block planning sign-off.

**Architecture Fit**

Confirmed from Review 1. The sub-package location for the shim (Q2, now closed)
is the right call. The pure-Dart constraint on `betto_onnxrt` is preserved.

**Risk and Edge Cases**

Two items carried forward from Review 1 require attention in implementation:

1. **`_openLibrary()` doc comment in `runtime.dart` is still wrong.** Q7
   covered the `hook/build.dart` doc comment, and that has been corrected.
   However, `runtime.dart`'s `_openLibrary()` doc comment (lines 163–172) still
   contains incorrect statements: line 165 says "iOS: resolved by the
   `.framework` bundle the build hook stages" and lines 171–172 say "On iOS the
   ORT dylib is embedded in the app's .framework bundle and linked at launch
   time." Both statements are false for the SPM shim approach — ORT is
   statically linked via SPM, not bundled by the hook as a `.framework`. This is
   a live correctness defect in the codebase. It must be fixed as part of Phase
   3, not deferred.

2. **Phase 3 checklist item 1 is already done.** The `Platform.isIOS →
   DynamicLibrary.process()` branch exists and is correct. The implementer
   should mark this done (or note it as pre-implemented) rather than
   re-examining it. The Phase 3 doc-comment fix to `_openLibrary()` is the
   actual remaining work in that phase.

3. **Q1 (symbol visibility) remains the most critical technical risk.** If
   `OrtGetApiBase` has hidden visibility in the static `.a`, `DynamicLibrary.
   process()` will throw at runtime with a `LookupError`. The `nm -gU` spike in
   Phase 1 is not optional. Do not proceed to Phase 2 without confirming this.

**Recommendations**

1. Fix the `_openLibrary()` doc comment in `runtime.dart` as part of Phase 3.
   The text at lines 163–172 must be updated to state that on iOS, ORT is
   statically linked via the `betto_onnxrt_ios` SPM plugin, and that
   `DynamicLibrary.process()` is used to resolve symbols from the process image.
   The reference to `.framework` bundles staged by the hook must be removed.

2. Update the Phase 3 checklist to acknowledge that the `DynamicLibrary.process()`
   branch is pre-implemented and that the work remaining is doc-comment
   correction only.

3. Resolve Q5 before Phase 5 implementation: decide explicitly whether the iOS
   CI job runs on every push (with the 3–5 minute simulator overhead) or on
   a scheduled/manual trigger. Both are defensible; the decision just needs to
   be recorded so the implementer does not have to re-debate it.

**Open questions**

- [ ] **Q5 — iOS CI trigger.** Should the `test-ios` job run on every push
  (adds ~5 min to CI wall time), on a nightly schedule, or on
  `workflow_dispatch` only? The existing `make ios_test` infrastructure is
  ready; this is a policy decision. Given the plan already defers real-device
  testing to a release checklist entry, a nightly or `workflow_dispatch` trigger
  is a reasonable default that avoids routine slowdown — but this must be
  decided before Phase 5 implementation.
