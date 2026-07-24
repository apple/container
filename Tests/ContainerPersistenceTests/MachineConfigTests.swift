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

import ContainerPersistence
import ContainerizationError
import Foundation
import SystemPackage
import Testing

struct MachineConfigTests {
    @Test func virtualizationDefaultsToFalse() throws {
        let config = MachineConfig.default
        #expect(config.virtualization == false)
        #expect(config.kernelPath == nil)
    }

    @Test func withSetsVirtualizationTrue() throws {
        let updated = try MachineConfig.default.with(["virtualization": "true"])
        #expect(updated.virtualization == true)
    }

    @Test func withSetsVirtualizationFalse() throws {
        let enabled = try MachineConfig.default.with(["virtualization": "true"])
        let cleared = try enabled.with(["virtualization": "false"])
        #expect(cleared.virtualization == false)
    }

    @Test func withRejectsBogusBoolean() {
        #expect(throws: ContainerizationError.self) {
            try MachineConfig.default.with(["virtualization": "yes"])
        }
    }

    @Test func withSetsKernelPath() throws {
        let updated = try MachineConfig.default.with(["kernel": "/opt/kernels/vmlinux"])
        #expect(updated.kernelPath == FilePath("/opt/kernels/vmlinux"))
    }

    @Test func withEmptyKernelClearsKernelPath() throws {
        let withCustom = try MachineConfig.default.with(["kernel": "/opt/kernels/vmlinux"])
        #expect(withCustom.kernelPath == FilePath("/opt/kernels/vmlinux"))
        let cleared = try withCustom.with(["kernel": ""])
        #expect(cleared.kernelPath == nil)
    }

    @Test func withPreservesUnchangedFields() throws {
        let updated = try MachineConfig.default.with([
            "virtualization": "true",
            "kernel": "/opt/kernels/vmlinux",
        ])
        #expect(updated.cpus == MachineConfig.default.cpus)
        #expect(updated.memory.toUInt64(unit: .bytes) == MachineConfig.default.memory.toUInt64(unit: .bytes))
        #expect(updated.homeMount == MachineConfig.default.homeMount)
    }

    @Test func decodingMissingFieldsUsesDefaults() throws {
        // Older boot-config.json files predate virtualization/kernel — they must still load.
        let legacy = #"{"cpus":4,"memory":"1gb","homeMount":"rw"}"#
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode(MachineConfig.self, from: data)
        #expect(decoded.cpus == 4)
        #expect(decoded.virtualization == false)
        #expect(decoded.kernelPath == nil)
    }

    @Test func roundTripJSON() throws {
        let config = try MachineConfig.default.with([
            "virtualization": "true",
            "kernel": "/some/vmlinux",
        ])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MachineConfig.self, from: data)
        #expect(decoded.virtualization == true)
        #expect(decoded.kernelPath == FilePath("/some/vmlinux"))
    }

    @Test func settableKeysIncludeNewFields() {
        let keys = MachineConfig.settableKeys.map(\.key)
        #expect(keys.contains("virtualization"))
        #expect(keys.contains("kernel"))
    }

    // MARK: - Mounts

    /// Creates a temporary directory and removes it once `body` completes.
    private func withTemporaryDirectory(_ body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url.path)
    }

    @Test func mountsDefaultToEmpty() {
        #expect(MachineConfig.default.mounts.isEmpty)
    }

    @Test func withParsesReadWriteMount() throws {
        try withTemporaryDirectory { source in
            let updated = try MachineConfig.default.with([:], mounts: ["\(source):/data"])
            #expect(updated.mounts.count == 1)
            #expect(updated.mounts[0].destination == "/data")
            #expect(updated.mounts[0].readOnly == false)
        }
    }

    @Test func withParsesReadOnlyMount() throws {
        try withTemporaryDirectory { source in
            let updated = try MachineConfig.default.with([:], mounts: ["\(source):/data:ro"])
            #expect(updated.mounts[0].readOnly == true)
        }
    }

    @Test func withParsesMultipleMounts() throws {
        try withTemporaryDirectory { source in
            let updated = try MachineConfig.default.with([:], mounts: ["\(source):/a", "\(source):/b:ro"])
            #expect(updated.mounts.map(\.destination) == ["/a", "/b"])
        }
    }

    @Test func nilMountsPreservesExisting() throws {
        try withTemporaryDirectory { source in
            let withMount = try MachineConfig.default.with([:], mounts: ["\(source):/data"])
            let unchanged = try withMount.with(["cpus": "4"])
            #expect(unchanged.mounts.count == 1)
            #expect(unchanged.cpus == 4)
        }
    }

    @Test func withRejectsInvalidMountMode() throws {
        try withTemporaryDirectory { source in
            #expect(throws: ContainerizationError.self) {
                try MachineConfig.default.with([:], mounts: ["\(source):/data:rx"])
            }
        }
    }

    @Test func withRejectsMissingSource() {
        #expect(throws: ContainerizationError.self) {
            try MachineConfig.default.with([:], mounts: ["/does/not/exist:/data"])
        }
    }

    @Test func withRejectsRelativeDestination() throws {
        try withTemporaryDirectory { source in
            #expect(throws: ContainerizationError.self) {
                try MachineConfig.default.with([:], mounts: ["\(source):data"])
            }
        }
    }

    @Test func withRejectsMalformedMount() throws {
        try withTemporaryDirectory { source in
            #expect(throws: ContainerizationError.self) {
                try MachineConfig.default.with([:], mounts: [source])
            }
        }
    }

    @Test func withRejectsDuplicateDestinations() throws {
        try withTemporaryDirectory { source in
            #expect(throws: ContainerizationError.self) {
                try MachineConfig.default.with([:], mounts: ["\(source):/data", "\(source):/data:ro"])
            }
        }
    }

    @Test func mountsRoundTripJSON() throws {
        try withTemporaryDirectory { source in
            let config = try MachineConfig.default.with([:], mounts: ["\(source):/data:ro"])
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(MachineConfig.self, from: data)
            #expect(decoded.mounts.count == 1)
            #expect(decoded.mounts[0].destination == "/data")
            #expect(decoded.mounts[0].readOnly == true)
        }
    }

    @Test func decodingMissingMountsUsesEmpty() throws {
        // Boot configs written before user mounts existed have no `mounts` key.
        let legacy = #"{"cpus":4,"memory":"1gb","homeMount":"rw"}"#
        let decoded = try JSONDecoder().decode(MachineConfig.self, from: Data(legacy.utf8))
        #expect(decoded.mounts.isEmpty)
    }
}
