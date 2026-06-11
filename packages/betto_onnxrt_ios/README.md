# betto_onnxrt_ios

iOS companion plugin for [`betto_onnxrt`](https://pub.dev/packages/betto_onnxrt).

`betto_onnxrt` is a pure-Dart package and therefore cannot declare a native
iOS dependency itself. This Flutter plugin exists to bridge that gap: it
declares a Swift Package Manager (SPM) dependency on
[`microsoft/onnxruntime-swift-package-manager`](https://github.com/microsoft/onnxruntime-swift-package-manager),
causing Xcode to statically link the ONNX Runtime XCFramework into the host
app binary. `betto_onnxrt` then resolves ORT symbols at runtime via
`DynamicLibrary.process()`.

Add this package to any Flutter iOS app that uses `betto_onnxrt`. No
CocoaPods or Podfile changes are needed — Flutter's SPM integration handles
everything.

## Installation

Add both packages to your `pubspec.yaml`:

```yaml
dependencies:
  betto_onnxrt: ^0.1.0
  betto_onnxrt_ios: ^0.1.0
```

Requires Flutter **≥ 3.27.0** (SPM plugin support was stabilised in Flutter
3.24; 3.27 is the version betto_onnxrt_ios was developed and tested against).

## How it works

1. Flutter's SPM tooling detects `ios/betto_onnxrt_ios/Package.swift` in this
   plugin and adds it to the generated `FlutterGeneratedPluginSwiftPackage`.
2. Xcode resolves the `onnxruntime` product from
   `onnxruntime-swift-package-manager` (pinned at `exact: "1.24.2"`) and
   statically links the XCFramework into the `Runner` binary.
3. At runtime, `OnnxRuntime.load()` calls `DynamicLibrary.process()` to
   resolve `OrtGetApiBase` from the process image — no `.dylib` is opened.
4. `betto_onnxrt`'s native-assets hook emits no `CodeAsset` on iOS; the ORT
   binary is delivered entirely through this plugin's SPM dependency.

## Version alignment

The SPM tag (`1.24.2`) is intentionally newer than the `betto_onnxrt`
baseline ORT version (`1.22.0`). The
`microsoft/onnxruntime-swift-package-manager` repository has no tags between
`1.20.0` and `1.24.1`, so `1.24.2` is the earliest available SPM release that
satisfies `>= 1.22.0`. The ORT C API is additive: requesting API version 22
from an ORT 1.24.2 binary returns the same vtable struct as 1.22.x.

## License

Apache License, Version 2.0 — see [LICENSE](LICENSE).
