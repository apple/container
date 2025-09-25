// swift-tools-version: 6.2
//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "container-compose",
    platforms: [.macOS("15")],
    products: [
        .executable(name: "compose", targets: ["ComposePlugin"]),
        .executable(name: "compose-debug", targets: ["ComposeDebug"])
    ],
    dependencies: [
        .package(name: "container", path: "../.."), // Main container package
        .package(url: "https://github.com/apple/containerization.git", exact: "0.8.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ComposePlugin",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerClient", package: "container"),
                .product(name: "ContainerLog", package: "container"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerBuild", package: "container"),
                "ComposeCore",
            ],
            path: "Sources/CLI"
        ),
        .target(
            name: "ComposeCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ContainerClient", package: "container"),
                .product(name: "ContainerCommands", package: "container"),
            ],
            path: "Sources/Core"
        ),
        .executableTarget(
            name: "ComposeDebug",
            dependencies: [
                "ComposeCore",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Debug"
        ),
        .testTarget(
            name: "ComposeTests",
            dependencies: [
                "ComposeCore",
                "ComposePlugin",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/ComposeTests"
        ),
    ]
)
