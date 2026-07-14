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
import SystemPackage

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

            if destination == "-" {
                guard case .container(let id, let path) = srcRef else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "when destination is '-', source must be a container reference"
                    )
                }
                guard case .local(let localDash) = dstRef, localDash == "-" else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "destination '-' is only supported for container-to-host tar streams"
                    )
                }
                try await Self.streamTarFromContainer(client: client, id: id, sourcePath: path)
                return
            }

            if source == "-" {
                guard case .local(let localDash) = srcRef, localDash == "-" else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "source '-' is only supported for host-to-container tar streams"
                    )
                }
                guard case .container(let id, let path) = dstRef else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "when source is '-', destination must be a container reference"
                    )
                }
                try await Self.streamTarToContainer(client: client, id: id, destinationPath: path)
                return
            }

            switch (srcRef, dstRef) {
            case (.container(let id, let path), .local(let localPath)):
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
                    try await client.copyOut(id: id, source: path, destination: finalDestPath.string)
                } else if localPath.hasSuffix("/") {
                    try await client.copyOut(id: id, source: path, destination: destPath.string)
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
                    try await client.copyOut(id: id, source: path, destination: destPath.string)
                }
                print(finalDestPath.string)
            case (.local(let localPath), .container(let id, let path)):
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

                try await client.copyIn(id: id, source: srcPath.string, destination: path, createParents: true)
                let printedDest = path.hasSuffix("/") ? "\(id):\(path)\(lastComponent.string)" : "\(id):\(path)"
                print(printedDest)
            case (.container, .container):
                throw ContainerizationError(.invalidArgument, message: "copying between containers is not supported")
            case (.local, .local):
                throw ContainerizationError(
                    .invalidArgument,
                    message: "one of source or destination must be a container reference (container_id:path)")
            }
        }

        private static func streamTarFromContainer(client: ContainerClient, id: String, sourcePath: String) async throws {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let sourceFilePath = FilePath(sourcePath)
            let fallbackName = "copy"
            let leafName = sourceFilePath.lastComponent?.string ?? fallbackName
            let stagingPath = tempDir.appendingPathComponent(leafName)

            try await client.copyOut(id: id, source: sourcePath, destination: stagingPath.path(percentEncoded: false), createParents: true)

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: stagingPath.path(percentEncoded: false), isDirectory: &isDirectory) else {
                throw ContainerizationError(.internalError, message: "failed to stage container copy source for tar streaming")
            }

            let tarArgs: [String] = ["-C", tempDir.path(percentEncoded: false), "-cf", "-", leafName]

            _ = isDirectory // kept for parity if future behavior diverges by source type

            try runTar(args: tarArgs, stdinData: nil, outputToStdout: true)
        }

        private static func streamTarToContainer(client: ContainerClient, id: String, destinationPath: String) async throws {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let extractDir = tempDir.appendingPathComponent("extract")
            let archivePath = tempDir.appendingPathComponent("stdin.tar")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: archivePath.path(percentEncoded: false), contents: nil)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let archiveHandle = try FileHandle(forWritingTo: archivePath)
            defer { try? archiveHandle.close() }

            var totalBytesRead = 0
            while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
                archiveHandle.write(chunk)
                totalBytesRead += chunk.count
            }

            if totalBytesRead == 0 {
                throw ContainerizationError(.invalidArgument, message: "empty tar stream on stdin")
            }

            let listed = try runTar(args: ["-tf", archivePath.path(percentEncoded: false)], stdinData: nil, outputToStdout: false)
            let entries = listed
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)

            guard !entries.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "tar stream has no entries")
            }

            for entry in entries {
                let normalized = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalized.isEmpty {
                    continue
                }
                if normalized.hasPrefix("/") {
                    throw ContainerizationError(.invalidArgument, message: "tar stream contains absolute path: \(normalized)")
                }
                let parts = normalized.split(separator: "/")
                if parts.contains("..") {
                    throw ContainerizationError(.invalidArgument, message: "tar stream contains parent traversal: \(normalized)")
                }
            }

            _ = try runTar(
                args: ["-xf", archivePath.path(percentEncoded: false), "-C", extractDir.path(percentEncoded: false)],
                stdinData: nil,
                outputToStdout: false
            )

            let topLevelNames = Set(entries.compactMap { entry -> String? in
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return String(trimmed.split(separator: "/", maxSplits: 1).first ?? "")
            }).sorted()

            guard !topLevelNames.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "tar stream has no copyable top-level entries")
            }

            if topLevelNames.count == 1 {
                let name = topLevelNames[0]
                let src = extractDir.appendingPathComponent(name).path(percentEncoded: false)
                try await client.copyIn(id: id, source: src, destination: destinationPath, createParents: true)
                return
            }

            let destinationDirPath = destinationPath.hasSuffix("/") ? destinationPath : destinationPath + "/"
            for name in topLevelNames {
                let src = extractDir.appendingPathComponent(name).path(percentEncoded: false)
                try await client.copyIn(id: id, source: src, destination: destinationDirPath, createParents: true)
            }
        }

        @discardableResult
        private static func runTar(args: [String], stdinData: Data?, outputToStdout: Bool) throws -> String {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/tar")
            process.arguments = args

            let errPipe = Pipe()
            process.standardError = errPipe
            if outputToStdout {
                process.standardOutput = FileHandle.standardOutput
            } else {
                process.standardOutput = Pipe()
            }

            if let stdinData {
                let inputPipe = Pipe()
                process.standardInput = inputPipe
                try process.run()
                inputPipe.fileHandleForWriting.write(stdinData)
                inputPipe.fileHandleForWriting.closeFile()
            } else {
                try process.run()
            }

            process.waitUntilExit()

            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(decoding: stderrData, as: UTF8.self)

            if process.terminationStatus != 0 {
                let errorText = stderrText.isEmpty ? "tar failed with status \(process.terminationStatus)" : stderrText
                throw ContainerizationError(.internalError, message: errorText)
            }

            if outputToStdout {
                return ""
            }

            let outPipe = process.standardOutput as? Pipe
            let stdoutData = outPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            return String(decoding: stdoutData, as: UTF8.self)
        }
    }
}
