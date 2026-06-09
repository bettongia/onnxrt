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

/// Tensor value types and session configuration for `betto_onnxrt`.
library;

import 'dart:typed_data';

import 'ort_api.dart';

// ── OnnxElementType ───────────────────────────────────────────────────────────

/// The element data type of an [OnnxTensor].
///
/// Maps to `ONNXTensorElementDataType` in `onnxruntime_c_api.h`. Only the
/// types supported in v1 are enumerated here.
///
/// ## Type code table (ORT API version 22)
///
/// | [OnnxElementType]  | ONNX type code | Constant name |
/// |--------------------|---------------|----------------|
/// | [float32]          | 1             | `ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT` |
/// | [uint8]            | 2             | `ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8` |
/// | [int32]            | 6             | `ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32` |
/// | [int64]            | 7             | `ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64` |
/// | [float64]          | 11            | `ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE` |
enum OnnxElementType {
  /// 32-bit IEEE 754 floating point. ONNX type code 1.
  float32,

  /// Unsigned 8-bit integer. ONNX type code 2.
  uint8,

  /// Signed 32-bit integer. ONNX type code 6.
  int32,

  /// Signed 64-bit integer. ONNX type code 7.
  int64,

  /// 64-bit IEEE 754 floating point (double). ONNX type code 11.
  float64;

  /// The ORT ONNX type code for this element type.
  ///
  /// Used when constructing input tensors via `CreateTensorWithDataAsOrtValue`
  /// and when interpreting output tensor types via `GetTensorTypeAndShapeInfo`.
  int get onnxTypeCode => switch (this) {
    OnnxElementType.float32 => onnxElementTypeFloat32,
    OnnxElementType.uint8 => onnxElementTypeUint8,
    OnnxElementType.int32 => onnxElementTypeInt32,
    OnnxElementType.int64 => onnxElementTypeInt64,
    OnnxElementType.float64 => onnxElementTypeFloat64,
  };

  /// Returns the [OnnxElementType] corresponding to [onnxTypeCode].
  ///
  /// Throws [ArgumentError] if [onnxTypeCode] does not correspond to a
  /// supported type.
  static OnnxElementType fromOnnxTypeCode(int onnxTypeCode) =>
      switch (onnxTypeCode) {
        1 => OnnxElementType.float32,
        2 => OnnxElementType.uint8,
        6 => OnnxElementType.int32,
        7 => OnnxElementType.int64,
        11 => OnnxElementType.float64,
        _ => throw ArgumentError(
          'Unsupported ONNX tensor element type code: $onnxTypeCode. '
          'Supported codes: 1 (float32), 2 (uint8), 6 (int32), 7 (int64), '
          '11 (float64).',
        ),
      };

  /// The size in bytes of a single element of this type.
  int get elementSizeInBytes => switch (this) {
    OnnxElementType.float32 => 4,
    OnnxElementType.uint8 => 1,
    OnnxElementType.int32 => 4,
    OnnxElementType.int64 => 8,
    OnnxElementType.float64 => 8,
  };
}

// ── OnnxTensor ────────────────────────────────────────────────────────────────

/// A multi-dimensional array of typed numeric values.
///
/// [OnnxTensor] is both the input type for [OnnxSession.run] and the return
/// type for each output. Construct input tensors via the named factories
/// [OnnxTensor.fromFloat32], [OnnxTensor.fromInt64], etc.
///
/// The [data] field is a [TypedData] view. For outputs, the view is
/// constructed over a copy of the native OrtValue data. The view type matches
/// the [elementType]:
///
/// | [elementType]       | [data] runtime type |
/// |---------------------|---------------------|
/// | [OnnxElementType.float32] | [Float32List]  |
/// | [OnnxElementType.uint8]   | [Uint8List]    |
/// | [OnnxElementType.int32]   | [Int32List]    |
/// | [OnnxElementType.int64]   | [Int64List]    |
/// | [OnnxElementType.float64] | [Float64List]  |
final class OnnxTensor {
  /// The element data type of this tensor.
  final OnnxElementType elementType;

