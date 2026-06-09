# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

The Makefile is the primary interface for all build, test, and quality tasks.

```bash
make                  # full quality gate: clean, prepare, license_check, format, analyze, test, coverage, doc
make pre_commit       # subset run before committing: format_check, analyze, license_check, test
make test             # dart test
make analyze          # dart analyze
make format           # dart format lib/ test/ hook/ tool/
make format_check     # format check (exits non-zero if changes needed — used in CI)
make coverage         # run tests with coverage and generate HTML report
make doc              # dart doc
make prepare          # dart pub get + activate coverage tool
make clean            # remove coverage/ and doc/

make license_check    # verify Apache 2.0 headers
make license_add      # add missing headers

# Integration tests (require a full Flutter build — not plain dart test)
make macos_test       # macOS on-device integration tests
make ios_test         # iOS simulator integration tests (see iOS note below)

make container_test   # build and run the CI container via podman
```

To run a single test file directly: `dart test test/foo_test.dart`

To regenerate `lib/src/generated/versions.g.dart` after bumping `VERSION_ONNX`: `dart run tool/generate_versions.dart`

`dart pub get` (run via `make prepare`) triggers the native-assets build hook (`hook/build.dart`), which downloads and caches the ORT binary at `.dart_tool/betto_onnxrt/{version}/`.

## Architecture

`betto_onnxrt` is a **pure-Dart library** (no Flutter dependency) with three distinct layers:

### 1. Native-assets build hook — `hook/build.dart`

Runs at build time via the Dart native-assets system. Downloads the ONNX Runtime prebuilt binary from GitHub Releases (desktop) or Maven Central (Android), verifies SHA-256, and emits a `CodeAsset` with `DynamicLoadingBundled` link mode. The cache lives at `.dart_tool/betto_onnxrt/{version}/` (gitignored, version-scoped so a bump forces re-download).

The SHA-256 manifest (`_sha256Manifest`) in `hook/build.dart` currently contains all-zeros placeholders — these must be replaced with real values before the first release (see `TODO(betto_onnxrt#2)` in the file).

### 2. Public library — `lib/`

| File | Exports |
|---|---|
| `lib/src/runtime.dart` | `OnnxRuntime` — opens the ORT dylib, creates sessions |
| `lib/src/session.dart` | `OnnxSession` — wraps an ORT inference session via FFI vtable slots |
| `lib/src/tensor.dart` | `OnnxTensor`, `OnnxElementType`, `SessionOptions` |
| `lib/src/model_downloader.dart` | `ModelDownloader` — SHA-256-verified cached downloads |
| `lib/src/model_spec.dart` | `ModelSpec`, `ModelFile`, `ResolvedModel`, `DownloadProgress` |
| `lib/src/allowlist_provider.dart` | `AllowlistProvider` interface |
| `lib/src/ort_api.dart` | FFI types and vtable-slot helpers (internal) |
| `lib/src/generated/versions.g.dart` | Generated version constants — do not edit by hand |

The ORT C API is accessed entirely through numeric vtable slot indices in `ort_api.dart`. Each slot is annotated with its ORT symbol name (`CreateEnv` = slot 3, `Run` = slot 9, etc.). `ort_api.dart` is the single source of truth for ORT versioning — when upgrading ORT, verify these slot indices still match the new `onnxruntime_c_api.h`.

**Thread safety**: `OnnxSession` is thread-affine — all `run()` and `dispose()` calls must come from the same Dart isolate that created the session. For isolate-based parallelism, create a fresh `OnnxRuntime` inside each isolate.

### 3. Integration test app — `integration_test_app/`

A separate Flutter app used for on-device integration tests. It is excluded from the main `dart analyze` and `dart test` runs (see `analysis_options.yaml`). Run via `make macos_test` or `make ios_test`.

## Key conventions

**ORT version**: Controlled by `VERSION_ONNX` at the repo root. After bumping it, run `dart run tool/generate_versions.dart` to regenerate `lib/src/generated/versions.g.dart`.

**OnnxSession tests** (`test/onnx_session_test.dart`) auto-skip when the ORT binary is not staged. They require the hook to have previously run and produced a cached artifact at `.dart_tool/betto_onnxrt/{version}/`.

**iOS status**: iOS is intentionally unsupported via the native-assets hook (Q1 2026 spike verdict). The ORT XCFramework ships a static library, but Flutter iOS native-assets requires dynamic link mode. iOS support requires an SPM plugin shim. `_buildIos` in `hook/build.dart` emits a warning and no `CodeAsset`.

**Plans**: Implementation plans live in `plans/`. New work is done on a git branch using a worktree in `.worktrees/`. See `plans/README.md` for the full workflow and plan template.

**License**: All `.dart` files must carry the Apache 2.0 header. `make license_check` / `make license_add` use `addlicense` with the config in `addlicense_config.txt`. Generated files and YAML/config files are excluded.
