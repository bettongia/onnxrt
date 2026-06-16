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

import 'package:test/test.dart';

import 'package:magika/src/magika_config.dart';
import 'package:magika/src/magika_result.dart';

void main() {
  /// Returns a [ContentType] with PDF metadata for use in tests.
  ContentType pdfContentType() {
    return const ContentType(
      label: 'pdf',
      mimeType: 'application/pdf',
      group: 'document',
      description: 'PDF document',
      extensions: ['pdf'],
      isText: false,
    );
  }

  /// Returns a [LabelDetail] for PDF.
  LabelDetail pdfDetail() {
    return LabelDetail.fromContentType(pdfContentType());
  }

  group('LabelDetail.toJson', () {
    test('produces the expected JSON sub-object', () {
      final detail = pdfDetail();
      final json = detail.toJson();
      expect(json['label'], 'pdf');
      expect(json['description'], 'PDF document');
      expect(json['extensions'], ['pdf']);
      expect(json['group'], 'document');
      expect(json['is_text'], false);
      expect(json['mime_type'], 'application/pdf');
    });

    test('uses snake_case keys matching Python output', () {
      final detail = pdfDetail();
      final json = detail.toJson();
      // Check the exact key names for Python interoperability.
      expect(json.containsKey('is_text'), isTrue);
      expect(json.containsKey('mime_type'), isTrue);
      expect(json.containsKey('extensions'), isTrue);
      // Must NOT use camelCase.
      expect(json.containsKey('isText'), isFalse);
      expect(json.containsKey('mimeType'), isFalse);
    });
  });

  group('MagikaResult.toJson', () {
    test('produces the value sub-object with dl, output, and score', () {
      final detail = pdfDetail();
      final result = MagikaResult(dl: detail, output: detail, score: 0.999);
      final json = result.toJson();
      expect(json.containsKey('dl'), isTrue);
      expect(json.containsKey('output'), isTrue);
      expect(json.containsKey('score'), isTrue);
    });

    test('score is preserved accurately', () {
      final detail = pdfDetail();
      final result = MagikaResult(dl: detail, output: detail, score: 0.12345);
      final json = result.toJson();
      expect(json['score'], closeTo(0.12345, 1e-9));
    });

    test('dl and output are both present and equal in v1', () {
      final detail = pdfDetail();
      final result = MagikaResult(dl: detail, output: detail, score: 0.9);
      final json = result.toJson();
      expect(json['dl'], equals(json['output']));
    });
  });

  group('MagikaFileResult.toJson — success path', () {
    test('produces the top-level structure with status ok', () {
      final detail = pdfDetail();
      final magikaResult = MagikaResult(
        dl: detail,
        output: detail,
        score: 0.999,
      );
      final fileResult = MagikaFileResult.ok(
        path: '/tmp/test.pdf',
        result: magikaResult,
      );
      final json = fileResult.toJson();
      expect(json['path'], '/tmp/test.pdf');
      expect((json['result'] as Map)['status'], 'ok');
      expect((json['result'] as Map).containsKey('value'), isTrue);
    });

    test('isOk is true for a successful result', () {
      final detail = pdfDetail();
      final magikaResult = MagikaResult(dl: detail, output: detail, score: 0.9);
      final fileResult = MagikaFileResult.ok(
        path: '/some/file',
        result: magikaResult,
      );
      expect(fileResult.isOk, isTrue);
    });
  });

  group('MagikaFileResult.toJson — error path', () {
    test('produces the top-level structure with status error', () {
      final fileResult = MagikaFileResult.error(
        path: '/tmp/missing.pdf',
        error: 'File not found',
      );
      final json = fileResult.toJson();
      expect(json['path'], '/tmp/missing.pdf');
      expect((json['result'] as Map)['status'], 'error');
      final value = (json['result'] as Map)['value'] as Map;
      expect(value['error'], 'File not found');
    });

    test('isOk is false for an error result', () {
      final fileResult = MagikaFileResult.error(
        path: '/some/file',
        error: 'oops',
      );
      expect(fileResult.isOk, isFalse);
    });
  });

  group('LabelDetail.fromContentType', () {
    test('copies all fields from the ContentType', () {
      final ct = pdfContentType();
      final detail = LabelDetail.fromContentType(ct);
      expect(detail.label, ct.label);
      expect(detail.mimeType, ct.mimeType);
      expect(detail.group, ct.group);
      expect(detail.description, ct.description);
      expect(detail.extensions, ct.extensions);
      expect(detail.isText, ct.isText);
    });
  });
}