  /// The shape of this tensor as a list of dimension sizes.
  ///
  /// For example, a BGE input tensor of 1 batch × 512 sequence length has
  /// shape `[1, 512]`. A scalar has shape `[]`.
  final List<int> shape;

  /// The raw data of this tensor as a [TypedData] view.
  ///
  /// The concrete type matches [elementType] — see the class doc table.
  final TypedData data;

  /// Creates an [OnnxTensor] with the given [elementType], [shape], and [data].
  ///
  /// For input tensors, prefer the named factories.
  const OnnxTensor({
    required this.elementType,
    required this.shape,
    required this.data,
  });

  // ── Named constructors ────────────────────────────────────────────────────

  /// Creates a float32 tensor with the given [shape] and [data].
  factory OnnxTensor.fromFloat32(List<int> shape, Float32List data) =>
      OnnxTensor(
        elementType: OnnxElementType.float32,
        shape: shape,
        data: data,
      );

  /// Creates a uint8 tensor with the given [shape] and [data].
  factory OnnxTensor.fromUint8(List<int> shape, Uint8List data) =>
      OnnxTensor(elementType: OnnxElementType.uint8, shape: shape, data: data);

  /// Creates an int32 tensor with the given [shape] and [data].
  factory OnnxTensor.fromInt32(List<int> shape, Int32List data) =>
      OnnxTensor(elementType: OnnxElementType.int32, shape: shape, data: data);

  /// Creates an int64 tensor with the given [shape] and [data].
  factory OnnxTensor.fromInt64(List<int> shape, Int64List data) =>
      OnnxTensor(elementType: OnnxElementType.int64, shape: shape, data: data);

  /// Creates a float64 tensor with the given [shape] and [data].
  factory OnnxTensor.fromFloat64(List<int> shape, Float64List data) =>
      OnnxTensor(
        elementType: OnnxElementType.float64,
        shape: shape,
        data: data,
      );

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// The total number of elements in this tensor (product of all dimensions).
  int get elementCount => shape.isEmpty ? 1 : shape.fold(1, (a, b) => a * b);

  /// Returns this tensor's data as a [Float32List].
  ///
  /// Throws [StateError] if [elementType] is not [OnnxElementType.float32].
  Float32List asFloat32() {
    if (elementType != OnnxElementType.float32) {
      throw StateError('Cannot view $elementType tensor as Float32List.');
    }
    return data as Float32List;
  }

  /// Returns this tensor's data as an [Int64List].
  ///
  /// Throws [StateError] if [elementType] is not [OnnxElementType.int64].
  Int64List asInt64() {
    if (elementType != OnnxElementType.int64) {
      throw StateError('Cannot view $elementType tensor as Int64List.');
    }
    return data as Int64List;
  }

  @override
  String toString() => 'OnnxTensor($elementType, shape=$shape)';
}

// ── SessionOptions ────────────────────────────────────────────────────────────

/// Session-creation options for [OnnxSession].
///
/// v1 exposes exactly two fields — thread-pool sizing. Both default to `1` to
/// preserve thread-pool-teardown-safe behaviour when ORT is called from a
/// single Dart isolate. Do not raise these values without understanding the
/// implications for isolate lifecycle (see `OnnxSession` class doc).
///
/// No additional fields are provided in v1. Future options will be added in
/// a backwards-compatible way.
final class SessionOptions {
  /// Creates [SessionOptions].
  ///
  /// Both thread counts default to `1` (single-threaded, teardown-safe).
  const SessionOptions({
    this.intraOpNumThreads = 1,
    this.interOpNumThreads = 1,
  });

  /// Number of threads used for parallelism within a single operator.
  ///
  /// Defaults to `1`. Setting this above `1` enables intra-op parallelism but
  /// risks thread-pool teardown races when the session is released from an
  /// isolate that was spawned for inference. Keep at `1` unless you fully
  /// control the session/isolate lifecycle.
  final int intraOpNumThreads;

  /// Number of threads used for parallelism across independent operators.
  ///
  /// Defaults to `1`. Same teardown-safety caveat as [intraOpNumThreads].
  final int interOpNumThreads;

  @override
  String toString() =>
      'SessionOptions(intra=$intraOpNumThreads, inter=$interOpNumThreads)';
}
