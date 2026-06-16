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

/// Magika CLI — detects file types using Google's Magika v3.3 ONNX model.
///
/// Usage:
/// ```
/// magika <file>
/// ```
///
/// On first run the tool downloads and caches the Magika model in
/// `~/.cache/betto_onnxrt/` (Linux/macOS) or
/// `%LOCALAPPDATA%\betto_onnxrt\cache\` (Windows).
///
/// Output is a JSON array that mirrors the Python Magika `--json` format.
/// Exit codes: 0 on success, 1 on file error or missing argument.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:betto_onnxrt/betto_onnxrt.dart';

import 'package:magika/src/magika_config.dart';
import 'package:magika/src/magika_postprocess.dart';
import 'package:magika/src/magika_preprocess.dart';
import 'package:magika/src/magika_result.dart';
import 'package:magika/src/magika_spec.dart';

Future<void> main(List<String> args) async {
  // Validate arguments: exactly one positional file path required.
  if (args.length != 1) {
    stderr.writeln('Usage: magika <file>');
    exit(1);
  }

  final filePath = args[0];

  // Resolve the model cache directory.
  final cacheDir = resolveModelCacheDir();

  // Download (or verify cached) model files.
  final downloader = ModelDownloader();
  late ResolvedModel resolved;
  try {
    resolved = await downloader.ensure(
      kMagikaModelSpec,
      cacheDir: cacheDir,
      onProgress: (received, total) {
        if (total > 0) {
          final pct = (received * 100 ~/ total);
          stderr.write('\rDownloading model... $pct%');
        }
      },
    );
    // Clear the progress line if we printed one.
    stderr.writeln();
  } catch (e) {
    stderr.writeln('Error downloading model: $e');
    exit(1);
  }

  // Read file bytes — the entire file is loaded into memory (v1 limitation).
  late Uint8List fileBytes;
  late String absolutePath;
  try {
    final file = File(filePath);
    absolutePath = file.absolute.path;
    fileBytes = await file.readAsBytes();
  } catch (e) {
    final errorResult = MagikaFileResult.error(
      path: File(filePath).absolute.path,
      error: e.toString(),
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert([errorResult.toJson()]),
    );
    exit(1);
  }

  // Parse model config and content-types knowledge base.
  late MagikaConfig config;
  try {
    final configJson = await File(
      resolved.filePaths[kModelFileKeyConfig]!,
    ).readAsString();
    final contentTypesJson = await File(
      resolved.filePaths[kModelFileKeyContentTypes]!,
    ).readAsString();
    config = MagikaConfig.fromJson(configJson, contentTypesJson);
  } catch (e) {
    stderr.writeln('Error loading model config: $e');
    exit(1);
  }

  // Load the ONNX Runtime and create the inference session.
  late OnnxRuntime runtime;
  late OnnxSession session;
  try {
    // OnnxRuntime.load() is async — awaited here before any inference work.
    runtime = await OnnxRuntime.load();
    session = runtime.createSessionFromFile(
      resolved.filePaths[kModelFileKeyOnnx]!,
    );
  } catch (e) {
    stderr.writeln('Error loading ONNX session: $e');
    exit(1);
  }

  // Run inference; dispose session and runtime in a try/finally so they are
  // guaranteed to be released even if postprocessing throws.
  late MagikaFileResult fileResult;
  try {
    final inputTensor = buildInputTensor(fileBytes, config);
    final outputs = session.run(
      inputs: {kMagikaInputName: inputTensor},
      outputNames: [kMagikaOutputName],
    );
    final result = postprocess(outputs.first, config);
    fileResult = MagikaFileResult.ok(path: absolutePath, result: result);
  } catch (e) {
    fileResult = MagikaFileResult.error(
      path: absolutePath,
      error: e.toString(),
    );
  } finally {
    // Always dispose to release native handles, even if inference threw.
    session.dispose();
    runtime.dispose();
  }

  // Emit the JSON array to stdout.
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert([fileResult.toJson()]),
  );

  // Exit 1 if the result is an error.
  if (!fileResult.isOk) {
    exit(1);
  }
}
