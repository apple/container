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

import Darwin
import Foundation
import Testing

// Convenience alias for the verbose entry type.
typealias FSEntry = ContainerFixture.FileSystemEntry

@Suite(.serialized)
struct TestCLIBuilderSerial {

    // MARK: - Basic build tests

    @Test func testBuildDefaultParams() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(dir: dir, dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20")
                // No tags — runtime generates one and prints it to stdout.
                let output = try f.buildWithPaths(contextDir: dir)
                let generatedTag = output.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(!generatedTag.isEmpty, "build should print the generated image tag to stdout")
                try f.assertImageBuilt(generatedTag)
            }
        }
    }

    @Test func testBuildDotFileSucceeds() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM scratch\nADD emptyFile /",
                    context: [
                        .file("emptyFile", content: .zeroFilled(size: 1)),
                        .file(".dockerignore", content: .data(".dockerignore\n".data(using: .utf8)!)),
                    ])
                let image = "registry.local/dot-file:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildFromPreviousStage() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM ghcr.io/linuxcontainers/alpine:3.20 AS layer1
                        RUN sh -c "echo 'layer1' > /layer1.txt"
                        FROM layer1
                        CMD ["cat", "/layer1.txt"]
                        """)
                let image = "registry.local/from-previous-layer:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildFromLocalImage() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM scratch\nADD emptyFile /",
                    context: [
                        .file("emptyFile", content: .zeroFilled(size: 0)),
                        .file(".dockerignore", content: .data(".dockerignore\n".data(using: .utf8)!)),
                    ])
                let image = "local-only:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)

                let dir2 = try f.createTempDir()
                try f.createContext(
                    dir: dir2,
                    dockerfile: "FROM \(image)",
                    context: [])
                let image2 = "from-local:\(UUID().uuidString)"
                try f.build(tag: image2, contextDir: dir2)
                try f.assertImageBuilt(image2)
            }
        }
    }

    @Test func testBuildAddFromSpecialDirs() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM scratch\nADD emptyFile /",
                    context: [.file("emptyFile", content: .zeroFilled(size: 1))])
                let image = "registry.local/scratch-add-special-dir:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildScratchAdd() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM scratch\nADD emptyFile /",
                    context: [.file("emptyFile", content: .zeroFilled(size: 1))])
                let image = "registry.local/scratch-add:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildAddAll() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        ADD . .
                        RUN cat emptyFile
                        RUN cat Test/testempty
                        """,
                    context: [
                        .directory("Test"),
                        .file("Test/testempty", content: .zeroFilled(size: 1)),
                        .file("emptyFile", content: .zeroFilled(size: 1)),
                    ])
                let image = "registry.local/add-all:\(UUID().uuidString)"
                let output = try f.build(tag: image, contextDir: dir)
                #expect(output.contains(image))
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildArg() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "ARG TAG=unknown\nFROM ghcr.io/linuxcontainers/alpine:${TAG}")
                let image = "registry.local/build-arg:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir, buildArgs: ["TAG=3.20"])
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildSecret() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        RUN --mount=type=secret,id=ENV1 \\
                            --mount=type=secret,id=env2 \\
                            --mount=type=secret,id=env3 \\
                            test xyyzzz = "`cat /run/secrets/ENV1 /run/secrets/env2 /run/secrets/env3`"
                        RUN --mount=type=secret,id=file \\
                            awk 'BEGIN {for(i=0; i<17; i++) for(c=0; c<256; c++) printf("%c", c)}' > /tmp/foo && \\
                            cmp /tmp/foo /run/secrets/file && \\
                            rm /tmp/foo
                        RUN --mount=type=secret,id=empty \\
                            ! test -e /run/secrets/file && \\
                            test -e /run/secrets/empty && \\
                            cmp /dev/null /run/secrets/empty
                        """)

                setenv("ENV1", "x", 1)
                setenv("ENV_VAR", "yy", 1)
                setenv("env3", "zzz", 1)
                f.addCleanup {
                    unsetenv("ENV1")
                    unsetenv("ENV_VAR")
                    unsetenv("env3")
                }

                let testData = Data((0..<17).flatMap { _ in Array(0...255) })
                let secretFile = try f.createTempFile(suffix: " _f,i=l.e+ ", contents: testData)
                let emptyFile = try f.createTempFile(suffix: "file2", contents: Data())

                let image = "registry.local/secrets:\(UUID().uuidString)"
                try f.build(
                    tag: image, contextDir: dir,
                    otherArgs: [
                        "--secret", "id=ENV1",
                        "--secret", "id=env2,env=ENV_VAR",
                        "--secret", "id=env3,env=env3",
                        "--secret", "id=file,src=\(secretFile.string)",
                        "--secret", "id=empty,src=\(emptyFile.string)",
                    ])
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildNetworkAccess() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        ARG HTTP_PROXY
                        ARG HTTPS_PROXY
                        ARG NO_PROXY
                        ARG http_proxy
                        ARG https_proxy
                        ARG no_proxy
                        RUN apk add --no-cache curl
                        """)
                var buildArgs: [String] = []
                for key in ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"] {
                    if let v = ProcessInfo.processInfo.environment[key] { buildArgs.append("\(key)=\(v)") }
                }
                let image = "registry.local/build-network-access:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir, buildArgs: buildArgs)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildDockerfileKeywords() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        ARG TAG=3.20
                        FROM ghcr.io/linuxcontainers/alpine:${TAG}
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        RUN echo "Hello, World!" > /hello.txt
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        RUN ["sh", "-c", "echo 'Exec form' > /exec.txt"]
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        CMD ["echo", "Exec default"]
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        LABEL version="1.0" description="Test image"
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        EXPOSE 8080
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        ENV MY_ENV=hello
                        RUN echo $MY_ENV > /env.txt
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        ADD emptyFile /
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        COPY toCopy /toCopy
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        ENTRYPOINT ["echo", "entrypoint!"]
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        VOLUME /data
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        RUN adduser -D myuser
                        USER myuser
                        CMD whoami
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        WORKDIR /app
                        RUN pwd > /pwd.out
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        ARG MY_VAR=default
                        RUN echo $MY_VAR > /var.out
                        """,
                    context: [
                        .file("emptyFile", content: .zeroFilled(size: 1)),
                        .file("toCopy", content: .zeroFilled(size: 1)),
                    ])
                let image = "registry.local/dockerfile-keywords:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildSymlink() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = """
                    FROM ghcr.io/linuxcontainers/alpine:3.20
                    ADD Test1Source Test1Source
                    ADD Test1Source2 Test1Source2
                    RUN cat Test1Source2/test.yaml
                    FROM ghcr.io/linuxcontainers/alpine:3.20
                    ADD Test2Source Test2Source
                    ADD Test2Source2 Test2Source2
                    RUN cat Test2Source2/Test/test.txt
                    FROM ghcr.io/linuxcontainers/alpine:3.20
                    ADD Test3Source Test3Source
                    ADD Test3Source2 Test3Source2
                    RUN cat Test3Source2/Dest/test.txt
                    """
                let context: [FSEntry] = [
                    .directory("Test1Source"), .directory("Test1Source2"),
                    .file("Test1Source/test.yaml", content: .zeroFilled(size: 200)),
                    .symbolicLink("Test1Source2/test.yaml", target: "Test1Source/test.yaml"),
                    .directory("Test2Source"), .directory("Test2Source2"),
                    .file("Test2Source/Test/Test/test.yaml", content: .zeroFilled(size: 300)),
                    .symbolicLink("Test2Source2/Test/test.yaml", target: "Test2Source/Test/Test/test.yaml"),
                    .directory("Test3Source/Source"), .directory("Test3Source2"),
                    .file("Test3Source/Source/test.txt", content: .zeroFilled(size: 1)),
                    .symbolicLink("Test3Source2/Dest", target: "Test3Source/Source"),
                ]
                try f.createContext(dir: dir, dockerfile: dockerfile, context: context)
                let image = "registry.local/build-symlinks:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildAndRun() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nRUN echo \"foobar\" > /file")
                let image = "\(f.testID)-build-and-run:latest"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
                try await f.withContainer(image: image) { name in
                    let output = try f.doExec(name, cmd: ["cat", "/file"])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    #expect(output == "foobar")
                }
            }
        }
    }

    @Test func testBuildDifferentPaths() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        RUN ls ./
                        COPY . /root
                        RUN cat /root/Test/test.txt
                        """,
                    context: [
                        .directory(".git"),
                        .file(".git/FETCH", content: .zeroFilled(size: 1)),
                        .directory("Test"),
                        .file("Test/test.txt", content: .zeroFilled(size: 1)),
                    ])
                let image = "registry.local/build-diff-context:\(UUID().uuidString)"
                try f.buildWithPaths(tags: [image], contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildMultiArch() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        ADD . .
                        RUN cat emptyFile
                        RUN cat Test/testempty
                        """,
                    context: [
                        .directory("Test"),
                        .file("Test/testempty", content: .zeroFilled(size: 1)),
                        .file("emptyFile", content: .zeroFilled(size: 1)),
                    ])
                let image = "registry.local/multi-arch:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir, otherArgs: ["--arch", "amd64,arm64"])
                try f.assertImageBuilt(image)

                let output = try f.doInspectImages(image)
                #expect(output.count == 1, "expected single inspect result")
                let archs = Set(output[0].variants.map { $0.platform.architecture })
                #expect(archs == Set(["amd64", "arm64"]), "expected amd64 and arm64 variants")
            }
        }
    }

    @Test func testBuildMultipleTags() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM scratch\nADD emptyFile /",
                    context: [.file("emptyFile", content: .zeroFilled(size: 1))])
                let uuid = UUID().uuidString
                let tag1 = "registry.local/multi-tag-test:\(uuid)"
                let tag2 = "registry.local/multi-tag-test:latest"
                let tag3 = "registry.local/multi-tag-test:v1.0.0"
                let output = try f.buildWithPaths(tags: [tag1, tag2, tag3], contextDir: dir)
                #expect(output.contains(tag1))
                #expect(output.contains(tag2))
                #expect(output.contains(tag3))
                try f.assertImageBuilt(tag1)
                try f.assertImageBuilt(tag2)
                try f.assertImageBuilt(tag3)
            }
        }
    }

    @Test func testBuildAfterContextChange() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let initialContent = "initial".data(using: .utf8)!
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nCOPY foo /foo\nCOPY bar /bar",
                    context: [
                        .file("foo", content: .data(Data((0..<4 * 1024 * 1024).map { UInt8($0 % 256) }))),
                        .file("bar", content: .data(initialContent)),
                    ])

                let image1 = "\(f.testID)-build-context-change:v1"
                try f.build(tag: image1, contextDir: dir)
                try await f.withContainer(image: image1) { name in
                    let out = try f.doExec(name, cmd: ["cat", "/bar"])
                    #expect(out == "initial")
                }

                let contextBar = dir.appending("context").appending("bar")
                try "updated".data(using: .utf8)!.write(to: URL(filePath: contextBar.string), options: .atomic)

                let image2 = "\(f.testID)-build-context-change:v2"
                try f.build(tag: image2, contextDir: dir)
                try await f.withContainer(image: image2) { name in
                    let out = try f.doExec(name, cmd: ["cat", "/bar"])
                    #expect(out == "updated")
                }
            }
        }
    }

    @Test func testBuildWithDockerfileFromStdin() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM scratch\nADD emptyFile /"
                try f.createContext(
                    dir: dir, dockerfile: "",
                    context: [.file("emptyFile", content: .zeroFilled(size: 1))])
                let image = "registry.local/stdin-file:\(UUID().uuidString)"
                try f.buildWithStdin(tags: [image], contextDir: dir, dockerfileContents: dockerfile)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testLowercaseDockerfile() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let files: [(String, String, String)] = [
                    ("COPY . /app", "copy-uppercase", "COPY"),
                    ("copy . /app", "copy-lowercase", "copy"),
                    ("ADD . /app", "add-uppercase", "ADD"),
                    ("add . /app", "add-lowercase", "add"),
                ]
                for (instruction, name, _) in files {
                    let dir = try f.createTempDir()
                    try f.createContext(
                        dir: dir,
                        dockerfile: """
                            FROM ghcr.io/linuxcontainers/alpine:3.20
                            \(instruction)
                            RUN test -f /app/testfile.txt
                            """,
                        context: [.file("testfile.txt", content: .data("test".data(using: .utf8)!))])
                    let image = "registry.local/\(name):\(UUID().uuidString)"
                    try f.build(tag: image, contextDir: dir)
                    try f.assertImageBuilt(image)
                }
            }
        }
    }

    @Test func testRunWithBindMount() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        RUN --mount=type=bind,source=.,target=/mnt/context \\
                            set -e; \\
                            if [ ! -f /mnt/context/app.py ]; then echo "ERROR: app.py missing"; exit 1; fi; \\
                            if [ ! -f /mnt/context/config.yaml ]; then echo "ERROR: config.yaml missing"; exit 1; fi; \\
                            cp /mnt/context/app.py /app.py
                        RUN cat /app.py
                        """,
                    context: [
                        .file("app.py", content: .data("print('Hello from bind mount')".data(using: .utf8)!)),
                        .file("config.yaml", content: .data("key: value".data(using: .utf8)!)),
                    ])
                let image = "registry.local/bind-mount-test:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    // MARK: - .dockerignore tests

    @Test func testBuildDockerIgnore() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerignore = """
                    secret.txt
                    *.log
                    **/*.log
                    !important.log
                    *.tmp
                    **/*.tmp
                    temp/
                    node_modules/
                    """
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        COPY . /app
                        RUN set -e; [ ! -f /app/secret.txt ] || exit 1
                        RUN set -e; [ ! -f /app/debug.log ] || exit 1
                        RUN set -e; [ -f /app/important.log ] || exit 1
                        RUN set -e; find /app -name "*.tmp" | grep . && exit 1; true
                        RUN set -e; [ ! -d /app/temp ] || exit 1
                        RUN set -e; [ ! -d /app/node_modules ] || exit 1
                        RUN set -e; [ -f /app/main.go ] && [ -f /app/README.md ] && [ -f /app/src/app.go ]
                        """,
                    context: [
                        .file(".dockerignore", content: .data(dockerignore.data(using: .utf8)!)),
                        .file("secret.txt", content: .data("secret".data(using: .utf8)!)),
                        .file("debug.log", content: .data("debug".data(using: .utf8)!)),
                        .file("important.log", content: .data("important".data(using: .utf8)!)),
                        .file("cache.tmp", content: .data("cache".data(using: .utf8)!)),
                        .file("main.go", content: .data("package main".data(using: .utf8)!)),
                        .file("README.md", content: .data("# README".data(using: .utf8)!)),
                        .directory("temp"),
                        .file("logs/app.log", content: .data("app log".data(using: .utf8)!)),
                        .directory("node_modules"),
                        .directory("src"),
                        .file("src/app.go", content: .data("package src".data(using: .utf8)!)),
                    ])
                let image = "registry.local/dockerignore-test:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testDockerIgnoreBasic() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir,
                    dockerfile: dockerfile,
                    context: [
                        .file("Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                        .file("included.txt", content: .data("included\n".data(using: .utf8)!)),
                        .file("ignored.txt", content: .data("ignored\n".data(using: .utf8)!)),
                        .file(".dockerignore", content: .data("ignored.txt\n".data(using: .utf8)!)),
                    ])
                let contextDir = dir.appending("context")
                let image = "registry.local/dockerignore-basic:\(UUID().uuidString)"
                let result = try f.run([
                    "build", "-f", contextDir.appending("Dockerfile").string,
                    "-t", image, contextDir.string,
                ])
                try result.check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerHasFile(name, at: "/app/included.txt")
                    try f.assertContainerMissingFile(name, at: "/app/ignored.txt")
                }
            }
        }
    }

    @Test func testDockerIgnoreDockerfileSpecific() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir, dockerfile: dockerfile,
                    context: [
                        .file("Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                        .file(".dockerignore", content: .data("general.txt\n".data(using: .utf8)!)),
                        .file("Dockerfile.dockerignore", content: .data("specific.txt\n".data(using: .utf8)!)),
                        .file("general.txt", content: .data("general\n".data(using: .utf8)!)),
                        .file("specific.txt", content: .data("specific\n".data(using: .utf8)!)),
                    ])
                let contextDir = dir.appending("context")
                let image = "registry.local/dockerignore-specific:\(UUID().uuidString)"
                try f.run([
                    "build", "-f", contextDir.appending("Dockerfile").string,
                    "-t", image, contextDir.string,
                ]).check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerMissingFile(name, at: "/app/specific.txt", "specific.txt should be ignored by Dockerfile.dockerignore")
                    try f.assertContainerHasFile(name, at: "/app/general.txt", "general.txt should be present (Dockerfile.dockerignore takes precedence)")
                }
            }
        }
    }

    @Test func testDockerIgnoreOutsideContext() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir, dockerfile: dockerfile,
                    context: [
                        .file(".dockerignore", content: .data("general.txt\n".data(using: .utf8)!)),
                        .file("general.txt", content: .data("general\n".data(using: .utf8)!)),
                        .file("specific.txt", content: .data("specific\n".data(using: .utf8)!)),
                    ])
                try "specific.txt\n".data(using: .utf8)!.write(to: URL(filePath: dir.appending("Dockerfile.dockerignore").string), options: .atomic)
                let image = "registry.local/dockerignore-outside:\(UUID().uuidString)"
                try f.run([
                    "build", "-f", dir.appending("Dockerfile").string,
                    "-t", image, dir.appending("context").string,
                ]).check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerMissingFile(name, at: "/app/specific.txt")
                    try f.assertContainerHasFile(name, at: "/app/general.txt")
                }
            }
        }
    }

    @Test func testDockerIgnoreIgnoredDockerfile() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir, dockerfile: dockerfile,
                    context: [
                        .file("Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                        .file(".dockerignore", content: .data("Dockerfile\n.dockerignore\n".data(using: .utf8)!)),
                        .file("test.txt", content: .data("test\n".data(using: .utf8)!)),
                    ])
                let contextDir = dir.appending("context")
                let image = "registry.local/dockerignore-ignored-dockerfile:\(UUID().uuidString)"
                try f.run([
                    "build", "-f", contextDir.appending("Dockerfile").string,
                    "-t", image, contextDir.string,
                ]).check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerMissingFile(name, at: "/app/Dockerfile")
                    try f.assertContainerMissingFile(name, at: "/app/.dockerignore")
                    try f.assertContainerHasFile(name, at: "/app/test.txt")
                }
            }
        }
    }

    @Test func testDockerIgnoreSubdirDockerfile() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir, dockerfile: dockerfile,
                    context: [
                        .file(".dockerignore", content: .data("included.txt\n".data(using: .utf8)!)),
                        .file("included.txt", content: .data("included\n".data(using: .utf8)!)),
                        .file("secret.txt", content: .data("secret\n".data(using: .utf8)!)),
                        .file("nested/secret.txt", content: .data("nested secret\n".data(using: .utf8)!)),
                        .file("nested/project/Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                        .file("nested/project/Dockerfile.dockerignore", content: .data("secret.txt\n**/secret.txt\n".data(using: .utf8)!)),
                        .file("nested/project/config.txt", content: .data("config\n".data(using: .utf8)!)),
                    ])
                let contextDir = dir.appending("context")
                let nestedDockerfile = contextDir.appending("nested").appending("project").appending("Dockerfile")
                let image = "registry.local/dockerignore-subdir:\(UUID().uuidString)"
                try f.run([
                    "build", "-f", nestedDockerfile.string, "-t", image, contextDir.string,
                ]).check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerHasFile(name, at: "/app/included.txt")
                    try f.assertContainerMissingFile(name, at: "/app/secret.txt")
                    try f.assertContainerMissingFile(name, at: "/app/nested/secret.txt")
                    try f.assertContainerHasFile(name, at: "/app/nested/project/config.txt")
                }
            }
        }
    }

    @Test func testDockerIgnoreCustomDockerfileName() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir, dockerfile: "",  // no top-level Dockerfile
                    context: [
                        .file(".dockerignore", content: .data("generic.txt\n".data(using: .utf8)!)),
                        .file("app1.Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                        .file("app1.Dockerfile.dockerignore", content: .data("app1-specific.txt\n".data(using: .utf8)!)),
                        .file("app1-specific.txt", content: .data("app1 specific\n".data(using: .utf8)!)),
                        .file("generic.txt", content: .data("generic\n".data(using: .utf8)!)),
                        .file("included.txt", content: .data("included\n".data(using: .utf8)!)),
                    ])
                let contextDir = dir.appending("context")
                let image = "registry.local/dockerignore-custom-name:\(UUID().uuidString)"
                try f.run([
                    "build", "-f", contextDir.appending("app1.Dockerfile").string,
                    "-t", image, contextDir.string,
                ]).check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerMissingFile(name, at: "/app/app1-specific.txt")
                    try f.assertContainerHasFile(name, at: "/app/generic.txt")
                    try f.assertContainerHasFile(name, at: "/app/included.txt")
                }
            }
        }
    }

    @Test func testDockerIgnoreCustomNameSubdir() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir, dockerfile: "",
                    context: [
                        .file(".dockerignore", content: .data("from-root-ignore.txt\n".data(using: .utf8)!)),
                        .file("from-root-ignore.txt", content: .data("root ignore\n".data(using: .utf8)!)),
                        .file("from-app2-ignore.txt", content: .data("app2 ignore\n".data(using: .utf8)!)),
                        .file("always-included.txt", content: .data("always\n".data(using: .utf8)!)),
                        .file("nested/project/app2.Dockerfile", content: .data(dockerfile.data(using: .utf8)!)),
                        .file("nested/project/app2.Dockerfile.dockerignore", content: .data("from-app2-ignore.txt\n".data(using: .utf8)!)),
                        .file("nested/project/config.yaml", content: .data("config\n".data(using: .utf8)!)),
                    ])
                let contextDir = dir.appending("context")
                let nestedDockerfile = contextDir.appending("nested").appending("project").appending("app2.Dockerfile")
                let image = "registry.local/dockerignore-custom-subdir:\(UUID().uuidString)"
                try f.run([
                    "build", "-f", nestedDockerfile.string, "-t", image, contextDir.string,
                ]).check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerMissingFile(name, at: "/app/from-app2-ignore.txt")
                    try f.assertContainerHasFile(name, at: "/app/from-root-ignore.txt")
                    try f.assertContainerHasFile(name, at: "/app/always-included.txt")
                    try f.assertContainerHasFile(name, at: "/app/nested/project/config.yaml")
                }
            }
        }
    }

    @Test func testDockerIgnoreCoexistingDockerfiles() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let appDockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir, dockerfile: "",
                    context: [
                        .file("Dockerfile", content: .data("FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . .\n".data(using: .utf8)!)),
                        .file("Dockerfile.dockerignore", content: .data("dockerfile-specific.txt\n".data(using: .utf8)!)),
                        .file("app.Dockerfile", content: .data(appDockerfile.data(using: .utf8)!)),
                        .file("app.Dockerfile.dockerignore", content: .data("app-specific.txt\n".data(using: .utf8)!)),
                        .file("dockerfile-specific.txt", content: .data("df specific\n".data(using: .utf8)!)),
                        .file("app-specific.txt", content: .data("app specific\n".data(using: .utf8)!)),
                        .file("included.txt", content: .data("included\n".data(using: .utf8)!)),
                    ])
                let contextDir = dir.appending("context")
                let image = "registry.local/dockerignore-coexisting:\(UUID().uuidString)"
                try f.run([
                    "build", "-f", contextDir.appending("app.Dockerfile").string,
                    "-t", image, contextDir.string,
                ]).check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerMissingFile(name, at: "/app/app-specific.txt")
                    try f.assertContainerHasFile(name, at: "/app/dockerfile-specific.txt")
                    try f.assertContainerHasFile(name, at: "/app/included.txt")
                }
            }
        }
    }

    @Test func testDockerIgnoreReadonlyContext() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let dockerfile = "FROM ghcr.io/linuxcontainers/alpine:3.20\nWORKDIR /app\nCOPY . ."
                try f.createContext(
                    dir: dir, dockerfile: dockerfile,
                    context: [
                        .file("included.txt", content: .data("included\n".data(using: .utf8)!)),
                        .file("secret.txt", content: .data("secret\n".data(using: .utf8)!)),
                    ])
                try "secret.txt\n".data(using: .utf8)!.write(to: URL(filePath: dir.appending("Dockerfile.dockerignore").string), options: .atomic)

                let contextDir = dir.appending("context")
                // Make the context read-only, then restore before cleanup.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555], ofItemAtPath: contextDir.string)
                f.addCleanup {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: contextDir.string)
                }

                let image = "registry.local/dockerignore-readonly:\(UUID().uuidString.prefix(6))"
                try f.run([
                    "build", "-f", dir.appending("Dockerfile").string,
                    "-t", image, contextDir.string,
                ]).check()
                try await f.withContainer(image: image, tag: "c") { name in
                    try f.assertContainerHasFile(name, at: "/app/included.txt")
                    try f.assertContainerMissingFile(name, at: "/app/secret.txt")
                }
            }
        }
    }

    @Test func testNonExistingDockerfile() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                let image = "registry.local/non-existing-dockerfile:\(UUID().uuidString)"
                let r1 = try f.run(["build", "-f", "non-existing-path", "-t", image, dir.string])
                #expect(r1.status != 0)
                let r2 = try f.run(["build", "-t", image, dir.string])
                #expect(r2.status != 0)
            }
        }
    }

    @Test func testBuildNoCachePullLatestImage() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM \(ContainerFixture.warmupImages[0])\nADD emptyFile /",
                    context: [.file("emptyFile", content: .zeroFilled(size: 1))])
                let image = "registry.local/no-cache-pull:\(UUID().uuidString)"
                try f.buildWithPaths(tags: [image], contextDir: dir, otherArgs: ["--pull", "--no-cache"])
                try f.assertImageBuilt(image)
            }
        }
    }

    // MARK: - Dockerfile ARG quoting

    @Test func testBuildQuotedImageDockerfileArg() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "ARG IMAGE=\"ghcr.io/linuxcontainers/alpine:3.20\"\nFROM $IMAGE\nRUN test -f /etc/alpine-release")
                let image = "registry.local/quoted-image-dockerfile-arg:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildQuotedStringDockerfileArg() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nARG MYSTRING='\"Hello, world!\"'\nRUN test \"$MYSTRING\" = '\"Hello, world!\"'")
                let image = "registry.local/quoted-string-dockerfile-arg:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildForwardReferencedDockerfileArg() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        ARG ALPINE="ghcr.io/linuxcontainers/alpine"
                        ARG IMAGE="${ALPINE}:3.20"
                        FROM $IMAGE
                        RUN test -f /etc/alpine-release
                        """)
                let image = "registry.local/forward-referenced-dockerfile-arg:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildQuotedImageBuildArg() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "ARG IMAGE\nFROM $IMAGE\nRUN test -f /etc/alpine-release")
                let image = "registry.local/quoted-image-build-arg:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir, buildArgs: ["IMAGE=ghcr.io/linuxcontainers/alpine:3.20"])
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildQuotedStringBuildArg() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nARG MYSTRING\nRUN test \"$MYSTRING\" = '\"Hello, world!\"'")
                let image = "registry.local/quoted-string-build-arg:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir, buildArgs: ["MYSTRING=\"Hello, world!\""])
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testBuildForwardReferencedBuildArg() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        ARG ALPINE
                        ARG IMAGE="$ALPINE:3.20"
                        FROM $IMAGE
                        RUN test -f /etc/alpine-release
                        """)
                let image = "registry.local/forward-referenced-build-arg:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir, buildArgs: ["ALPINE=ghcr.io/linuxcontainers/alpine"])
                try f.assertImageBuilt(image)
            }
        }
    }

    // MARK: - COPY --from tests

    @Test func testCopyFromLocalImage() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let baseDir = try f.createTempDir()
                let baseName = "local-base:\(UUID().uuidString)"
                try f.createContext(
                    dir: baseDir,
                    dockerfile: "FROM scratch\nADD hello.txt /hello.txt",
                    context: [.file("hello.txt", content: .data("hello\n".data(using: .utf8)!))])
                try f.build(tag: baseName, contextDir: baseDir)
                try f.assertImageBuilt(baseName)

                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nCOPY --from=\(baseName) /hello.txt /copied.txt\nRUN cat /copied.txt")
                let image = "registry.local/copy-from-local:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testCopyFromBuildStage() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM scratch AS builder
                        ADD hello.txt /hello.txt
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        COPY --from=builder /hello.txt /copied.txt
                        RUN cat /copied.txt
                        """,
                    context: [.file("hello.txt", content: .data("hello\n".data(using: .utf8)!))])
                let image = "registry.local/copy-from-stage:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testCopyRenameFromStage() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM scratch AS builder
                        ADD hello.txt /hello.txt
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        COPY --from=builder /hello.txt /renamed.txt
                        RUN cat /renamed.txt
                        """,
                    context: [.file("hello.txt", content: .data("hello\n".data(using: .utf8)!))])
                let image = "registry.local/copy-rename:\(UUID().uuidString)"
                try f.build(tag: image, contextDir: dir)
                try f.assertImageBuilt(image)
            }
        }
    }

    @Test func testCopyMissingFileFails() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: """
                        FROM scratch AS builder
                        FROM ghcr.io/linuxcontainers/alpine:3.20
                        COPY --from=builder /does-not-exist.txt /copied.txt
                        """)
                let image = "registry.local/copy-missing:\(UUID().uuidString)"
                let result = try f.run([
                    "build", "-f", dir.appending("Dockerfile").string,
                    "-t", image, dir.appending("context").string,
                ])
                #expect(result.status != 0, "build should fail when source file is missing")
            }
        }
    }

    @Test func testCopyInvalidStageFails() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nCOPY --from=not_a_stage /hello.txt /copied.txt")
                let image = "registry.local/copy-invalid-stage:\(UUID().uuidString)"
                let result = try f.run([
                    "build", "-f", dir.appending("Dockerfile").string,
                    "-t", image, dir.appending("context").string,
                ])
                #expect(result.status != 0, "build should fail with invalid stage name")
            }
        }
    }

    @Test func testCopyFromNonexistentImageFails() async throws {
        try await ContainerFixture.with { f in
            try await f.withBuilder { f in
                let dir = try f.createTempDir()
                try f.createContext(
                    dir: dir,
                    dockerfile: "FROM ghcr.io/linuxcontainers/alpine:3.20\nCOPY --from=doesnotexist:latest /hello.txt /copied.txt")
                let image = "registry.local/copy-bad-image:\(UUID().uuidString)"
                let result = try f.run([
                    "build", "-f", dir.appending("Dockerfile").string,
                    "-t", image, dir.appending("context").string,
                ])
                #expect(result.status != 0, "build should fail when source image does not exist")
            }
        }
    }
}
