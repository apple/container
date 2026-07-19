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

import Containerization
import Foundation
import MachineAPIClient
import Testing

@Suite
struct TestCLIMachineCommand {
    private let machineImage = "ghcr.io/linuxcontainers/alpine:3.20"

    @Test func testCreate() async throws {
        try await ContainerFixture.with { f in
            let name = "\(f.testID)-machine"
            f.addCleanup { f.cleanupMachine(name) }
            try f.doMachineCreate(name: name, image: machineImage)
            try f.doMachineRemove(name: name)
        }
    }

    @Test func testCreateRejectsDots() async throws {
        try await ContainerFixture.with { f in
            let result = try f.runMachine(["create", "--name", "my.bad.name", machineImage])
            #expect(result.status != 0, "create should reject names with dots")
            #expect(result.error.contains("must start and end"), "error should explain the constraint")
        }
    }

    @Test func testCreateNameLongestValid() async {
        await withKnownIssue("XPC timeout on machine-apiserver.bootMachine", isIntermittent: true) {
            try await ContainerFixture.with { f in
                let maxNameLength = LinuxContainer.maxIDLength - MachineConfiguration.containerUUIDLength - 1
                let name = String(repeating: "a", count: maxNameLength)
                f.addCleanup { f.cleanupMachine(name) }
                try f.doMachineCreate(name: name, image: machineImage)
                try f.doMachineBoot(name: name)
            }
        }
    }

    @Test func testCreateNameLongerThanMax() async throws {
        try await ContainerFixture.with { f in
            let maxNameLength = LinuxContainer.maxIDLength - MachineConfiguration.containerUUIDLength - 1
            let name = String(repeating: "a", count: maxNameLength + 1)
            let result = try f.runMachine(["create", "--no-boot", "--name", name, machineImage])
            #expect(result.status != 0, "create should reject names longer than max")
        }
    }
}
