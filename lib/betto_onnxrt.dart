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

/// `betto_onnxrt` — ONNX Runtime for Dart.
///
/// Provides a build-time native-assets hook that downloads and stages the
/// ONNX Runtime binary, a generalised [OnnxSession] API, and model-download
/// infrastructure.
///
/// ## Quick start
///
/// ```dart
/// import 'package:betto_onnxrt/betto_onnxrt.dart';
///
/// // 1. Load the ORT runtime (opens the native library staged by the hook).
/// final runtime = await OnnxRuntime.load();
///
/// // 2. Download a model (skips if already cached and verified).
/// final downloader = ModelDownloader();
/// final resolved = await downloader.ensure(
///   myModelSpec,
///   cacheDir: '/path/to/cache',
/// );
///
/// // 3. Create a session and run inference.
/// final modelBytes = File(resolved.filePaths['onnx']!).readAsBytesSync();
/// final session = runtime.createSession(modelBytes);
/// final outputs = session.run(
///   inputs: {'input_ids': inputTensor},
///   outputNames: ['last_hidden_state'],
/// );
/// session.dispose();
/// runtime.dispose();
/// ```
library;

export 'src/allowlist_provider.dart' show AllowlistProvider;
export 'src/model_downloader.dart' show ModelDownloader;
export 'src/model_spec.dart'
    show DownloadProgress, ModelFile, ModelSpec, ResolvedModel;
export 'src/runtime.dart' show OnnxRuntime;
export 'src/session.dart' show OnnxSession;
export 'src/tensor.dart' show OnnxElementType, OnnxTensor, SessionOptions;
