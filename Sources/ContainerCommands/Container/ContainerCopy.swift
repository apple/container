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
import Containerization
import ContainerizationError
import Foundation

extension Application {
    public struct ContainerCopy: AsyncLoggableCommand {
        enum PathRef {
            case local(String)
            case container(id: String, path: String)
        }

        static func parsePathRef(_ ref: String) -> PathRef {
            let parts = ref.components(separatedBy: ":")
            if parts.count == 2 {
                let id = parts[0]
                let path = parts[1]
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
                let srcURL = URL(fileURLWithPath: path)
                let localDest = localPath.hasSuffix("/") ? localPath + srcURL.lastPathComponent : localPath
                let destURL = URL(fileURLWithPath: localDest).standardizedFileURL
                try await client.copyOut(id: id, source: srcURL, destination: destURL)
            case (.local(let localPath), .container(let id, let path)):
                let srcURL = URL(fileURLWithPath: localPath).standardizedFileURL
                let containerDest = path.hasSuffix("/") ? path + srcURL.lastPathComponent : path
                let destURL = URL(fileURLWithPath: containerDest)
                try await client.copyIn(id: id, source: srcURL, destination: destURL)
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
