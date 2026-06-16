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

/// Flutter plugin shim that links ORT via SPM on iOS for `betto_onnxrt`.
///
/// This package has no Dart-side API surface. Its sole function is to carry
/// the `ios/Package.swift` SPM dependency on
/// `microsoft/onnxruntime-swift-package-manager` (`onnxruntime-c`), which
/// causes Xcode to statically link the full ORT C API XCFramework into the
/// host app binary when this plugin is included in a Flutter project.
///
/// ## Usage
///
/// In your Flutter app's `pubspec.yaml`:
///
/// ```yaml
/// dependencies:
///   betto_onnxrt: ^0.1.0-dev.1
///   betto_onnxrt_ios: ^0.1.0-dev.1
/// ```
///
/// No `Podfile` changes are required. Flutter picks up the SPM dependency
/// automatically from the plugin's `ios/Package.swift`.
///
/// Once the plugin is in the dependency graph, `OnnxRuntime.load()` from
/// `betto_onnxrt` will successfully resolve ORT C API symbols via
/// `DynamicLibrary.process()` on iOS.
library;
