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

/// Model specification and cache-directory helper for the Magika
/// `standard_v3_3` model.
///
/// SHA-256 checksums were computed from the files as downloaded from
/// `raw/main` on 2026-06-11. The model URLs use a floating `main` ref —
/// if Google pushes an updated model the checksums will no longer match.
///
/// To update checksums after a model change:
/// ```bash
/// curl -fsSL https://github.com/google/magika/raw/main/assets/models/standard_v3_3/model.onnx \
///   | shasum -a 256
/// curl -fsSL https://github.com/google/magika/raw/main/assets/models/standard_v3_3/config.min.json \
///   | shasum -a 256
/// curl -fsSL https://raw.githubusercontent.com/google/magika/main/python/src/magika/config/content_types_kb.min.json \
///   | shasum -a 256
/// ```
/// Then replace [kModelOnnxSha256], [kModelConfigSha256], and
/// [kModelContentTypesSha256] below.
library;

import 'dart:io';

import 'package:betto_onnxrt/betto_onnxrt.dart';

/// The ONNX model file key used in [kMagikaModelSpec].
const kModelFileKeyOnnx = 'onnx';

/// The model config JSON file key used in [kMagikaModelSpec].
const kModelFileKeyConfig = 'config';

/// The content-types knowledge base file key used in [kMagikaModelSpec].
const kModelFileKeyContentTypes = 'content_types';

/// Input tensor name expected by the Magika `standard_v3_3` ONNX model.
///
/// The model accepts a single input named `bytes` with shape `[batch, 2048]`
/// and dtype int32. Values are raw byte integers (0–255) plus the
/// [kMagikaPaddingToken] sentinel (256) for padding positions.
const kMagikaInputName = 'bytes';

/// Output tensor name produced by the Magika `standard_v3_3` ONNX model.
///
/// The model produces a single output named `target_label` with shape
/// `[batch, 214]` and dtype float32 (softmax probabilities over labels).
const kMagikaOutputName = 'target_label';

/// SHA-256 checksum (lowercase hex) of `model.onnx` as of 2026-06-11.
const kModelOnnxSha256 =
    'fe2d2eb49c5f88a9e0a6c048e15d6ffdf86235519c2afc535044de433169ec8c';

/// SHA-256 checksum (lowercase hex) of `config.min.json` as of 2026-06-11.
const kModelConfigSha256 =
    'ae24c742205358f6ff6dfd5facb6743fb69743dbba8373e73da58ff0cbd695db';

/// SHA-256 checksum (lowercase hex) of `content_types_kb.min.json` as of
/// 2026-06-11.
const kModelContentTypesSha256 =
    '75208adba69bc0556403b62b32ef3ccf8b5ce494411780845852e52e6583a10d';

/// The [ModelSpec] describing the Magika `standard_v3_3` model files.
///
/// Pass this to [ModelDownloader.ensure] along with the cache directory
/// returned by [resolveModelCacheDir] to download and verify all three files:
/// the ONNX model, the model config, and the content-types knowledge base.
final kMagikaModelSpec = ModelSpec(
  id: 'magika_standard_v3_3',
  files: {
    kModelFileKeyOnnx: ModelFile(
      url: Uri.parse(
        'https://github.com/google/magika/raw/main/assets/models/standard_v3_3/model.onnx',
      ),
      sha256: kModelOnnxSha256,
    ),
    kModelFileKeyConfig: ModelFile(
      url: Uri.parse(
        'https://github.com/google/magika/raw/main/assets/models/standard_v3_3/config.min.json',
      ),
      sha256: kModelConfigSha256,
    ),
    kModelFileKeyContentTypes: ModelFile(
      url: Uri.parse(
        'https://raw.githubusercontent.com/google/magika/main/python/src/magika/config/content_types_kb.min.json',
      ),
      sha256: kModelContentTypesSha256,
    ),
  },
);

/// The padding token value used to fill short segments.
///
/// Bytes 0–255 are raw file byte values; 256 is the out-of-band padding
/// sentinel defined by the Magika model.
const kMagikaPaddingToken = 256;

/// Resolves the root cache directory for `betto_onnxrt` models.
///
/// Follows XDG conventions:
/// - **Linux / macOS**: `~/.cache/betto_onnxrt/` (via `HOME`).
/// - **Windows**: `%LOCALAPPDATA%\betto_onnxrt\cache\`.
///
/// Falls back to a subdirectory of [Directory.systemTemp] if the expected
/// environment variables are absent (unusual environments or containers
/// without a home directory). Note that temp-directory contents may be
/// cleared between runs, which will trigger unnecessary re-downloads.
String resolveModelCacheDir() {
  if (Platform.isWindows) {
    final localAppData =
        Platform.environment['LOCALAPPDATA'] ?? Platform.environment['APPDATA'];
    if (localAppData != null) {
      return '$localAppData\\betto_onnxrt\\cache';
    }
  } else {
    final home = Platform.environment['HOME'];
    if (home != null) {
      return '$home/.cache/betto_onnxrt';
    }
  }
  // Fall back to system temp — contents may be cleared between runs.
  return '${Directory.systemTemp.path}/betto_onnxrt_cache';
}
