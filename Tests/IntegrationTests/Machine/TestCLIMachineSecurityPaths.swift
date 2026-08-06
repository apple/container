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
import Containerization
import Foundation
import Testing

@Suite
struct TestCLIMachineSecurityPaths {
    private let machineImage = WarmupImage.alpine320.rawValue

    /// Mount points inside the machine. A masked path is a bind mount of
    /// /dev/null (files) or an empty tmpfs (directories), and a read-only path
    /// is a bind mount of itself, so every applied path appears in /proc/mounts.
    private func mountPoints(_ f: ContainerFixture, _ name: String) throws -> Set<String> {
        let mounts = try f.doMachineRun(name: name, root: true, command: ["cat", "/proc/mounts"])
        return Set(
            mounts.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ")
                return fields.count > 1 ? String(fields[1]) : nil
            })
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Invalid paths

    @Test func testMachineCreateRejectsRelativePaths() async throws {
        try await ContainerFixture.with { f in
            let masked = try f.runMachine(["create", "--no-boot", "--name", "rel-masked", "--masked-path", "proc/kcore", machineImage])
            #expect(masked.status != 0)
            #expect(masked.error.contains("proc/kcore"))

            let readonly = try f.runMachine(["create", "--no-boot", "--name", "rel-readonly", "--read-only-path", "proc/sys", machineImage])
            #expect(readonly.status != 0)
            #expect(readonly.error.contains("proc/sys"))
        }
    }

    // MARK: - Paths added on top of the defaults

    @Test func testMachineCreateAppliesMaskedAndReadOnlyPaths() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }

            try f.doMachineCreate(
                name: name,
                image: machineImage,
                extraArgs: ["--masked-path", "/etc/alpine-release", "--read-only-path", "/bin"]
            )

            // The persisted machine configuration captures the paths, and they
            // are applied on top of the runtime defaults.
            let inspect = try f.doMachineInspect(name: name)
            #expect(inspect.maskedPaths == LinuxContainer.defaultMaskedPaths() + ["/etc/alpine-release"])
            #expect(inspect.readonlyPaths == LinuxContainer.defaultReadonlyPaths() + ["/bin"])

            // Boot the machine (doMachineRun auto-boots it) and verify the paths
            // are active inside the guest.
            let mounted = try mountPoints(f, name)
            #expect(mounted.contains("/etc/alpine-release"))
            #expect(mounted.contains("/bin"))

            // A masked file is replaced with /dev/null, so it reads as empty.
            let size = try f.doMachineRun(
                name: name, root: true, command: ["sh", "-c", "wc -c < /etc/alpine-release"])
            #expect(trimmed(size) == "0")
        }
    }

    // MARK: - NONE sentinel

    @Test func testMachineCreateNoneClearsDefaults() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine-none"
            f.addCleanup { f.cleanupMachine(name) }

            try f.doMachineCreate(
                name: name,
                image: machineImage,
                extraArgs: ["--masked-path", "NONE", "--read-only-path", "NONE"]
            )

            let inspect = try f.doMachineInspect(name: name)
            #expect(inspect.maskedPaths == [])
            #expect(inspect.readonlyPaths == [])
        }
    }
}
