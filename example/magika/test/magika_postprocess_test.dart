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

import 'package:betto_onnxrt/betto_onnxrt.dart';
import 'package:test/test.dart';

import 'package:magika/src/magika_config.dart';
import 'package:magika/src/magika_postprocess.dart';

void main() {
  /// Build a [MagikaConfig] for testing with a small label space.
  MagikaConfig makeConfig(
    List<String> labels, {
    Map<String, ContentType>? contentTypes,
  }) {
    final cts = contentTypes ?? {};
    // Synthesise fallback entries for any labels that have no explicit entry.
    for (final label in labels) {
      cts.putIfAbsent(
        label,
        () => ContentType(
          label: label,
          mimeType: 'application/octet-stream',
          group: 'unknown',
          description: label,
          extensions: [],
          isText: false,
        ),
      );
    }
    return MagikaConfig(
      begSize: 1024,
      midSize: 0,
      endSize: 1024,
      paddingToken: 256,
      blockSize: 4096,
      targetLabelsSpace: labels,
      contentTypes: cts,
    );
  }

  /// Creates a float32 [OnnxTensor] from a [List<double>] of scores.
  OnnxTensor makeTensor(List<double> scores) {
    return OnnxTensor.fromFloat32([
      1,
      scores.length,
    ], Float32List.fromList(scores));
  }

  group('postprocess — basic argmax', () {
    test('selects the label with the highest score', () {
      final config = makeConfig(['txt', 'pdf', 'png']);
      // Probability distribution: txt=0.05, pdf=0.90, png=0.05
      final tensor = makeTensor([0.05, 0.90, 0.05]);
      final result = postprocess(tensor, config);
      expect(result.dl.label, 'pdf');
    });

    test('returns the correct score for the best label', () {
      final config = makeConfig(['txt', 'pdf', 'png']);
      final tensor = makeTensor([0.05, 0.90, 0.05]);
      final result = postprocess(tensor, config);
      expect(result.score, closeTo(0.90, 1e-6));
    });

    test('selects the first label when all scores are equal', () {
      final config = makeConfig(['a', 'b', 'c']);
      final tensor = makeTensor([0.333, 0.333, 0.333]);
      final result = postprocess(tensor, config);
      expect(result.dl.label, 'a');
    });

    test('selects the last label when it has the highest score', () {
      final config = makeConfig(['a', 'b', 'c']);
      final tensor = makeTensor([0.1, 0.2, 0.7]);
      final result = postprocess(tensor, config);
      expect(result.dl.label, 'c');
      expect(result.score, closeTo(0.7, 1e-6));
    });
  });

  group('postprocess — content type metadata', () {
    test('populates mime_type from content type knowledge base', () {
      final cts = {
        'pdf': ContentType(
          label: 'pdf',
          mimeType: 'application/pdf',
          group: 'document',
          description: 'PDF document',
          extensions: ['pdf'],
          isText: false,
        ),
      };
      final config = makeConfig(['txt', 'pdf'], contentTypes: cts);
      final tensor = makeTensor([0.01, 0.99]);
      final result = postprocess(tensor, config);
      expect(result.dl.mimeType, 'application/pdf');
      expect(result.dl.group, 'document');
      expect(result.dl.description, 'PDF document');
      expect(result.dl.extensions, ['pdf']);
      expect(result.dl.isText, isFalse);
    });

    test(
      'uses fallback content type when label is absent from knowledge base',
      () {
        // makeConfig auto-synthesises fallback for 'exotic'.
        final config = makeConfig(['exotic']);
        final tensor = makeTensor([1.0]);
        final result = postprocess(tensor, config);
        expect(result.dl.label, 'exotic');
        expect(result.dl.mimeType, 'application/octet-stream');
        expect(result.dl.group, 'unknown');
      },
    );
  });

  group('postprocess — output equals dl in v1', () {
    test('output label matches dl label', () {
      final config = makeConfig(['txt', 'pdf']);
      final tensor = makeTensor([0.1, 0.9]);
      final result = postprocess(tensor, config);
      expect(result.output.label, result.dl.label);
    });

    test('output mime_type matches dl mime_type', () {
      final config = makeConfig(['txt', 'pdf']);
      final tensor = makeTensor([0.1, 0.9]);
      final result = postprocess(tensor, config);
      expect(result.output.mimeType, result.dl.mimeType);
    });
  });

  group('postprocess — single-label model', () {
    test('returns the only label with score 1.0', () {
      final config = makeConfig(['unknown']);
      final tensor = makeTensor([1.0]);
      final result = postprocess(tensor, config);
      expect(result.dl.label, 'unknown');
      expect(result.score, closeTo(1.0, 1e-6));
    });
  });

  group('postprocess — error cases', () {
    test('throws ArgumentError for empty score tensor', () {
      final config = makeConfig(['pdf']);
      final emptyTensor = OnnxTensor.fromFloat32([1, 0], Float32List(0));
      expect(() => postprocess(emptyTensor, config), throwsArgumentError);
    });
  });
}
