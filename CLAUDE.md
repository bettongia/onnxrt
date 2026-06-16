# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

This is a **monorepo**. Published packages live under `packages/`:

| Directory | Package | Description |
|---|---|---|
| `packages/betto_onnxrt/` | `betto_onnxrt` | Pure-Dart ONNX Runtime library |
| `packages/betto_onnxrt_ios/` | `betto_onnxrt_ios` | Flutter plugin SPM shim for iOS |

The git root is the workspace root and contains no `pubspec.yaml`. All Dart
commands (`dart pub get`, `dart test`, `dart analyze`) must be run from inside
the appropriate package directory (or via the Makefile targets, which handle
the `cd` automatically).

## Specification — read this first

The canonical description of `betto_onnxrt`'s design, public API, platform
support, and architectural decisions lives in **`docs/spec/README.md`**.

**Before starting any planning or implementation work, read the spec.** It is
the authoritative reference for:

- What the library does and why
- Which platforms are supported and how each is handled
- The full public API contract (types, methods, throws, lifecycle)
- Thread safety rules
- Known limitations and their scope

**If implementation work changes the architecture, public API, platform
support, or any behaviour described in the spec, the spec must be updated as
part of that work — not as a follow-up.** A PR that changes behaviour without
updating the spec will not be considered complete.

## Commands

The root Makefile is the primary interface for all build, test, and quality tasks.
It composes per-package `.mk` fragments — all targets are available from the
repo root.

```bash
make                  # full quality gate: clean, prepare, license_check, format, analyze, test, coverage, doc
make pre_commit       # subset run before committing: format_check, analyze, license_check, test
make test             # dart test (runs from packages/betto_onnxrt/)
make analyze          # dart analyze (runs from packages/betto_onnxrt/)
make format           # dart format lib/ test/ hook/ tool/ (in packages/betto_onnxrt/)
make format_check     # format check (exits non-zero if changes needed — used in CI)
make coverage         # run tests with coverage and generate HTML report
make doc              # dart doc (in packages/betto_onnxrt/)
make prepare          # dart pub get + activate coverage tool + flutter pub get for all sub-projects
make clean            # remove coverage/, doc/, and Flutter build outputs

make license_check    # verify Apache 2.0 headers (betto_onnxrt package)
make license_add      # add missing headers (betto_onnxrt package)
make license_check_ios  # verify Apache 2.0 headers (betto_onnxrt_ios package)
make license_add_ios    # add missing headers (betto_onnxrt_ios package)

# Integration tests (require a full Flutter build — not plain dart test)
make macos_test       # macOS on-device integration tests
make ios_test         # iOS simulator integration tests (see iOS note below)
make android_test     # Android emulator integration tests (see Android note below; requires a running emulator)

make container_test   # build and run the CI container via podman
```

To run a single test file directly: `cd packages/betto_onnxrt && dart test test/foo_test.dart`

To regenerate `packages/betto_onnxrt/lib/src/generated/versions.g.dart` after bumping `VERSION_ONNX`:
`cd packages/betto_onnxrt && dart run tool/generate_versions.dart`

`dart pub get` (run via `make prepare`) triggers the native-assets build hook
(`packages/betto_onnxrt/hook/build.dart`), which downloads and caches the ORT
binary at `packages/betto_onnxrt/.dart_tool/betto_onnxrt/{version}/`.

## Architecture

`betto_onnxrt` is a **pure-Dart library** (no Flutter dependency) with three distinct layers:

### 1. Native-assets build hook — `packages/betto_onnxrt/hook/build.dart`

Runs at build time via the Dart native-assets system. Downloads the ONNX Runtime prebuilt binary from GitHub Releases (desktop) or Maven Central (Android), verifies SHA-256, and emits a `CodeAsset` with `DynamicLoadingBundled` link mode. The cache lives at `packages/betto_onnxrt/.dart_tool/betto_onnxrt/{version}/` (gitignored, version-scoped so a bump forces re-download).

