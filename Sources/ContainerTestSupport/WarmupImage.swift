//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

import ContainerPersistence
import SystemPackage

/// Images preloaded by the ``ImageWarmup`` suite before concurrent tests run.
/// Add new commonly-used images here; the warmup pass pulls them in parallel.
public enum WarmupImage: String, CaseIterable, Sendable {
    case alpine320 = "ghcr.io/linuxcontainers/alpine:3.20"
    case alpine318 = "ghcr.io/linuxcontainers/alpine:3.18"
    case busybox136 = "ghcr.io/containerd/busybox:1.36"
    case kindestNodeV1_35_5 = "docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"

    /// Directory under app-root holding OCI tar archives of each warmup image.
    ///
    /// Living under app-root (rather than a scratch dir tied to a single
    /// fixture) means the cache survives across the warmup/concurrent/serial
    /// `swift test` invocations, which run as separate processes, and rides
    /// along whatever process clears app-root between full test runs — no
    /// dedicated cleanup needed.
    public static var cacheDirectory: FilePath {
        PathUtils.BaseConfigPath.appRoot.basePath().appending("test-image-cache")
    }

    /// Path to this image's cached OCI tar archive.
    public var cacheTarPath: FilePath {
        Self.cacheDirectory.appending("\(self).tar")
    }
}
