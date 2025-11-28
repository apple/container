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
    public struct ContentDelete: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Remove a blob from the content store",
            aliases: ["rm"]
        )

        @OptionGroup
        var global: Flags.Global

        @Argument(help: "Blob digest to delete")
        var digest: String

        public func run() async throws {
            let client = RemoteContentStoreClient()
            let digestWithoutPrefix = digest.replacingOccurrences(of: "sha256:", with: "")
            let (deleted, size) = try await client.delete(digests: [digestWithoutPrefix])

            guard deleted.contains(digestWithoutPrefix) else {
                throw ContainerizationError(.notFound, message: "blob \(digest)")
            }

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let freed = formatter.string(fromByteCount: Int64(size))

            print("Deleted \(digest)")
            print("Reclaimed \(freed) in disk space")
        }
    }
}
