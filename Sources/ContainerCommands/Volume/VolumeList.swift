//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import ContainerizationExtras
import Foundation

extension Application.VolumeCommand {
    public struct VolumeList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List volumes",
            aliases: ["ls"]
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the volume name")
        var quiet: Bool = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let volumes = try await ClientVolume.list()

            if format == .json {
                try emit(renderJSON(volumes))
                return
            }

            // Sort by creation time (newest first) for table display only,
            // matching the original behavior where JSON and quiet emit unsorted.
            let items = quiet ? volumes : volumes.sorted { $0.createdAt > $1.createdAt }
            emit(renderList(items.map { PrintableVolume($0) }, quiet: quiet))
        }
    }
}

private struct PrintableVolume: ListDisplayable {
    let name: String
    let volumeType: String
    let driver: String
    let optionsString: String

    init(_ volume: Volume) {
        self.name = volume.name
        self.volumeType = volume.isAnonymous ? "anonymous" : "named"
        self.driver = volume.driver
        self.optionsString =
            volume.options.isEmpty
            ? ""
            : volume.options.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    static var tableHeader: [String] {
        ["NAME", "TYPE", "DRIVER", "OPTIONS"]
    }

    var tableRow: [String] {
        [name, volumeType, driver, optionsString]
    }

    var quietValue: String {
        name
    }
}
