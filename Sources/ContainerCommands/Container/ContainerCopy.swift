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
import ContainerizationError
import Foundation
import Containerization

extension Application {
    public struct ContainerCopy: AsyncLoggableCommand {
        enum PathRef {
            case local(String)
            case container(id: String, path: String)
        }

        static func parsePathRef(_ ref: String) -> PathRef {
            if let colonIdx = ref.firstIndex(of: ":") {
                let id = String(ref[ref.startIndex..<colonIdx])
                let path = String(ref[ref.index(after: colonIdx)...])
                if !id.isEmpty && !path.isEmpty {
                    return .container(id: id, path: path)
                }
            }
            return .local(ref)
        }

        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "copy",
            abstract: "Copy files/folders between a container and the local filesystem",
            aliases: ["cp"])

        @OptionGroup()
        public var logOptions: Flags.Logging

        @Argument(help: "Source path (container:path or local path)")
        var source: String

        @Argument(help: "Destination path (container:path or local path)")
        var destination: String

        public func run() async throws {
            let client = ContainerClient()
            let srcRef = Self.parsePathRef(source)
            let dstRef = Self.parsePathRef(destination)
            
            switch (srcRef, dstRef) {
            case (.container(let id, let path), .local(let localPath)):
                let resolvedLocal = URL(fileURLWithPath: localPath).standardizedFileURL.path
                try await client.copyOut(id: id, source: path, destination: resolvedLocal)
            case (.local(let localPath), .container(let id, let path)):
                let resolvedLocal = URL(fileURLWithPath: localPath).standardizedFileURL.path
                let filename = URL(fileURLWithPath: resolvedLocal).lastPathComponent
                let containerDest = path.hasSuffix("/") ? path + filename : path + "/" + filename
                try await client.copyIn(id: id, source: resolvedLocal, destination: containerDest)
            case (.container, .container):
                throw ContainerizationError(.invalidArgument, message: "copying between containers is not supported")
            case (.local, .local):
                throw ContainerizationError(
                    .invalidArgument,
                    message: "one of source or destination must be a container reference (container_id:path)")
            }
        }
    }
}
