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

/// Reads VERSION_ONNX from the repo root and writes a Dart constant file to
/// `lib/src/generated/versions.g.dart`.
///
/// Run this script whenever VERSION_ONNX is changed:
///   dart run tool/generate_versions.dart
library;

import 'dart:io';

void main() {
  final scriptDir = File(Platform.script.toFilePath()).parent;
  // Repo root is one level up from tool/.
  final repoRoot = scriptDir.parent;

  final versionFile = File('${repoRoot.path}/VERSION_ONNX');
  if (!versionFile.existsSync()) {
    stderr.writeln('ERROR: VERSION_ONNX not found at ${versionFile.path}');
    exitCode = 1;
    return;
  }

  // Read the version string and strip leading 'v' and whitespace.
  final rawVersion = versionFile.readAsStringSync().trim();
  final version = rawVersion.startsWith('v')
      ? rawVersion.substring(1)
      : rawVersion;
  // Keep the full version tag (e.g. "v1.22.0") for URL construction.
  final versionTag = rawVersion.startsWith('v') ? rawVersion : 'v$rawVersion';

  final outputDir = Directory('${repoRoot.path}/lib/src/generated');
  if (!outputDir.existsSync()) {
    outputDir.createSync(recursive: true);
  }

  final outputFile = File('${outputDir.path}/versions.g.dart');
  // Write the generated file. Do NOT add a license header — this file is
  // generated and the header_template.txt comment style is applied to
  // manually-authored files only.
  outputFile.writeAsStringSync('''
// GENERATED CODE — DO NOT EDIT BY HAND.
// Run `dart run tool/generate_versions.dart` to regenerate.
// Source of truth: VERSION_ONNX in the repository root.

// ignore_for_file: constant_identifier_names

/// The ONNX Runtime version string without the leading 'v' (e.g. '1.22.0').
///
/// Used by [hook/build.dart] to construct GitHub Releases download URLs and
/// cache paths. Bump [VERSION_ONNX] at the repo root and re-run
/// `dart run tool/generate_versions.dart` to update this constant.
const String ortVersion = '$version';

/// The ONNX Runtime version tag as used in GitHub Releases URLs (e.g. 'v1.22.0').
const String ortVersionTag = '$versionTag';
''');

  stdout.writeln('Generated ${outputFile.path}');
  stdout.writeln('  ortVersion   = "$version"');
  stdout.writeln('  ortVersionTag = "$versionTag"');
}
