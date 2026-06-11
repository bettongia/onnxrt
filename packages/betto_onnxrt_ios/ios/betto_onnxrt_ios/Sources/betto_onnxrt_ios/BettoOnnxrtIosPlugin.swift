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

import Flutter

/// No-op Flutter plugin class for `betto_onnxrt_ios`.
///
/// This plugin's only purpose is to carry the SPM dependency on
/// `onnxruntime-c` (from `microsoft/onnxruntime-swift-package-manager`),
/// which causes Xcode to statically link the full ORT C API XCFramework into
/// the host app binary. There is no method channel, no event channel, and no
/// platform interaction beyond registration.
///
/// `OnnxRuntime.load()` in `betto_onnxrt` calls `DynamicLibrary.process()` on
/// iOS, which resolves ORT C API symbols from the process image after the
/// static link.
public class BettoOnnxrtIosPlugin: NSObject, FlutterPlugin {
    /// Registers this plugin with the Flutter engine.
    ///
    /// This is a no-op — no channels are set up. The registration call itself
    /// is required by the Flutter plugin protocol and is invoked automatically
    /// by the generated plugin registrant in the host app.
    public static func register(with registrar: FlutterPluginRegistrar) {}
}
