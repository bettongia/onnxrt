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

/// Generic [ModelSpec] and [ModelFile] types for downloadable ONNX models.
library;

/// A single file that is part of a downloadable model.
///
/// Contains the HTTPS download [url] and a lowercase hex SHA-256
/// [sha256] checksum used by [ModelDownloader] for integrity verification.
///
/// ## Example
///
/// ```dart
/// const onnxFile = ModelFile(
///   url: Uri.parse('https://example.com/model.onnx'),
///   sha256: 'abc123...',
/// );
/// ```
final class ModelFile {
  /// Creates a [ModelFile].
  const ModelFile({required this.url, required this.sha256});

  /// The HTTPS URL from which this file is downloaded.
  final Uri url;

  /// Lowercase hex SHA-256 digest of the file at [url].
  ///
  /// Used by [ModelDownloader] to verify download integrity. A mismatch
  /// triggers deletion of the corrupt download and throws [StateError].
  final String sha256;

  @override
  String toString() => 'ModelFile(url=$url)';
}

/// A downloadable ONNX model described by a stable [id], a map of named
/// [files], and caller-defined [meta] data.
///
/// [ModelSpec] is the generic container — it makes no assumptions about the
/// model's architecture or required files. Callers (e.g. `kmdb_inferencing`)
/// define which file names are meaningful:
///
/// ```dart
/// const bgeSpec = ModelSpec(
///   id: 'bge-small-en-v1.5',
///   files: {
///     'onnx':  ModelFile(url: Uri.parse('…'), sha256: '…'),
///     'vocab': ModelFile(url: Uri.parse('…'), sha256: '…'),
///   },
///   meta: {'dimensions': 384},
/// );
/// ```
///
/// After a successful [ModelDownloader.ensure] call, file names in [files]
/// map to absolute local paths in [ResolvedModel.filePaths].
final class ModelSpec {
  /// Creates a [ModelSpec].
  const ModelSpec({
    required this.id,
    required this.files,
    this.meta = const {},
  });

  /// Stable identifier for this model.
  ///
  /// Used as the subdirectory name under the [ModelDownloader] cache
  /// directory and persisted in system state so that model changes can be
  /// detected and dependent indexes rebuilt. Must be unique within an
  /// application's model catalog.
  ///
  /// Examples: `'bge-small-en-v1.5'`, `'bge-m3-v1.0'`
  final String id;

  /// Named files that make up this model.
  ///
  /// Keys are caller-defined names (e.g. `'onnx'`, `'vocab'`). Values are
  /// [ModelFile] objects holding the download URL and SHA-256 checksum.
  /// After a successful [ModelDownloader.ensure] call, the same keys appear
  /// in [ResolvedModel.filePaths] with absolute local path values.
  final Map<String, ModelFile> files;

  /// Caller-defined metadata for this model.
  ///
  /// Uninterpreted by `betto_onnxrt`. Consumers use this for model-specific
  /// parameters that do not belong in the generic [files] map. For example,
  /// `kmdb_inferencing` stores `{'dimensions': 384}` here and reads it as
  /// `spec.meta['dimensions'] as int`.
  final Map<String, Object?> meta;

  @override
  String toString() => 'ModelSpec(id=$id, files=${files.keys.toList()})';
}

/// The resolved local file paths for a downloaded model.
///
/// Returned by [ModelDownloader.ensure] once all [ModelSpec.files] are
/// present on disk and their SHA-256 checksums have been verified.
///
/// Keys in [filePaths] match the keys in [ModelSpec.files].
final class ResolvedModel {
  /// Creates a [ResolvedModel].
  const ResolvedModel({required this.spec, required this.filePaths});

  /// The [ModelSpec] that was resolved.
  final ModelSpec spec;

  /// Absolute paths to each downloaded model file.
  ///
  /// Keys are the same as [ModelSpec.files]. For example, if the spec has
  /// `files: {'onnx': …, 'vocab': …}`, then [filePaths] contains
  /// `{'onnx': '/path/to/model.onnx', 'vocab': '/path/to/vocab.txt'}`.
  final Map<String, String> filePaths;

  @override
  String toString() =>
      'ResolvedModel(id=${spec.id}, files=${filePaths.keys.toList()})';
}

/// Callback invoked during file downloads to report download progress.
///
/// [received] is the number of bytes downloaded so far.
/// [total] is the expected total size in bytes. `-1` means the server did
/// not supply a `Content-Length` header and the total is unknown.
typedef DownloadProgress = void Function(int received, int total);
