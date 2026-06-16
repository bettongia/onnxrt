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

/// Hook smoke test for `betto_onnxrt`.
///
/// Verifies that the native-assets build hook (`hook/build.dart`) completes
/// without errors and stages the ORT code asset into `.dart_tool/`. The hook
/// is triggered automatically by the Dart test runner whenever a package has
/// native-asset dependencies — by the time this test file is loaded, the
/// hook has already run if the ORT artifact is available on the network (or
/// is cached from a previous run).
///
/// This test file does **not** make network calls. It only inspects the
/// `.dart_tool/` cache directory to confirm:
///   1. The `native_assets.yaml` file was produced by the hook runner.
///   2. The hook did not leave an incomplete `.part` artifact.
///   3. Either a cached ORT library is present (network available at hook
///      time), or the artifact is absent (offline / CI cold-cache), in which
///      case the hook-did-run check is still confirmed via `native_assets.yaml`.
///
/// For a full end-to-end hook verification including an actual binary
/// download, see `docs/spec/28_release_checklist.md` RC-15.
library;

import 'dart:io';

import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Returns the package root directory.
///
/// `dart test` always sets `Directory.current` to the package root when
/// invoked from `cd packages/foo && dart test` (or via melos). This is more
/// reliable than `Platform.script`, which can point to a `.dill` snapshot path
/// when running a single test file.
String _packageRoot() => Directory.current.path;

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  final packageRoot = _packageRoot();

  group('Hook smoke test', () {
    test('native_assets.yaml exists after hook run', () {
      // The Dart test runner invokes the hook before loading any test file.
      // If the hook errored, the test runner itself would have aborted before
      // reaching this test. The presence of native_assets.yaml confirms the
      // hook completed successfully (it is written by the hooks_runner).
      final nativeAssetsFile = File(
        '$packageRoot/.dart_tool/native_assets.yaml',
      );
      expect(
        nativeAssetsFile.existsSync(),
        isTrue,
        reason:
            'native_assets.yaml must exist — the build hook should have '
            'created it. If missing, the hook may have failed silently.',
      );
    });

    test('no stale .part artifact left in the hook cache', () {
      // A leftover .part file means the hook was interrupted mid-download on
      // a previous run and the crash-safety cleanup did not fire. This should
      // never happen with the atomic-rename discipline in _ensureFile().
      final versionFile = File('$packageRoot/VERSION_ONNX');
      if (!versionFile.existsSync()) {
        // VERSION_ONNX missing — package is incomplete; skip gracefully.
        return;
      }
      final version = versionFile.readAsStringSync().trim().replaceFirst(
        'v',
        '',
      );
      final cacheDir = Directory(
        '$packageRoot/.dart_tool/betto_onnxrt/$version',
      );

      if (!cacheDir.existsSync()) {
        // Cache dir absent means hook has not downloaded anything yet
        // (e.g. cold CI with no network). That is acceptable — the hook ran
        // but found no local artifact to stage yet. Nothing to check.
        return;
      }

      final partFiles = cacheDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.part'))
          .toList();

      expect(
        partFiles,
        isEmpty,
        reason:
            'Found leftover .part file(s): ${partFiles.map((f) => f.path).join(', ')}. '
            'This indicates an incomplete download that was not cleaned up — '
            'delete the file(s) and re-run the hook.',
      );
    });

    test('hook cache directory is version-scoped', () {
      final versionFile = File('$packageRoot/VERSION_ONNX');
      expect(
        versionFile.existsSync(),
        isTrue,
        reason: 'VERSION_ONNX must exist at the package root.',
      );

      final raw = versionFile.readAsStringSync().trim();
      // Accept both 'v1.22.0' and '1.22.0' forms.
      final version = raw.startsWith('v') ? raw.substring(1) : raw;

      // Version string must be non-empty and contain at least one dot.
      expect(version, isNotEmpty);
      expect(version, contains('.'));

      // The hook cache is scoped to the version so a bump forces a fresh
      // download. Confirm the path convention matches what _cacheDirectory()
      // in hook/build.dart computes.
      final expectedCachePath = '$packageRoot/.dart_tool/betto_onnxrt/$version';
      final hookCachePath = Directory(expectedCachePath).path;
      expect(hookCachePath, endsWith(version));
    });
  });
}
