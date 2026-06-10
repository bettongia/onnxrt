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

// swift-tools-version: 5.9
// Package.swift for the betto_onnxrt_ios Flutter SPM plugin.
//
// This file declares an SPM dependency on
// microsoft/onnxruntime-swift-package-manager (product: onnxruntime-c), which
// causes Xcode to statically link the full ORT C API XCFramework into the host
// app binary when the plugin is included in a Flutter project.
//
// The `from:` version pin must match VERSION_ONNX in the betto_onnxrt repo
// root (without the leading "v"). The Makefile `check_ios_version` target
// asserts that these two values stay in sync.
import PackageDescription

let package = Package(
    name: "betto_onnxrt_ios",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "betto-onnxrt-ios", targets: ["betto_onnxrt_ios"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            from: "1.22.0"
        ),
    ],
    targets: [
        .target(
            name: "betto_onnxrt_ios",
            dependencies: [
                .product(
                    name: "onnxruntime-c",
                    package: "onnxruntime-swift-package-manager"
                ),
            ],
            path: "Classes"
        ),
    ]
)
