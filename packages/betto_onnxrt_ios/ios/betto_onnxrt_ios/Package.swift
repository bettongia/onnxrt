// swift-tools-version: 5.9
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
//
// Package.swift for the betto_onnxrt_ios Flutter SPM plugin.
//
// This file must be at ios/<plugin_name>/Package.swift so Flutter's SPM
// tooling (flutter_tools swift_package_manager.dart) can detect and symlink
// it into FlutterGeneratedPluginSwiftPackage.
//
// Dependencies:
// - FlutterFramework: provided by Flutter at a sibling path in the generated
//   Packages directory. Required so `import Flutter` compiles.
// - onnxruntime-swift-package-manager: causes Xcode to statically link the
//   full ORT C API XCFramework into the host app binary.
//
// The `exact:` version pin is stored in version_onnx.json under the "ios"
// platform entry (field "version"). The Makefile `check_ios_version` target
// asserts that these two values stay in sync.
//
// Note: the iOS SPM version (currently 1.24.2) differs from VERSION_ONNX
// (1.22.0) because the microsoft/onnxruntime-swift-package-manager repo has
// no tags between 1.20.0 and 1.24.1. The ORT C API is append-only: requesting
// API version 22 from ORT 1.24.2 returns the same vtable struct as 1.22.x.
import PackageDescription

let package = Package(
    name: "betto_onnxrt_ios",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "betto-onnxrt-ios", targets: ["betto_onnxrt_ios"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            exact: "1.24.2"
        ),
    ],
    targets: [
        .target(
            name: "betto_onnxrt_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(
                    name: "onnxruntime",
                    package: "onnxruntime-swift-package-manager"
                ),
            ]
        ),
    ]
)
