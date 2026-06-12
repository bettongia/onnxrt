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

/// Configuration and content-type data parsed from the Magika model files.
///
/// [MagikaConfig] is populated by reading two JSON files downloaded alongside
/// the ONNX model:
/// - `config.min.json` — model parameters and label list.
/// - `content_types_kb.min.json` — per-label metadata (mime type, group, etc.)
library;

import 'dart:convert';

/// Metadata for a single content type as defined in `content_types_kb.min.json`.
final class ContentType {
  /// Constructs a [ContentType] from its individual fields.
  const ContentType({
    required this.label,
    required this.mimeType,
    required this.group,
    required this.description,
    required this.extensions,
    required this.isText,
  });

  /// Parses a [ContentType] from the value object in
  /// `content_types_kb.min.json` plus the map key as [label].
  ///
  /// Null `mime_type`, `group`, or `description` values in the JSON are
  /// replaced with sensible defaults matching the Python reference
  /// implementation.
  factory ContentType.fromJson(String label, Map<String, dynamic> json) {
    return ContentType(
      label: label,
      mimeType:
          (json['mime_type'] as String?) ??
          (json['is_text'] == true ? 'text/plain' : 'application/octet-stream'),
      group: (json['group'] as String?) ?? 'unknown',
      description: (json['description'] as String?) ?? label,
      extensions:
          (json['extensions'] as List<dynamic>?)?.cast<String>().toList() ?? [],
      isText: json['is_text'] as bool? ?? false,
    );
  }

  /// The short label string (e.g. `"pdf"`, `"txt"`) from the model.
  final String label;

  /// IANA media type (e.g. `"application/pdf"`).
  final String mimeType;

  /// High-level category group (e.g. `"document"`, `"text"`, `"code"`).
  final String group;

  /// Human-readable description (e.g. `"PDF document"`).
  final String description;

  /// Common file extensions associated with this content type.
  final List<String> extensions;

  /// Whether this content type represents plain-text content.
  final bool isText;

  @override
  String toString() =>
      'ContentType(label: $label, mimeType: $mimeType, group: $group)';
}

/// Parsed representation of the Magika model configuration.
///
/// Created by calling [MagikaConfig.fromJson] with the parsed contents of
/// `config.min.json` and `content_types_kb.min.json`.
final class MagikaConfig {
  /// Constructs a [MagikaConfig] directly from its fields.
  ///
  /// Prefer [MagikaConfig.fromJson] when loading from disk.
  const MagikaConfig({
    required this.begSize,
    required this.midSize,
    required this.endSize,
    required this.paddingToken,
    required this.blockSize,
    required this.targetLabelsSpace,
    required this.contentTypes,
  });

  /// Parses model configuration from [configJson] (content of
  /// `config.min.json`) and [contentTypesJson] (content of
  /// `content_types_kb.min.json`).
  ///
  /// Throws [FormatException] if required fields are missing or have
  /// unexpected types.
  factory MagikaConfig.fromJson(String configJson, String contentTypesJson) {
    final config = jsonDecode(configJson) as Map<String, dynamic>;
    final contentTypesRaw =
        jsonDecode(contentTypesJson) as Map<String, dynamic>;

    final begSize = config['beg_size'] as int;
    final midSize = config['mid_size'] as int;
    final endSize = config['end_size'] as int;
    final paddingToken = config['padding_token'] as int;
    final blockSize = config['block_size'] as int;

    final labelsList = (config['target_labels_space'] as List<dynamic>)
        .cast<String>()
        .toList();

    // Build the content-types lookup map from the knowledge-base JSON.
    // The knowledge base may contain entries for labels not in the model's
    // target space — only entries that appear in [labelsList] are used.
    final contentTypes = <String, ContentType>{};
    for (final entry in contentTypesRaw.entries) {
      contentTypes[entry.key] = ContentType.fromJson(
        entry.key,
        entry.value as Map<String, dynamic>,
      );
    }

    // Synthesise fallback entries for any labels present in the model's
    // target space but absent from the knowledge base, so that label
    // lookup never throws.
    for (final label in labelsList) {
      contentTypes.putIfAbsent(
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
      begSize: begSize,
      midSize: midSize,
      endSize: endSize,
      paddingToken: paddingToken,
      blockSize: blockSize,
      targetLabelsSpace: labelsList,
      contentTypes: contentTypes,
    );
  }

  /// Number of bytes taken from the beginning of the file.
  ///
  /// For `standard_v3_3` this is 1024.
  final int begSize;

  /// Number of bytes taken from the middle of the file.
  ///
  /// For `standard_v3_3` this is 0 (mid segment is unused).
  final int midSize;

  /// Number of bytes taken from the end of the file.
  ///
  /// For `standard_v3_3` this is 1024.
  final int endSize;

  /// Total input vector length: `begSize + midSize + endSize`.
  int get totalInputSize => begSize + midSize + endSize;

  /// Byte value used as the padding token for positions beyond the end of
  /// the file. The model reserves value 256 (outside the byte range 0–255).
  final int paddingToken;

  /// Maximum number of bytes read from each end of the file before trimming
  /// to [begSize] / [endSize].
  final int blockSize;

  /// Ordered list of content-type label strings corresponding to the model's
  /// output vector indices.
  ///
  /// `targetLabelsSpace[i]` is the label whose probability is in
  /// `outputScores[i]`.
  final List<String> targetLabelsSpace;

  /// Map from label string to [ContentType] metadata.
  ///
  /// All labels in [targetLabelsSpace] are guaranteed to have an entry here
  /// (synthesised with fallback values if absent from the knowledge base).
  final Map<String, ContentType> contentTypes;

  /// Returns the [ContentType] for a given [label].
  ///
  /// Falls back to a generic `application/octet-stream` entry if the label
  /// is not in the knowledge base (should not happen for well-formed models).
  ContentType contentTypeFor(String label) {
    return contentTypes[label] ??
        ContentType(
          label: label,
          mimeType: 'application/octet-stream',
          group: 'unknown',
          description: label,
          extensions: [],
          isText: false,
        );
  }
}
