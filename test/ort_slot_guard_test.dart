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

/// ORT vtable-slot guard test.
///
/// This test reads `lib/src/ort_api.dart` as text, extracts all
/// `// SLOT:Name=N` annotations, and asserts they match the golden table
/// for ORT API version 22 (ORT v1.22.x).
///
/// ## Why this test exists
///
/// The vtable slot indices in `ort_api.dart` are hand-maintained against
/// `onnxruntime_c_api.h`. A silent slot drift — e.g. a copy-paste error or a
/// version bump without re-verifying indices — calls the wrong C function and
/// may produce silent wrong output rather than a crash.
///
/// The `// SLOT:Name=N` markers are machine-greppable annotations on each
/// bound typedef pair. The regex `SLOT:(\w+)=(\d+)` is unambiguous and
/// cannot produce false matches from other comments or code in the file.
///
/// ## Limitations
///
/// This guard catches comment drift (a marker that disagrees with the golden)
/// but cannot replace a real load+inference run when slot numbers change.
/// **Any PR that edits slot indices or bumps `ortApiVersion` must include
/// evidence of a passing `make macos_test` (or `make linux_test`) run in the
/// PR description.**
library;

import 'dart:io';

import 'package:test/test.dart';

// ── Golden table for ORT API version 22 (ORT v1.22.x) ───────────────────────
//
// Cross-checked against the `OrtApi` struct field order in
// `onnxruntime_c_api.h` for API version 22.
//
// When upgrading ORT, update this table to match the new header and add the
// new `VERSION_ONNX` to the comment. Also update the `// slot N:` prose
// comments and `// SLOT:Name=N` markers in `lib/src/ort_api.dart`.
const Map<String, int> _expectedSlotsV22 = {
  'CreateStatus': 0,
  'GetErrorMessage': 2,
  'CreateEnv': 3,
  'CreateSession': 7,
  'CreateSessionFromArray': 8,
  'Run': 9,
  'CreateSessionOptions': 10,
  'SetIntraOpNumThreads': 24,
  'SetInterOpNumThreads': 25,
  'CreateTensorWithDataAsOrtValue': 49,
  'GetTensorMutableData': 51,
  'GetTensorElementType': 60,
  'GetDimensionsCount': 61,
  'GetDimensions': 62,
  'GetTensorTypeAndShape': 65,
  'CreateCpuMemoryInfo': 69,
  'ReleaseEnv': 92,
  'ReleaseStatus': 93,
  'ReleaseMemoryInfo': 94,
  'ReleaseSession': 95,
  'ReleaseValue': 96,
  'ReleaseTensorTypeAndShapeInfo': 99,
  'ReleaseSessionOptions': 100,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Returns the package root directory.
///
/// `dart test` always sets [Directory.current] to the package root when
/// invoked from the package directory. This is more reliable than
/// `Platform.script`, which can point to a `.dill` snapshot path when running
/// a single test file directly.
String _packageRoot() => Directory.current.path;

/// Extracts all `// SLOT:Name=N` pairs from [source].
///
/// The regex `SLOT:(\w+)=(\d+)` is deliberately narrow so that it cannot
/// match doc-comment prose or any other existing comment format in the file.
/// It matches only lines introduced specifically for this guard.
Map<String, int> _extractSlotMarkers(String source) {
  final pattern = RegExp(r'SLOT:(\w+)=(\d+)');
  final result = <String, int>{};
  for (final match in pattern.allMatches(source)) {
    final name = match.group(1)!;
    final slot = int.parse(match.group(2)!);
    result[name] = slot;
  }
  return result;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('ORT vtable-slot guard', () {
    late Map<String, int> actualSlots;

    setUpAll(() {
      // Read ort_api.dart relative to the package root where dart test runs.
      final ortApiPath = '${_packageRoot()}/lib/src/ort_api.dart';
      final source = File(ortApiPath).readAsStringSync();
      actualSlots = _extractSlotMarkers(source);
    });

    test('all expected SLOT markers are present in ort_api.dart', () {
      // Report missing markers individually for clear failure messages.
      for (final entry in _expectedSlotsV22.entries) {
        expect(
          actualSlots,
          containsPair(entry.key, entry.value),
          reason:
              'Expected // SLOT:${entry.key}=${entry.value} in '
              'lib/src/ort_api.dart. If the slot changed, update both the '
              'marker and _expectedSlotsV22 in this test, then include '
              'evidence of a passing make macos_test or make linux_test run '
              'in the PR description.',
        );
      }
    });

    test('no unexpected SLOT markers exist in ort_api.dart', () {
      // Catch markers added to the file but not yet to the golden.
      for (final entry in actualSlots.entries) {
        expect(
          _expectedSlotsV22,
          containsPair(entry.key, entry.value),
          reason:
              '// SLOT:${entry.key}=${entry.value} found in '
              'lib/src/ort_api.dart but is not in _expectedSlotsV22. '
              'Add it to the golden table in this test file.',
        );
      }
    });

    test('extracted slot count matches golden entry count', () {
      expect(
        actualSlots.length,
        equals(_expectedSlotsV22.length),
        reason:
            'Number of SLOT markers (${actualSlots.length}) differs from '
            'golden entry count (${_expectedSlotsV22.length}). '
            'Ensure every bound typedef pair has a // SLOT:Name=N marker.',
      );
    });
  });
}
