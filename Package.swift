// swift-tools-version: 6.2
//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let releaseVersion = ProcessInfo.processInfo.environment["RELEASE_VERSION"] ?? "0.0.0"
let gitCommit = ProcessInfo.processInfo.environment["GIT_COMMIT"] ?? "unspecified"
let builderShimVersion = "0.7.0"
let scVersion = "0.24.5"

let package = Package(
    name: "container",
    platforms: [.macOS("15")],
    products: [
        .library(name: "ContainerCommands", targets: ["ContainerCommands"]),
        .library(name: "ContainerBuild", targets: ["ContainerBuild"]),
        .library(name: "ContainerAPIService", targets: ["ContainerAPIService"]),
        .library(name: "ContainerAPIClient", targets: ["ContainerAPIClient"]),
        .library(name: "ContainerImagesService", targets: ["ContainerImagesService", "ContainerImagesServiceClient"]),
        .library(name: "ContainerNetworkService", targets: ["ContainerNetworkService", "ContainerNetworkServiceClient"]),
        .library(name: "ContainerSandboxService", targets: ["ContainerSandboxService", "ContainerSandboxServiceClient"]),
        .library(name: "ContainerResource", targets: ["ContainerResource"]),
        .library(name: "ContainerLog", targets: ["ContainerLog"]),
        .library(name: "ContainerPersistence", targets: ["ContainerPersistence"]),
        .library(name: "ContainerPlugin", targets: ["ContainerPlugin"]),
        .library(name: "ContainerVersion", targets: ["ContainerVersion"]),
        .library(name: "ContainerXPC", targets: ["ContainerXPC"]),
        .library(name: "SocketForwarder", targets: ["SocketForwarder"]),
        .library(name: "TerminalProgress", targets: ["TerminalProgress"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.2.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.26.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.29.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.1.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.20.1"),
        .package(url: "https://github.com/orlandos-nl/DNSClient.git", from: "2.4.1"),
        .package(url: "https://github.com/Bouke/DNS.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: scVersion)),
    ],
    targets: [
        .executableTarget(
            name: "container",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ContainerAPIClient",
                "ContainerCommands",
            ],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerBuild",
                "ContainerResource",
            ],
            path: "Tests/CLITests"
        ),
        .target(
            name: "ContainerCommands",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerBuild",
                "ContainerAPIClient",
                "ContainerLog",
                "ContainerNetworkService",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerVersion",
                "TerminalProgress",
            ],
            path: "Sources/ContainerCommands"
        ),
        .target(
            name: "ContainerBuild",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ContainerAPIClient",
            ]
        ),
        .testTarget(
            name: "ContainerBuildTests",
            dependencies: [
                "ContainerBuild"
            ]
        ),
        .executableTarget(
            name: "container-apiserver",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Logging", package: "swift-log"),
                "ContainerAPIService",
                "ContainerAPIClient",
                "ContainerLog",
                "ContainerNetworkService",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerVersion",
                "ContainerXPC",
                "DNSServer",
            ],
            path: "Sources/Helpers/APIServer"
        ),
        .target(
            name: "ContainerAPIService",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                "CVersion",
                "ContainerAPIClient",
                "ContainerNetworkServiceClient",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerSandboxServiceClient",
                "ContainerVersion",
                "ContainerXPC",
                "TerminalProgress",
            ],
            path: "Sources/Services/ContainerAPIService/Server"
        ),
        .target(
            name: "ContainerAPIClient",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerImagesServiceClient",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerXPC",
                "TerminalProgress",
            ],
            path: "Sources/Services/ContainerAPIService/Client"
        ),
        .testTarget(
            name: "ContainerAPIClientTests",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                "ContainerAPIClient",
                "ContainerPersistence",
            ]
        ),
        .executableTarget(
            name: "container-core-images",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                "ContainerImagesService",
                "ContainerLog",
                "ContainerPlugin",
                "ContainerVersion",
                "ContainerXPC",
            ],
            path: "Sources/Helpers/Images"
        ),
        .target(
            name: "ContainerImagesService",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerAPIClient",
                "ContainerImagesServiceClient",
                "ContainerLog",
                "ContainerPersistence",
                "ContainerResource",
                "ContainerXPC",
                "TerminalProgress",
            ],
            path: "Sources/Services/ContainerImagesService/Server"
        ),
        .target(
            name: "ContainerImagesServiceClient",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                "ContainerXPC",
                "ContainerLog",
            ],
            path: "Sources/Services/ContainerImagesService/Client"
        ),
        .executableTarget(
            name: "container-network-vmnet",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationIO", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerLog",
                "ContainerNetworkService",
                "ContainerNetworkServiceClient",
                "ContainerResource",
                "ContainerVersion",
                "ContainerXPC",
            ],
            path: "Sources/Helpers/NetworkVmnet"
        ),
        .target(
            name: "ContainerNetworkService",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerNetworkServiceClient",
                "ContainerPersistence",
                "ContainerResource",
                "ContainerXPC",
            ],
            path: "Sources/Services/ContainerNetworkService/Server"
        ),
        .testTarget(
            name: "ContainerNetworkServiceTests",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerNetworkService",
            ]
        ),
        .target(
            name: "ContainerNetworkServiceClient",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                "ContainerLog",
                "ContainerResource",
                "ContainerXPC",
            ],
            path: "Sources/Services/ContainerNetworkService/Client"
        ),
        .executableTarget(
            name: "container-runtime-linux",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Containerization", package: "containerization"),
                "ContainerLog",
                "ContainerResource",
                "ContainerSandboxService",
                "ContainerSandboxServiceClient",
                "ContainerVersion",
                "ContainerXPC",
            ],
            path: "Sources/Helpers/RuntimeLinux"
        ),
        .target(
            name: "ContainerSandboxService",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ContainerAPIClient",
                "ContainerNetworkServiceClient",
                "ContainerPersistence",
                "ContainerResource",
                "ContainerSandboxServiceClient",
                "ContainerXPC",
                "SocketForwarder",
            ],
            path: "Sources/Services/ContainerSandboxService/Server"
        ),
        .target(
            name: "ContainerSandboxServiceClient",
            dependencies: [
                "ContainerResource",
                "ContainerXPC",
            ],
            path: "Sources/Services/ContainerSandboxService/Client"
        ),
        .target(
            name: "ContainerResource",
            dependencies: [
                .product(name: "Containerization", package: "containerization")
            ]
        ),
        .testTarget(
            name: "ContainerResourceTests",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerResource",
            ]
        ),
        .target(
            name: "ContainerLog",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "ContainerPersistence",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                "CVersion",
                "ContainerVersion",
            ]
        ),
        .target(
            name: "ContainerPlugin",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerVersion",
            ]
        ),
        .testTarget(
            name: "ContainerPluginTests",
            dependencies: [
                "ContainerPlugin"
            ]
        ),
        .target(
            name: "ContainerXPC",
            dependencies: [
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                "CAuditToken",
            ]
        ),
        .target(
            name: "TerminalProgress",
            dependencies: [
                .product(name: "ContainerizationOS", package: "containerization")
            ]
        ),
        .testTarget(
            name: "TerminalProgressTests",
            dependencies: ["TerminalProgress"]
        ),
        .target(
            name: "DNSServer",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "DNSClient", package: "DNSClient"),
                .product(name: "DNS", package: "DNS"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "DNSServerTests",
            dependencies: [
                .product(name: "DNS", package: "DNS"),
                "DNSServer",
            ]
        ),
        .target(
            name: "SocketForwarder",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "SocketForwarderTests",
            dependencies: ["SocketForwarder"]
        ),
        .target(
            name: "ContainerVersion",
            dependencies: [
                "CVersion"
            ],
        ),
        .target(
            name: "CVersion",
            dependencies: [],
            publicHeadersPath: "include",
            cSettings: [
                .define("CZ_VERSION", to: "\"\(scVersion)\""),
                .define("GIT_COMMIT", to: "\"\(gitCommit)\""),
                .define("RELEASE_VERSION", to: "\"\(releaseVersion)\""),
                .define("BUILDER_SHIM_VERSION", to: "\"\(builderShimVersion)\""),
            ],
        ),
        .target(
            name: "CAuditToken",
            dependencies: [],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("bsm")
            ]
        ),
    ]
)
