// Copyright 2026 The Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/// [OnnxRuntime] — loads the ORT native library staged by the build hook.
///
/// This file is native-only (`dart:io`). Web is excluded from
/// `betto_onnxrt` by design — semantic search is not supported on web
/// (see §20 in the KMDB spec).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'generated/versions.g.dart';
import 'ort_api.dart';
import 'session.dart';
import 'tensor.dart';

/// Entry point for ONNX Runtime inference.
///
/// [OnnxRuntime] opens the ORT dynamic library that was staged by the
/// `betto_onnxrt` native-assets build hook and initialises the `OrtApi`
/// vtable. Inference is performed through [OnnxSession] objects.
///
/// ## Lifecycle
///
/// 1. Call [load] once to open the library and obtain an [OnnxRuntime].
/// 2. Create one or more sessions with [createSession] or [createSessionFromFile].
/// 3. Call [OnnxSession.run] for inference.
/// 4. Call [OnnxSession.dispose] when each session is no longer needed.
/// 5. Call [dispose] when the runtime itself is no longer needed.
///
/// ## Thread safety
///
/// ORT sessions are **thread-affine**: all [OnnxSession.run] and
/// [OnnxSession.dispose] calls must come from the same isolate that called
/// [createSession]. Spawning a separate `Isolate` for inference creates an
/// independent thread that causes ORT's internal thread pool to tear down when
/// the isolate exits, corrupting shared mutex state. If you need isolate
/// offloading, create the session *inside* the spawned isolate.
///
/// [OnnxRuntime] itself (i.e. `load`, `createSession`) is safe to call from
/// any isolate as long as sessions are not shared across isolate boundaries.
final class OnnxRuntime {
  final DynamicLibrary _lib;

  /// The resolved OrtApi vtable pointer for this runtime instance.
  ///
  /// Exposed for internal use by [OnnxSession]. Not part of the public API.
  final Pointer<Void> ortApi;

  OnnxRuntime._(this._lib, this.ortApi);

  /// Opens the ORT library staged by the native-assets build hook and
  /// returns an [OnnxRuntime] ready to create sessions.
  ///
  /// The library is resolved via the native-assets mechanism. `hook/build.dart`
  /// registers the library under the asset ID
  /// `package:betto_onnxrt/src/ort_library.dart`; the Dart/Flutter build
  /// system places the library adjacent to the compiled executable (or inside
  /// the app bundle on mobile) before this call is reached.
  ///
  /// Throws [StateError] if the library cannot be loaded or if the ORT API
  /// version does not match [ortApiVersion].
  static Future<OnnxRuntime> load() async {
    // Open the ORT library. On Android the .so is bundled in the APK lib/
    // directory and the dynamic linker resolves it by name. On all other
    // platforms the build hook places the library adjacent to the executable.
    final lib = _openLibrary();

    // Resolve the single real exported symbol: OrtApiBase* OrtGetApiBase().
    final getApiBase = lib.lookupFunction<OrtGetApiBaseC, OrtGetApiBaseDart>(
      'OrtGetApiBase',
    );
    final apiBase = getApiBase();
    if (apiBase == nullptr) {
      throw StateError(
        'OrtGetApiBase() returned null. '
        'The ORT library may be corrupt or incompatible.',
      );
    }

    // Obtain OrtApi* for the target API version via slot 0 of OrtApiBase.
    // This is the GetApi(uint32_t version) function pointer.
    final getApi = ortSlotPtr<GetApiC>(apiBase, 0).asFunction<GetApiDart>();
    final api = getApi(ortApiVersion);
    if (api == nullptr) {
      throw StateError(
        'ORT API version $ortApiVersion is not supported by this library. '
        'Update VERSION_ONNX in betto_onnxrt and rebuild the native library.',
      );
    }

    return OnnxRuntime._(lib, api);
  }

