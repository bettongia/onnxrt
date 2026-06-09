# betto_onnxrt

ONNX Runtime for Dart — a native-assets build hook that bundles the ORT
binary at compile time, a generalised `OnnxSession` inference API, and
crash-safe model-download infrastructure.

## Features

- **Zero-config binary delivery** — `hook/build.dart` downloads the correct
  ONNX Runtime prebuilt for your target platform and architecture, verifies
  its SHA-256 checksum, and registers it as a `CodeAsset`. No manual binary
  management required.
- **Generalised inference API** — `OnnxSession.run` accepts arbitrary named
  inputs and output names, so it works with any ONNX model, not just a
  specific architecture.
- **Typed tensor API** — `OnnxTensor` supports `float32`, `float64`, `int32`,
  `int64`, and `uint8` element types with named factories and typed accessors.
- **Model downloader** — `ModelDownloader` fetches and locally caches ONNX
  model files described by a `ModelSpec`. Downloads are SHA-256 verified and
  written crash-safely via a temp-file + atomic rename.
- **Allowlist support** — implement `AllowlistProvider` to gate which models
  `ModelDownloader` is permitted to fetch.

## Platform support

| Platform | Status   | Notes                                          |
|----------|----------|------------------------------------------------|
| macOS    | Supported | `libonnxruntime.dylib` bundled via hook        |
| Linux    | Supported | `libonnxruntime.so` bundled via hook           |
| Windows  | Supported | `onnxruntime.dll` bundled via hook             |
| Android  | Supported | `libonnxruntime.so` bundled in APK `lib/`      |
| iOS      | Supported | ORT XCFramework extracted and statically linked |
| Web      | Not supported | Native inference is excluded by design     |

Bundles ONNX Runtime **v1.22.0**.

## Requirements

- Dart SDK `^3.12.0`
- Native assets support must be enabled in your project (Dart ≥ 3.3 or
  Flutter ≥ 3.22 for stable native-assets support)

## Getting started

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  betto_onnxrt: ^0.1.0
```

The build hook runs automatically during `dart build` or `flutter build`.
No additional setup is required to get the ORT binary.

## Usage

### Loading the runtime and running inference

```dart
import 'dart:io';
import 'package:betto_onnxrt/betto_onnxrt.dart';

// 1. Load the ORT runtime (opens the native library staged by the hook).
final runtime = await OnnxRuntime.load();

// 2. Create a session from model bytes.
final modelBytes = File('/path/to/model.onnx').readAsBytesSync();
final session = runtime.createSession(modelBytes);

// 3. Build input tensors and run inference.
final inputIds = OnnxTensor.fromInt64(
  [1, 512],
  Int64List.fromList(List.filled(512, 0)),
);
final outputs = session.run(
  inputs: {'input_ids': inputIds},
  outputNames: ['last_hidden_state'],
);

// 4. Read the output.
final embeddings = outputs.first.asFloat32();

// 5. Clean up.
session.dispose();
runtime.dispose();
```

### Creating a session from a file path

```dart
final session = runtime.createSessionFromFile(
  '/path/to/model.onnx',
  options: const SessionOptions(intraOpNumThreads: 2),
);
```

### Downloading a model

```dart
const myModel = ModelSpec(
  id: 'my-model-v1',
  files: {
    'onnx': ModelFile(
      url: Uri.parse('https://example.com/model.onnx'),
      sha256: 'abc123…',
    ),
  },
);

final downloader = ModelDownloader();
final resolved = await downloader.ensure(
  myModel,
  cacheDir: '/path/to/cache',
  onProgress: (received, total) => print('$received / $total'),
);

final onnxPath = resolved.filePaths['onnx']!;
```

### Restricting downloads with an allowlist

```dart
class MyCatalog implements AllowlistProvider {
  static const _permitted = {'my-model-v1', 'other-model-v2'};

  @override
  bool isAllowed(ModelSpec spec) => _permitted.contains(spec.id);
}

final downloader = ModelDownloader(allowlist: MyCatalog());
```

## Thread safety

`OnnxSession` is **thread-affine**: all calls to `run` and `dispose` must
come from the same Dart isolate that created the session. If you need
isolate-based parallelism, create a fresh `OnnxRuntime` (and therefore a
fresh ORT environment) inside each isolate.

## Additional information

- [ONNX Runtime](https://onnxruntime.ai) — the underlying inference engine
- [Source repository](https://github.com/bettongia/onnxrt)

Licensed under the [Apache License, Version 2.0](LICENSE).
