// Copyright 2026 The Authors
//
// Please refer to the AUTHORS file in the base directory for this project.
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

import 'package:test/test.dart';

import 'package:magika/src/magika_config.dart';
import 'package:magika/src/magika_preprocess.dart';

void main() {
  // Build a minimal MagikaConfig for testing that matches standard_v3_3
  // dimensions: beg=1024, mid=0, end=1024, block=4096, padding=256.
  MagikaConfig makeConfig({
    int begSize = 1024,
    int midSize = 0,
    int endSize = 1024,
    int blockSize = 4096,
    int paddingToken = 256,
  }) {
    return MagikaConfig(
      begSize: begSize,
      midSize: midSize,
      endSize: endSize,
      paddingToken: paddingToken,
      blockSize: blockSize,
      targetLabelsSpace: [],
      contentTypes: {},
    );
  }

  group('buildInputTensor — shape and element type', () {
    test('returns a tensor with shape [1, 2048] for standard config', () {
      final config = makeConfig();
      final tensor = buildInputTensor(Uint8List(0), config);
      expect(tensor.shape, [1, 2048]);
    });

    test('data length equals beg_size + mid_size + end_size', () {
      final config = makeConfig();
      final tensor = buildInputTensor(Uint8List(100), config);
      expect(tensor.asInt32().length, 2048);
    });
  });

  group('empty file', () {
    test('all values are the padding token', () {
      final config = makeConfig();
      final data = buildInputTensor(Uint8List(0), config).asInt32();
      expect(data.every((v) => v == 256), isTrue);
    });

    test('beg segment is all padding', () {
      final config = makeConfig();
      final data = buildInputTensor(Uint8List(0), config).asInt32();
      final beg = data.sublist(0, 1024);
      expect(beg.every((v) => v == 256), isTrue);
    });

    test('end segment is all padding', () {
      final config = makeConfig();
      final data = buildInputTensor(Uint8List(0), config).asInt32();
      final end = data.sublist(1024, 2048);
      expect(end.every((v) => v == 256), isTrue);
    });
  });

  group('file shorter than beg_size (100 bytes of non-whitespace)', () {
    late MagikaConfig config;
    late Int32List data;
    late Uint8List input;

    setUp(() {
      config = makeConfig();
      // 100 bytes: values 1..100 (none are whitespace).
      input = Uint8List.fromList(List.generate(100, (i) => i + 1));
      data = buildInputTensor(input, config).asInt32();
    });

    test('beg segment starts with the file bytes', () {
      for (var i = 0; i < 100; i++) {
        expect(data[i], i + 1, reason: 'beg[$i] should be ${i + 1}');
      }
    });

    test('beg segment is right-padded after the file bytes', () {
      for (var i = 100; i < 1024; i++) {
        expect(data[i], 256, reason: 'beg[$i] should be padding');
      }
    });

    test('end segment ends with the file bytes (left-padded)', () {
      // End segment: last 100 positions should be file bytes; first 924 padding.
      final endSegment = data.sublist(1024, 2048);
      for (var i = 0; i < 924; i++) {
        expect(endSegment[i], 256, reason: 'end[$i] should be padding');
      }
      for (var i = 0; i < 100; i++) {
        expect(
          endSegment[924 + i],
          i + 1,
          reason: 'end[${924 + i}] should be ${i + 1}',
        );
      }
    });
  });

  group('file exactly beg_size (1024 bytes of non-whitespace)', () {
    late MagikaConfig config;
    late Int32List data;
    late Uint8List input;

    setUp(() {
      config = makeConfig();
      // 1024 bytes: values cycling 1..200.
      input = Uint8List.fromList(List.generate(1024, (i) => (i % 200) + 1));
      data = buildInputTensor(input, config).asInt32();
    });

    test('beg segment equals first 1024 file bytes (no padding)', () {
      for (var i = 0; i < 1024; i++) {
        expect(data[i], input[i], reason: 'beg[$i] mismatch');
      }
    });

    test('end segment equals last 1024 file bytes (no padding)', () {
      final endSegment = data.sublist(1024, 2048);
      for (var i = 0; i < 1024; i++) {
        expect(endSegment[i], input[i], reason: 'end[$i] mismatch');
      }
    });

    test('no padding tokens anywhere', () {
      expect(data.any((v) => v == 256), isFalse);
    });
  });

  group('file in range (beg_size, 2 * beg_size) — 1500 bytes', () {
    late MagikaConfig config;
    late Int32List data;
    late Uint8List input;

    setUp(() {
      config = makeConfig();
      // 1500 bytes: values cycling 1..200 (not whitespace).
      input = Uint8List.fromList(List.generate(1500, (i) => (i % 200) + 1));
      data = buildInputTensor(input, config).asInt32();
    });

    test('beg segment equals first 1024 file bytes (no padding)', () {
      for (var i = 0; i < 1024; i++) {
        expect(data[i], input[i], reason: 'beg[$i] mismatch');
      }
    });

    test('end segment equals last 1024 file bytes (no padding)', () {
      final endSegment = data.sublist(1024, 2048);
      for (var i = 0; i < 1024; i++) {
        expect(
          endSegment[i],
          input[1500 - 1024 + i],
          reason: 'end[$i] mismatch',
        );
      }
    });

    test(
      'no padding tokens (file > beg_size, both segments fully covered)',
      () {
        expect(data.any((v) => v == 256), isFalse);
      },
    );
  });

  group('file larger than block_size (5000 bytes)', () {
    late MagikaConfig config;
    late Int32List data;
    late Uint8List input;

    setUp(() {
      config = makeConfig();
      // 5000 bytes: values cycling 1..200 (not whitespace).
      input = Uint8List.fromList(List.generate(5000, (i) => (i % 200) + 1));
      data = buildInputTensor(input, config).asInt32();
    });

    test(
      'beg segment equals first 1024 file bytes (block_size 4096 > 1024)',
      () {
        for (var i = 0; i < 1024; i++) {
          expect(data[i], input[i], reason: 'beg[$i] mismatch');
        }
      },
    );

    test('end segment equals last 1024 file bytes', () {
      final endSegment = data.sublist(1024, 2048);
      for (var i = 0; i < 1024; i++) {
        expect(
          endSegment[i],
          input[5000 - 1024 + i],
          reason: 'end[$i] mismatch',
        );
      }
    });

    test('no padding tokens', () {
      expect(data.any((v) => v == 256), isFalse);
    });
  });

  group('whitespace stripping', () {
    test('leading whitespace is stripped from beg segment', () {
      final config = makeConfig();
      // 5 spaces then 10 non-whitespace bytes (value 65 = 'A').
      final bytes = Uint8List.fromList([
        0x20, 0x20, 0x20, 0x20, 0x20, // 5 spaces
        ...List.filled(10, 65), // 'A'
      ]);
      final data = buildInputTensor(bytes, config).asInt32();
      // After lstrip, 10 'A' bytes should be at positions 0..9.
      for (var i = 0; i < 10; i++) {
        expect(data[i], 65, reason: 'beg[$i] should be 65 (A)');
      }
      // Positions 10..1023 should be padding.
      for (var i = 10; i < 1024; i++) {
        expect(data[i], 256);
      }
    });

    test('trailing whitespace is stripped from end segment', () {
      final config = makeConfig();
      // 10 non-whitespace bytes then 5 spaces.
      final bytes = Uint8List.fromList([
        ...List.filled(10, 66), // 'B'
        0x20, 0x20, 0x20, 0x20, 0x20, // 5 spaces
      ]);
      final data = buildInputTensor(bytes, config).asInt32();
      // After rstrip, end segment should have 10 'B' bytes in the last 10
      // positions and padding in the first 1014 positions.
      final endSegment = data.sublist(1024, 2048);
      for (var i = 0; i < 1014; i++) {
        expect(endSegment[i], 256, reason: 'end[$i] should be padding');
      }
      for (var i = 0; i < 10; i++) {
        expect(
          endSegment[1014 + i],
          66,
          reason: 'end[${1014 + i}] should be 66 (B)',
        );
      }
    });

    test('file containing only whitespace → all padding', () {
      final config = makeConfig();
      final bytes = Uint8List.fromList(List.filled(500, 0x20)); // all spaces
      final data = buildInputTensor(bytes, config).asInt32();
      expect(data.every((v) => v == 256), isTrue);
    });
  });

  group('mid segment is empty for standard config', () {
    test('mid_size=0 produces no mid elements in the tensor', () {
      final config = makeConfig(); // midSize = 0
      final bytes = Uint8List.fromList(
        List.generate(3000, (i) => (i % 200) + 1),
      );
      final tensor = buildInputTensor(bytes, config);
      // Total should be beg_size + end_size = 2048
      expect(tensor.shape, [1, 2048]);
    });
  });

  group('mid segment — future model support (mid_size > 0)', () {
    test('mid segment is right-padded when file is short', () {
      // Use a config with mid_size=512 to test the mid-segment logic.
      final config = makeConfig(
        begSize: 512,
        midSize: 512,
        endSize: 512,
        blockSize: 2048,
      );
      // 100-byte file — all segments should have the same 100 bytes in their
      // "real" position, rest padding.
      final input = Uint8List.fromList(List.generate(100, (i) => i + 1));
      final data = buildInputTensor(input, config).asInt32();

      expect(data.length, 1536);
      // Mid segment occupies positions 512..1023.
      final mid = data.sublist(512, 1024);
      // First 100 positions should be file bytes; rest padding.
      for (var i = 0; i < 100; i++) {
        expect(mid[i], i + 1);
      }
      for (var i = 100; i < 512; i++) {
        expect(mid[i], 256);
      }
    });
  });
}
