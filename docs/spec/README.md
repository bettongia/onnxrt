# betto_onnxrt Specification

**Package**: `betto_onnxrt`  
**Version**: 0.1.0  
**ORT version**: 1.22.0  
**Audience**: Dart and Flutter developers integrating `betto_onnxrt` into applications.

---

## Contents

1. [Overview](#1-overview)
2. [Platform support](#2-platform-support)
3. [Requirements](#3-requirements)
4. [Binary delivery — native-assets build hook](#4-binary-delivery--native-assets-build-hook)
5. [Public API](#5-public-api)
   - 5.1 [OnnxRuntime](#51-onnxruntime)
   - 5.2 [OnnxSession](#52-onnxsession)
   - 5.3 [OnnxTensor and OnnxElementType](#53-onnxtensor-and-onnxelementtype)
   - 5.4 [SessionOptions](#54-sessionoptions)
   - 5.5 [ModelDownloader](#55-modeldownloader)
   - 5.6 [ModelSpec, ModelFile, and ResolvedModel](#56-modelspec-modelfile-and-resolvedmodel)
   - 5.7 [AllowlistProvider](#57-allowlistprovider)
   - 5.8 [Error handling and recovery](#58-error-handling-and-recovery)
6. [iOS — SPM plugin shim](#6-ios--spm-plugin-shim)
7. [Thread safety](#7-thread-safety)
8. [Known limitations and future work](#8-known-limitations-and-future-work)

---

## 1. Overview

`betto_onnxrt` is a **pure-Dart library** (no Flutter dependency) that brings
ONNX Runtime inference to Dart and Flutter applications across macOS, Linux,
Windows, Android, and iOS. It has three concerns:

1. **Binary delivery** — a native-assets build hook (`hook/build.dart`)
   downloads and verifies the correct prebuilt ORT binary for the target
   platform at compile time. Consumers never manage binaries manually.

2. **Inference API** — a thin FFI wrapper around the ORT C API vtable that
   exposes a generalised `OnnxSession.run` capable of loading any ONNX model,
   not one specific architecture.

3. **Model download infrastructure** — `ModelDownloader` fetches and locally
   caches ONNX model files described by a `ModelSpec`. Downloads are
   SHA-256-verified and written crash-safely via a temp-file + atomic rename.

### ONNX Runtime version

`betto_onnxrt` bundles **ONNX Runtime v1.22.0**, sourced from the
[ONNX Runtime project](https://onnxruntime.ai). Bumping the bundled version
requires updating `VERSION_ONNX` at the repo root, regenerating
`lib/src/generated/versions.g.dart`, and updating the SHA-256 manifest in
`hook/build.dart`.

The primary consumer within the Bettongia workspace is `kmdb_inferencing`,
which uses `betto_onnxrt` to run BGE embedding models for semantic search.
The library is intentionally generic so it can serve any ONNX model.

---

## 2. Platform support

| Platform | Status       | Notes |
|----------|--------------|-------|
| macOS    | Supported    | `libonnxruntime.dylib` bundled via hook; wrapped in a `.framework` by Flutter. |
| Linux    | Supported    | `libonnxruntime.so` bundled via hook. |
| Windows  | Supported    | `onnxruntime.dll` bundled via hook. |
| Android  | Supported    | `libonnxruntime.so` bundled in APK `lib/{abi}/`; requires `minSdkVersion 35`. Supported ABIs: `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`. |
| iOS      | Supported    | Via the `betto_onnxrt_ios` SPM plugin shim. ORT is statically linked at build time; `DynamicLibrary.process()` resolves the symbols. See §6. |
| Web      | Not supported | The browser provides no FFI mechanism and no `dart:io`, so the ORT native library cannot be loaded or called. ONNX inference on web would require a WASM build of ORT, which is out of scope. |

---

## 3. Requirements

- Dart SDK `^3.12.0`
- Native-assets support enabled (`dart` ≥ 3.3 or `flutter` ≥ 3.22 for stable
  native-assets support).

### Android

Set `minSdkVersion` to at least **35** in `android/app/build.gradle`:

```kotlin
android {
    defaultConfig {
        minSdk = 35
    }
}
```

No additional Gradle dependencies or manual binary management are required. The
build hook handles the ORT `.so` download, verification, and placement.

### iOS

Add the `betto_onnxrt_ios` package as a dependency alongside `betto_onnxrt`.
No additional Xcode configuration is required; the SPM plugin shim pulls the
ORT XCFramework automatically. See §6 for full details.

---

## 4. Binary delivery — native-assets build hook

`hook/build.dart` runs automatically during every `dart build` or
`flutter build`. It has no effect on the consumer beyond binary availability.

### What the hook does

1. Determines the target platform and ABI from the build environment.
2. Checks whether a valid cached binary already exists at
   `.dart_tool/betto_onnxrt/{ort_version}/`. If so, skips the download.
3. Downloads the correct prebuilt ORT binary:
   - **Desktop** (macOS, Linux, Windows): GitHub Releases.
   - **Android**: Maven Central (the official `com.microsoft.onnxruntime:onnxruntime-android` AAR).
4. Verifies SHA-256:
   - **Android**: two-level verification — the downloaded AAR archive first,
     then each extracted `.so` per ABI.
   - **Desktop** (macOS, Linux, Windows): archive-level verification against the
     digest in `version_onnx.json`. Real SHA-256 digests are in place as of
     v1.22.0. Cached binaries are trusted via a `.sha256` sidecar file.
   - **iOS**: the hook emits no `CodeAsset` on iOS and does not consult the
     manifest; iOS SHA-256 is recorded in `version_onnx.json` for reference only.
5. Registers the binary as a `CodeAsset` with `DynamicLoadingBundled` link
   mode so the Dart/Flutter build system places it alongside the executable.

### Hook does nothing on iOS

The hook emits a warning and **no `CodeAsset`** for iOS. The ORT XCFramework
ships a static library; Flutter iOS native-assets requires dynamic link mode.
iOS support is handled entirely by the SPM plugin shim (see §6).

### Cache location

`.dart_tool/betto_onnxrt/{ort_version}/` — version-scoped so bumping
`VERSION_ONNX` forces a re-download.

---

## 5. Public API

All public types are exported from `package:betto_onnxrt/betto_onnxrt.dart`.

### 5.1 OnnxRuntime

Entry point for inference. Opens the ORT native library staged by the build
hook and initialises the `OrtApi` vtable.

```dart
final class OnnxRuntime {
  static Future<OnnxRuntime> load();

  OnnxSession createSession(
    Uint8List modelBytes, {
    SessionOptions? options,
  });

  OnnxSession createSessionFromFile(
    String modelPath, {
    SessionOptions? options,
  });

  void dispose();
}
```

**Lifecycle**:

1. Call `OnnxRuntime.load()` once to open the library and obtain a runtime.
2. Create one or more sessions with `createSession` or `createSessionFromFile`.
3. Call `OnnxSession.run` for inference.
4. Call `OnnxSession.dispose()` when each session is no longer needed.
5. Call `OnnxRuntime.dispose()` when the runtime itself is no longer needed.
   All sessions must be disposed before the runtime.

**`createSession(modelBytes)`** loads the ONNX model directly from memory via
ORT's `CreateSessionFromArray` (slot 8). Prefer this when the model is already
in memory; it avoids temporary file I/O and is safe on platforms that use
lazy mmap.

**`createSessionFromFile(modelPath)`** loads the model from an absolute file
path via ORT's `CreateSession` (slot 7). `modelPath` must exist on the local
filesystem.

**`load()` throws** `StateError` if the native library cannot be opened or if
the ORT API version does not match the compiled-in `ortApiVersion`.

### 5.2 OnnxSession

A thin FFI wrapper around an ORT inference session. Not constructed directly;
obtained via `OnnxRuntime.createSession` or `OnnxRuntime.createSessionFromFile`.

```dart
final class OnnxSession {
  List<OnnxTensor> run({
    required Map<String, OnnxTensor> inputs,
    required List<String> outputNames,
  });

  void dispose();
}
```

**`run`** submits the inputs to ORT (`Run`, slot 9) and returns the requested
output tensors in the same order as `outputNames`. Each output tensor's
`shape` is read from the native `OrtValue` via the type-and-shape-info vtable
slots (65, 61, 62). All native handles are released before `run` returns.

**`run` throws** `Exception` if any ORT call fails; `ArgumentError` if an
output tensor has an unsupported element type.

**`dispose`** releases the native ORT session, memory info, and environment
handles. Must be called exactly once; calling `run` after `dispose` is
undefined behaviour.

**Output element type (v0.1.0 constraint)**: `run` always returns
`OnnxElementType.float32` output tensors regardless of the model's declared
output type. Full element-type introspection via slot 35 is planned for a
future version. See §8.

### 5.3 OnnxTensor and OnnxElementType

`OnnxTensor` is both the input type for `OnnxSession.run` and the return type
for each output.

```dart
final class OnnxTensor {
  final OnnxElementType elementType;
  final List<int> shape;      // e.g. [1, 512] for batch=1, seq=512
  final TypedData data;

  int get elementCount;       // product of all dimensions; 1 for scalars

  // Named factories for constructing input tensors:
  factory OnnxTensor.fromFloat32(List<int> shape, Float32List data);
  factory OnnxTensor.fromFloat64(List<int> shape, Float64List data);
  factory OnnxTensor.fromInt32(List<int> shape, Int32List data);
  factory OnnxTensor.fromInt64(List<int> shape, Int64List data);
  factory OnnxTensor.fromUint8(List<int> shape, Uint8List data);

  // Typed accessors:
  Float32List asFloat32();
  Int64List asInt64();
}
```

`OnnxElementType` maps to `ONNXTensorElementDataType` in `onnxruntime_c_api.h`.
Supported types in v0.1.0:

| `OnnxElementType` | ONNX type code | `TypedData` type |
|-------------------|---------------|-----------------|
| `float32`         | 1             | `Float32List`   |
| `uint8`           | 2             | `Uint8List`     |
| `int32`           | 6             | `Int32List`     |
| `int64`           | 7             | `Int64List`     |
| `float64`         | 11            | `Float64List`   |

Output tensor data is **copied** from native memory into the Dart `TypedData`
before the `OrtValue` handle is released. Callers own the returned data and
do not need to free it.

### 5.4 SessionOptions

Controls ORT thread-pool sizing. Both counts default to `1` (single-threaded),
which is the safe default for applications that create sessions from a single
Dart isolate.

```dart
final class SessionOptions {
  const SessionOptions({
    int intraOpNumThreads = 1,   // threads within a single operator
    int interOpNumThreads = 1,   // threads across independent operators
  });
}
```

Raising these values above `1` enables ORT parallelism but introduces
thread-pool teardown races when the session is released from a spawned isolate.
See §7.

### 5.5 ModelDownloader

Downloads and locally caches ONNX model files described by a `ModelSpec`.

```dart
final class ModelDownloader {
  ModelDownloader({
    AllowlistProvider? allowlist,
    HttpClient Function()? httpClientFactory,
  });

  Future<ResolvedModel> ensure(
    ModelSpec spec, {
    required String cacheDir,
    DownloadProgress? onProgress,
  });
}

typedef DownloadProgress = void Function(int received, int total);
```

**`ensure`** guarantees that all files in `spec.files` are present under
`cacheDir/{spec.id}/` and that their SHA-256 checksums match. Files that are
already cached and valid are not re-downloaded (fast path: existence + checksum
check only). Returns a `ResolvedModel` with absolute paths to each file.

**Download protocol**:

1. Check existence and SHA-256 of the destination file. Skip if valid.
2. Download to `{dest}.part` (a `.part` suffix ensures partial downloads are
   never treated as complete on a later run).
3. Verify SHA-256 of the downloaded data. Delete `.part` and throw `StateError`
   on mismatch.
4. Atomically rename `.part` to the final path.

**Concurrency**: concurrent callers sharing the same `cacheDir` are safe
without locking; last-writer-wins on the atomic rename is correct because both
writers produce byte-identical, checksum-verified output.

**`onProgress`**: called with `(received, total)` bytes during each download.
`total` is `-1` when the server does not supply a `Content-Length` header.

**Throws**:
- `ArgumentError` if `allowlist` rejects `spec`.
- `StateError` if a downloaded file fails SHA-256 verification.
- `HttpException` if the server returns a non-2xx status.

**`httpClientFactory`**: injectable for testing. Defaults to `HttpClient.new`.
Inject a mock factory in unit tests to avoid network access.

#### Cache management and recovery

The core guarantee is that **`ensure` is idempotent and self-healing** — calling
it is always safe and is the correct recovery action for almost every filesystem
anomaly. Consumers do not need to pre-check the cache state before calling it.

| Scenario | What happens |
|----------|-------------|
| File is present and checksum matches | Returned immediately; no network access. |
| File is missing (never downloaded, or manually deleted) | Re-downloaded and verified. |
| File is present but checksum fails (corrupted or manually modified) | Re-downloaded and verified; corrupt file is overwritten. |
| `ModelSpec` updated to a new URL or SHA-256 | Existing file fails the new checksum check; re-downloaded automatically. |
| Leftover `.part` file from a previously interrupted download | Silently overwritten on the next download attempt. |
| Cache directory missing (manually deleted) | Recreated automatically before writing. |
| Disk full during download | `.part` file may be left behind; surfaces as `IOException`. Call `ensure` again once space is available — the `.part` file is overwritten and the download retried. |
| File or directory permission error | Surfaces as `IOException`. Fix permissions on `cacheDir`, then call `ensure` again. |

**Clearing the cache explicitly**: to force a fresh download — for example, to
free disk space or to recover from an unknown filesystem state — delete the
model's subdirectory and call `ensure` again:

```dart
// Force a clean re-download of a specific model.
final modelDir = Directory('$cacheDir/${spec.id}');
if (await modelDir.exists()) {
  await modelDir.delete(recursive: true);
}
final resolved = await downloader.ensure(spec, cacheDir: cacheDir);
```

To clear all cached models, delete the entire `cacheDir` directory. `ensure`
will recreate it on the next call.

**Choosing a cache location**: use the application's persistent data directory
(e.g. from `path_provider`'s `getApplicationSupportDirectory()` on Flutter, or
a stable path of your choice on Dart CLI). Avoid `Directory.systemTemp` in
production — its contents may be cleared by the OS between runs, triggering
unnecessary re-downloads.

### 5.6 ModelSpec, ModelFile, and ResolvedModel

```dart
final class ModelSpec {
  const ModelSpec({
    required String id,
    required Map<String, ModelFile> files,
    Map<String, Object?> meta = const {},
  });
}

final class ModelFile {
  const ModelFile({required Uri url, required String sha256});
}

final class ResolvedModel {
  final ModelSpec spec;
  final Map<String, String> filePaths;  // same keys as spec.files
}
```

`ModelSpec.id` is used as the subdirectory name under `cacheDir` and should be
stable across versions. Changing `id` invalidates the existing cache entry.

`ModelSpec.meta` is uninterpreted by `betto_onnxrt`. Consumers store
model-specific parameters here (e.g. `{'dimensions': 384}` for an embedding
model's output dimension).

File keys in `spec.files` (e.g. `'onnx'`, `'vocab'`) are caller-defined.
`ResolvedModel.filePaths` uses the same keys with absolute local path values.

### 5.7 AllowlistProvider

```dart
abstract interface class AllowlistProvider {
  bool isAllowed(ModelSpec spec);
}
```

Implement this interface to restrict which models `ModelDownloader` will fetch.
Pass an instance to `ModelDownloader(allowlist: ...)`. If `null` (the default),
`ModelDownloader` operates in permit-all mode.

**Security note**: ONNX models are executable artifacts — they can contain
custom operators that invoke arbitrary native code at inference time. Accepting
a model from an unknown or untrusted source carries the same risk as running an
arbitrary binary. `AllowlistProvider` is therefore a **security control**, not
merely a catalogue-management convenience. Production applications should always
supply an allowlist and treat the permitted set as a trust boundary, reviewing
any new model ID before adding it.

The canonical implementation pattern:

```dart
class ModelCatalog implements AllowlistProvider {
  static const _permitted = {'bge-small-en-v1.5', 'bge-m3-v1.0'};

  @override
  bool isAllowed(ModelSpec spec) => _permitted.contains(spec.id);
}
```

### 5.8 Error handling and recovery

#### OnnxRuntime.load()

A failure here means the ORT native library could not be opened or its API
version is incompatible. This is not a transient error — retrying `load()` on
the same process will produce the same result. Recovery options are:

- If the error message indicates an API version mismatch, the bundled ORT
  binary is incompatible with the vtable slots compiled into the library.
  Update `betto_onnxrt` to a version that matches the binary, or bump
  `VERSION_ONNX` and rebuild.
- If the library cannot be found, the native-assets build hook did not run or
  did not stage the binary correctly. Run `dart pub get` (which triggers the
  hook) and rebuild.
- On iOS, a `symbol not found: OrtGetApiBase` error means `betto_onnxrt_ios`
  is not in the dependency graph. Add it to `pubspec.yaml` and rebuild.

#### OnnxSession.run()

A thrown `Exception` from `run()` means ORT itself rejected the inputs or
encountered an internal error. The session's **state is undefined after a
`run()` failure** — do not attempt to call `run()` again on the same session.
Instead:

1. Call `session.dispose()` to release native handles.
2. Create a fresh session via `runtime.createSession(...)`.
3. Retry the inference call on the new session.

The `OnnxRuntime` instance itself remains valid after a session failure and
does not need to be re-created.

#### ModelDownloader.ensure()

Network and checksum errors from `ensure()` are transient by design — calling
`ensure()` again is always the correct recovery action. See the cache
management table in §5.5 for a full breakdown of scenarios.

---

## 6. iOS — SPM plugin shim

The ORT XCFramework ships a **static library**. Flutter's iOS native-assets
pipeline requires **dynamic** link mode, so the build hook cannot stage a
`CodeAsset` on iOS. Support is instead provided by a companion Flutter plugin:
`betto_onnxrt_ios`.

### How it works

1. `betto_onnxrt_ios` is a Flutter plugin (in `packages/betto_onnxrt_ios/`)
   that declares an SPM dependency on
   `microsoft/onnxruntime-swift-package-manager` (`onnxruntime-c`).
2. Xcode pulls the ORT XCFramework via SPM and **statically links** it into
   the host app binary at build time.
3. Because ORT is part of the process image at launch, `betto_onnxrt` uses
   `DynamicLibrary.process()` on iOS instead of `DynamicLibrary.open(...)`.
   All ORT C API symbols are resolved from the process image.
4. The build hook detects `Platform.isIOS`, emits a warning, and produces no
   `CodeAsset`. The hook's absence is the correct behaviour; the plugin shim
   is the sole mechanism.

### Consumer setup

Add both packages to `pubspec.yaml`:

```yaml
dependencies:
  betto_onnxrt: ^0.1.0
  betto_onnxrt_ios: ^0.1.0
```

No additional Xcode project configuration is required. SPM integration is
declared inside the plugin and handled automatically by `flutter build ios`.

**Multi-platform apps**: it is safe to add `betto_onnxrt_ios` unconditionally
to an app that also targets Android, macOS, Windows, or Linux. The plugin
declares only the `ios` platform in its pubspec, so Flutter activates it
exclusively during iOS builds. It has no effect on any other platform and
introduces no runtime overhead there.

### CocoaPods note

CocoaPods support is deprecated by the CocoaPods project (end-of-2026 per the
[CocoaPods support plans announcement](https://blog.cocoapods.org/CocoaPods-Support-Plans)).
`betto_onnxrt_ios` uses only SPM and is not registered with or dependent on
CocoaPods.

---

## 7. Thread safety

**`OnnxSession` is thread-affine** — it is bound to the thread (Dart isolate)
that created it, and all `run` and `dispose` calls must come from that same
isolate. ORT maintains an internal
thread pool per environment; releasing a session from a different isolate can
corrupt that pool's mutex state.

**Pattern for isolate-based parallelism**: create a fresh `OnnxRuntime` (and
therefore a fresh ORT environment) inside each isolate. Do not share sessions
across isolate boundaries.

```dart
// Correct: isolate creates its own runtime and session.
await Isolate.run(() async {
  final runtime = await OnnxRuntime.load();
  final session = runtime.createSession(modelBytes);
  final result = session.run(inputs: {...}, outputNames: [...]);
  session.dispose();
  runtime.dispose();
  return result;
});
```

**`OnnxRuntime` itself** (`load`, `createSession`) is safe to call from any
isolate, as long as sessions created in that isolate are not transferred to
another.

---

## 8. Known limitations and future work

### CPU-only inference

v0.1.0 uses only the default ORT CPU execution provider. GPU acceleration
(CUDA on Windows/Linux, CoreML on macOS/iOS, NNAPI on Android) is not exposed.
Adding execution provider support requires extending `SessionOptions` and the
session creation path; this is tracked for a future version.

### Output element type always float32

`OnnxSession.run` currently returns all output tensors as `OnnxElementType.float32`
regardless of the model's declared output type. Reading the actual element type
from the native `OrtValue` via vtable slot 35 (`GetTensorElementType`) is
planned for v0.2.0. Models that produce non-float32 outputs (e.g. classifier
logits as `int64`) will have their data misinterpreted in v0.1.0.

### ONNX external data format not supported via in-memory loading

Some large models split weights into a separate `.onnx_data` file alongside
the `.onnx` graph file (ONNX external data format). `createSession(modelBytes)`
cannot load such models — ORT requires the external data file to be on disk and
resolvable relative to the `.onnx` path, which is impossible when loading from
a byte array.

`createSessionFromFile(modelPath)` may work if all files are co-located in the
same directory (e.g. downloaded together via `ModelDownloader` into
`cacheDir/{spec.id}/`), but this path is untested and not officially supported
in v0.

**Workaround**: prefer quantized or otherwise self-contained single-file ONNX
exports. For BGE-M3, for example, `Xenova/bge-m3`'s `model_quantized.onnx`
(570 MB, int8 weights, float32 output) is a drop-in alternative to the
full-precision `BAAI/bge-m3` export which requires a separate 2.17 GB
`model.onnx_data` file.

### iOS SHA-256 digest is not verified at build time

Desktop (macOS, Linux, Windows) SHA-256 verification is active as of v1.22.0.
All desktop archive digests are recorded in `version_onnx.json` and verified
by the hook before extraction.

The iOS entry in `version_onnx.json` carries a real SHA-256 digest (sourced
from Microsoft's SPM `Package.swift` at tag 1.24.2) for documentation and
supply-chain reference. However, the hook exits before any manifest lookup on
iOS — no `CodeAsset` is emitted and no binary is downloaded. The iOS digest is
therefore not verified at build time; it is a documented-unreachable value that
records what ORT version the SPM shim links.

### Windows and Linux integration testing

Pure-Dart ORT inference is exercised automatically in CI on both platforms:

- **Linux** (`build` job in `.github/workflows/cicd.yml`): `cicd_linux` runs
  `dart pub get`, creates the unversioned `libonnxruntime.so` symlink, exports
  `LD_LIBRARY_PATH`, then calls `dart test` — including `onnx_session_test.dart`
  against the real ORT binary. `make linux_test` is the analogous local target
  for running only the ORT inference tests in isolation.
- **Windows** (`test-windows` job): `cicd_windows` runs `dart pub get` (which
  stages `onnxruntime.dll`) and `dart test` — including `onnx_session_test.dart`
  against the real DLL. `make windows_test` is the analogous local convenience
  target; it assumes `PATH` already includes the ORT DLL directory (as the CI
  pipeline sets up in the "Add ORT DLL directory to PATH" step).

Flutter Desktop automation on Linux and Windows remains out of scope for v0.
The written manual smoke checklist at `docs/manual_checks.md` covers this gap
with the detail needed for a trustworthy non-automated check: Flutter
channel/version, load-verification steps, failure signatures, and where to
record evidence in the PR description.
