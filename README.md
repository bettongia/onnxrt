# betto_onnxrt

ONNX Runtime for Dart and Flutter — binary delivery via the native-assets build
hook, a generalised inference API, and model-download infrastructure.

Wraps [ONNX Runtime](https://onnxruntime.ai) v1.22.0. Targets macOS, Linux,
Windows, Android, and iOS. Web is excluded (no FFI in the browser).

---

## Packages

| Package                                          | Directory                    | Description                                                       |
| ------------------------------------------------ | ---------------------------- | ----------------------------------------------------------------- |
| [`betto_onnxrt`](packages/betto_onnxrt/)         | `packages/betto_onnxrt/`     | Pure-Dart library — build hook, FFI session API, model downloader |
| [`betto_onnxrt_ios`](packages/betto_onnxrt_ios/) | `packages/betto_onnxrt_ios/` | Flutter plugin SPM shim for iOS — statically links ORT via Xcode  |

`betto_onnxrt` has no Flutter dependency and works in CLI, server, and Flutter
contexts. Add `betto_onnxrt_ios` as an additional dependency only when targeting
iOS.

---

## Documentation

| Document                             | Description                                                        |
| ------------------------------------ | ------------------------------------------------------------------ |
| [Specification](docs/spec/README.md) | Public API contract, platform support, architecture, thread safety |
| [Roadmap](docs/roadmap/v0.md)        | v0 development goals and completion status                         |
| [Plans](docs/plans/)                 | Implementation plans (open, in-progress, and completed)            |
| [Releasing](docs/releasing.md)       | Release process and pub.dev publication checklist                  |

---

## Quick start

Add to `pubspec.yaml`:

```yaml
dependencies:
  betto_onnxrt: ^0.1.0-dev.1
  betto_onnxrt_ios: ^0.1.0-dev.1 # Flutter + iOS targets only
```

Run `dart pub get` (or `flutter pub get`). The native-assets build hook
downloads and verifies the ORT binary for your target platform automatically —
no manual binary management needed.

```dart
import 'package:betto_onnxrt/betto_onnxrt.dart';

final runtime = OnnxRuntime.load();
final session = runtime.createSession('/path/to/model.onnx');
final outputs = session.run({'input': inputTensor});
session.dispose();
```

See the [specification](docs/spec/README.md) for the full API and the
[example](example/) directory for a working command-line sample.

---

## Development

All build, test, and quality targets are available from the repo root via
`make`. The Makefile composes per-package `.mk` fragments.

```bash
make              # full quality gate (format, analyze, test, coverage, doc)
make pre_commit   # subset run before committing
make test         # unit tests
make macos_test   # on-device integration tests (macOS)
make ios_test     # iOS simulator integration tests
make android_test # Android emulator integration tests
```

See [CLAUDE.md](CLAUDE.md) for the full command reference and architectural
notes aimed at AI-assisted development.

---

## Status

Pre-release (`0.1.0-dev.1`).

See the [v0 roadmap](docs/roadmap/v0.md) for remaining work before the first
stable release.

---

## License

Apache 2.0. See [LICENSE](packages/betto_onnxrt/LICENSE).