The SHA-256 manifest (`_sha256Manifest`) in `packages/betto_onnxrt/hook/build.dart` holds real checksums for Android (both archive-level AAR and per-ABI `.so` digests). Desktop and iOS checksums remain all-zeros placeholders — replace them with real values before the first release (see `TODO(betto_onnxrt#2)` in the file).

For Android, two-level verification is applied: the downloaded AAR is checksummed against the archive-level entry before extraction, then the extracted `.so` is verified against its per-ABI entry.

### 2. Public library — `packages/betto_onnxrt/lib/`

| File | Exports |
|---|---|
| `packages/betto_onnxrt/lib/src/runtime.dart` | `OnnxRuntime` — opens the ORT dylib, creates sessions |
| `packages/betto_onnxrt/lib/src/session.dart` | `OnnxSession` — wraps an ORT inference session via FFI vtable slots |
| `packages/betto_onnxrt/lib/src/tensor.dart` | `OnnxTensor`, `OnnxElementType`, `SessionOptions` |
| `packages/betto_onnxrt/lib/src/model_downloader.dart` | `ModelDownloader` — SHA-256-verified cached downloads |
| `packages/betto_onnxrt/lib/src/model_spec.dart` | `ModelSpec`, `ModelFile`, `ResolvedModel`, `DownloadProgress` |
| `packages/betto_onnxrt/lib/src/allowlist_provider.dart` | `AllowlistProvider` interface |
| `packages/betto_onnxrt/lib/src/ort_api.dart` | FFI types and vtable-slot helpers (internal) |
| `packages/betto_onnxrt/lib/src/generated/versions.g.dart` | Generated version constants — do not edit by hand |

The ORT C API is accessed entirely through numeric vtable slot indices in
`packages/betto_onnxrt/lib/src/ort_api.dart`. Each slot is annotated with its
ORT symbol name (`CreateEnv` = slot 3, `Run` = slot 9, etc.). `ort_api.dart`
is the single source of truth for ORT versioning — when upgrading ORT, verify
these slot indices still match the new `onnxruntime_c_api.h`.

**Thread safety**: `OnnxSession` is thread-affine — all `run()` and `dispose()` calls must come from the same Dart isolate that created the session. For isolate-based parallelism, create a fresh `OnnxRuntime` inside each isolate.

### 3. Integration test app — `packages/betto_onnxrt/integration_test_app/`

A separate Flutter app used for on-device integration tests. It is excluded
from the main `dart analyze` and `dart test` runs (see
`packages/betto_onnxrt/analysis_options.yaml`). Run via `make macos_test`,
`make ios_test`, or `make android_test`.

## Key conventions

**ORT version**: Controlled by `packages/betto_onnxrt/VERSION_ONNX`. After
bumping it, run `cd packages/betto_onnxrt && dart run tool/generate_versions.dart`
to regenerate `packages/betto_onnxrt/lib/src/generated/versions.g.dart`. Also
update `packages/betto_onnxrt/version_onnx.json` with new `version`, `url`,
and `sha256` fields for every platform. Note the prefix convention: `VERSION_ONNX`
uses a `v` prefix (e.g. `v1.22.0`); `version_onnx.json` platform `version` fields
use the bare version without `v` (e.g. `1.22.0`). Platform versions may also differ
from `VERSION_ONNX` (e.g. Windows uses `1.22.1` as a patch release). The hook
cache directory is `packages/betto_onnxrt/.dart_tool/betto_onnxrt/{platform_version}/`
— CI scripts read the version from `packages/betto_onnxrt/version_onnx.json` per
platform, not from `VERSION_ONNX`.

**OnnxSession tests** (`packages/betto_onnxrt/test/onnx_session_test.dart`)
auto-skip when the ORT binary is not staged. They require the hook to have
previously run and produced a cached artifact at
`packages/betto_onnxrt/.dart_tool/betto_onnxrt/{version}/`.

