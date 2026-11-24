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

import ContainerTestSupport
import Darwin
import Foundation
import Testing

/// Tests for `container builder start`, `stop`, and `delete` lifecycle commands.
///
/// Serialized because they stop/delete the shared `buildkit` container, which
/// would race with in-flight builds in the concurrent pool.
@Suite(.serialized)
struct TestCLIBuilderLifecycleSerial {
    @Test func testBuilderStartStopCommand() async throws {
        try await ContainerFixture.with { f in
            f.addCleanup { try? f.builderDelete(force: true) }

            try f.builderStart()
            try await f.waitForBuilderRunning()
            let status1 = try f.getContainerStatus("buildkit")
            #expect(status1 == "running", "buildkit container should be running")

            try f.builderStop()
            let status2 = try f.getContainerStatus("buildkit")
            #expect(status2 == "stopped", "buildkit container should be stopped")
        }
    }

    @Test func testBuilderEnvironmentColors() async throws {
        try await ContainerFixture.with { f in
            let originalColors = ProcessInfo.processInfo.environment["BUILDKIT_COLORS"]
            let originalNoColor = ProcessInfo.processInfo.environment["NO_COLOR"]
            f.addCleanup {
                if let c = originalColors { setenv("BUILDKIT_COLORS", c, 1) } else { unsetenv("BUILDKIT_COLORS") }
                if let n = originalNoColor { setenv("NO_COLOR", n, 1) } else { unsetenv("NO_COLOR") }
                _ = try? f.builderDelete(force: true)
            }

            _ = try? f.builderDelete(force: true)
            setenv("BUILDKIT_COLORS", "run=green:warning=yellow:error=red:cancel=cyan", 1)
            setenv("NO_COLOR", "true", 1)

            try f.run(["builder", "start"]).check()
            try await f.waitForBuilderRunning()

            let container = try f.inspectContainer("buildkit")
            let env = container.configuration.initProcess.environment
            #expect(
                env.contains("BUILDKIT_COLORS=run=green:warning=yellow:error=red:cancel=cyan"),
                "BUILDKIT_COLORS should be forwarded to the buildkit container")
            #expect(
                env.contains("NO_COLOR=true"),
                "NO_COLOR should be forwarded to the buildkit container")
        }
    }

    @Test func testBuildWithSSHDefaultForwarding() async throws {
        try await ContainerFixture.with { f in
            let socketDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: socketDir)
            }

            let socketPath = socketDir.appendingPathComponent("ssh-auth.sock").path

            let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(serverFd >= 0, "socket() failed")
            defer {
                Darwin.close(serverFd)
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { bytes in
                socketPath.withCString { cStr in
                    bytes.copyMemory(from: UnsafeRawBufferPointer(start: cStr, count: socketPath.utf8.count + 1))
                }
            }

            let bindResult = withUnsafePointer(to: addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            precondition(bindResult == 0, "bind() failed: \(errno)")
            precondition(listen(serverFd, 5) == 0, "listen() failed")

            let acceptThread = Thread {
                while true {
                    let clientFd = accept(serverFd, nil, nil)
                    if clientFd < 0 { break }
                    Darwin.close(clientFd)
                }
            }
            acceptThread.start()

            let dir = try f.createTempDir()
            try f.createContext(
                dir: dir,
                dockerfile: """
                    FROM ghcr.io/linuxcontainers/alpine:3.20
                    RUN --mount=type=ssh \\
                        test -n "$SSH_AUTH_SOCK" && \\
                        test -S "$SSH_AUTH_SOCK"
                    """)

            let image = "registry.local/ssh-default-forwarding:\(UUID().uuidString)"
            try f.run(
                [
                    "build",
                    "--ssh", "default",
                    "-f", dir.appending("Dockerfile").string,
                    "-t", image,
                    dir.appending("context").string,
                ], env: ["SSH_AUTH_SOCK": socketPath]
            ).check()
            try f.assertImageBuilt(image)
        }
    }

    @available(macOS 26, *)
    @Test func testBuilderCustomNetwork() async throws {
        try await ContainerFixture.with { f in
            let net = "\(f.testID)-builder-net"
            f.addCleanup { f.doNetworkDeleteIfExists(net) }
            f.addCleanup { try? f.builderDelete(force: true) }

            try f.doNetworkCreate(net)
            _ = try? f.builderDelete(force: true)

            try f.builderStart(networks: [net])
            try await f.waitForBuilderRunning()

            let builderOnCustomNet = try f.inspectContainer("buildkit")
            #expect(
                builderOnCustomNet.configuration.networks.map(\.network) == [net],
                "builder should be configured with custom network \(net)")
            #expect(
                builderOnCustomNet.networks.map(\.network) == [net],
                "builder should be attached to custom network \(net)")

            let dir = try f.createTempDir()
            try f.createContext(
                dir: dir,
                dockerfile: "FROM scratch\nADD emptyFile /",
                context: [.file("emptyFile", content: .zeroFilled(size: 1))]
            )
            let image1 = "registry.local/builder-custom-net:\(UUID().uuidString)"
            try f.build(tag: image1, contextDir: dir)
            try f.assertImageBuilt(image1)

            let builderAfterBuild = try f.inspectContainer("buildkit")
            #expect(
                builderAfterBuild.configuration.networks.map(\.network) == [net],
                "build without --network should preserve the builder's existing custom network")

            let missingResult = try f.run(["builder", "start", "--network", "missing-\(f.testID)"])
            #expect(missingResult.status != 0, "builder start with nonexistent network should fail")
            let builderAfterError = try f.inspectContainer("buildkit")
            #expect(builderAfterError.status.state == "running")
            #expect(builderAfterError.configuration.networks.map(\.network) == [net])

            let image2 = "registry.local/builder-default-net:\(UUID().uuidString)"
            try f.build(tag: image2, contextDir: dir, otherArgs: ["--network", "default"])
            try f.assertImageBuilt(image2)

            let builderOnDefault = try f.inspectContainer("buildkit")
            #expect(
                builderOnDefault.configuration.networks.map(\.network) == ["default"],
                "build --network default should switch builder back to default network")
        }
    }
}
