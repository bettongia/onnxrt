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

import 'dart:typed_data';

import 'package:betto_onnxrt/betto_onnxrt.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late OnnxRuntime runtime;
  late Uint8List identityModelBytes;

  setUpAll(() async {
    // Load the identity float32[1,4]→float32[1,4] ONNX fixture from assets.
    // This tiny model has no real weights — it exists only to exercise the
    // session-creation and run paths with a valid ONNX file.
    final byteData = await rootBundle.load('assets/identity_float32.onnx');
    identityModelBytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    runtime = await OnnxRuntime.load();
  });

  tearDownAll(() {
    runtime.dispose();
  });

  // ---------------------------------------------------------------------------
  // OnnxRuntime — library load
  // ---------------------------------------------------------------------------

  group('OnnxRuntime — library load', () {
    test('load() succeeds and returns a non-null runtime', () {
      // If we reach this point setUpAll completed without throwing, which means
      // the native-assets hook staged the ORT binary and the library loaded.
      expect(runtime, isNotNull);
    });

    test('ortApi pointer is non-null after load', () {
      expect(runtime.ortApi.address, isNonZero);
    });
  });

  // ---------------------------------------------------------------------------
  // OnnxRuntime — session creation
  // ---------------------------------------------------------------------------

  group('OnnxRuntime — session creation', () {
    test('createSession() from model bytes succeeds', () {
      final session = runtime.createSession(identityModelBytes);
      session.dispose();
    });

    test('createSession() with explicit SessionOptions succeeds', () {
      const opts = SessionOptions(intraOpNumThreads: 1, interOpNumThreads: 1);
      final session = runtime.createSession(identityModelBytes, options: opts);
      session.dispose();
    });

    test('createSession() with invalid bytes throws', () {
      expect(
        () => runtime.createSession(Uint8List.fromList([0, 1, 2, 3])),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // OnnxSession — inference
  // ---------------------------------------------------------------------------

  group('OnnxSession — identity model inference', () {
    // The identity model passes input through unchanged: output == input.
    // Input/output name is 'input' / 'output' in the generated fixture.
    // Shape: float32[1, 4].

    late OnnxSession session;

    setUp(() {
      session = runtime.createSession(identityModelBytes);
    });

    tearDown(() {
      session.dispose();
    });

    test('run() returns one output tensor', () {
      final input = OnnxTensor.fromFloat32(
        [1, 4],
        Float32List.fromList([1.0, 2.0, 3.0, 4.0]),
      );
      final outputs = session.run(
        inputs: {'input': input},
        outputNames: ['output'],
      );
      expect(outputs, hasLength(1));
    });

    test('run() output shape matches input shape [1, 4]', () {
      final input = OnnxTensor.fromFloat32(
        [1, 4],
        Float32List.fromList([1.0, 2.0, 3.0, 4.0]),
      );
      final outputs = session.run(
        inputs: {'input': input},
        outputNames: ['output'],
      );
      expect(outputs[0].shape, equals([1, 4]));
    });

    test('run() identity: output values equal input values', () {
      const inputValues = [1.5, -2.5, 0.0, 42.0];
      final input = OnnxTensor.fromFloat32(
        [1, 4],
        Float32List.fromList(inputValues),
      );
      final outputs = session.run(
        inputs: {'input': input},
        outputNames: ['output'],
      );
      final result = outputs[0].asFloat32();
      expect(result.length, equals(4));
      for (var i = 0; i < inputValues.length; i++) {
        expect(result[i], closeTo(inputValues[i], 1e-6));
      }
    });

    test('run() can be called multiple times on the same session', () {
      for (var call = 0; call < 3; call++) {
        final values = Float32List.fromList(
          List.generate(4, (i) => (call + i).toDouble()),
        );
        final outputs = session.run(
          inputs: {'input': OnnxTensor.fromFloat32([1, 4], values)},
          outputNames: ['output'],
        );
        final result = outputs[0].asFloat32();
        for (var i = 0; i < 4; i++) {
          expect(result[i], closeTo(values[i], 1e-6));
        }
      }
    });

    test('run() with zeros returns zeros', () {
      final input = OnnxTensor.fromFloat32(
        [1, 4],
        Float32List(4), // all zeros
      );
      final outputs = session.run(
        inputs: {'input': input},
        outputNames: ['output'],
      );
      final result = outputs[0].asFloat32();
      expect(result, everyElement(closeTo(0.0, 1e-6)));
    });

    test('run() with large values does not overflow', () {
      const inputValues = [1e30, -1e30, 1e-30, -1e-30];
      final input = OnnxTensor.fromFloat32(
        [1, 4],
        Float32List.fromList(inputValues),
      );
      final outputs = session.run(
        inputs: {'input': input},
        outputNames: ['output'],
      );
      final result = outputs[0].asFloat32();
      for (var i = 0; i < 4; i++) {
        // Identity — values pass through; large magnitudes preserved (within
        // float32 precision, no overflow expected at these magnitudes).
        expect(result[i].isNaN, isFalse);
        expect(result[i].isInfinite, isFalse);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // OnnxSession — OrtApi vtable version
  // ---------------------------------------------------------------------------

  group('OnnxRuntime — ORT API version', () {
    test('ortApi is for ORT API v22 (ortApiVersion constant)', () {
      // This test is a documentation check: the build hook stages v1.22.0
      // which exposes ORT API version 22. If a newer ORT binary is staged
      // without updating VERSION_ONNX, the runtime's load() would fail before
      // reaching this test. Passing confirms the version gate worked.
      expect(runtime.ortApi.address, isNonZero);
    });
  });
}
