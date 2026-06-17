# Changelog

## 0.1.0-dev.2

## 0.1.0-dev.1

Initial development release.

- Native-assets build hook (`hook/build.dart`) that downloads and stages the
  ONNX Runtime prebuilt binary (v1.22.0) for macOS, Linux, Windows, Android, and
  iOS.
- `OnnxRuntime` — opens the staged ORT library and initialises the `OrtApi`
  vtable.
- `OnnxSession` — generalised FFI inference session supporting arbitrary named
  inputs and outputs; exposes output tensor shape and element type.
- `OnnxTensor` — typed multi-dimensional array with named factories for
  `float32`, `float64`, `int32`, `int64`, and `uint8` element types.
- `SessionOptions` — thread-pool sizing for intra-op and inter-op parallelism.
- `ModelDownloader` — SHA-256 verified, crash-safe download of ONNX model files
  described by a `ModelSpec`.
- `AllowlistProvider` — interface for gating which models `ModelDownloader` is
  permitted to fetch.
- Added `example/magika/` — a standalone Dart CLI tool that detects file types
  using Google's Magika v3.3 ONNX model. Demonstrates end-to-end use of
  `OnnxRuntime`, `OnnxSession`, and `ModelDownloader` with a real-world model.
  Output mirrors the Python Magika `--json` format. Run with
  `dart run bin/magika.dart <file>` or compile with `dart build cli` from inside
  `example/magika/`.
