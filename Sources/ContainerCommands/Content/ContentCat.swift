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
    public struct ContentCat: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "cat",
            abstract: "Output the contents of a blob from the content store"
        )

        @OptionGroup
        var global: Flags.Global

        @Option(name: .shortAndLong, help: "Path to write blob content (writes to stdout if not specified)")
        var output: String?

        @Argument(help: "Blob digest to output")
        var digest: String

        public func run() async throws {
            let client = RemoteContentStoreClient()
            guard let content = try await client.get(digest: digest) else {
                throw ContainerizationError(.notFound, message: "blob \(digest)")
            }

            let data = try content.data()

            if let outputPath = output {
                let outputURL = URL(fileURLWithPath: outputPath)
                try data.write(to: outputURL)

                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let formattedSize = formatter.string(fromByteCount: Int64(data.count))

                print("Wrote \(formattedSize) to \(outputPath)")
            } else {
                FileHandle.standardOutput.write(data)
            }
        }
    }
}
