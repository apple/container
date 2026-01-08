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
import Crypto
import Foundation

extension Application {
    public struct ContentIngest: AsyncParsableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "ingest",
            abstract: "Add a blob to the content store from a file or stdin"
        )

        @OptionGroup
        var global: Flags.Global

        @Option(name: .shortAndLong, help: "Path to read content from (reads from stdin if not specified)")
        var input: String?

        @Option(name: .shortAndLong, help: "Expected blob digest (computed and verified if not provided)")
        var digest: String?

        public func run() async throws {
            let client = RemoteContentStoreClient()
            let inputPath = self.input
            let expectedDigest = self.digest

            // Show hint when reading from stdin
            if inputPath == nil {
                FileHandle.standardError.write(Data("Reading from stdin...\n".utf8))
            }

            // Start a new ingest session
            let (sessionId, ingestDir) = try await client.newIngestSession()

            // Hash the data as we ingest it
            var hasher = SHA256()
            var ingestedDigest: String = ""

            do {
                // Determine temporary digest for filename (use expected or placeholder)
                let tempDigestForFilename: String
                if let expected = expectedDigest {
                    tempDigestForFilename = expected.replacingOccurrences(of: "sha256:", with: "")
                } else {
                    // Use a temporary name, we'll compute the real digest
                    tempDigestForFilename = "temp-\(UUID().uuidString)"
                }

                let blobPath = ingestDir.appendingPathComponent(tempDigestForFilename)

                // Open source handle
                let sourceHandle: FileHandle
                if let inputPath = inputPath {
                    let inputURL = URL(fileURLWithPath: inputPath)
                    sourceHandle = try FileHandle(forReadingFrom: inputURL)
                } else {
                    sourceHandle = FileHandle.standardInput
                }
                defer {
                    if inputPath != nil {
                        try? sourceHandle.close()
                    }
                }

                // Create destination file
                FileManager.default.createFile(atPath: blobPath.path, contents: nil)
                let destHandle = try FileHandle(forWritingTo: blobPath)
                defer { try? destHandle.close() }

                // Stream data while computing hash
                let bufferSize = 1024 * 1024 // 1 MB
                while let chunk = try sourceHandle.read(upToCount: bufferSize), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    try destHandle.write(contentsOf: chunk)
                }

                // Compute final digest
                let digestValue = hasher.finalize()
                ingestedDigest = "sha256:\(digestValue.map { String(format: "%02x", $0) }.joined())"

                // Verify against expected digest if provided
                if let expectedDigest = expectedDigest {
                    if ingestedDigest != expectedDigest {
                        // Digest mismatch - cancel ingest
                        try await client.cancelIngestSession(sessionId)
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "Digest mismatch: expected \(expectedDigest), got \(ingestedDigest)"
                        )
                    }
                }

                // If we used a temp filename, rename it to the correct digest
                if tempDigestForFilename.starts(with: "temp-") {
                    let correctDigestFilename = ingestedDigest.replacingOccurrences(of: "sha256:", with: "")
                    let correctBlobPath = ingestDir.appendingPathComponent(correctDigestFilename)
                    try FileManager.default.moveItem(at: blobPath, to: correctBlobPath)
                }

                // Complete the ingest session
                let ingested = try await client.completeIngestSession(sessionId)
                let digestWithoutPrefix = ingestedDigest.replacingOccurrences(of: "sha256:", with: "")

                guard ingested.contains(digestWithoutPrefix) else {
                    throw ContainerizationError(
                        .internalError,
                        message: "ingested blob not found in content store"
                    )
                }

                print("Ingested \(ingestedDigest)")

            } catch {
                // Cancel the ingest session on any error
                try? await client.cancelIngestSession(sessionId)
                throw error
            }
        }
    }
}
