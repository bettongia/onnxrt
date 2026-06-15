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

/// Postprocessing: converts the raw model output tensor into a
/// [MagikaResult].
///
/// The Magika model produces a float32 softmax probability vector over all
/// possible content-type labels. Postprocessing finds the argmax index,
/// looks up the corresponding label in the config, and produces a typed
/// result object ready for JSON serialisation.
///
/// **Note**: `OnnxTensor.asFloat32()` throws a [StateError] if the output
/// tensor is not float32. This is safe for the `standard_v3_3` model, which
/// has a confirmed float32 output. If a future model version changes the
/// output type, this code must be updated accordingly.
library;

import 'package:betto_onnxrt/betto_onnxrt.dart';

import 'magika_config.dart';
import 'magika_result.dart';

/// Converts the raw [scoresTensor] from [OnnxSession.run] into a
/// [MagikaResult] using label metadata from [config].
///
/// [scoresTensor] must be a float32 tensor with shape `[1, N]` where `N`
/// matches `config.targetLabelsSpace.length`. Throws [StateError] if the
/// tensor is not float32 (use `.asFloat32()` — see library doc comment).
/// Throws [ArgumentError] if the tensor has no elements.
MagikaResult postprocess(OnnxTensor scoresTensor, MagikaConfig config) {
  // Access the raw probability scores. This throws StateError if the tensor
  // is not float32 — confirmed safe for Magika standard_v3_3.
  final scores = scoresTensor.asFloat32();

  if (scores.isEmpty) {
    throw ArgumentError('Score tensor is empty; cannot determine label.');
  }

  // Find the argmax: the index of the highest-probability label.
  var bestIdx = 0;
  var bestScore = scores[0];
  for (var i = 1; i < scores.length; i++) {
    if (scores[i] > bestScore) {
      bestScore = scores[i];
      bestIdx = i;
    }
  }

  // Look up the label name and its content-type metadata.
  final labels = config.targetLabelsSpace;
  if (bestIdx >= labels.length) {
    throw ArgumentError(
      'Argmax index $bestIdx exceeds label space size ${labels.length}.',
    );
  }

  final label = labels[bestIdx];
  final contentType = config.contentTypeFor(label);
  final detail = LabelDetail.fromContentType(contentType);

  return MagikaResult(
    dl: detail,
    // v1: output always equals dl (no rule-based overrides).
    output: detail,
    score: bestScore.toDouble(),
  );
}
