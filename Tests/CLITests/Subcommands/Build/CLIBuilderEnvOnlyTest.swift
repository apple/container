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

import Foundation
import Testing

extension TestCLIBuildBase {
    class CLIBuilderEnvOnlyTest: TestCLIBuildBase {
        override init() throws {
            try super.init()
        }

        deinit {
            try? builderDelete(force: true)
        }

        @Test func testBuildEnvironmentOnlyImageFromScratch() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM scratch

                ARG BUILD_DATE
                ARG VERSION=1.0.0

                ENV TERM=xterm \\
                    BUILD_DATE=${BUILD_DATE} \\
                    APP_VERSION=${VERSION} \\
                    PATH=/usr/local/bin:/usr/bin:/bin

                LABEL maintainer="test@example.com" \\
                      version="${VERSION}"
                """

            try createContext(tempDir: tempDir, dockerfile: dockerfile)
            let imageName = "test-env-only:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir, buildArgs: ["BUILD_DATE=2025-01-01", "VERSION=2.0.0"])
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildEnvironmentOnlyImageFromAlpine() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20

                ENV APP_NAME=myapp \\
                    APP_VERSION=1.0.0 \\
                    APP_ENV=production

                LABEL maintainer="test@example.com" \\
                      version="1.0.0" \\
                      description="Test environment-only image"
                """

            try createContext(tempDir: tempDir, dockerfile: dockerfile)
            let imageName = "test-alpine-env:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testMultiStageBuildWithEnvOnlyBase() throws {
            let tempDir: URL = try createTempDir()
            let baseImageName = "test-env-base:\(UUID().uuidString)"

            // First, create an environment-only base image
            let baseDockerfile =
                """
                FROM scratch

                ARG JOBS=6
                ARG ARCH=amd64

                ENV MAKEOPTS="-j${JOBS}" \\
                    ARCH="${ARCH}" \\
                    PATH=/usr/local/bin:/usr/bin
                """

            try createContext(tempDir: tempDir, dockerfile: baseDockerfile)
            try self.build(tag: baseImageName, tempDir: tempDir, buildArgs: ["JOBS=8", "ARCH=arm64"])
            #expect(try self.inspectImage(baseImageName) == baseImageName, "expected base image to build successfully")

            // Now create a downstream image that uses it
            let downstreamTempDir: URL = try createTempDir()
            let downstreamDockerfile =
                """
                FROM \(baseImageName)

                # Verify environment is inherited - note: can't use RUN with scratch base
                LABEL test="env-inherited"
                """

            try createContext(tempDir: downstreamTempDir, dockerfile: downstreamDockerfile)
            let downstreamImageName = "test-env-child:\(UUID().uuidString)"
            try self.build(tag: downstreamImageName, tempDir: downstreamTempDir)
            #expect(
                try self.inspectImage(downstreamImageName) == downstreamImageName,
                "expected downstream image to build successfully"
            )
        }

        @Test func testComplexArgAndEnvCombinations() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM scratch

                ARG JOBS=6
                ARG MAXLOAD=7.00
                ARG ARCH=amd64
                ARG PROFILE_PATH=23.0/split-usr/no-multilib
                ARG CHOST=x86_64-pc-linux-gnu
                ARG CFLAGS=-O2 -pipe

                ENV JOBS="${JOBS}" \\
                    MAXLOAD="${MAXLOAD}" \\
                    GENTOO_PROFILE="default/linux/${ARCH}/${PROFILE_PATH}" \\
                    CHOST="${CHOST}" \\
                    MAKEOPTS="-j${JOBS}" \\
                    CFLAGS="${CFLAGS}" \\
                    CXXFLAGS="${CFLAGS}"

                LABEL maintainer="test@example.com"
                """

            try createContext(tempDir: tempDir, dockerfile: dockerfile)
            let imageName = "test-complex-env:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir, buildArgs: ["JOBS=12", "ARCH=arm64"])
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testLabelOnlyDockerfile() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM scratch

                LABEL maintainer="test@example.com" \\
                      version="1.0.0" \\
                      description="Test image with only labels" \\
                      org.opencontainers.image.title="Test Image"
                """

            try createContext(tempDir: tempDir, dockerfile: dockerfile)
            let imageName = "test-label-only:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }
    }
}
