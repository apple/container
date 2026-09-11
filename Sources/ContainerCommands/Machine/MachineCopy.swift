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
import MachineAPIClient
import SystemPackage

extension Application {
    public struct MachineCopy: AsyncLoggableCommand {
        enum PathRef {
            case local(String)
            case machine(id: String, path: String)
        }

        static func parsePathRef(_ ref: String) throws -> PathRef {
            let parts = ref.components(separatedBy: ":")
            switch parts.count {
            case 1:
                return .local(ref)
            case 2 where !parts[0].isEmpty && parts[1].starts(with: "/"):
                return .machine(id: parts[0], path: parts[1])
            default:
                throw ContainerizationError(.invalidArgument, message: "invalid path given: \(ref)")
            }
        }

        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "copy",
            abstract: "Copy files/folders between a container machine and the local filesystem",
            aliases: ["cp"])

        @OptionGroup()
        public var logOptions: Flags.Logging

        @Argument(help: "Source path (machine:path or local path)")
        var source: String

        @Argument(help: "Destination path (machine:path or local path)")
        var destination: String

        private func resolveContainerId(for machineId: String, machineClient: MachineClient) async throws -> String {
            let snapshot = try await machineClient.inspect(id: machineId)
            guard snapshot.status == .running else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine '\(machineId)' is not running (status: \(snapshot.status.rawValue))"
                )
            }
            guard let containerId = snapshot.containerId else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container machine '\(machineId)' is running but has no container ID"
                )
            }
            return containerId
        }

        public func run() async throws {
            let machineClient = MachineClient()
            let client = ContainerClient()
            let srcRef = try Self.parsePathRef(source)
            let dstRef = try Self.parsePathRef(destination)

            switch (srcRef, dstRef) {
            case (.machine(let machineId, let path), .local(let localPath)):
                let containerId = try await resolveContainerId(for: machineId, machineClient: machineClient)
                let srcPath = FilePath(path)
                let destPath = FilePath(URL(fileURLWithPath: localPath, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false))
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: destPath.string, isDirectory: &isDirectory)

                var finalDestPath = destPath
                if exists && isDirectory.boolValue {
                    guard let lastComponent = srcPath.lastComponent else {
                        throw ContainerizationError(.invalidArgument, message: "source path has no last component: \(path)")
                    }
                    finalDestPath = destPath.appending(lastComponent)
                    try await client.copyOut(id: containerId, source: path, destination: finalDestPath.string)
                } else if localPath.hasSuffix("/") {
                    try await client.copyOut(id: containerId, source: path, destination: destPath.string)
                    var resultIsDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: destPath.string, isDirectory: &resultIsDir),
                        !resultIsDir.boolValue
                    {
                        try? FileManager.default.removeItem(atPath: destPath.string)
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "destination is not a directory: \(localPath)")
                    }
                } else {
                    try await client.copyOut(id: containerId, source: path, destination: destPath.string)
                }
                print(finalDestPath.string)
            case (.local(let localPath), .machine(let machineId, let path)):
                let containerId = try await resolveContainerId(for: machineId, machineClient: machineClient)
                let srcPath = FilePath(URL(fileURLWithPath: localPath, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false))
                var isDirectory: ObjCBool = false

                guard let lastComponent = srcPath.lastComponent else {
                    throw ContainerizationError(.invalidArgument, message: "source path has no last component: \(localPath)")
                }

                guard FileManager.default.fileExists(atPath: srcPath.string, isDirectory: &isDirectory) else {
                    throw ContainerizationError(.notFound, message: "source path does not exist: \(localPath)")
                }
                if localPath.hasSuffix("/") && !isDirectory.boolValue {
                    throw ContainerizationError(.invalidArgument, message: "source path is not a directory: \(localPath)")
                }

                try await client.copyIn(id: containerId, source: srcPath.string, destination: path, createParents: true)
                let printedDest = path.hasSuffix("/") ? "\(machineId):\(path)\(lastComponent.string)" : "\(machineId):\(path)"
                print(printedDest)
            case (.machine, .machine):
                throw ContainerizationError(.invalidArgument, message: "copying between container machines is not supported")
            case (.local, .local):
                throw ContainerizationError(
                    .invalidArgument,
                    message: "one of source or destination must be a container machine reference (machine_name:path)")
            }
        }
    }
}
