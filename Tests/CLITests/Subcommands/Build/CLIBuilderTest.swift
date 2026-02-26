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

import ContainerizationOCI
import Foundation
import Testing

extension TestCLIBuildBase {
    class CLIBuilderTest: TestCLIBuildBase {
        override init() throws {
            try super.init()
        }

        deinit {
            try? builderDelete(force: true)
        }

        @Test func testBuildDotFileSucceeds() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch

                ADD emptyFile /
                """
            let context: [FileSystemEntry] = [
                .file("emptyFile", content: .zeroFilled(size: 1)),
                .file(".dockerignore", content: .data(".dockerignore\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName = "registry.local/dot-file:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildFromPreviousStage() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20 AS layer1
                RUN sh -c "echo 'layer1' > /layer1.txt"

                FROM layer1
                CMD ["cat", "/layer1.txt"]
                """

            try createContext(tempDir: tempDir, dockerfile: dockerfile)
            let imageName = "registry.local/from-previous-layer:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully build \(imageName)")
        }

        @Test func testBuildFromLocalImage() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch

                ADD emptyFile /
                """
            let context: [FileSystemEntry] = [
                .file("emptyFile", content: .zeroFilled(size: 0)),
                .file(".dockerignore", content: .data(".dockerignore\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName = "local-only:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")

            let newTempDir: URL = try createTempDir()
            let newDockerfile: String =
                """
                 FROM \(imageName)
                """
            let newContext: [FileSystemEntry] = []
            try createContext(tempDir: newTempDir, dockerfile: newDockerfile, context: newContext)
            let newImageName = "from-local:\(UUID().uuidString)"
            try self.build(tag: newImageName, tempDir: newTempDir)
            #expect(try self.inspectImage(newImageName) == newImageName, "expected to have successfully built \(newImageName)")
        }

        @Test func testBuildAddFromSpecialDirs() throws {
            let tempDir = URL(filePath: "/tmp/container/.clitests" + testUUID)
            try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            defer {
                try! FileManager.default.removeItem(at: tempDir)
            }

            let dockerfile: String =
                """
                FROM scratch

                ADD emptyFile /
                """
            let context: [FileSystemEntry] = [.file("emptyFile", content: .zeroFilled(size: 1))]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName = "registry.local/scratch-add-special-dir:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildScratchAdd() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch

                ADD emptyFile /
                """
            let context: [FileSystemEntry] = [.file("emptyFile", content: .zeroFilled(size: 1))]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName = "registry.local/scratch-add:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildAddAll() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20

                ADD . .

                RUN cat emptyFile 
                RUN cat Test/testempty
                """
            let context: [FileSystemEntry] = [
                .directory("Test"),
                .file("Test/testempty", content: .zeroFilled(size: 1)),
                .file("emptyFile", content: .zeroFilled(size: 1)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName: String = "registry.local/add-all:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildArg() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                ARG TAG=unknown 
                FROM ghcr.io/linuxcontainers/alpine:${TAG} 
                """
            try createContext(tempDir: tempDir, dockerfile: dockerfile)
            let imageName: String = "registry.local/build-arg:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir, buildArgs: ["TAG=3.20"])
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildNetworkAccess() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                ARG ADDRESS
                RUN nc -zv ${ADDRESS%:*} ${ADDRESS##*:} || exit 1
                """
            try createContext(tempDir: tempDir, dockerfile: dockerfile)
            let imageName = "registry.local/build-network-access:\(UUID().uuidString)"

            let proxyEnv = ProcessInfo.processInfo.environment["HTTP_PROXY"]
            var address = "8.8.8.8:53"
            if let proxyAddr = proxyEnv {
                address = String(proxyAddr.trimmingPrefix("http://"))
            }
            try self.build(tag: imageName, tempDir: tempDir, buildArgs: ["ADDRESS=\(address)"])
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildDockerfileKeywords() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                # stage 1 Meta ARG
                ARG TAG=3.20
                FROM ghcr.io/linuxcontainers/alpine:${TAG}

                # stage 2 RUN 
                FROM ghcr.io/linuxcontainers/alpine:3.20
                RUN echo "Hello, World!" > /hello.txt

                # stage 3 - RUN []
                FROM ghcr.io/linuxcontainers/alpine:3.20
                RUN ["sh", "-c", "echo 'Exec form' > /exec.txt"]

                # stage 4 - CMD 
                FROM ghcr.io/linuxcontainers/alpine:3.20        
                CMD ["echo", "Exec default"]

                # stage 5 - CMD []
                FROM ghcr.io/linuxcontainers/alpine:3.20
                CMD ["echo", "Exec'ing"]

                #stage 6 - LABEL
                FROM ghcr.io/linuxcontainers/alpine:3.20
                LABEL version="1.0" description="Test image"

                # stage 7 - EXPOSE
                FROM ghcr.io/linuxcontainers/alpine:3.20
                EXPOSE 8080

                # stage 8 - ENV
                FROM ghcr.io/linuxcontainers/alpine:3.20
                ENV MY_ENV=hello
                RUN echo $MY_ENV > /env.txt

                # stage 9 - ADD
                FROM ghcr.io/linuxcontainers/alpine:3.20
                ADD emptyFile /

                # stage 10 - COPY
                FROM ghcr.io/linuxcontainers/alpine:3.20
                COPY toCopy /toCopy

                # stage 11 - ENTRYPOINT
                FROM ghcr.io/linuxcontainers/alpine:3.20
                ENTRYPOINT ["echo", "entrypoint!"]

                # stage 12 - VOLUME
                FROM ghcr.io/linuxcontainers/alpine:3.20
                VOLUME /data

                # stage 13 - USER
                FROM ghcr.io/linuxcontainers/alpine:3.20
                RUN adduser -D myuser
                USER myuser
                CMD whoami

                # stage 14 - WORKDIR
                FROM ghcr.io/linuxcontainers/alpine:3.20
                WORKDIR /app
                RUN pwd > /pwd.out

                # stage 15 - ARG
                FROM ghcr.io/linuxcontainers/alpine:3.20
                ARG MY_VAR=default
                RUN echo $MY_VAR > /var.out

                # stage 16 - ONBUILD
                # FROM ghcr.io/linuxcontainers/alpine:3.20
                # ONBUILD RUN echo "onbuild triggered" > /onbuild.out

                # stage 17 - STOPSIGNAL
                # FROM ghcr.io/linuxcontainers/alpine:3.20
                # STOPSIGNAL SIGTERM

                # stage 18 - HEALTHCHECK
                # FROM ghcr.io/linuxcontainers/alpine:3.20
                # HEALTHCHECK CMD echo "healthy" || exit 1

                # stage 19 - SHELL
                # FROM ghcr.io/linuxcontainers/alpine:3.20
                # SHELL ["/bin/sh", "-c"]
                # RUN echo $0 > /shell.txt
                """

            let context: [FileSystemEntry] = [
                .file("emptyFile", content: .zeroFilled(size: 1)),
                .file("toCopy", content: .zeroFilled(size: 1)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let imageName = "registry.local/dockerfile-keywords:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildSymlink() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                # Test 1: Test basic symlinking
                FROM ghcr.io/linuxcontainers/alpine:3.20

                ADD Test1Source Test1Source
                ADD Test1Source2 Test1Source2

                RUN cat Test1Source2/test.yaml 

                # Test2: Test symlinks in nested directories 
                FROM ghcr.io/linuxcontainers/alpine:3.20

                ADD Test2Source Test2Source
                ADD Test2Source2 Test2Source2

                RUN cat Test2Source2/Test/test.txt

                # Test 3: Test symlinks to directories work 
                FROM ghcr.io/linuxcontainers/alpine:3.20

                ADD Test3Source Test3Source
                ADD Test3Source2 Test3Source2

                RUN cat Test3Source2/Dest/test.txt
                """
            let context: [FileSystemEntry] = [
                // test 1
                .directory("Test1Source"),
                .directory("Test1Source2"),
                .file("Test1Source/test.yaml", content: .zeroFilled(size: 1)),
                .symbolicLink("Test1Source2/test.yaml", target: "Test1Source/test.yaml"),

                // test 2
                .directory("Test2Source"),
                .directory("Test2Source2"),
                .file("Test2Source/Test/Test/test.yaml", content: .zeroFilled(size: 1)),
                .symbolicLink("Test2Source2/Test/test.yaml", target: "Test2Source/Test/Test/test.yaml"),

                // test 3
                .directory("Test3Source/Source"),
                .directory("Test3Source2"),
                .file("Test3Source/Source/test.txt", content: .zeroFilled(size: 1)),
                .symbolicLink("Test3Source2/Dest", target: "Test3Source/Source"),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName = "registry.local/build-symlinks:\(UUID().uuidString)"

            #expect(throws: Never.self) {
                try self.build(tag: imageName, tempDir: tempDir)
            }
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildAndRun() throws {
            let name: String = "test-build-and-run"

            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                RUN echo "foobar" > /file
                """
            let context: [FileSystemEntry] = []
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName = "\(name):latest"
            let containerName = "\(name)-container"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
            // Check if the image we built is actually in the image store, and can be used.
            try self.doLongRun(name: containerName, image: imageName)
            defer {
                try? self.doStop(name: containerName)
            }
            var output = try doExec(name: containerName, cmd: ["cat", "/file"])
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = "foobar"
            try self.doStop(name: containerName)
            #expect(output == expected, "expected file contents to be \(expected), instead got \(output)")
        }

        @Test func testBuildDifferentPaths() throws {
            let buildContextDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20

                RUN ls ./
                COPY . /root

                RUN cat /root/Test/test.txt
                """
            let buildContext: [FileSystemEntry] = [
                .directory(".git"),
                .file(".git/FETCH", content: .zeroFilled(size: 1)),
                .directory("Test"),
                .file("Test/test.txt", content: .zeroFilled(size: 1)),
            ]
            try createContext(tempDir: buildContextDir, dockerfile: dockerfile, context: buildContext)

            let imageName = "registry.local/build-diff-context:\(UUID().uuidString)"
            #expect(throws: Never.self) {
                try self.build(tags: [imageName], tempDir: buildContextDir)
            }
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildMultiArch() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20

                ADD . .

                RUN cat emptyFile 
                RUN cat Test/testempty
                """
            let context: [FileSystemEntry] = [
                .directory("Test"),
                .file("Test/testempty", content: .zeroFilled(size: 1)),
                .file("emptyFile", content: .zeroFilled(size: 1)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName: String = "registry.local/multi-arch:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir, otherArgs: ["--arch", "amd64,arm64"])
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")

            let output = try doInspectImages(image: imageName)
            #expect(output.count == 1, "expected a single image inspect output, got \(output)")

            let expected = Set([
                Platform(arch: "amd64", os: "linux", variant: nil),
                Platform(arch: "arm64", os: "linux", variant: nil),
            ])
            let actual = Set(
                output[0].variants.map { v in
                    Platform(arch: v.platform.architecture, os: v.platform.os, variant: nil)
                })
            #expect(
                actual == expected,
                "expected platforms \(expected), got \(actual)"
            )
        }

        @Test func testBuildMultipleTags() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile: String =
                """
                FROM scratch

                ADD emptyFile /
                """
            let context: [FileSystemEntry] = [.file("emptyFile", content: .zeroFilled(size: 1))]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let uuid = UUID().uuidString
            let tag1 = "registry.local/multi-tag-test:\(uuid)"
            let tag2 = "registry.local/multi-tag-test:latest"
            let tag3 = "registry.local/multi-tag-test:v1.0.0"

            try self.build(tags: [tag1, tag2, tag3], tempDir: tempDir)

            // Verify all three tags exist and point to the same image
            #expect(try self.inspectImage(tag1) == tag1, "expected to have successfully built \(tag1)")
            #expect(try self.inspectImage(tag2) == tag2, "expected to have successfully built \(tag2)")
            #expect(try self.inspectImage(tag3) == tag3, "expected to have successfully built \(tag3)")
        }

        @Test func testBuildAfterContextChange() throws {
            let name = "test-build-context-change"
            let tempDir: URL = try createTempDir()

            // Create initial context with file "foo" containing "initial"
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                COPY foo /foo
                COPY bar /bar
                """
            let initialContent = "initial".data(using: .utf8)!
            let context: [FileSystemEntry] = [
                .file("foo", content: .data(Data((0..<4 * 1024 * 1024).map { UInt8($0 % 256) }))),
                .file("bar", content: .data(initialContent)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            // Build first image
            let imageName1 = "\(name):v1"
            let containerName1 = "\(name)-container-v1"
            try self.build(tag: imageName1, tempDir: tempDir)
            #expect(try self.inspectImage(imageName1) == imageName1, "expected to have successfully built \(imageName1)")

            // Run container and verify content is "initial"
            try self.doLongRun(name: containerName1, image: imageName1)
            defer {
                try? self.doStop(name: containerName1)
            }
            var output = try doExec(name: containerName1, cmd: ["cat", "/bar"])
            #expect(output == "initial", "expected file contents to be 'initial', instead got '\(output)'")

            // Update the file "foo" to contain "updated"
            let updatedContent = "updated".data(using: .utf8)!
            let contextDir = tempDir.appendingPathComponent("context")
            let barPath = contextDir.appendingPathComponent("bar")
            try updatedContent.write(to: barPath, options: .atomic)

            // Build second image
            let imageName2 = "\(name):v2"
            let containerName2 = "\(name)-container-v2"
            try self.build(tag: imageName2, tempDir: tempDir)
            #expect(try self.inspectImage(imageName2) == imageName2, "expected to have successfully built \(imageName2)")

            // Run container and verify content is "updated"
            try self.doLongRun(name: containerName2, image: imageName2)
            defer {
                try? self.doStop(name: containerName2)
            }
            output = try doExec(name: containerName2, cmd: ["cat", "/bar"])
            #expect(output == "updated", "expected file contents to be 'updated', instead got '\(output)'")
        }

        @Test func testBuildWithDockerfileFromStdin() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM scratch

                ADD emptyFile /
                """
            let context: [FileSystemEntry] = [.file("emptyFile", content: .zeroFilled(size: 1))]
            try createContext(tempDir: tempDir, dockerfile: "", context: context)
            let imageName = "registry.local/stdin-file:\(UUID().uuidString)"
            try buildWithStdin(tags: [imageName], tempContext: tempDir, dockerfileContents: dockerfile)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testLowercaseDockerfile() throws {
            // Test 1: COPY with uppercase
            let tempDir1: URL = try createTempDir()
            let dockerfile1 =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                COPY . /app
                RUN test -f /app/testfile.txt
                """
            let context1: [FileSystemEntry] = [
                .file("testfile.txt", content: .data("test".data(using: .utf8)!))
            ]
            try createContext(tempDir: tempDir1, dockerfile: dockerfile1, context: context1)
            let imageName1 = "registry.local/copy-uppercase:\(UUID().uuidString)"
            try self.build(tag: imageName1, tempDir: tempDir1)
            #expect(try self.inspectImage(imageName1) == imageName1, "expected COPY to work")

            // Test 2: copy with lowercase
            let tempDir2: URL = try createTempDir()
            let dockerfile2 =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                copy . /app
                RUN test -f /app/testfile.txt
                """
            let context2: [FileSystemEntry] = [
                .file("testfile.txt", content: .data("test".data(using: .utf8)!))
            ]
            try createContext(tempDir: tempDir2, dockerfile: dockerfile2, context: context2)
            let imageName2 = "registry.local/copy-lowercase:\(UUID().uuidString)"
            try self.build(tag: imageName2, tempDir: tempDir2)
            #expect(try self.inspectImage(imageName2) == imageName2, "expected copy to work")

            // Test 3: ADD with uppercase
            let tempDir3: URL = try createTempDir()
            let dockerfile3 =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                ADD . /app
                RUN test -f /app/testfile.txt
                """
            let context3: [FileSystemEntry] = [
                .file("testfile.txt", content: .data("test".data(using: .utf8)!))
            ]
            try createContext(tempDir: tempDir3, dockerfile: dockerfile3, context: context3)
            let imageName3 = "registry.local/add-uppercase:\(UUID().uuidString)"
            try self.build(tag: imageName3, tempDir: tempDir3)
            #expect(try self.inspectImage(imageName3) == imageName3, "expected ADD to work")

            // Test 4: add with lowercase
            let tempDir4: URL = try createTempDir()
            let dockerfile4 =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                add . /app
                RUN test -f /app/testfile.txt
                """
            let context4: [FileSystemEntry] = [
                .file("testfile.txt", content: .data("test".data(using: .utf8)!))
            ]
            try createContext(tempDir: tempDir4, dockerfile: dockerfile4, context: context4)
            let imageName4 = "registry.local/add-lowercase:\(UUID().uuidString)"
            try self.build(tag: imageName4, tempDir: tempDir4)
            #expect(try self.inspectImage(imageName4) == imageName4, "expected add to work")
        }

        @Test func testRunWithBindMount() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20

                # Use bind mount to access build context during RUN
                RUN --mount=type=bind,source=.,target=/mnt/context \
                    set -e; \
                    echo "Checking files in bind mount..."; \
                    ls -la /mnt/context/; \
                    \
                    echo "Verifying files are accessible in mount..."; \
                    if [ ! -f /mnt/context/app.py ]; then \
                        echo "ERROR: app.py should be in bind mount!"; \
                        exit 1; \
                    fi; \
                    if [ ! -f /mnt/context/config.yaml ]; then \
                        echo "ERROR: config.yaml should be in bind mount!"; \
                        exit 1; \
                    fi; \
                    \
                    echo "RUN --mount bind check passed!"; \
                    cp /mnt/context/app.py /app.py

                RUN cat /app.py
                """

            let context: [FileSystemEntry] = [
                .file("app.py", content: .data("print('Hello from bind mount')".data(using: .utf8)!)),
                .file("config.yaml", content: .data("key: value".data(using: .utf8)!)),
            ]

            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName = "registry.local/bind-mount-test:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        @Test func testBuildDockerIgnore() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20

                # Copy all files - should respect .dockerignore
                COPY . /app

                # Verify specific files are excluded
                RUN set -e; \
                    echo "Checking specific file exclusion..."; \
                    if [ -f /app/secret.txt ]; then \
                        echo "ERROR: secret.txt should be excluded!"; \
                        exit 1; \
                    fi

                # Verify wildcard *.log files are excluded
                RUN set -e; \
                    echo "Checking *.log exclusion..."; \
                    if [ -f /app/debug.log ]; then \
                        echo "ERROR: debug.log should be excluded by *.log pattern!"; \
                        exit 1; \
                    fi; \
                    if ls /app/logs/*.log 2>/dev/null; then \
                        echo "ERROR: logs/*.log files should be excluded!"; \
                        exit 1; \
                    fi

                # Verify exception pattern (!important.log) works
                RUN set -e; \
                    echo "Checking exception pattern..."; \
                    if [ ! -f /app/important.log ]; then \
                        echo "ERROR: important.log should be included (exception with !)"; \
                        exit 1; \
                    fi

                # Verify *.tmp files are excluded
                RUN set -e; \
                    echo "Checking *.tmp exclusion..."; \
                    if find /app -name "*.tmp" | grep .; then \
                        echo "ERROR: .tmp files should be excluded!"; \
                        exit 1; \
                    fi

                # Verify directories are excluded
                RUN set -e; \
                    echo "Checking directory exclusion..."; \
                    if [ -d /app/temp ]; then \
                        echo "ERROR: temp/ directory should be excluded!"; \
                        exit 1; \
                    fi; \
                    if [ -d /app/node_modules ]; then \
                        echo "ERROR: node_modules/ should be excluded!"; \
                        exit 1; \
                    fi

                # Verify included files ARE present
                RUN set -e; \
                    echo "Checking included files..."; \
                    if [ ! -f /app/main.go ]; then \
                        echo "ERROR: main.go should be included!"; \
                        exit 1; \
                    fi; \
                    if [ ! -f /app/README.md ]; then \
                        echo "ERROR: README.md should be included!"; \
                        exit 1; \
                    fi; \
                    if [ ! -f /app/src/app.go ]; then \
                        echo "ERROR: src/app.go should be included!"; \
                        exit 1; \
                    fi; \
                    echo "All .dockerignore checks passed!"
                """

            let dockerignore =
                """
                # Exclude specific files
                secret.txt

                # Exclude all log files
                *.log
                **/*.log

                # But make an exception for important.log
                !important.log

                # Exclude all temporary files
                *.tmp
                **/*.tmp

                # Exclude directories
                temp/
                node_modules/
                """

            let context: [FileSystemEntry] = [
                .file(".dockerignore", content: .data(dockerignore.data(using: .utf8)!)),
                .file("secret.txt", content: .data("secret content".data(using: .utf8)!)),
                .file("debug.log", content: .data("debug log content".data(using: .utf8)!)),
                .file("important.log", content: .data("important log content".data(using: .utf8)!)),
                .file("cache.tmp", content: .data("cache".data(using: .utf8)!)),
                .file("main.go", content: .data("package main".data(using: .utf8)!)),
                .file("README.md", content: .data("# README".data(using: .utf8)!)),
                .directory("temp"),
                .file("temp/cache.tmp", content: .data("temp cache".data(using: .utf8)!)),
                .directory("logs"),
                .file("logs/app.log", content: .data("app log".data(using: .utf8)!)),
                .directory("node_modules"),
                .file("node_modules/package.json", content: .data("{}".data(using: .utf8)!)),
                .directory("src"),
                .file("src/app.go", content: .data("package src".data(using: .utf8)!)),
                .file("src/test.tmp", content: .data("temp".data(using: .utf8)!)),
            ]

            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)
            let imageName = "registry.local/dockerignore-test:\(UUID().uuidString)"
            try self.build(tag: imageName, tempDir: tempDir)
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }

        // Test 1: Basic .dockerignore
        @Test func testDockerIgnoreBasic() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                WORKDIR /app
                COPY . .
                """
            let context: [FileSystemEntry] = [
                .file("Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                .file("included.txt", content: .data("This file should be included in the build context.\n".data(using: .utf8)!)),
                .file("ignored.txt", content: .data("This file should be ignored by .dockerignore.\n".data(using: .utf8)!)),
                .file(".dockerignore", content: .data("ignored.txt\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let contextDir = tempDir.appendingPathComponent("context")
            let dockerfilePath = contextDir.appendingPathComponent("Dockerfile")
            let imageName = "registry.local/dockerignore-basic:\(UUID().uuidString)"
            let args = ["build", "-f", dockerfilePath.path, "-t", imageName, contextDir.path]
            let response = try run(arguments: args)
            if response.status != 0 {
                throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
            }

            let containerName = "dockerignore-basic-\(UUID().uuidString)"
            try self.doLongRun(name: containerName, image: imageName)
            defer { try? self.doStop(name: containerName) }

            let includedResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/included.txt"])
            #expect(includedResult.status == 0, "included.txt should be present in the image")

            let ignoredResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/ignored.txt"])
            #expect(ignoredResult.status != 0, "ignored.txt should NOT be present in the image")
        }

        // Test 2: Dockerfile-specific ignore file (Dockerfile.dockerignore takes precedence over .dockerignore)
        @Test func testDockerIgnoreDockerfileSpecific() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                WORKDIR /app
                COPY . .
                """
            // .dockerignore ignores general.txt; Dockerfile.dockerignore ignores specific.txt.
            // When both exist, Dockerfile.dockerignore takes precedence, so general.txt is included.
            // Dockerfile and its .dockerignore must be co-located; here both live in the context root.
            let context: [FileSystemEntry] = [
                .file("Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                .file(".dockerignore", content: .data("general.txt\n".data(using: .utf8)!)),
                .file("Dockerfile.dockerignore", content: .data("specific.txt\n".data(using: .utf8)!)),
                .file("general.txt", content: .data("This file should be included (Dockerfile.dockerignore takes precedence over .dockerignore).\n".data(using: .utf8)!)),
                .file("specific.txt", content: .data("This file should be ignored by Dockerfile.dockerignore.\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let contextDir = tempDir.appendingPathComponent("context")
            let dockerfilePath = contextDir.appendingPathComponent("Dockerfile")
            let imageName = "registry.local/dockerignore-specific:\(UUID().uuidString)"
            let args = ["build", "-f", dockerfilePath.path, "-t", imageName, contextDir.path]
            let response = try run(arguments: args)
            if response.status != 0 {
                throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
            }

            let containerName = "dockerignore-specific-\(UUID().uuidString)"
            try self.doLongRun(name: containerName, image: imageName)
            defer { try? self.doStop(name: containerName) }

            let specificResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/specific.txt"])
            #expect(specificResult.status != 0, "specific.txt should NOT be present (ignored by Dockerfile.dockerignore)")

            let generalResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/general.txt"])
            #expect(generalResult.status == 0, "general.txt should be present (only in .dockerignore, not Dockerfile.dockerignore)")
        }

        // Test 5: Build succeeds when Dockerfile is listed in .dockerignore
        @Test func testDockerIgnoreIgnoredDockerfile() async throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                WORKDIR /app
                COPY . .
                """
            // Dockerfile is listed in .dockerignore but build must still succeed.
            // Dockerfile lives in the context root so the ignore rule applies to it.
            let context: [FileSystemEntry] = [
                .file("Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                .file(".dockerignore", content: .data("Dockerfile\n.dockerignore\n".data(using: .utf8)!)),
                .file("test.txt", content: .data("This file should be included even though Dockerfile is ignored.\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let contextDir = tempDir.appendingPathComponent("context")
            let dockerfilePath = contextDir.appendingPathComponent("Dockerfile")
            let imageName = "registry.local/dockerignore-ignored-dockerfile:\(UUID().uuidString)"
            let args = ["build", "-f", dockerfilePath.path, "-t", imageName, contextDir.path]
            let response = try run(arguments: args)
            if response.status != 0 {
                throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
            }

            let containerName = "dockerignore-ignored-dockerfile"
            try self.doLongRun(name: containerName, image: imageName)
            defer { try? self.doStop(name: containerName) }

            let dockerfileResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/Dockerfile"])
            #expect(dockerfileResult.status != 0, "Dockerfile should NOT be present in the image")

            let dockerignoreResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/.dockerignore"])
            #expect(dockerignoreResult.status != 0, ".dockerignore should NOT be present in the image")

            let testFileResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/test.txt"])
            #expect(testFileResult.status == 0, "test.txt should be present in the image")
        }

        // Test 8: Dockerfile in nested subdirectory; Dockerfile.dockerignore next to it takes precedence over root .dockerignore
        @Test func testDockerIgnoreSubdirDockerfile() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                WORKDIR /app
                COPY . .
                """
            // Root .dockerignore ignores included.txt; nested Dockerfile.dockerignore ignores secret.txt
            // When Dockerfile is in nested/project/, Dockerfile.dockerignore next to it takes precedence
            let context: [FileSystemEntry] = [
                .file(".dockerignore", content: .data("included.txt\n".data(using: .utf8)!)),
                .file("included.txt", content: .data("This file should be included (Dockerfile.dockerignore takes precedence).\n".data(using: .utf8)!)),
                .file("secret.txt", content: .data("This file should be ignored by Dockerfile.dockerignore.\n".data(using: .utf8)!)),
                .file("nested/secret.txt", content: .data("This file should be ignored by Dockerfile.dockerignore.\n".data(using: .utf8)!)),
                .file("nested/project/Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                .file("nested/project/Dockerfile.dockerignore", content: .data("secret.txt\n".data(using: .utf8)!)),
                .file("nested/project/config.txt", content: .data("This config file should be included.\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let contextDir = tempDir.appendingPathComponent("context")
            let nestedDockerfile = contextDir.appendingPathComponent("nested/project/Dockerfile")
            let imageName = "registry.local/dockerignore-subdir:\(UUID().uuidString)"
            let args = ["build", "-f", nestedDockerfile.path, "-t", imageName, contextDir.path]
            let response = try run(arguments: args)
            if response.status != 0 {
                throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
            }

            let containerName = "dockerignore-subdir-\(UUID().uuidString)"
            try self.doLongRun(name: containerName, image: imageName)
            defer { try? self.doStop(name: containerName) }

            let includedResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/included.txt"])
            #expect(includedResult.status == 0, "included.txt should be present (Dockerfile.dockerignore takes precedence over .dockerignore)")

            let secretResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/secret.txt"])
            #expect(secretResult.status != 0, "secret.txt should NOT be present (ignored by Dockerfile.dockerignore)")

            let nestedSecretResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/nested/secret.txt"])
            #expect(nestedSecretResult.status != 0, "nested/secret.txt should NOT be present (ignored by Dockerfile.dockerignore)")

            let configResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/nested/project/config.txt"])
            #expect(configResult.status == 0, "nested/project/config.txt should be present")
        }

        // Test 9: Custom-named Dockerfile (app1.Dockerfile) uses app1.Dockerfile.dockerignore
        @Test func testDockerIgnoreCustomDockerfileName() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                WORKDIR /app
                COPY . .
                """
            // .dockerignore ignores generic.txt; app1.Dockerfile.dockerignore ignores app1-specific.txt
            // When building with -f app1.Dockerfile, app1.Dockerfile.dockerignore takes precedence
            let context: [FileSystemEntry] = [
                .file("Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                .file(".dockerignore", content: .data("generic.txt\n".data(using: .utf8)!)),
                .file("app1.Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                .file("app1.Dockerfile.dockerignore", content: .data("app1-specific.txt\n".data(using: .utf8)!)),
                .file("app1-specific.txt", content: .data("This file should be ignored by app1.Dockerfile.dockerignore.\n".data(using: .utf8)!)),
                .file("generic.txt", content: .data("This file should be included (only in .dockerignore, not app1.Dockerfile.dockerignore).\n".data(using: .utf8)!)),
                .file("included.txt", content: .data("This file should always be included.\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: "", context: context)

            let contextDir = tempDir.appendingPathComponent("context")
            let customDockerfile = contextDir.appendingPathComponent("app1.Dockerfile")
            let imageName = "registry.local/dockerignore-custom-name:\(UUID().uuidString)"
            let args = ["build", "-f", customDockerfile.path, "-t", imageName, contextDir.path]
            let response = try run(arguments: args)
            if response.status != 0 {
                throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
            }

            let containerName = "dockerignore-custom-name-\(UUID().uuidString)"
            try self.doLongRun(name: containerName, image: imageName)
            defer { try? self.doStop(name: containerName) }

            let app1SpecificResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/app1-specific.txt"])
            #expect(app1SpecificResult.status != 0, "app1-specific.txt should NOT be present (ignored by app1.Dockerfile.dockerignore)")

            let genericResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/generic.txt"])
            #expect(genericResult.status == 0, "generic.txt should be present (only in .dockerignore, not app1.Dockerfile.dockerignore)")

            let includedResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/included.txt"])
            #expect(includedResult.status == 0, "included.txt should be present")
        }

        // Test 10: Custom-named Dockerfile in subdirectory uses its co-located .dockerignore
        @Test func testDockerIgnoreCustomNameSubdir() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                WORKDIR /app
                COPY . .
                """
            // Root .dockerignore ignores from-root-ignore.txt
            // nested/project/app2.Dockerfile.dockerignore ignores from-app2-ignore.txt
            // When building with -f nested/project/app2.Dockerfile, the nested ignore takes precedence
            let context: [FileSystemEntry] = [
                .file("Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                .file(".dockerignore", content: .data("from-root-ignore.txt\n".data(using: .utf8)!)),
                .file("from-root-ignore.txt", content: .data("This file should be included (only in .dockerignore, not app2.Dockerfile.dockerignore).\n".data(using: .utf8)!)),
                .file("from-app2-ignore.txt", content: .data("This file should be ignored by app2.Dockerfile.dockerignore.\n".data(using: .utf8)!)),
                .file("always-included.txt", content: .data("This file should always be included.\n".data(using: .utf8)!)),
                .file("nested/project/app2.Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                .file("nested/project/app2.Dockerfile.dockerignore", content: .data("from-app2-ignore.txt\n".data(using: .utf8)!)),
                .file("nested/project/config.yaml", content: .data("Config file in project directory.\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: "", context: context)

            let contextDir = tempDir.appendingPathComponent("context")
            let customDockerfile = contextDir.appendingPathComponent("nested/project/app2.Dockerfile")
            let imageName = "registry.local/dockerignore-custom-subdir:\(UUID().uuidString)"
            let args = ["build", "-f", customDockerfile.path, "-t", imageName, contextDir.path]
            let response = try run(arguments: args)
            if response.status != 0 {
                throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
            }

            let containerName = "dockerignore-custom-subdir-\(UUID().uuidString)"
            try self.doLongRun(name: containerName, image: imageName)
            defer { try? self.doStop(name: containerName) }

            let app2IgnoreResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/from-app2-ignore.txt"])
            #expect(app2IgnoreResult.status != 0, "from-app2-ignore.txt should NOT be present (ignored by app2.Dockerfile.dockerignore)")

            let rootIgnoreResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/from-root-ignore.txt"])
            #expect(rootIgnoreResult.status == 0, "from-root-ignore.txt should be present (only in .dockerignore, not app2.Dockerfile.dockerignore)")

            let alwaysIncludedResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/always-included.txt"])
            #expect(alwaysIncludedResult.status == 0, "always-included.txt should be present")

            let configResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/nested/project/config.yaml"])
            #expect(configResult.status == 0, "nested/project/config.yaml should be present")
        }

        // Test 11: app.Dockerfile coexists with Dockerfile; app.Dockerfile.dockerignore is used, not Dockerfile.dockerignore
        @Test func testDockerIgnoreCoexistingDockerfiles() throws {
            let tempDir: URL = try createTempDir()
            let appDockerfile =
                """
                FROM ghcr.io/linuxcontainers/alpine:3.20
                WORKDIR /app
                COPY . .
                """
            let context: [FileSystemEntry] = [
                .file("Dockerfile", content: .data("FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . .\n".data(using: .utf8)!)),
                .file("Dockerfile.dockerignore", content: .data("dockerfile-specific.txt\n".data(using: .utf8)!)),
                .file("app.Dockerfile", content: .data(appDockerfile.data(using: .utf8)!)),
                .file("app.Dockerfile.dockerignore", content: .data("app-specific.txt\n".data(using: .utf8)!)),
                .file(
                    "dockerfile-specific.txt", content: .data("This file should NOT be copied when using Dockerfile, but SHOULD when using app.Dockerfile.\n".data(using: .utf8)!)),
                .file("app-specific.txt", content: .data("This file should NOT be copied (ignored by app.Dockerfile.dockerignore).\n".data(using: .utf8)!)),
                .file("included.txt", content: .data("This file should be copied.\n".data(using: .utf8)!)),
            ]
            try createContext(tempDir: tempDir, dockerfile: "", context: context)

            let contextDir = tempDir.appendingPathComponent("context")
            let appDockerfilePath = contextDir.appendingPathComponent("app.Dockerfile")
            let imageName = "registry.local/dockerignore-coexisting:\(UUID().uuidString)"
            let args = ["build", "-f", appDockerfilePath.path, "-t", imageName, contextDir.path]
            let response = try run(arguments: args)
            if response.status != 0 {
                throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
            }

            let containerName = "dockerignore-coexisting-\(UUID().uuidString)"
            try self.doLongRun(name: containerName, image: imageName)
            defer { try? self.doStop(name: containerName) }

            let appSpecificResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/app-specific.txt"])
            #expect(appSpecificResult.status != 0, "app-specific.txt should NOT be present (ignored by app.Dockerfile.dockerignore)")

            let dockerfileSpecificResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/dockerfile-specific.txt"])
            #expect(dockerfileSpecificResult.status == 0, "dockerfile-specific.txt should be present (Dockerfile.dockerignore was not used)")

            let includedResult = try run(arguments: ["exec", containerName, "test", "-f", "/app/included.txt"])
            #expect(includedResult.status == 0, "included.txt should be present")
        }

        @Test func testBuildNoCachePullLatestImage() throws {
            let tempDir: URL = try createTempDir()
            let dockerfile =
                """
                FROM \(alpine)

                ADD emptyFile /
                """
            let context: [FileSystemEntry] = [.file("emptyFile", content: .zeroFilled(size: 1))]
            try createContext(tempDir: tempDir, dockerfile: dockerfile, context: context)

            let imageName = "registry.local/no-cache-pull:\(UUID().uuidString)"
            try self.build(
                tags: [imageName],
                tempDir: tempDir,
                otherArgs: ["--pull", "--no-cache"]
            )
            #expect(try self.inspectImage(imageName) == imageName, "expected to have successfully built \(imageName)")
        }
    }
}
