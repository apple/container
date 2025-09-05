//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

final class TestCLIComposeBuild: CLITest {
    private func shouldRunE2E() -> Bool {
        ProcessInfo.processInfo.environment["RUN_COMPOSE_E2E"] == "1"
    }

    private func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test
    func testBuildOnlyServiceUpDown() throws {
        guard shouldRunE2E() else { return #expect(Bool(true)) }

        let dir = testDir
        let dockerfile = dir.appendingPathComponent("Dockerfile")
        try write("""
        FROM alpine:3.19
        CMD ["sleep","60"]
        """.trimmingCharacters(in: .whitespacesAndNewlines), to: dockerfile)

        let compose = dir.appendingPathComponent("docker-compose.yml")
        try write("""
        version: '3'
        services:
          app:
            build:
              context: .
              dockerfile: Dockerfile
            container_name: compose_build_app
        """, to: compose)

        // Up
        let (_, _, upStatus) = try run(arguments: ["compose", "-f", compose.path, "up", "-d"], currentDirectory: dir)
        #expect(upStatus == 0)

        // Check running
        let status = try getContainerStatus("compose_build_app")
        #expect(status == "running")

        // Down
        let (_, _, downStatus) = try run(arguments: ["compose", "-f", compose.path, "down"], currentDirectory: dir)
        #expect(downStatus == 0)
    }

    @Test
    func testBuildWithImageTagging() throws {
        guard shouldRunE2E() else { return #expect(Bool(true)) }

        let dir = testDir
        let dockerfile = dir.appendingPathComponent("Dockerfile")
        try write("""
        FROM alpine:3.19
        CMD ["sleep","60"]
        """.trimmingCharacters(in: .whitespacesAndNewlines), to: dockerfile)

        let compose = dir.appendingPathComponent("docker-compose.yml")
        try write("""
        version: '3'
        services:
          app:
            image: e2e:test
            build:
              context: .
              dockerfile: Dockerfile
            container_name: compose_build_image_app
        """, to: compose)

        // Up
        let (_, _, upStatus) = try run(arguments: ["compose", "-f", compose.path, "up", "-d"], currentDirectory: dir)
        #expect(upStatus == 0)

        // Check running
        let status = try getContainerStatus("compose_build_image_app")
        #expect(status == "running")

        // Down
        let (_, _, downStatus) = try run(arguments: ["compose", "-f", compose.path, "down"], currentDirectory: dir)
        #expect(downStatus == 0)
    }
}
