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

/// Preprocessing: converts raw file bytes into the int32 input tensor
/// expected by the Magika ONNX model.
///
/// This module implements the "features extraction v2" algorithm from the
/// Python Magika source (magika/magika.py,
/// `_extract_features_from_seekable`). The key steps are:
///
/// 1. Read at most `block_size` bytes from the beginning and from the end.
/// 2. Left-strip whitespace from the beg window; right-strip from the end.
/// 3. Build the beg segment: first `beg_size` bytes, right-padded.
/// 4. Build the end segment: last `end_size` bytes, left-padded.
/// 5. Build the mid segment: empty (mid_size = 0 for standard_v3_3).
/// 6. Concatenate [beg, mid, end] → int32 list of length `totalInputSize`.
library;

import 'dart:typed_data';

import 'package:betto_onnxrt/betto_onnxrt.dart';

import 'magika_config.dart';

/// Builds the int32 input tensor from raw [fileBytes] using the given
/// [config].
///
/// The returned [OnnxTensor] has shape `[1, config.totalInputSize]` and
/// element type `int32`. The data layout is:
///   `[beg_segment, mid_segment, end_segment]`
/// where each segment's length is given by [MagikaConfig.begSize],
/// [MagikaConfig.midSize], and [MagikaConfig.endSize] respectively.
///
/// This is a pure function — it does not perform any I/O.
OnnxTensor buildInputTensor(Uint8List fileBytes, MagikaConfig config) {
  final beg = _buildBegSegment(fileBytes, config);
  final mid = _buildMidSegment(fileBytes, config);
  final end = _buildEndSegment(fileBytes, config);

  // Concatenate all segments into a single int32 list.
  final total = config.totalInputSize;
  final data = Int32List(total);
  var offset = 0;
  for (final v in beg) {
    data[offset++] = v;
  }
  for (final v in mid) {
    data[offset++] = v;
  }
  for (final v in end) {
    data[offset++] = v;
  }

  assert(offset == total, 'Expected $total elements, got $offset');

  return OnnxTensor.fromInt32([1, total], data);
}

/// Builds the beginning segment of the input tensor.
///
/// Reads at most `block_size` bytes from position 0. Left-strips ASCII
/// whitespace (matching Python's `bytes.lstrip()`). Then takes the first
/// `beg_size` bytes and right-pads with [MagikaConfig.paddingToken] to
/// reach exactly `beg_size` elements.
List<int> _buildBegSegment(Uint8List fileBytes, MagikaConfig config) {
  if (config.begSize == 0) return [];

  // Read at most block_size bytes from the beginning.
  final bytesToRead = config.blockSize < fileBytes.length
      ? config.blockSize
      : fileBytes.length;
  var beg = fileBytes.sublist(0, bytesToRead);

  // Left-strip ASCII whitespace (bytes 0x09–0x0d and 0x20), matching
  // Python's bytes.lstrip() with no arguments.
  var start = 0;
  while (start < beg.length && _isAsciiWhitespace(beg[start])) {
    start++;
  }
  if (start > 0) {
    beg = beg.sublist(start);
  }

  // Take at most beg_size bytes.
  final take = config.begSize < beg.length ? config.begSize : beg.length;
  final result = List<int>.filled(config.begSize, config.paddingToken);
  for (var i = 0; i < take; i++) {
    result[i] = beg[i];
  }
  // Positions [take, begSize) remain as paddingToken (right-padding).
  return result;
}

/// Builds the middle segment of the input tensor.
///
/// For the `standard_v3_3` model, [MagikaConfig.midSize] is 0 and this
/// returns an empty list. The implementation is included for completeness and
/// to support future model versions that use a mid segment.
List<int> _buildMidSegment(Uint8List fileBytes, MagikaConfig config) {
  if (config.midSize == 0) return [];

  // Centre-align a window of block_size bytes, then take mid_size bytes
  // from the middle, right-padding if necessary.
  final n = fileBytes.length;
  final midStart = (n ~/ 2) - (config.blockSize ~/ 2);
  final clampedStart = midStart < 0 ? 0 : midStart;
  final clampedEnd = clampedStart + config.blockSize < n
      ? clampedStart + config.blockSize
      : n;

  final window = fileBytes.sublist(clampedStart, clampedEnd);

  // Take at most mid_size bytes from the window.
  final take = config.midSize < window.length ? config.midSize : window.length;
  final result = List<int>.filled(config.midSize, config.paddingToken);
  for (var i = 0; i < take; i++) {
    result[i] = window[i];
  }
  return result;
}

/// Builds the end segment of the input tensor.
///
/// Reads at most `block_size` bytes from the end of the file. Right-strips
/// ASCII whitespace (matching Python's `bytes.rstrip()`). Then takes the
/// last `end_size` bytes and left-pads with [MagikaConfig.paddingToken] to
/// reach exactly `end_size` elements.
List<int> _buildEndSegment(Uint8List fileBytes, MagikaConfig config) {
  if (config.endSize == 0) return [];

  // Read at most block_size bytes from the end.
  final n = fileBytes.length;
  final endWindowStart = n - config.blockSize > 0 ? n - config.blockSize : 0;
  var end = fileBytes.sublist(endWindowStart, n);

  // Right-strip ASCII whitespace (bytes 0x09–0x0d and 0x20), matching
  // Python's bytes.rstrip() with no arguments.
  var endIdx = end.length;
  while (endIdx > 0 && _isAsciiWhitespace(end[endIdx - 1])) {
    endIdx--;
  }
  if (endIdx < end.length) {
    end = end.sublist(0, endIdx);
  }

  // Take at most end_size bytes from the END of the stripped window.
  final take = config.endSize < end.length ? config.endSize : end.length;
  final result = List<int>.filled(config.endSize, config.paddingToken);
  // Left-pad: actual bytes occupy the last [take] positions.
  final padCount = config.endSize - take;
  // Positions [0, padCount) remain as paddingToken (left-padding).
  for (var i = 0; i < take; i++) {
    result[padCount + i] = end[end.length - take + i];
  }
  return result;
}

/// Returns whether [byte] is an ASCII whitespace character.
///
/// Matches Python's definition: space (0x20), tab (0x09), newline (0x0a),
/// vertical tab (0x0b), form feed (0x0c), carriage return (0x0d).
bool _isAsciiWhitespace(int byte) {
  return byte == 0x20 || (byte >= 0x09 && byte <= 0x0d);
}
