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

/// Golden-value tests for the ONNX tensor element type constants and ORT
/// configuration constants declared in [ort_api.dart].
///
/// These constants are mapped from fixed values in:
/// - The ONNX protobuf spec (`TensorProto.DataType` enum in `onnx.proto3`)
/// - The ORT C API header (`OrtLoggingLevel`, `OrtAllocatorType`,
///   `OrtMemType` enums in `onnxruntime_c_api.h`)
///
/// Getting an element type constant wrong silently corrupts tensor creation
/// (CreateTensorWithDataAsOrtValue slot 49) and output parsing
/// (GetTensorElementType slot 60). These tests catch copy-paste errors and
/// version-bump drift without requiring the ORT native binary.
library;

import 'package:betto_onnxrt/src/ort_api.dart'
    show
        onnxElementTypeFloat32,
        onnxElementTypeFloat64,
        onnxElementTypeInt32,
        onnxElementTypeInt64,
        onnxElementTypeUint8,
        ortApiVersion,
        ortDeviceAllocator,
        ortLoggingWarning,
        ortMemTypeCpuInput;
import 'package:test/test.dart';

void main() {
  // ── ONNX tensor element type constants ──────────────────────────────────────
  //
  // Values come from the ONNX `TensorProto.DataType` protobuf enum, which is
  // stable across ONNX versions and matches `ONNXTensorElementDataType` in
  // onnxruntime_c_api.h. These are used at slot 49 (CreateTensorWithDataAsOrtValue)
  // for inputs and slot 60 (GetTensorElementType) for outputs.

  group('ONNX tensor element type constants', () {
    test(
      'onnxElementTypeFloat32 is 1 (ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)',
      () {
        expect(onnxElementTypeFloat32, equals(1));
      },
    );

    test('onnxElementTypeUint8 is 2 (ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8)', () {
      expect(onnxElementTypeUint8, equals(2));
    });

    test('onnxElementTypeInt32 is 6 (ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32)', () {
      expect(onnxElementTypeInt32, equals(6));
    });

    test('onnxElementTypeInt64 is 7 (ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)', () {
      expect(onnxElementTypeInt64, equals(7));
    });

    test(
      'onnxElementTypeFloat64 is 11 (ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE)',
      () {
        expect(onnxElementTypeFloat64, equals(11));
      },
    );

    test('element type values are distinct', () {
      final values = [
        onnxElementTypeFloat32,
        onnxElementTypeUint8,
        onnxElementTypeInt32,
        onnxElementTypeInt64,
        onnxElementTypeFloat64,
      ];
      expect(values.toSet(), hasLength(values.length));
    });
  });

  // ── ORT C API configuration constants ───────────────────────────────────────
  //
  // Values from onnxruntime_c_api.h enums. ortLoggingWarning is passed to
  // CreateEnv (slot 3). ortDeviceAllocator and ortMemTypeCpuInput are passed
  // to CreateCpuMemoryInfo (slot 69). ortApiVersion is passed to
  // OrtApiBase.GetApi to select the vtable version.

  group('ORT configuration constants', () {
    test('ortLoggingWarning is 2 (ORT_LOGGING_LEVEL_WARNING)', () {
      expect(ortLoggingWarning, equals(2));
    });

    test('ortDeviceAllocator is 0 (OrtDeviceAllocator)', () {
      expect(ortDeviceAllocator, equals(0));
    });

    test('ortMemTypeCpuInput is -2 (OrtMemTypeCPUInput)', () {
      expect(ortMemTypeCpuInput, equals(-2));
    });

    test('ortApiVersion is 22 (ORT v1.22.x)', () {
      expect(ortApiVersion, equals(22));
    });
  });
}
