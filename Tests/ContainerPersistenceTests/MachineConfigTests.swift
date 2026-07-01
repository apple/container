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
        #expect(keys.contains("network"))
    }

    @Test func networksDefaultToEmpty() {
        #expect(MachineConfig.default.networks.isEmpty)
    }

    @Test func withReplacesNetworks() throws {
        let updated = try MachineConfig.default.with([:], networks: ["default", "lan,ip=192.168.1.50"])
        #expect(updated.networks == ["default", "lan,ip=192.168.1.50"])
    }

    @Test func withNilNetworksPreservesExisting() throws {
        let withNets = try MachineConfig.default.with([:], networks: ["lan"])
        // A scalar update (networks omitted) must not clear the network list.
        let updated = try withNets.with(["cpus": "4"])
        #expect(updated.networks == ["lan"])
        #expect(updated.cpus == 4)
    }

    @Test func withEmptyNetworksResetsToDefault() throws {
        let withNets = try MachineConfig.default.with([:], networks: ["lan"])
        let reset = try withNets.with([:], networks: [])
        #expect(reset.networks.isEmpty)
    }

    @Test func decodingMissingNetworksUsesEmpty() throws {
        // Boot-config.json written before machine networking must still load.
        let legacy = #"{"cpus":4,"memory":"1gb","homeMount":"rw"}"#
        let decoded = try JSONDecoder().decode(MachineConfig.self, from: Data(legacy.utf8))
        #expect(decoded.networks.isEmpty)
    }

    @Test func roundTripJSONNetworks() throws {
        let config = try MachineConfig.default.with([:], networks: ["lan,ip=192.168.1.50", "default"])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MachineConfig.self, from: data)
        #expect(decoded.networks == ["lan,ip=192.168.1.50", "default"])
    }

    @Test func settableKeysIncludeKernelArg() {
        #expect(MachineConfig.settableKeys.map(\.key).contains("kernel-arg"))
    }

    @Test func kernelArgsDefaultToEmpty() {
        #expect(MachineConfig.default.kernelArgs.isEmpty)
    }

    @Test func withReplacesKernelArgs() throws {
        let updated = try MachineConfig.default.with([:], kernelArgs: ["quiet", "console=ttyS0"])
        #expect(updated.kernelArgs == ["quiet", "console=ttyS0"])
    }

    @Test func withNilKernelArgsPreservesExisting() throws {
        let withArgs = try MachineConfig.default.with([:], kernelArgs: ["quiet"])
        let updated = try withArgs.with(["cpus": "4"])
        #expect(updated.kernelArgs == ["quiet"])
    }

    @Test func withEmptyKernelArgsClears() throws {
        let withArgs = try MachineConfig.default.with([:], kernelArgs: ["quiet"])
        let cleared = try withArgs.with([:], kernelArgs: [])
        #expect(cleared.kernelArgs.isEmpty)
    }

    @Test func decodingMissingKernelArgsUsesEmpty() throws {
        let legacy = #"{"cpus":4,"memory":"1gb","homeMount":"rw"}"#
        let decoded = try JSONDecoder().decode(MachineConfig.self, from: Data(legacy.utf8))
        #expect(decoded.kernelArgs.isEmpty)
    }

    @Test func roundTripJSONKernelArgs() throws {
        let config = try MachineConfig.default.with([:], kernelArgs: ["quiet", "loglevel=3"])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MachineConfig.self, from: data)
        #expect(decoded.kernelArgs == ["quiet", "loglevel=3"])
    }
}
