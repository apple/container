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

import Foundation
import Testing

@Suite(.serialized)
struct TestCLIBuilderEnvOnlySerial {
    @Test func testBuildEnvironmentOnlyImageFromScratch() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile =
                    """
                    FROM scratch
                    ARG BUILD_DATE
                    ARG VERSION=1.0.0
                    ENV TERM=xterm \\
                        BUILD_DATE=${BUILD_DATE} \\
                        APP_VERSION=${VERSION} \\
                        PATH=/usr/local/bin:/usr/bin:/bin
                    LABEL maintainer="test@example.com" version="${VERSION}"
                    """
                try f.createContext(dir: dir, dockerfile: dockerfile)
                let imageName = "test-env-only:\(UUID().uuidString)"
                try f.build(tag: imageName, contextDir: dir, buildArgs: ["BUILD_DATE=2025-01-01", "VERSION=2.0.0"])
                try f.assertImageBuilt(imageName)
            }
        }
    }

    @Test func testBuildEnvironmentOnlyImageFromAlpine() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile =
                    """
                    FROM ghcr.io/linuxcontainers/alpine:3.20
                    ENV APP_NAME=myapp APP_VERSION=1.0.0 APP_ENV=production
                    LABEL maintainer="test@example.com" version="1.0.0"
                    """
                try f.createContext(dir: dir, dockerfile: dockerfile)
                let imageName = "test-alpine-env:\(UUID().uuidString)"
                try f.build(tag: imageName, contextDir: dir)
                try f.assertImageBuilt(imageName)
            }
        }
    }

    @Test func testMultiStageBuildWithEnvOnlyBase() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let baseDir = try f.createTempDir()
                let baseDockerfile =
                    """
                    FROM scratch
                    ARG JOBS=6
                    ARG ARCH=amd64
                    ENV MAKEOPTS="-j${JOBS}" ARCH="${ARCH}" PATH=/usr/local/bin:/usr/bin
                    """
                try f.createContext(dir: baseDir, dockerfile: baseDockerfile)
                let baseImageName = "test-env-base:\(UUID().uuidString)"
                try f.build(tag: baseImageName, contextDir: baseDir, buildArgs: ["JOBS=8", "ARCH=arm64"])
                try f.assertImageBuilt(baseImageName)

                let downstreamDir = try f.createTempDir()
                let downstreamDockerfile =
                    """
                    FROM \(baseImageName)
                    LABEL test="env-inherited"
                    """
                try f.createContext(dir: downstreamDir, dockerfile: downstreamDockerfile)
                let downstreamImageName = "test-env-child:\(UUID().uuidString)"
                try f.build(tag: downstreamImageName, contextDir: downstreamDir)
                try f.assertImageBuilt(downstreamImageName)
            }
        }
    }

    @Test func testComplexArgAndEnvCombinations() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile =
                    """
                    FROM scratch
                    ARG JOBS=6
                    ARG MAXLOAD=7.00
                    ARG ARCH=amd64
                    ARG PROFILE_PATH=23.0/split-usr/no-multilib
                    ARG CHOST=x86_64-pc-linux-gnu
                    ARG CFLAGS=-O2 -pipe
                    ENV JOBS="${JOBS}" MAXLOAD="${MAXLOAD}" \\
                        GENTOO_PROFILE="default/linux/${ARCH}/${PROFILE_PATH}" \\
                        CHOST="${CHOST}" MAKEOPTS="-j${JOBS}" \\
                        CFLAGS="${CFLAGS}" CXXFLAGS="${CFLAGS}"
                    LABEL maintainer="test@example.com"
                    """
                try f.createContext(dir: dir, dockerfile: dockerfile)
                let imageName = "test-complex-env:\(UUID().uuidString)"
                try f.build(tag: imageName, contextDir: dir, buildArgs: ["JOBS=12", "ARCH=arm64"])
                try f.assertImageBuilt(imageName)
            }
        }
    }

    @Test func testLabelOnlyDockerfile() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile =
                    """
                    FROM scratch
                    LABEL maintainer="test@example.com" version="1.0.0" \\
                          description="Test image with only labels" \\
                          org.opencontainers.image.title="Test Image"
                    """
                try f.createContext(dir: dir, dockerfile: dockerfile)
                let imageName = "test-label-only:\(UUID().uuidString)"
                try f.build(tag: imageName, contextDir: dir)
                try f.assertImageBuilt(imageName)
            }
        }
    }
}
