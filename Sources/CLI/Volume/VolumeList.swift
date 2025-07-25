//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import ContainerClient
import ContainerizationExtras
import Foundation

extension Application.VolumeCommand {
    struct VolumeList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List volumes",
            aliases: ["ls"]
        )

        @Option(name: .long, help: "Provide filter values (e.g., 'dangling=true')")
        var filter: [String] = []

        @Flag(name: .shortAndLong, help: "Only display volume names")
        var quiet: Bool = false

        @Option(name: .long, help: "Format of the output")
        var format: Application.ListFormat = .table

        func run() async throws {
            let response = try await ClientVolume.list()
            let parsedFilters = Utility.parseKeyValuePairs(filter)

            let filteredVolumes = response.volumes.filter { volume in
                for (key, value) in parsedFilters {
                    switch key {
                    case "name":
                        if !volume.name.contains(value) && volume.name != value { return false }
                    case "driver":
                        if volume.driver != value { return false }
                    case "label":
                        if value.isEmpty {
                            if volume.labels.isEmpty { return false }
                        } else if let labelValue = volume.labels[value] {
                            if labelValue.isEmpty { return false }
                        } else {
                            return false
                        }
                    default:
                        break
                    }
                }
                return true
            }

            try printVolumes(volumes: filteredVolumes, format: format)
        }

        private func createHeader() -> [[String]] {
            [["NAME", "DRIVER", "OPTIONS"]]
        }

        private func printVolumes(volumes: [Volume], format: Application.ListFormat) throws {
            if format == .json {
                let data = try JSONEncoder().encode(volumes)
                print(String(data: data, encoding: .utf8)!)
                return
            }

            if quiet {
                volumes.forEach {
                    print($0.name)
                }
                return
            }

            var rows = createHeader()
            for volume in volumes {
                rows.append(volume.asRow)
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }
    }
}

extension Volume {
    var asRow: [String] {
        let optionsString = options.isEmpty ? "" : options.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return [
            self.name,
            self.driver,
            optionsString,
        ]
    }
}
