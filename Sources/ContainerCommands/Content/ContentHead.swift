//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import ContainerImagesServiceClient
import ContainerizationError
import Foundation

extension Application {
    public struct ContentHead: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "head",
            abstract: "Display metadata about a blob in the content store"
        )

        @OptionGroup
        var global: Flags.Global

        @Option(name: .long, help: "Format of the output (json or table)")
        var format: ListFormat = .table

        @Argument(help: "Blob digest to inspect")
        var digest: String

        public func run() async throws {
            let client = RemoteContentStoreClient()
            guard let content = try await client.get(digest: digest) else {
                throw ContainerizationError(.notFound, message: "blob \(digest)")
            }

            let size = try content.size()

            if format == .json {
                struct BlobInfo: Codable {
                    let digest: String
                    let size: UInt64
                }
                let info = BlobInfo(digest: digest, size: size)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(info)
                guard let jsonString = String(data: data, encoding: .utf8) else {
                    throw ContainerizationError(.internalError, message: "Failed to encode JSON output")
                }
                print(jsonString)
            } else {
                // Machine-readable default: digest-size
                print("\(digest)-\(size)")
            }
        }
    }
}
