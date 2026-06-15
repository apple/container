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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Foundation
import MachineAPIClient

extension Application {
    public struct MachineInspect: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display detailed information about a container machine"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container machine ID (uses default if not specified)")
        var id: String?

        public func run() async throws {
            let client = MachineClient()
            let machineId = try await resolveMachineId(id, client: client)
            let snapshot = try await client.inspect(id: machineId)

            let output = InspectOutput(snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode([output])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}

private struct InspectOutput: Codable {
    let id: String
    let image: ImageDescription
    let platform: ContainerizationOCI.Platform
    let userSetup: UserSetup
    let status: RuntimeStatus
    let startedDate: Date?
    let createdDate: Date?
    let containerId: String?
    let cpus: Int
    let memory: UInt64
    let homeMount: MachineConfig.HomeMountOption
    let diskSize: UInt64?
    let ipAddress: String?

    init(_ snapshot: MachineSnapshot) {
        self.id = snapshot.id
        self.image = snapshot.configuration.image
        self.platform = snapshot.platform
        self.userSetup = snapshot.configuration.userSetup
        self.status = snapshot.status
        self.startedDate = snapshot.startedDate
        self.createdDate = snapshot.createdDate
        self.containerId = snapshot.containerId
        self.cpus = snapshot.bootConfig.cpus
        self.memory = snapshot.bootConfig.memory.toUInt64(unit: .bytes)
        self.homeMount = snapshot.bootConfig.homeMount
        self.diskSize = snapshot.diskSize
        self.ipAddress = snapshot.ipAddress
    }
}
