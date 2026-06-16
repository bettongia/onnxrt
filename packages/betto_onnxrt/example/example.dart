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

// ignore_for_file: avoid_print

/// Demonstrates the three main concerns of `betto_onnxrt`:
///
/// 1. Loading the ORT runtime (opened from the native-assets-staged library).
/// 2. Running inference with `OnnxSession`.
/// 3. Downloading a model with `ModelDownloader` + `ModelSpec`.
///
/// This example is intentionally self-contained and does not hit the network
/// or load a real model file. It shows the API shape; swap in a real `.onnx`
/// path and `ModelSpec` to use it in production.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:betto_onnxrt/betto_onnxrt.dart';

// ---------------------------------------------------------------------------
// Example 1 — Running inference from a model file
// ---------------------------------------------------------------------------

Future<void> runInferenceExample() async {
  // Load the ORT runtime. The native library was staged by hook/build.dart
  // at compile time; this call opens it and initialises the OrtApi vtable.
  final runtime = await OnnxRuntime.load();

  // Open a session from a local .onnx file.
  // Use createSession(bytes) if the model is already in memory.
  final session = runtime.createSessionFromFile(
    '/path/to/your/model.onnx',
    options: const SessionOptions(intraOpNumThreads: 1),
  );

  // Build input tensors. Shape and names must match the model's input spec.
  // This example uses a BGE-style text-embedding model with a single
  // [batch=1, seq=512] int64 input called "input_ids".
  final inputIds = OnnxTensor.fromInt64(
    [1, 512],
    Int64List.fromList(List.filled(512, 0)),
  );

  // Run inference and collect the named outputs.
  final outputs = session.run(
    inputs: {'input_ids': inputIds},
    outputNames: ['last_hidden_state'],
  );

  // The output is a float32 tensor. Shape is read from the native OrtValue.
  final embeddings = outputs.first;
  print('output shape : ${embeddings.shape}');
  print('first 4 values: ${embeddings.asFloat32().take(4).toList()}');

  // Always dispose sessions before the runtime.
  session.dispose();
  runtime.dispose();
}

// ---------------------------------------------------------------------------
// Example 2 — Downloading a model with ModelDownloader
// ---------------------------------------------------------------------------

// Define a model catalogue entry. In production this lives in your app's
// model catalogue class, not inline.
final _myModel = ModelSpec(
  id: 'bge-small-en-v1.5',
  files: {
    'onnx': ModelFile(
      url: Uri(
        scheme: 'https',
        host: 'huggingface.co',
        path: '/BAAI/bge-small-en-v1.5/resolve/main/onnx/model.onnx',
      ),
      sha256:
          '828e1496d7fabb79cfa4dcd84fa38625'
          'c0d3d21da474a00f08db0f559940cf35',
    ),
  },
  meta: {'dimensions': 384},
);

Future<void> downloadModelExample() async {
  final cacheDir = Directory.systemTemp.path;

  // ModelDownloader verifies SHA-256 and skips re-downloading cached files.
  final downloader = ModelDownloader();

  print('Ensuring model is cached…');
  final resolved = await downloader.ensure(
    _myModel,
    cacheDir: cacheDir,
    onProgress: (received, total) {
      if (total > 0) {
        final pct = (received / total * 100).toStringAsFixed(1);
        stdout.write('\r  $pct %   ');
      }
    },
  );
  print('\nModel ready at: ${resolved.filePaths['onnx']}');
}

// ---------------------------------------------------------------------------
// Example 3 — AllowlistProvider
// ---------------------------------------------------------------------------

class _MyCatalog implements AllowlistProvider {
  static const _permitted = {'bge-small-en-v1.5', 'bge-m3-v1.0'};

  @override
  bool isAllowed(ModelSpec spec) => _permitted.contains(spec.id);
}

Future<void> allowlistExample() async {
  // ModelDownloader rejects specs not on the allowlist.
  final downloader = ModelDownloader(allowlist: _MyCatalog());

  try {
    await downloader.ensure(
      const ModelSpec(id: 'unknown-model', files: {}),
      cacheDir: Directory.systemTemp.path,
    );
  } on ArgumentError catch (e) {
    print('Blocked as expected: $e');
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

Future<void> main() async {
  // Example 1 requires a real .onnx file — skipped here to keep the example
  // runnable without assets.
  print('--- Example 1: inference (skipped — needs a real .onnx file) ---');

  print('--- Example 2: model download ---');
  // Uncomment to actually hit the network:
  // await downloadModelExample();
  print('(network download skipped in example)');

  print('--- Example 3: allowlist ---');
  await allowlistExample();
}
