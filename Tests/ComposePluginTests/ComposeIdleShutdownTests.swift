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

@Suite("Compose idle shutdown")
struct ComposeIdleShutdownTests {
    @Test
    func disabledByDefault() throws {
        let result = try runScript(
            dockerScript: "#!/bin/sh\nexit 0\n",
            dateScript: "#!/bin/sh\nprintf '601\\n'\n",
            timeout: "0",
            runOnce: false
        )

        #expect(result.status == 0)
        #expect(result.systemctlOutput.isEmpty)
    }

    @Test
    func powersOffAfterTenMinutesWithoutContainers() throws {
        let result = try runScript(
            dockerScript: "#!/bin/sh\nexit 0\n",
            dateScript: """
                #!/bin/sh
                count=$(cat "$COMPOSE_IDLE_SHUTDOWN_DATE_STATE")
                if [ "$count" -eq 0 ]; then
                    printf '0\\n'
                else
                    printf '601\\n'
                fi
                printf '%s\\n' "$((count + 1))" > "$COMPOSE_IDLE_SHUTDOWN_DATE_STATE"
                """,
            timeout: "600",
            runOnce: false
        )

        #expect(result.status == 0)
        #expect(result.systemctlOutput == "poweroff --no-wall\n")
    }

    @Test
    func doesNotPowerOffWhileAContainerIsRunning() throws {
        let result = try runScript(
            dockerScript: "#!/bin/sh\nprintf 'container-id\\n'\n",
            dateScript: "#!/bin/sh\nprintf '601\\n'\n",
            timeout: "600",
            runOnce: true
        )

        #expect(result.status == 0)
        #expect(result.systemctlOutput.isEmpty)
    }

    @Test
    func connectedDockerClientPreventsShutdown() throws {
        let result = try runScript(
            dockerScript: "#!/bin/sh\nexit 0\n",
            dateScript: "#!/bin/sh\nprintf '0\\n'\n",
            unixSocketsContent: "00000000: 00000003 00000000 00000000 0001 03 123 /etc/docker/docker.sock\\n",
            timeout: "600",
            runOnce: true
        )

        #expect(result.status == 0)
        #expect(result.systemctlOutput.isEmpty)
    }

    private struct ScriptResult {
        let status: Int32
        let systemctlOutput: String
    }

    private func runScript(
        dockerScript: String,
        dateScript: String,
        unixSocketsContent: String = "",
        timeout: String,
        runOnce: Bool
    ) throws -> ScriptResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent(
            "Sources/ContainerCompose/Resources/container-compose-idle-shutdown"
        )
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("compose-idle-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let docker = temp.appendingPathComponent("docker")
        let date = temp.appendingPathComponent("date")
        let systemctl = temp.appendingPathComponent("systemctl")
        let systemctlLog = temp.appendingPathComponent("systemctl.log")
        let dateState = temp.appendingPathComponent("date.state")
        let unixSockets = temp.appendingPathComponent("unix")

        try Data(dockerScript.utf8).write(to: docker)
        try Data(dateScript.utf8).write(to: date)
        try Data(unixSocketsContent.utf8).write(to: unixSockets)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$COMPOSE_IDLE_SHUTDOWN_SYSTEMCTL_LOG\"\n".utf8)
            .write(to: systemctl)
        try Data("0\n".utf8).write(to: dateState)
        for url in [docker, date, systemctl] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: url.path
            )
        }

        var environment = ProcessInfo.processInfo.environment
        environment["COMPOSE_IDLE_SHUTDOWN_DOCKER_BIN"] = docker.path
        environment["COMPOSE_IDLE_SHUTDOWN_DATE_BIN"] = date.path
        environment["COMPOSE_IDLE_SHUTDOWN_UNIX_SOCKETS_FILE"] = unixSockets.path
        environment["COMPOSE_IDLE_SHUTDOWN_SYSTEMCTL_BIN"] = systemctl.path
        environment["COMPOSE_IDLE_SHUTDOWN_SLEEP_BIN"] = "/bin/sleep"
        environment["COMPOSE_IDLE_SHUTDOWN_IDLE_SECONDS"] = timeout
        environment["COMPOSE_IDLE_SHUTDOWN_INTERVAL_SECONDS"] = "0"
        environment["COMPOSE_IDLE_SHUTDOWN_SYSTEMCTL_LOG"] = systemctlLog.path
        environment["COMPOSE_IDLE_SHUTDOWN_DATE_STATE"] = dateState.path
        if runOnce {
            environment["COMPOSE_IDLE_SHUTDOWN_RUN_ONCE"] = "1"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let output =
            FileManager.default.fileExists(atPath: systemctlLog.path)
            ? try String(contentsOf: systemctlLog, encoding: .utf8)
            : ""
        return ScriptResult(status: process.terminationStatus, systemctlOutput: output)
    }
}
