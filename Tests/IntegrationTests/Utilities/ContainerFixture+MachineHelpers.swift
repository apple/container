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

// MARK: - Machine output types

struct MachineListItem: Codable {
    let id: String
    let status: String
    let `default`: Bool
    let ipAddress: String?
    let cpus: Int
    let memory: UInt64
    let diskSize: UInt64?
    let createdDate: Date?
}

struct MachineInspectOutput: Codable {
    let id: String
    let image: ImageDescription
    let platform: Platform
    let status: String
    let startedDate: Date?
    let createdDate: Date?
    let containerId: String?
    let cpus: Int
    let memory: UInt64
    let homeMount: String?
    let diskSize: UInt64?
    let ipAddress: String?

    struct ImageDescription: Codable {
        let reference: String
    }

    struct Platform: Codable {
        let os: String
        let architecture: String
    }
}

// MARK: - Machine lifecycle helpers

extension ContainerFixture {

    /// Runs `container machine <arguments>` and returns the result.
    func runMachine(_ arguments: [String], env: [String: String] = [:]) throws -> CommandResult {
        try run(["machine"] + arguments, env: env, pty: true)
    }

    /// Creates a machine without booting it.
    func doMachineCreate(name: String, image: String, extraArgs: [String] = []) throws {
        var args = ["create", "--no-boot", "--name", name]
        args += extraArgs
        args.append(image)
        try runMachine(args).check()
    }

    /// Boots a machine by running a trivial command (which auto-boots).
    func doMachineBoot(name: String) throws {
        try runMachine(["run", "--root", "-n", name, "true"]).check()
    }

    /// Stops a machine and returns the output (the machine name).
    @discardableResult
    func doMachineStop(name: String) throws -> String {
        let result = try runMachine(["stop", name]).check()
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a machine.
    func doMachineRemove(name: String) throws {
        try runMachine(["rm", name]).check()
    }

    /// Silently stops and removes a machine, ignoring errors.
    func cleanupMachine(_ name: String) {
        _ = try? runMachine(["stop", name])
        _ = try? runMachine(["rm", name])
    }

    /// Inspects a machine and decodes the JSON output.
    func doMachineInspect(name: String? = nil) throws -> MachineInspectOutput {
        var args = ["inspect"]
        if let name { args.append(name) }
        let result = try runMachine(args).check()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let results = try decoder.decode([MachineInspectOutput].self, from: result.outputData)
        guard let first = results.first else {
            throw CommandError.executionFailed("machine inspect returned empty array")
        }
        return first
    }

    /// Runs a command inside a machine and returns its stdout.
    @discardableResult
    func doMachineRun(
        name: String,
        root: Bool = false,
        env: [String] = [],
        cwd: String? = nil,
        command: [String]
    ) throws -> String {
        var args = ["run", "-n", name]
        if root { args.append("--root") }
        if let cwd { args += ["--cwd", cwd] }
        for e in env { args += ["-e", e] }
        args += command
        let result = try runMachine(args).check()
        return result.output
    }

    /// Polls machine inspect until the status matches or the attempt limit is reached.
    func waitForMachineStatus(_ name: String, status: String, maxAttempts: Int = 30) async throws {
        for _ in 0..<maxAttempts {
            let snapshot = try doMachineInspect(name: name)
            if snapshot.status == status { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw CommandError.executionFailed("machine '\(name)' did not reach status '\(status)' within \(maxAttempts)s")
    }
}
