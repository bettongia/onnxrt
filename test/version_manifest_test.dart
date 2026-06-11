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

/// Tests for `version_onnx.json` integrity.
///
/// Reads the manifest directly from the file system and asserts that all
/// SHA-256 digests are real (not placeholder zeros) and conform to the expected
/// format. This guards against a future edit that accidentally re-introduces an
/// all-zeros placeholder, which would silently bypass supply-chain verification
/// in the native-assets build hook.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  // Locate version_onnx.json relative to the package root.
  // The test runner's working directory is the package root when run via
  // `dart test` or `make test`.
  late Map<String, dynamic> manifest;
  late Map<String, dynamic> platforms;

  /// Pattern that a valid lowercase hex SHA-256 digest must match.
  final sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  setUpAll(() {
    final manifestFile = File('version_onnx.json');
    expect(
      manifestFile.existsSync(),
      isTrue,
      reason: 'version_onnx.json must exist at the package root',
    );
    final raw = manifestFile.readAsStringSync();
    // Asserts that the file is valid JSON (throws FormatException otherwise).
    manifest = jsonDecode(raw) as Map<String, dynamic>;
    platforms = manifest['platforms'] as Map<String, dynamic>;
  });

  group('version_onnx.json top-level structure', () {
    test('has required top-level keys', () {
      expect(manifest.containsKey('baseline_ort_version'), isTrue);
      expect(manifest.containsKey('ort_api_version'), isTrue);
      expect(manifest.containsKey('platforms'), isTrue);
    });

    test('ort_api_version is an integer >= 1', () {
      final apiVersion = manifest['ort_api_version'];
      expect(apiVersion, isA<int>());
      expect(apiVersion as int, greaterThanOrEqualTo(1));
    });

    test('platforms is a non-empty map', () {
      expect(platforms, isA<Map<String, dynamic>>());
      expect(platforms, isNotEmpty);
    });
  });

  group('platform sha256 digests', () {
    /// Verifies that [value] is a 64-character lowercase hex string.
    /// This rejects all-zeros placeholders, uppercase digits, and whitespace.
    void checkDigest(String fieldName, String platformKey, dynamic value) {
      expect(
        value,
        isA<String>(),
        reason: '$fieldName for $platformKey must be a string',
      );
      final hex = value as String;
      expect(
        sha256Pattern.hasMatch(hex),
        isTrue,
        reason:
            '$fieldName for $platformKey must be 64 lowercase hex chars '
            '(got "$hex")',
      );
    }

    test('every sha256 field is a real 64-char lowercase hex digest', () {
      for (final entry in platforms.entries) {
        final key = entry.key;
        final data = entry.value as Map<String, dynamic>;

        // Direct sha256 field (desktop, iOS).
        if (data.containsKey('sha256')) {
          checkDigest('sha256', key, data['sha256']);
        }

        // Archive-level sha256 (Android two-level verification).
        if (data.containsKey('sha256_archive')) {
          checkDigest('sha256_archive', key, data['sha256_archive']);
        }

        // Per-ABI sha256 map (Android two-level verification).
        if (data.containsKey('sha256_per_abi')) {
          final perAbi = data['sha256_per_abi'] as Map<String, dynamic>;
          expect(
            perAbi,
            isNotEmpty,
            reason: 'sha256_per_abi for $key must not be empty',
          );
          for (final abiEntry in perAbi.entries) {
            checkDigest('sha256_per_abi[${abiEntry.key}]', key, abiEntry.value);
          }
        }
      }
    });

    test('no sha256 field is all-zeros placeholder', () {
      const zeros =
          '0000000000000000000000000000000000000000000000000000000000000000';
      for (final entry in platforms.entries) {
        final key = entry.key;
        final data = entry.value as Map<String, dynamic>;

        if (data.containsKey('sha256')) {
          expect(
            data['sha256'],
            isNot(equals(zeros)),
            reason: 'sha256 for $key must not be an all-zeros placeholder',
          );
        }

        if (data.containsKey('sha256_archive')) {
          expect(
            data['sha256_archive'],
            isNot(equals(zeros)),
            reason:
                'sha256_archive for $key must not be an all-zeros placeholder',
          );
        }

        if (data.containsKey('sha256_per_abi')) {
          final perAbi = data['sha256_per_abi'] as Map<String, dynamic>;
          for (final abiEntry in perAbi.entries) {
            expect(
              abiEntry.value,
              isNot(equals(zeros)),
              reason:
                  'sha256_per_abi[${abiEntry.key}] for $key must not be an '
                  'all-zeros placeholder',
            );
          }
        }
      }
    });
  });

  group('known platform entries', () {
    test('macos-arm64 is present with expected fields', () {
      expect(platforms.containsKey('macos-arm64'), isTrue);
      final entry = platforms['macos-arm64'] as Map<String, dynamic>;
      expect(entry.containsKey('version'), isTrue);
      expect(entry.containsKey('url'), isTrue);
      expect(entry.containsKey('sha256'), isTrue);
    });

    test('android is present with two-level verification fields', () {
      expect(platforms.containsKey('android'), isTrue);
      final entry = platforms['android'] as Map<String, dynamic>;
      expect(entry.containsKey('version'), isTrue);
      expect(entry.containsKey('url'), isTrue);
      expect(entry.containsKey('sha256_archive'), isTrue);
      expect(entry.containsKey('sha256_per_abi'), isTrue);
      final perAbi = entry['sha256_per_abi'] as Map<String, dynamic>;
      // All four Android ABIs must be present.
      expect(perAbi.containsKey('arm64-v8a'), isTrue);
      expect(perAbi.containsKey('armeabi-v7a'), isTrue);
      expect(perAbi.containsKey('x86_64'), isTrue);
      expect(perAbi.containsKey('x86'), isTrue);
    });

    test(
      'ios entry is present (documentation only — not read at build time)',
      () {
        expect(platforms.containsKey('ios'), isTrue);
        final entry = platforms['ios'] as Map<String, dynamic>;
        expect(entry.containsKey('sha256'), isTrue);
        // The iOS entry uses SPM distribution; it carries a real SHA-256 for
        // reference even though the hook never consults it.
        expect(entry['distribution'], equals('spm'));
      },
    );
  });
}
