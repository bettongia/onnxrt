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

/// Generates `test/fixtures/identity_float32.onnx` — a minimal ONNX model
/// that passes a float32[1,4] input directly to a float32[1,4] output
/// (identity graph with no actual ops: just an input → output mapping via
/// a single Identity node).
///
/// Run with:
///   dart run tool/generate_test_fixture.dart
///
/// The generated file is committed to the repository so that the OnnxSession
/// tests in `test/onnx_session_test.dart` can use it without a network
/// download. It is intentionally tiny (< 1 KB) and carries no weights.
///
/// ONNX protobuf wire format reference (proto3):
///   ModelProto   field 1  = ir_version (int64)
///   ModelProto   field 8  = opset_import (repeated OperatorSetIdProto)
///   ModelProto   field 7  = graph (GraphProto)
///   GraphProto   field 1  = node (repeated NodeProto)
///   GraphProto   field 11 = name (string)
///   GraphProto   field 11 = input (repeated ValueInfoProto)   — field 11
///   GraphProto   field 12 = output (repeated ValueInfoProto)  — field 12
///   NodeProto    field 1  = input (repeated string)
///   NodeProto    field 2  = output (repeated string)
///   NodeProto    field 4  = op_type (string)
///   ValueInfoProto field 1 = name (string)
///   ValueInfoProto field 2 = type (TypeProto)
///   TypeProto    field 1  = tensor_type (TypeProto.Tensor)
///   TypeProto.Tensor field 1 = elem_type (int32)
///   TypeProto.Tensor field 2 = shape (TensorShapeProto)
///   TensorShapeProto field 1 = dim (repeated Dimension)
///   Dimension    field 1  = dim_value (int64)
///   OperatorSetIdProto field 2 = version (int64)
library;

import 'dart:io';
import 'dart:typed_data';

// ── Protobuf primitives ───────────────────────────────────────────────────────

/// Encodes a varint (unsigned, little-endian base-128).
List<int> _varint(int value) {
  final result = <int>[];
  while (value > 0x7F) {
    result.add((value & 0x7F) | 0x80);
    value >>= 7;
  }
  result.add(value & 0x7F);
  return result;
}

/// Encodes a protobuf field tag: (field_number << 3) | wire_type.
List<int> _tag(int fieldNumber, int wireType) =>
    _varint((fieldNumber << 3) | wireType);

/// Wire type 0 = varint.
List<int> _varintField(int fieldNumber, int value) => [
  ..._tag(fieldNumber, 0),
  ..._varint(value),
];

/// Wire type 2 = length-delimited (bytes, string, embedded message).
List<int> _lenField(int fieldNumber, List<int> data) => [
  ..._tag(fieldNumber, 2),
  ..._varint(data.length),
  ...data,
];

/// Encodes a UTF-8 string as a length-delimited field.
List<int> _stringField(int fieldNumber, String value) {
  final bytes = value.codeUnits; // ASCII-safe for our names
  return _lenField(fieldNumber, bytes);
}

// ── ONNX structure builders ───────────────────────────────────────────────────

/// Builds a TensorShapeProto with the given fixed dimension values.
///
/// TensorShapeProto: field 1 = dim (repeated Dimension)
/// Dimension:        field 1 = dim_value (int64, wire 0)
List<int> _tensorShape(List<int> dims) {
  final dimMessages = <int>[];
  for (final d in dims) {
    // Dimension message: field 1 = dim_value (varint)
    final dimMsg = _varintField(1, d);
    dimMessages.addAll(_lenField(1, dimMsg)); // field 1 = dim
  }
  return dimMessages;
}

/// Builds a TypeProto for a fixed-shape float32 tensor (elem_type = 1).
///
/// TypeProto:        field 1 = tensor_type (TypeProto.Tensor, message)
/// TypeProto.Tensor: field 1 = elem_type (int32), field 2 = shape
List<int> _typeProto(List<int> shape) {
  final shapeBytes = _tensorShape(shape);
  final tensorType = [
    ..._varintField(1, 1), // elem_type = 1 (FLOAT)
    ..._lenField(2, shapeBytes), // shape
  ];
  return _lenField(1, tensorType); // TypeProto.tensor_type
}

/// Builds a ValueInfoProto with a fixed-shape float32 type.
///
/// ValueInfoProto: field 1 = name (string), field 2 = type (TypeProto)
List<int> _valueInfo(String name, List<int> shape) {
  return [..._stringField(1, name), ..._lenField(2, _typeProto(shape))];
}

/// Builds a NodeProto for the Identity op.
///
/// NodeProto: field 1 = input (repeated string), field 2 = output (repeated),
///            field 4 = op_type (string)
List<int> _identityNode(String inputName, String outputName) {
  return [
    ..._stringField(1, inputName), // input
    ..._stringField(2, outputName), // output
    ..._stringField(4, 'Identity'), // op_type
  ];
}

/// Builds an OperatorSetIdProto with domain="" (ONNX) and the given version.
///
/// OperatorSetIdProto: field 1 = domain (string), field 2 = version (int64)
List<int> _opsetImport(int version) {
  return [
    ..._stringField(1, ''), // domain = "" = ONNX standard
    ..._varintField(2, version),
  ];
}

/// Builds the complete GraphProto.
///
/// GraphProto: field 1 = node, field 2 = name, field 11 = input,
///             field 12 = output
List<int> _graphProto({
  required String name,
  required String inputName,
  required String outputName,
  required List<int> shape,
}) {
  final node = _identityNode(inputName, outputName);
  final input = _valueInfo(inputName, shape);
  final output = _valueInfo(outputName, shape);

  return [
    ..._lenField(1, node), // node
    ..._stringField(2, name), // name
    ..._lenField(11, input), // input
    ..._lenField(12, output), // output
  ];
}

/// Builds the complete ModelProto.
///
/// ModelProto: field 1 = ir_version (int64), field 7 = graph,
///             field 8 = opset_import
List<int> _modelProto({
  required int irVersion,
  required int opsetVersion,
  required List<int> graph,
}) {
  final opset = _opsetImport(opsetVersion);
  return [
    ..._varintField(1, irVersion), // ir_version
    ..._lenField(7, graph), // graph
    ..._lenField(8, opset), // opset_import
  ];
}

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
  // Build a minimal identity graph:
  //   input  'input'  — float32[1, 4]
  //   output 'output' — float32[1, 4]
  //   node   Identity(input -> output)
  //
  // ir_version = 8 (ONNX IR version for ORT 1.x)
  // opset version = 17 (safe minimum for Identity op)
  final graph = _graphProto(
    name: 'identity',
    inputName: 'input',
    outputName: 'output',
    shape: [1, 4],
  );

  final model = _modelProto(irVersion: 8, opsetVersion: 17, graph: graph);

  final outputPath = 'test/fixtures/identity_float32.onnx';
  File(outputPath).writeAsBytesSync(Uint8List.fromList(model));

  final size = model.length;
  print('Generated $outputPath ($size bytes).');
  print('This fixture is a minimal ONNX identity model (float32[1,4]).');
  print('Commit it alongside test/onnx_session_test.dart.');
}
