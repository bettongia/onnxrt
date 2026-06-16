# Changelog

## 0.1.0-dev.1

Initial pre-release of `betto_onnxrt_ios`.

- Flutter plugin shim that statically links the ONNX Runtime XCFramework into
  the host app via the Swift Package Manager (SPM).
- SPM dependency pins `microsoft/onnxruntime-swift-package-manager` at
  `exact: "1.24.2"` — the earliest SPM tag that satisfies the ORT v1.22.0
  baseline used by `betto_onnxrt`.
- Registers `BettoOnnxrtIosPlugin` so that `OnnxRuntime.load()` from
  `betto_onnxrt` can resolve ORT C API symbols via `DynamicLibrary.process()`
  on iOS.
