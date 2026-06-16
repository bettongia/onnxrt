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

/// OnnxSession integration tests.
///
/// These tests require the ORT native binary to be staged by the build hook
/// (`dart build` / `flutter build`). They are therefore **skipped in CI**
/// unless the hook has already run and produced a cached artifact at
/// `.dart_tool/betto_onnxrt/{version}/`.
///
/// To run locally after the hook has produced the binary:
///   cd /path/to/onnxrt && dart test test/onnx_session_test.dart
///
/// See `docs/spec/README.md` §8 for the full manual verification procedure.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:betto_onnxrt/betto_onnxrt.dart';
import 'package:betto_onnxrt/src/ort_api.dart'
    show
        GetApiC,
        GetApiDart,
        OrtGetApiBaseC,
        OrtGetApiBaseDart,
        ortApiVersion,
        ortSlotPtr;
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Returns `true` when `OnnxRuntime.load()` is expected to succeed.
///
/// Mirrors the exact platform name that `OnnxRuntime._openLibrary()` passes to
/// `DynamicLibrary.open` so the probe matches what the actual load path will do.
/// The library must be on the OS dynamic-linker search path (e.g. via
/// `DYLD_LIBRARY_PATH` on macOS or `LD_LIBRARY_PATH` on Linux), which is only
/// set up by a `dart build` / AOT pipeline — plain `dart test` JIT mode does
/// not inject the native-assets path for filename-based opens.
///
/// Also verifies the ORT API version matches [ortApiVersion]. A system-wide
/// ORT installation of the wrong version (e.g. 1.17.x on Windows CI runners)
/// opens successfully via `DynamicLibrary.open` but would fail the version
/// check inside `OnnxRuntime.load()` — this probe catches that case and
/// returns `false` so the tests are skipped rather than failing.
///
/// Returns `false` (and all OnnxSession tests are skipped) on any failure.
bool _ortLibraryAvailable() {
  // Hoist libName so the catch block can reference it in diagnostic output.
  final String libName;
  if (Platform.isMacOS) {
    libName = 'libonnxruntime.dylib';
  } else if (Platform.isLinux) {
    libName = 'libonnxruntime.so';
  } else if (Platform.isWindows) {
    // Use an absolute path rather than a bare DLL name.  On Windows,
    // LoadLibrary searches System32 *before* PATH entries, so a system-wide
    // ORT installation (e.g. Windows ML in System32) is found first when
    // only the filename is given — regardless of our PATH prepend.  An
    // absolute path bypasses the search entirely and also causes Windows to
    // look for onnxruntime_providers_shared.dll in the same directory.
    libName = _windowsOrtDllPath(_packageRoot());
  } else {
    return false; // Android/iOS require full build — always skip in test.
  }
  try {
    final lib = DynamicLibrary.open(libName);
    // Verify the ORT API version matches what this package was built against.
    // Mirrors the version check in OnnxRuntime.load().
    final getApiBase = lib.lookupFunction<OrtGetApiBaseC, OrtGetApiBaseDart>(
      'OrtGetApiBase',
    );
    final apiBase = getApiBase();
    if (apiBase == nullptr) {
      lib.close();
      return false;
    }
    final getApi = ortSlotPtr<GetApiC>(apiBase, 0).asFunction<GetApiDart>();
    final compatible = getApi(ortApiVersion) != nullptr;
    lib.close();
    return compatible;
  } catch (e, st) {
    // Print on CI so the exact LoadLibrary error appears in the job log.
    if (Platform.environment.containsKey('CI')) {
      print('[betto_onnxrt diag] DynamicLibrary.open($libName) failed: $e');
      print('[betto_onnxrt diag] $st');
    }
    return false;
  }
}

/// Returns the package root directory.
///
/// `dart test` always sets `Directory.current` to the package root when
/// invoked from the package directory (or via melos). This is more reliable
/// than `Platform.script`, which can point to a `.dill` snapshot path when
/// running a single test file.
String _packageRoot() => Directory.current.path;

