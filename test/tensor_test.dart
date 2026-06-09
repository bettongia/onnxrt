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
import 'package:test/test.dart';

void main() {
  // ── OnnxElementType ─────────────────────────────────────────────────────────

  group('OnnxElementType', () {
    group('onnxTypeCode', () {
      test('float32 → code 1', () {
        expect(OnnxElementType.float32.onnxTypeCode, equals(1));
      });
      test('uint8 → code 2', () {
        expect(OnnxElementType.uint8.onnxTypeCode, equals(2));
      });
      test('int32 → code 6', () {
        expect(OnnxElementType.int32.onnxTypeCode, equals(6));
      });
      test('int64 → code 7', () {
        expect(OnnxElementType.int64.onnxTypeCode, equals(7));
      });
      test('float64 → code 11', () {
        expect(OnnxElementType.float64.onnxTypeCode, equals(11));
      });
    });

    group('fromOnnxTypeCode', () {
      test('code 1 → float32', () {
        expect(OnnxElementType.fromOnnxTypeCode(1), equals(OnnxElementType.float32));
      });
      test('code 2 → uint8', () {
        expect(OnnxElementType.fromOnnxTypeCode(2), equals(OnnxElementType.uint8));
      });
      test('code 6 → int32', () {
        expect(OnnxElementType.fromOnnxTypeCode(6), equals(OnnxElementType.int32));
      });
      test('code 7 → int64', () {
        expect(OnnxElementType.fromOnnxTypeCode(7), equals(OnnxElementType.int64));
      });
      test('code 11 → float64', () {
        expect(OnnxElementType.fromOnnxTypeCode(11), equals(OnnxElementType.float64));
      });
      test('unsupported code throws ArgumentError', () {
        expect(
          () => OnnxElementType.fromOnnxTypeCode(99),
          throwsA(isA<ArgumentError>()),
        );
      });
      test('ArgumentError message mentions the bad code', () {
        expect(
          () => OnnxElementType.fromOnnxTypeCode(42),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              contains('42'),
            ),
          ),
        );
      });
    });

    group('elementSizeInBytes', () {
      test('float32 is 4 bytes', () {
        expect(OnnxElementType.float32.elementSizeInBytes, equals(4));
      });
      test('uint8 is 1 byte', () {
        expect(OnnxElementType.uint8.elementSizeInBytes, equals(1));
      });
      test('int32 is 4 bytes', () {
        expect(OnnxElementType.int32.elementSizeInBytes, equals(4));
      });
      test('int64 is 8 bytes', () {
        expect(OnnxElementType.int64.elementSizeInBytes, equals(8));
      });
      test('float64 is 8 bytes', () {
        expect(OnnxElementType.float64.elementSizeInBytes, equals(8));
      });
    });

    test('fromOnnxTypeCode round-trips all supported codes', () {
      for (final type in OnnxElementType.values) {
        expect(
          OnnxElementType.fromOnnxTypeCode(type.onnxTypeCode),
          equals(type),
          reason: '$type should round-trip through onnxTypeCode',
        );
      }
    });
  });

  // ── OnnxTensor ──────────────────────────────────────────────────────────────

  group('OnnxTensor', () {
    group('named constructors', () {
      test('fromFloat32 sets elementType, shape, and data', () {
        final data = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
        final tensor = OnnxTensor.fromFloat32([2, 2], data);

        expect(tensor.elementType, equals(OnnxElementType.float32));
        expect(tensor.shape, equals([2, 2]));
        expect(tensor.data, same(data));
      });

      test('fromUint8 sets elementType, shape, and data', () {
        final data = Uint8List.fromList([10, 20, 30]);
        final tensor = OnnxTensor.fromUint8([3], data);

        expect(tensor.elementType, equals(OnnxElementType.uint8));
        expect(tensor.shape, equals([3]));
        expect(tensor.data, same(data));
      });

      test('fromInt32 sets elementType, shape, and data', () {
        final data = Int32List.fromList([100, 200]);
        final tensor = OnnxTensor.fromInt32([1, 2], data);

        expect(tensor.elementType, equals(OnnxElementType.int32));
        expect(tensor.shape, equals([1, 2]));
        expect(tensor.data, same(data));
      });

      test('fromInt64 sets elementType, shape, and data', () {
        final data = Int64List.fromList([1000, 2000, 3000]);
        final tensor = OnnxTensor.fromInt64([1, 3], data);

        expect(tensor.elementType, equals(OnnxElementType.int64));
        expect(tensor.shape, equals([1, 3]));
        expect(tensor.data, same(data));
      });

      test('fromFloat64 sets elementType, shape, and data', () {
        final data = Float64List.fromList([0.1, 0.2]);
        final tensor = OnnxTensor.fromFloat64([2], data);

        expect(tensor.elementType, equals(OnnxElementType.float64));
        expect(tensor.shape, equals([2]));
        expect(tensor.data, same(data));
      });
    });

    group('elementCount', () {
      test('product of shape dimensions', () {
        final data = Float32List(6);
        final tensor = OnnxTensor.fromFloat32([2, 3], data);
        expect(tensor.elementCount, equals(6));
      });

      test('scalar (empty shape) has element count 1', () {
        final data = Float32List(1);
        final tensor = OnnxTensor.fromFloat32([], data);
        expect(tensor.elementCount, equals(1));
      });

      test('3-D tensor', () {
        final data = Int64List(24);
        final tensor = OnnxTensor.fromInt64([2, 3, 4], data);
        expect(tensor.elementCount, equals(24));
      });

      test('single-element 1-D tensor', () {
        final data = Float32List(1);
        final tensor = OnnxTensor.fromFloat32([1], data);
        expect(tensor.elementCount, equals(1));
      });
    });

    group('asFloat32', () {
      test('returns Float32List for float32 tensor', () {
        final data = Float32List.fromList([1.5, 2.5]);
        final tensor = OnnxTensor.fromFloat32([2], data);
        expect(tensor.asFloat32(), same(data));
      });

      test('throws StateError for non-float32 tensor', () {
        final tensor = OnnxTensor.fromInt64([1], Int64List(1));
        expect(() => tensor.asFloat32(), throwsA(isA<StateError>()));
      });
    });

    group('asInt64', () {
      test('returns Int64List for int64 tensor', () {
        final data = Int64List.fromList([42, 43]);
        final tensor = OnnxTensor.fromInt64([2], data);
        expect(tensor.asInt64(), same(data));
      });

      test('throws StateError for non-int64 tensor', () {
        final tensor =
            OnnxTensor.fromFloat32([1], Float32List.fromList([1.0]));
        expect(() => tensor.asInt64(), throwsA(isA<StateError>()));
      });
    });

    group('toString', () {
      test('includes element type and shape', () {
        final tensor = OnnxTensor.fromFloat32([1, 512], Float32List(512));
        final s = tensor.toString();
        expect(s, contains('float32'));
        expect(s, contains('512'));
      });
    });
  });

  // ── SessionOptions ───────────────────────────────────────────────────────────

  group('SessionOptions', () {
    test('defaults: intra=1, inter=1', () {
      const opts = SessionOptions();
      expect(opts.intraOpNumThreads, equals(1));
      expect(opts.interOpNumThreads, equals(1));
    });

    test('custom values are stored', () {
      const opts = SessionOptions(intraOpNumThreads: 4, interOpNumThreads: 2);
      expect(opts.intraOpNumThreads, equals(4));
      expect(opts.interOpNumThreads, equals(2));
    });

    test('toString includes both thread counts', () {
      const opts = SessionOptions(intraOpNumThreads: 3, interOpNumThreads: 2);
      expect(opts.toString(), contains('3'));
      expect(opts.toString(), contains('2'));
    });
  });
}
