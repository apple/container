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

        static func parsePathRef(_ ref: String) throws -> PathRef {
            let parts = ref.components(separatedBy: ":")
            switch parts.count {
            case 1:
                return .local(ref)
            case 2 where !parts[0].isEmpty && parts[1].starts(with: "/"):
                return .container(id: parts[0], path: parts[1])
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid path given: \(ref)")
            }
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
            let srcRef = try Self.parsePathRef(source)
            let dstRef = try Self.parsePathRef(destination)

            switch (srcRef, dstRef) {
            case (.container(let id, let path), .local(let localPath)):
                let srcURL = URL(fileURLWithPath: path)
                let destURL = URL(fileURLWithPath: localPath).standardizedFileURL
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDirectory)
                if localPath.hasSuffix("/") {
                    guard exists && isDirectory.boolValue else {
                        throw ContainerizationError(.invalidArgument, message: "destination path is not a directory: \(localPath)")
                    }
                }
                let appendFilename = localPath.hasSuffix("/") || (exists && isDirectory.boolValue)
                let finalDestURL = appendFilename ? destURL.appendingPathComponent(srcURL.lastPathComponent) : destURL
                try await client.copyOut(id: id, source: srcURL, destination: finalDestURL)
            case (.local(let localPath), .container(let id, let path)):
                let srcURL = URL(fileURLWithPath: localPath).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: srcURL.path, isDirectory: &isDirectory) else {
                    throw ContainerizationError(.notFound, message: "source path does not exist: \(localPath)")
                }
                if localPath.hasSuffix("/") && !isDirectory.boolValue {
                    throw ContainerizationError(.invalidArgument, message: "source path is not a directory: \(localPath)")
                }
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
