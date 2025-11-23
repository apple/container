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
import Darwin
import Foundation

extension Application.VolumeCommand {
    struct VolumeCopy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cp",
            abstract: "Copy files/folders between a container volume and the local filesystem"
        )

        @Argument(help: "Source path (use volume:path for volume paths)")
        var source: String

        @Argument(help: "Destination path (use volume:path for volume paths)")
        var destination: String

        @Flag(name: .shortAndLong, help: "Copy recursively")
        var recursive: Bool = false

        func run() async throws {
            let (sourceVol, sourcePath) = parsePath(source)
            let (destVol, destPath) = parsePath(destination)

            try validatePaths(sourceVol, destVol)

            if let volName = sourceVol, let volPath = sourcePath {
                try await copyFromVolume(volume: volName, volumePath: volPath, localPath: destination)
            } else if let volName = destVol, let volPath = destPath {
                try await copyToVolume(volume: volName, volumePath: volPath, localPath: source)
            }
        }

        private func validatePaths(_ sourceVol: String?, _ destVol: String?) throws {
            if sourceVol != nil && destVol != nil {
                throw ValidationError("copying between volumes is not supported")
            }
            if sourceVol == nil && destVol == nil {
                throw ValidationError("one path must be a volume path (use volume:path format)")
            }
        }

        private func copyFromVolume(volume: String, volumePath: String, localPath: String) async throws {
            let localURL = URL(fileURLWithPath: localPath)
            let pipe = Pipe()

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let writeFD = dup(pipe.fileHandleForWriting.fileDescriptor)
            let writeHandle = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    defer { try? pipe.fileHandleForWriting.close() }
                    try await ClientVolume.copyOut(volume: volume, path: volumePath, fileHandle: writeHandle)
                }
                group.addTask {
                    try Archiver.uncompress(from: pipe.fileHandleForReading, to: tempDir)
                }
                try await group.waitForAll()
            }

            let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            if contents.count == 1 {
                let extracted = contents[0]
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: extracted.path, isDirectory: &isDir)
                if isDir.boolValue && !recursive {
                    throw ValidationError("source '\(volume):\(volumePath)' is a directory, use -r to copy recursively")
                }
                if FileManager.default.fileExists(atPath: localPath) {
                    _ = try FileManager.default.replaceItemAt(localURL, withItemAt: extracted)
                } else {
                    try FileManager.default.moveItem(at: extracted, to: localURL)
                }
            } else {
                if !recursive {
                    throw ValidationError("source '\(volume):\(volumePath)' is a directory, use -r to copy recursively")
                }
                try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
                for item in contents {
                    let dest = localURL.appendingPathComponent(item.lastPathComponent)
                    try FileManager.default.moveItem(at: item, to: dest)
                }
            }
        }

        private func copyToVolume(volume: String, volumePath: String, localPath: String) async throws {
            let localURL = URL(fileURLWithPath: localPath)
            let pipe = Pipe()

            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) {
                throw ValidationError("source path does not exist: '\(localPath)'")
            }
            if isDir.boolValue && !recursive {
                throw ValidationError("source is a directory, use -r to copy recursively")
            }

            let readFD = dup(pipe.fileHandleForReading.fileDescriptor)
            let readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)

            let isDirectory = isDir.boolValue

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    defer { try? pipe.fileHandleForWriting.close() }
                    try Archiver.compress(source: localURL, to: pipe.fileHandleForWriting) { url in
                        let relativePath = self.computeRelativePath(source: localURL, current: url, isDirectory: isDirectory)
                        return Archiver.ArchiveEntryInfo(
                            pathOnHost: url,
                            pathInArchive: URL(fileURLWithPath: relativePath)
                        )
                    }
                }
                group.addTask {
                    try await ClientVolume.copyIn(volume: volume, path: volumePath, fileHandle: readHandle)
                }
                try await group.waitForAll()
            }
        }

        private func computeRelativePath(source: URL, current: URL, isDirectory: Bool) -> String {
            guard source.path != current.path else {
                return source.lastPathComponent
            }
            let components = current.pathComponents
            let baseComponents = source.pathComponents
            guard components.count > baseComponents.count && components.prefix(baseComponents.count) == baseComponents[...] else {
                return current.lastPathComponent
            }
            let relativePart = components[baseComponents.count...].joined(separator: "/")
            return "\(source.lastPathComponent)/\(relativePart)"
        }

        private func parsePath(_ path: String) -> (String?, String?) {
            let parts = path.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                return (String(parts[0]), String(parts[1]))
            }
            return (nil, nil)
        }
    }
}
