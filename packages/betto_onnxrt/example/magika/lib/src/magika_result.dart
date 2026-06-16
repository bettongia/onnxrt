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

/// Data classes for the Magika inference result and JSON serialisation.
///
/// The JSON output mirrors the Python Magika CLI `--json` format for
/// interoperability with tools that consume Python Magika output.
library;

import 'magika_config.dart';

/// Detail block for a single inferred content type.
///
/// This corresponds to the `dl` / `output` sub-object in the Python Magika
/// JSON output.
final class LabelDetail {
  /// Constructs a [LabelDetail] from a [ContentType] entry.
  factory LabelDetail.fromContentType(ContentType ct) {
    return LabelDetail(
      label: ct.label,
      description: ct.description,
      extensions: List.unmodifiable(ct.extensions),
      group: ct.group,
      isText: ct.isText,
      mimeType: ct.mimeType,
    );
  }

  /// Constructs a [LabelDetail] directly from its fields.
  const LabelDetail({
    required this.label,
    required this.description,
    required this.extensions,
    required this.group,
    required this.isText,
    required this.mimeType,
  });

  /// The short model label string (e.g. `"pdf"`).
  final String label;

  /// Human-readable description (e.g. `"PDF document"`).
  final String description;

  /// Common file extensions for this type (e.g. `["pdf"]`).
  final List<String> extensions;

  /// High-level category group (e.g. `"document"`).
  final String group;

  /// Whether the content type is text-based.
  final bool isText;

  /// IANA media type (e.g. `"application/pdf"`).
  final String mimeType;

  /// Serialises this detail block to the Python-compatible JSON sub-object.
  Map<String, Object?> toJson() {
    return {
      'label': label,
      'description': description,
      'extensions': extensions,
      'group': group,
      'is_text': isText,
      'mime_type': mimeType,
    };
  }
}

/// The inference result for a single file.
///
/// In this v1 implementation the [output] field is always equal to [dl].
/// Rule-based overrides (e.g. declaring very small files `unknown`) are
/// deferred to a future plan.
final class MagikaResult {
  /// Constructs a [MagikaResult] with the inferred label details and score.
  ///
  /// [dl] is the raw deep-learning model output. [output] mirrors [dl] in
  /// v1 (no rule-based overrides).
  const MagikaResult({
    required this.dl,
    required this.output,
    required this.score,
  });

  /// The raw model output label detail.
  final LabelDetail dl;

  /// The final output label detail (equals [dl] in v1).
  final LabelDetail output;

  /// Softmax confidence score in the range [0.0, 1.0].
  final double score;

  /// Serialises this result to the Python-compatible `result.value` JSON
  /// sub-object (the `"value"` inside a `"status": "ok"` result).
  Map<String, Object?> toJson() {
    return {'dl': dl.toJson(), 'output': output.toJson(), 'score': score};
  }
}

/// Wraps a [MagikaResult] together with the file path it was computed for.
///
/// The [toJson] output matches the top-level array element in the Python
/// Magika CLI `--json` format.
final class MagikaFileResult {
  /// Constructs a successful result for [path].
  ///
  /// [result] is the [MagikaResult] produced by inference.
  const MagikaFileResult.ok({required this.path, required this.result})
    : error = null;

  /// Constructs an error result for [path] with the given [error] message.
  const MagikaFileResult.error({required this.path, required this.error})
    : result = null;

  /// Absolute path of the file that was analysed.
  final String path;

  /// The inference result, or `null` when [error] is set.
  final MagikaResult? result;

  /// The error message, or `null` when [result] is set.
  final String? error;

  /// Whether this result represents a successful inference.
  bool get isOk => result != null;

  /// Serialises this result to a single element of the Python-compatible
  /// JSON array.
  ///
  /// Success format:
  /// ```json
  /// {"path": "...", "result": {"status": "ok", "value": { ... }}}
  /// ```
  ///
  /// Error format:
  /// ```json
  /// {"path": "...", "result": {"status": "error", "value": {"error": "..."}}}
  /// ```
  Map<String, Object?> toJson() {
    if (result != null) {
      return {
        'path': path,
        'result': {'status': 'ok', 'value': result!.toJson()},
      };
    } else {
      return {
        'path': path,
        'result': {
          'status': 'error',
          'value': {'error': error},
        },
      };
    }
  }
}