/// Returns the absolute path to `onnxruntime.dll` in the hook cache.
///
/// Reads the platform-specific version from `version_onnx.json` so we open
/// exactly the DLL that the hook staged (e.g. `1.22.1` on Windows, which
/// differs from the `1.22.0` baseline in `VERSION_ONNX`).  An absolute path
/// is required because `LoadLibrary` on Windows searches `System32` before
/// `PATH` entries — a bare filename always finds a pre-installed system ORT
/// (e.g. Windows ML) before our cached version.
///
/// Falls back to the bare filename `'onnxruntime.dll'` if the manifest or
/// the cached file cannot be found, so that local developer setups without
/// a system ORT still work.
String _windowsOrtDllPath(String packageRoot) {
  try {
    final manifest =
        jsonDecode(File('$packageRoot/version_onnx.json').readAsStringSync())
            as Map<String, dynamic>;
    final key = Abi.current() == Abi.windowsArm64
        ? 'windows-arm64'
        : 'windows-x64';
    final version =
        ((manifest['platforms'] as Map<String, dynamic>)[key]
                as Map<String, dynamic>)['version']
            as String;
    final dll = File(
      '$packageRoot/.dart_tool/betto_onnxrt/$version/onnxruntime.dll',
    );
    if (dll.existsSync()) return dll.path;
  } catch (_) {}
  return 'onnxruntime.dll';
}

/// Skip message shown when the ORT library is not staged.
const _skipMessage =
    'ORT binary not staged — run `dart build` (or the betto_onnxrt hook) '
    'first. See test/onnx_session_test.dart file-level doc and '
    'docs/spec/README.md §8.';

// ── Tiny ONNX fixture path ─────────────────────────────────────────────────---