**Android status**: Android is supported. `_buildAndroid` in
`packages/betto_onnxrt/hook/build.dart` downloads the ORT AAR from Maven
Central, applies two-level SHA-256 verification (archive then per-ABI `.so`),
and emits a `DynamicLoadingBundled` `CodeAsset`. Real checksums are in
`_sha256Manifest` for v1.22.0. Android testing is developer-run via
`make android_test` (not CI), consistent with `ios_test`. Use
`make emulator_android_create` to create an `arm64-v8a` AVD (recommended on
Apple Silicon) and `make emulators_stop_android` to shut it down.

**iOS status**: iOS is supported via the `betto_onnxrt_ios` SPM plugin shim
(`packages/betto_onnxrt_ios/`). The ORT XCFramework is statically linked into
the host app by the shim; `OnnxRuntime.load()` uses `DynamicLibrary.process()`
to resolve ORT symbols from the process image. The native-assets hook emits no
`CodeAsset` on iOS — this is correct behaviour. `betto_onnxrt_ios` is wired
into `packages/betto_onnxrt/integration_test_app/` as a path dependency;
`GeneratedPluginRegistrant.m` registers `BettoOnnxrtIosPlugin`. The SPM pin is
`exact: "1.24.2"` (the SPM repo has no tags between 1.20.0 and 1.24.1; this is
what `from: "1.22.0"` was already resolving to). Run `make ios_test` to verify
end-to-end on a simulator. After the first successful build, confirm
`_OrtGetApiBase` survives static linking:
`nm -gU packages/betto_onnxrt/integration_test_app/build/ios/iphonesimulator/Runner.app/Runner | grep OrtGetApiBase`.

**Roadmap**: The active roadmap is `docs/roadmap/v0.md`. All development work
should be driven by and traceable to an item in that roadmap. We are currently
in the **v0 series** — assembling the pieces needed for a stable alpha release.
Nothing here should be considered v1 until the v0 roadmap is complete and the
package has been published to pub.dev and validated in real consumer projects.
If you are about to start work that does not map to a roadmap item, raise it
with the user before proceeding.

**Plans**: Implementation plans live in `docs/plans/`. New work is done on a
git branch using a worktree in `.claude/worktrees/`. See
`docs/plans/README.md` for the full workflow and plan template.

**ORT vtable slot integrity**: Every bound typedef pair in
`packages/betto_onnxrt/lib/src/ort_api.dart` carries a `// SLOT:Name=N`
marker (e.g. `// SLOT:CreateEnv=3`). These markers are parsed and
cross-checked by `packages/betto_onnxrt/test/ort_slot_guard_test.dart` against
a golden table for ORT API v22. The guard catches comment drift but **cannot
replace a real load+inference run**. Any PR that edits slot indices, adds or
removes bound typedefs, or bumps `ortApiVersion` must include evidence of a
passing `make macos_test` (or `make linux_test`) run in the PR description.

**ORTCHAR_T call-site pattern**: Any ORT slot that accepts a file-system path
uses `ORTCHAR_T*` — `char*` (UTF-8) on POSIX, `wchar_t*` (UTF-16) on Windows.
In the Dart FFI typedef, use `Pointer<Void>` for that parameter. At the call
site, use a `Platform.isWindows` conditional:
`path.toNativeUtf16(allocator: arena).cast<Void>()` on Windows and
`path.toNativeUtf8(allocator: arena).cast<Void>()` on POSIX. See
`packages/betto_onnxrt/lib/src/session.dart` (`createSessionFromFile`) for the
reference implementation.

**License**: All `.dart` files must carry the Apache 2.0 header.
`make license_check` / `make license_add` use `addlicense` with the config in
`packages/betto_onnxrt/addlicense_config.txt`. Generated files and YAML/config
files are excluded. Use `make license_check_ios` / `make license_add_ios` for
the iOS companion package.