  /// Creates an [OnnxSession] by loading a model from [modelBytes].
  ///
  /// [modelBytes] must contain the binary content of a valid `.onnx` model
  /// file. The bytes are passed directly to ORT via `CreateSessionFromArray`
  /// (slot 8), avoiding any temporary file.
  ///
  /// [options] controls thread-pool sizing (defaults: single-threaded).
  ///
  /// Throws [Exception] if the model is invalid or cannot be loaded.
  OnnxSession createSession(Uint8List modelBytes, {SessionOptions? options}) {
    return OnnxSession.createFromBytes(ortApi, modelBytes, options: options);
  }

  /// Creates an [OnnxSession] from an ONNX model file at [modelPath].
  ///
  /// [modelPath] must be the absolute path to a `.onnx` file that exists on
  /// the local filesystem. Prefer [createSession] when the model is already
  /// in memory.
  ///
  /// [options] controls thread-pool sizing (defaults: single-threaded).
  ///
  /// Throws [Exception] if [modelPath] does not exist or the model is invalid.
  OnnxSession createSessionFromFile(
    String modelPath, {
    SessionOptions? options,
  }) {
    return OnnxSession.create(ortApi, modelPath, options: options);
  }

  /// Releases the [DynamicLibrary] handle for the ORT native library.
  ///
  /// All [OnnxSession] objects created from this runtime must be
  /// [OnnxSession.dispose]d before calling [dispose]. Accessing a session
  /// after the runtime has been disposed is undefined behaviour.
  void dispose() {
    _lib.close();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Opens the ORT [DynamicLibrary] for the current platform.
  ///
  /// The library path/name matches what the build hook stages:
  /// - macOS: `libonnxruntime.{version}.dylib`
  /// - Linux: `libonnxruntime.so.{version}`
  /// - Windows: `onnxruntime.dll`
  /// - Android: `libonnxruntime.so` (resolved by dynamic linker from APK)
  /// - iOS: ORT is statically linked via the `betto_onnxrt_ios` SPM plugin
  ///   shim; the build hook does not stage a CodeAsset on iOS.
  ///
  /// At runtime Dart's native-assets manifest maps the asset ID
  /// `package:betto_onnxrt/src/ort_library.dart` to the actual bundled file.
  /// We use [DynamicLibrary.process] on iOS (where ORT is statically linked
  /// into the app binary by Xcode via SPM) and a name-based open elsewhere.
  static DynamicLibrary _openLibrary() {
    if (Platform.isIOS) {
      // ORT is statically linked into the app binary by the betto_onnxrt_ios
      // SPM plugin shim; all ORT symbols are in the process image at launch.
      return DynamicLibrary.process();
    }
    if (Platform.isAndroid) {
      // Android: the .so is bundled in the APK lib/{abi}/ directory by the
      // build system; the dynamic linker resolves it by name alone.
      return DynamicLibrary.open('libonnxruntime.so');
    }
    // Desktop (macOS, Linux, Windows): the build hook stages the library
    // adjacent to the compiled executable. The native-assets framework
    // resolves the asset path at build time; at runtime the library is in a
    // known relative location. We open it via the asset name registered by
    // the hook.
    //
    // macOS: the Flutter build system wraps DynamicLoadingBundled dylibs in
    // versioned .framework bundles. The framework name is derived from the
    // staged filename (libonnxruntime.{ver}.dylib) by stripping 'lib', the
    // '.dylib' suffix, and all dots: libonnxruntime.1.22.0.dylib →
    // onnxruntime1220.framework/onnxruntime1220. macOS dlopen expands rpath
    // entries for relative paths, so the @executable_path/../Frameworks rpath
    // baked into the app binary finds Contents/Frameworks/onnxruntime1220.framework/.
    if (Platform.isMacOS) {
      final fw = 'onnxruntime${ortVersion.replaceAll('.', '')}';
      return DynamicLibrary.open('$fw.framework/$fw');
    }
    if (Platform.isLinux) return DynamicLibrary.open('libonnxruntime.so');
    if (Platform.isWindows) return DynamicLibrary.open('onnxruntime.dll');
    throw UnsupportedError(
      'betto_onnxrt: unsupported platform ${Platform.operatingSystem}. '
      'Supported: macOS, Linux, Windows, Android, iOS.',
    );
  }
}
