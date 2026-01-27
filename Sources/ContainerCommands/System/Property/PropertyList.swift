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
import ContainerPersistence
import Foundation

extension Application {
    public struct PropertyList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List system properties",
            aliases: ["ls"]
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: .shortAndLong, help: "Only output the property ID")
        var quiet = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let vals = DefaultsStore.allValues()
            try printValues(vals, format: format)
        }

        private func createHeader() -> [[String]] {
            [["ID", "TYPE", "VALUE", "DESCRIPTION"]]
        }

        private func printValues(_ vals: [DefaultsStoreValue], format: ListFormat) throws {
            if format == .json {
                let data = try JSONEncoder().encode(vals)
                print(String(data: data, encoding: .utf8)!)
                return
            }

            if self.quiet {
                vals.forEach {
                    print($0.id)
                }
                return
            }

            var rows = createHeader()
            for property in vals {
                rows.append(property.asRow)
            }

            let formatter = TableOutput(rows: rows)
            print(formatter.format())
        }
    }
}

extension DefaultsStoreValue {
    var asRow: [String] {
        [id, String(describing: type), value?.description.elided(to: 40) ?? "*undefined*", description]
    }
}

extension String {
    func elided(to maxCount: Int) -> String {
        let ellipsis = "..."
        guard self.count > maxCount else {
            return self
        }

        if maxCount < ellipsis.count {
            return ellipsis
        }

        let prefixCount = maxCount - ellipsis.count
        return self.prefix(prefixCount) + ellipsis
    }
}