String get _fixtureModelPath {
  final packageRoot = _packageRoot();
  return '$packageRoot/test/fixtures/identity_float32.onnx';
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // Evaluate availability once per test run to avoid repeated filesystem hits.
  final ortAvailable = _ortLibraryAvailable();

  // On CI runners where the ORT binary should be staged (Linux and Windows),
  // a missing binary indicates a misconfigured pipeline — fail immediately
  // rather than silently skipping all inference tests.
  //
  // macOS is excluded: dart test runs in JIT mode where the macOS framework
  // path only exists after a Flutter/AOT build.  macOS inference coverage is
  // provided by `make macos_test` (Flutter integration test) in CI.
  setUpAll(() {
    final inCI = Platform.environment.containsKey('CI');
    if (inCI && (Platform.isLinux || Platform.isWindows) && !ortAvailable) {
      // Emit diagnostics so the CI log shows exactly what went wrong.
      final cacheRoot = Directory('${_packageRoot()}/.dart_tool/betto_onnxrt');
      print('[betto_onnxrt diag] cache root: ${cacheRoot.path}');
      if (cacheRoot.existsSync()) {
        for (final e in cacheRoot.listSync(recursive: true)) {
          print('[betto_onnxrt diag]   ${e.path}');
        }
      } else {
        print('[betto_onnxrt diag]   (cache root does not exist)');
      }
      if (Platform.isWindows) {
        final path = Platform.environment['PATH'] ?? '(not set)';
        print('[betto_onnxrt diag] PATH=$path');
      }
      fail(
        'CI: ORT binary not found on the dynamic-linker search path. '
        'Ensure LD_LIBRARY_PATH (Linux) or PATH (Windows) includes '
        '.dart_tool/betto_onnxrt/<version>/ before running dart test. '
        'See .github/workflows/cicd.yml for the setup steps.',
      );
    }
  });

  // All groups in this file are skipped unless the ORT library is staged.
  //
  // Design rationale: OnnxSession wraps the ORT C API via numeric vtable
  // slot indices. The FFI binding cannot be exercised without the real binary;
  // there is no safe way to mock a DynamicLibrary at the Dart level. A tiny
  // fixture .onnx model (test/fixtures/identity_float32.onnx) is sufficient
  // for these tests — it does not need to be a real trained model, just a
  // valid ONNX graph with the expected input/output names and shapes.

  group('OnnxRuntime.load', () {
    test(
      'load() returns an OnnxRuntime with a non-null ortApi',
      skip: ortAvailable ? false : _skipMessage,
      () async {
        final rt = await OnnxRuntime.load();
        addTearDown(rt.dispose);
        // ortApi is Pointer<Void> — it is non-null when the library loaded.
        // We test this indirectly: if load() did not throw, the api is valid.
        expect(rt, isNotNull);
      },
    );
  });

  group('OnnxSession — identity model', () {
    late OnnxRuntime runtime;

    setUp(() async {
      if (!ortAvailable) return;
      runtime = await OnnxRuntime.load();
    });

    tearDown(() {
      if (!ortAvailable) return;
      runtime.dispose();
    });

    test(
      'createSession from bytes does not throw',
      skip: ortAvailable ? false : _skipMessage,
      () {
        final modelBytes = File(_fixtureModelPath).readAsBytesSync();
        final session = runtime.createSession(modelBytes);
        addTearDown(session.dispose);
        expect(session, isNotNull);
      },
    );

    test(
      'createSessionFromFile does not throw',
      skip: ortAvailable ? false : _skipMessage,
      () {
        final session = runtime.createSessionFromFile(_fixtureModelPath);
        addTearDown(session.dispose);
        expect(session, isNotNull);
      },
    );

    test(
      'run() returns one float32 output tensor with correct shape',
      skip: ortAvailable ? false : _skipMessage,
      () {
        // The identity_float32.onnx fixture is a single-op ONNX graph:
        //   input:  'input'  — float32[1, 4]
        //   output: 'output' — float32[1, 4]
        // It passes the input directly to the output (identity op).
        final session = runtime.createSessionFromFile(_fixtureModelPath);
        addTearDown(session.dispose);

        final inputData = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
        final input = OnnxTensor.fromFloat32([1, 4], inputData);

        final outputs = session.run(
          inputs: {'input': input},
          outputNames: ['output'],
        );

        expect(outputs, hasLength(1));
        expect(outputs[0].elementType, equals(OnnxElementType.float32));
        expect(outputs[0].shape, equals([1, 4]));

        final outData = outputs[0].asFloat32();
        expect(outData, equals([1.0, 2.0, 3.0, 4.0]));
      },
    );

    test(
      'SessionOptions with custom thread counts is accepted',
      skip: ortAvailable ? false : _skipMessage,
      () {
        const opts = SessionOptions(intraOpNumThreads: 2, interOpNumThreads: 1);
        final session = runtime.createSessionFromFile(
          _fixtureModelPath,
          options: opts,
        );
        addTearDown(session.dispose);
        expect(session, isNotNull);
      },
    );

    test(
      'dispose() can be called without error',
      skip: ortAvailable ? false : _skipMessage,
      () {
        final session = runtime.createSessionFromFile(_fixtureModelPath);
        // Should not throw.
        expect(session.dispose, returnsNormally);
      },
    );
  });

  // ── Non-float32 output types ───────────────────────────────────────────────
  //
  // These tests exercise the _copyTensorData branches in session.dart for
  // element types other than float32.  They are gated on the same ORT
  // availability check as the identity-model tests above, so they are skipped
  // under plain `dart test` on macOS (where the ORT dylib is not on the
  // dynamic-linker path after a JIT run) and only execute on Linux/Windows CI
  // (where the hook has staged the ORT binary) and via `make macos_test`.
  //
  // A minimal ONNX identity fixture is used for each type — the fixture is
  // committed to test/fixtures/ and carries no weights.

  group('OnnxSession — non-float32 output', () {
    late OnnxRuntime runtime;

    setUp(() async {
      if (!ortAvailable) return;
      runtime = await OnnxRuntime.load();
    });

    tearDown(() {
      if (!ortAvailable) return;
      runtime.dispose();
    });

    test(
      'uint8 identity model: elementType==uint8 and values preserved',
      skip: ortAvailable ? false : _skipMessage,
      () {
        // identity_uint8.onnx: input/output uint8[1,4], elem_type=2.
        // The _copyTensorData uint8 branch allocates a Uint8List and copies
        // each element via rawPtr.cast<Uint8>()[i].
        final fixturePath =
            '${_packageRoot()}/test/fixtures/identity_uint8.onnx';
        final session = runtime.createSessionFromFile(fixturePath);
        addTearDown(session.dispose);

        final inputData = Uint8List.fromList([10, 20, 30, 40]);
        final input = OnnxTensor.fromUint8([1, 4], inputData);

        final outputs = session.run(
          inputs: {'input': input},
          outputNames: ['output'],
        );

        expect(outputs, hasLength(1));
        expect(outputs[0].elementType, equals(OnnxElementType.uint8));
        expect(outputs[0].shape, equals([1, 4]));
        expect(outputs[0].asUint8(), equals([10, 20, 30, 40]));
      },
    );

    test(
      'int32 identity model: elementType==int32 and values preserved',
      skip: ortAvailable ? false : _skipMessage,
      () {
        // identity_int32.onnx: input/output int32[1,4], elem_type=6.
        // The _copyTensorData int32 branch allocates an Int32List and copies
        // each element via rawPtr.cast<Int32>()[i].
        final fixturePath =
            '${_packageRoot()}/test/fixtures/identity_int32.onnx';
        final session = runtime.createSessionFromFile(fixturePath);
        addTearDown(session.dispose);

        final inputData = Int32List.fromList([100, 200, 300, 400]);
        final input = OnnxTensor.fromInt32([1, 4], inputData);

        final outputs = session.run(
          inputs: {'input': input},
          outputNames: ['output'],
        );

        expect(outputs, hasLength(1));
        expect(outputs[0].elementType, equals(OnnxElementType.int32));
        expect(outputs[0].shape, equals([1, 4]));
        expect(outputs[0].asInt32(), equals([100, 200, 300, 400]));
      },
    );

    test(
      'int64 identity model: elementType==int64 and values preserved',
      skip: ortAvailable ? false : _skipMessage,
      () {
        // identity_int64.onnx: input/output int64[1,4], elem_type=7.
        // The _copyTensorData int64 branch allocates an Int64List and copies
        // each element via rawPtr.cast<Int64>()[i].
        final fixturePath =
            '${_packageRoot()}/test/fixtures/identity_int64.onnx';
        final session = runtime.createSessionFromFile(fixturePath);
        addTearDown(session.dispose);

        final inputData = Int64List.fromList([1, 2, 3, 4]);
        final input = OnnxTensor.fromInt64([1, 4], inputData);

        final outputs = session.run(
          inputs: {'input': input},
          outputNames: ['output'],
        );

        expect(outputs, hasLength(1));
        expect(outputs[0].elementType, equals(OnnxElementType.int64));
        expect(outputs[0].shape, equals([1, 4]));
        expect(outputs[0].asInt64(), equals([1, 2, 3, 4]));
      },
    );

    test(
      'float64 identity model: elementType==float64 and values preserved',
      skip: ortAvailable ? false : _skipMessage,
      () {
        // identity_float64.onnx: input/output float64[1,4], elem_type=11.
        // The _copyTensorData float64 branch allocates a Float64List and copies
        // each element via rawPtr.cast<Double>()[i].
        final fixturePath =
            '${_packageRoot()}/test/fixtures/identity_float64.onnx';
        final session = runtime.createSessionFromFile(fixturePath);
        addTearDown(session.dispose);

        final inputData = Float64List.fromList([1.1, 2.2, 3.3, 4.4]);
        final input = OnnxTensor.fromFloat64([1, 4], inputData);

        final outputs = session.run(
          inputs: {'input': input},
          outputNames: ['output'],
        );

        expect(outputs, hasLength(1));
        expect(outputs[0].elementType, equals(OnnxElementType.float64));
        expect(outputs[0].shape, equals([1, 4]));
        // Float64 round-trips through ORT identity without precision loss.
        expect(outputs[0].asFloat64(), equals([1.1, 2.2, 3.3, 4.4]));
      },
    );
  });

  // KNOWN: cross-isolate use is UB — not automated; documented in OnnxSession
  // class docstring. Calling run() or dispose() from isolate B on a session
  // created in isolate A triggers undefined behaviour at the ORT level (mutex
  // corruption or silent wrong output), which is unsafe to exercise in CI.
  // Only the same-isolate sequential positive contract is verified here.
  group('OnnxSession — thread affinity', () {
    late OnnxRuntime runtime;

    setUp(() async {
      if (!ortAvailable) return;
      runtime = await OnnxRuntime.load();
    });

    tearDown(() {
      if (!ortAvailable) return;
      runtime.dispose();
    });

    test(
      'three sequential run() calls on the same isolate all return correct '
      'results',
      skip: ortAvailable ? false : _skipMessage,
      () {
        // Verifies the same-isolate sequential contract: a single session may
        // be called multiple times from the isolate that created it without
        // error or result corruption.
        //
        // The identity_float32.onnx fixture is deterministic: run() on
        // [1.0, 2.0, 3.0, 4.0] always returns [1.0, 2.0, 3.0, 4.0]
        // (float32 output — the model passes the input directly to the output).
        final session = runtime.createSessionFromFile(_fixtureModelPath);
        addTearDown(session.dispose);

        final inputData = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
        final expectedOutput = [1.0, 2.0, 3.0, 4.0];

        for (var i = 0; i < 3; i++) {
          final input = OnnxTensor.fromFloat32([1, 4], inputData);
          final outputs = session.run(
            inputs: {'input': input},
            outputNames: ['output'],
          );

          expect(outputs, hasLength(1), reason: 'run $i: expected 1 output');
          expect(
            outputs[0].elementType,
            equals(OnnxElementType.float32),
            reason: 'run $i: expected float32 output',
          );
          expect(
            outputs[0].shape,
            equals([1, 4]),
            reason: 'run $i: expected shape [1, 4]',
          );
          expect(
            outputs[0].asFloat32(),
            equals(expectedOutput),
            reason: 'run $i: expected identity output',
          );
        }
      },
    );
  });
}
