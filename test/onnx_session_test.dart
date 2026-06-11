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
/// See `docs/spec/28_release_checklist.md` RC-15 for the full manual
/// verification procedure.
library;

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
  try {
    // Use the same name that OnnxRuntime._openLibrary() uses for this platform.
    final String libName;
    if (Platform.isMacOS) {
      libName = 'libonnxruntime.dylib';
    } else if (Platform.isLinux) {
      libName = 'libonnxruntime.so';
    } else if (Platform.isWindows) {
      libName = 'onnxruntime.dll';
    } else {
      return false; // Android/iOS require full build — always skip in test.
    }
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
  } catch (_) {
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

/// Skip message shown when the ORT library is not staged.
const _skipMessage =
    'ORT binary not staged — run `dart build` (or the betto_onnxrt hook) '
    'first. See test/onnx_session_test.dart file-level doc and '
    'docs/spec/28_release_checklist.md RC-15.';

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
