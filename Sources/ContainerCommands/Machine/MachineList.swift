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
import ContainerResource
import Foundation
import MachineAPIClient

extension Application {
    public struct MachineList: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List container machines",
            aliases: ["ls"]
        )

        @Option(name: .long, help: "Format of the output")
        var format: MachineCommand.ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the container machine ID")
        var quiet = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let client = MachineClient()
            let machines = try await client.list()

            if self.quiet {
                machines.forEach { print($0.id) }
                return
            }

            let defaultMachine = try await client.getDefault()
            try printMachines(machines: machines, format: format, defaultMachine: defaultMachine)
        }

        private func printMachines(
            machines: [MachineSnapshot],
            format: MachineCommand.ListFormat,
            defaultMachine: String?
        ) throws {
            if format == .json {
                let printables = machines.map {
                    PrintableMachine($0, isDefault: $0.id == defaultMachine)
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(printables)
                print(String(decoding: data, as: UTF8.self))
                return
            }

            var rows: [[String]] = [["NAME", "CREATED", "IP", "CPUS", "MEMORY", "DISK", "STATE", "DEFAULT"]]
            for machine in machines {
                rows.append([
                    machine.id,
                    machine.createdDate.map { formatDate($0) } ?? "-",
                    machine.ipAddress ?? "-",
                    "\(machine.bootConfig.cpus)",
                    formatMemory(machine.bootConfig.memory.toUInt64(unit: .bytes)),
                    machine.diskSize.map { formatMemory($0) } ?? "-",
                    machine.status.rawValue,
                    machine.id == defaultMachine ? "*" : "",
                ])
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }
    }
}

private func formatMemory(_ bytes: UInt64) -> String {
    let gib: UInt64 = 1024 * 1024 * 1024
    if bytes >= gib {
        if bytes % gib == 0 {
            return "\(bytes / gib)G"
        }
        let formatted = String(format: "%.1fG", Double(bytes) / Double(gib))
        if formatted.hasSuffix(".0G") {
            return "\(bytes / gib)G"
        }
        return formatted
    }
    return "\(bytes / (1024 * 1024))M"
}

private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

private func formatDate(_ date: Date) -> String {
    dateFormatter.string(from: date)
}

private struct PrintableMachine: Codable {
    let id: String
    let status: RuntimeStatus
    let `default`: Bool
    let ipAddress: String?
    let cpus: Int
    let memory: UInt64
    let diskSize: UInt64?
    let createdDate: Date?

    init(_ machine: MachineSnapshot, isDefault: Bool) {
        self.id = machine.id
        self.status = machine.status
        self.default = isDefault
        self.ipAddress = machine.ipAddress
        self.cpus = machine.bootConfig.cpus
        self.memory = machine.bootConfig.memory.toUInt64(unit: .bytes)
        self.diskSize = machine.diskSize
        self.createdDate = machine.createdDate
    }
}
