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

/// [ModelDownloader] — SHA-256 verified download with crash-safe staging.
///
/// This file is native-only (`dart:io`). Web is excluded from
/// `betto_onnxrt` by design — semantic search is not supported on web.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'allowlist_provider.dart';
import 'model_spec.dart';

/// Downloads and verifies ONNX model files described by a [ModelSpec].
///
/// [ModelDownloader] maintains a local cache directory. For each file in
/// [ModelSpec.files] it:
///
/// 1. Checks whether the file is already present and its SHA-256 checksum
///    matches [ModelFile.sha256]. If so, the download is skipped (fast path).
/// 2. Downloads the file from [ModelFile.url] to a temporary `.part` path in
///    the same directory.
/// 3. Verifies the SHA-256 checksum of the downloaded data. If it does not
///    match, the partial file is deleted and [StateError] is thrown.
/// 4. Atomically renames the verified temporary file to its final path.
///
/// ## Crash safety
///
/// Writes go through a temp-file + atomic rename so a partial or interrupted
/// download never passes the existence-and-checksum check on a later run. A
/// leftover `.part` file is silently overwritten on the next attempt.
///
/// ## Concurrency
///
/// For concurrent invocations sharing the same [cacheDir], **no locking is
/// needed**: last-writer-wins on the atomic rename is safe because both
/// writers produce byte-identical, checksum-verified output.
///
/// ## Allowlist
///
/// If an [AllowlistProvider] is supplied, [ensure] calls [AllowlistProvider.isAllowed]
/// before downloading. Pass `null` (default) to permit any model.
///
/// ## Platform
///
/// This class is **native-only** (`dart:io`). Web callers must not use it.
/// Semantic search (the primary consumer) is excluded from the web browser.
///
/// ## Usage
///
/// ```dart
/// final downloader = ModelDownloader(allowlist: ModelCatalog());
/// final resolved = await downloader.ensure(
///   spec,
///   cacheDir: '/path/to/cache',
///   onProgress: (received, total) =>
///       stderr.writeln('$received / $total bytes'),
/// );
/// final onnxPath = resolved.filePaths['onnx']!;
/// ```
final class ModelDownloader {
  /// Creates a [ModelDownloader].
  ///
  /// [allowlist] — if non-null, [ensure] rejects any [ModelSpec] for which
  /// [AllowlistProvider.isAllowed] returns `false`.
  ///
  /// [httpClientFactory] — optional override for the [HttpClient] used during
  /// downloads. Defaults to `HttpClient()`. Inject a custom factory in tests
  /// to avoid hitting the network.
  // The `allowlist` parameter intentionally differs from the private field
  // name `_allowlist` to present a clean public API. Initializing formals
  // cannot be used across different public/private names.
  ModelDownloader({
    AllowlistProvider? allowlist,
    HttpClient Function()? httpClientFactory,
  })  : _allowlist = allowlist, // ignore: prefer_initializing_formals
        _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final AllowlistProvider? _allowlist;
  final HttpClient Function() _httpClientFactory;

  /// Ensures all files for [spec] are present and verified under [cacheDir].
  ///
  /// Returns a [ResolvedModel] with absolute paths to each file once all
  /// downloads are complete. Files that are already cached and whose
  /// SHA-256 matches are not re-downloaded.
  ///
  /// [cacheDir] — the root cache directory. A model-specific subdirectory
  /// named [ModelSpec.id] is created inside it.
  ///
  /// [onProgress] — optional callback invoked with incremental byte counts
  /// during each download. Not called for cached files.
  ///
  /// Throws [ArgumentError] if [spec] is rejected by the [allowlist].
  /// Throws [StateError] if a downloaded file fails SHA-256 verification.
  /// Throws [HttpException] if the server returns a non-2xx status.
  Future<ResolvedModel> ensure(
    ModelSpec spec, {
    required String cacheDir,
    DownloadProgress? onProgress,
  }) async {
    // Gate on the allowlist before any I/O.
    if (_allowlist != null && !_allowlist.isAllowed(spec)) {
      throw ArgumentError(
        "Model '${spec.id}' is not permitted by the allowlist. "
        'Add it to your AllowlistProvider implementation to enable downloads.',
      );
    }

    // Create the model-specific subdirectory inside the cache dir.
    // Using the model ID as the subdirectory name keeps models isolated.
    final modelDir = Directory('$cacheDir/${spec.id}');

    final filePaths = <String, String>{};

    for (final entry in spec.files.entries) {
      final fileName = entry.key;
      final modelFile = entry.value;

      // Use a stable local filename derived from the URL's last path segment.
      // This avoids collisions if two files have the same key name.
      final localName = Uri.parse(modelFile.url.toString()).pathSegments.last;
      final destFile = File('${modelDir.path}/$localName');

      if (!_isValid(destFile, modelFile.sha256)) {
        await modelDir.create(recursive: true);
        await _download(
          url: modelFile.url.toString(),
          dest: destFile,
          expectedSha256: modelFile.sha256,
          onProgress: onProgress,
        );
      }

      filePaths[fileName] = destFile.path;
    }

    return ResolvedModel(spec: spec, filePaths: filePaths);
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Returns `true` if [file] exists and its SHA-256 digest matches
  /// [expectedHex].
  bool _isValid(File file, String expectedHex) {
    if (!file.existsSync()) return false;
    try {
      final bytes = file.readAsBytesSync();
      final digest = sha256.convert(bytes);
      return digest.toString() == expectedHex;
    } catch (_) {
      return false;
    }
  }

  /// Downloads [url] to a temp `.part` file alongside [dest], verifies the
  /// SHA-256, and atomically renames the temp file to [dest] on success.
  ///
  /// The `.part` suffix ensures a partial download can never pass the
  /// existence+checksum check on a subsequent run. A leftover `.part` file
  /// from a prior interrupted download is overwritten silently.
  ///
  /// Throws [StateError] if the downloaded data does not match
  /// [expectedSha256]. Throws [HttpException] on non-2xx responses.
  Future<void> _download({
    required String url,
    required File dest,
    required String expectedSha256,
    DownloadProgress? onProgress,
  }) async {
    // Write to a .part temp file so a partial download is never mistaken for
    // a complete, verified file on a later run.
    final tempFile = File('${dest.path}.part');

    final client = _httpClientFactory();
    try {
      final uri = Uri.parse(url);
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}: $url',
          uri: uri,
        );
      }

      final totalBytes =
          response.headers.contentLength < 0
              ? -1
              : response.headers.contentLength;
      var receivedBytes = 0;

      // Stream the response to the temp file and accumulate bytes for
      // checksum computation in a single pass.
      final sink = tempFile.openWrite();
      final accumulator = BytesBuilder(copy: false);
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          accumulator.add(chunk);
          receivedBytes += chunk.length;
          onProgress?.call(receivedBytes, totalBytes);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // Verify the downloaded content against the expected checksum.
      final allBytes = accumulator.toBytes();
      final digest = sha256.convert(allBytes);
      if (digest.toString() != expectedSha256) {
        // Delete the corrupt temp file before throwing.
        await tempFile.delete().catchError((_) => tempFile);
        throw StateError(
          'SHA-256 checksum mismatch for ${dest.path}.\n'
          '  Expected : $expectedSha256\n'
          '  Got      : ${digest.toString()}\n'
          'The download may be corrupt or the ModelSpec checksum is wrong. '
          'Delete the cache directory and retry.',
        );
      }

      // Checksum verified — atomically rename the temp file to the final path.
      // Last-writer-wins is safe: concurrent writers produce identical output.
      await tempFile.rename(dest.path);
    } finally {
      client.close();
    }
  }
}
