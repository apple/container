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

import Foundation
import Testing

@testable import ContainerBuild

/* CLIBuildBase is the base class used for creating builder tests. Subtests classes
// for these tests are nested in extensions of CLIBuildBase so that we can set
// the serialized parallelization attribute across all builder tests.
*/
@Suite(.serialized)
class TestCLIBuildBase: CLITest {
    override init() throws {
        try super.init()

        try? builderDelete(force: true)
        try builderStart()
        try waitForBuilderRunning()
    }

    deinit {
        try? builderDelete(force: true)
    }

    func waitForBuilderRunning() throws {
        let buildkitName = "buildkit"
        try waitForContainerRunning(buildkitName, 10)

        // exec into buildkit and check if builder-shim is running
        var attempt = 3
        while attempt > 0 {
            attempt -= 1
            let response = try doExec(name: buildkitName, cmd: ["pidof", "-s", "container-builder-shim"])
            if !response.isEmpty {
                // found the init process running
                return
            }
            sleep(1)
        }
        throw CLIError.executionFailed("failed to wait for container-builder-shim process on \(buildkitName)")
    }

    func createTempDir() throws -> URL {
        let tempDir = testDir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    func createContext(tempDir: URL, dockerfile: String, context: [FileSystemEntry]? = nil) throws {
        let dockerfileBytes = dockerfile.data(using: .utf8)!
        try dockerfileBytes.write(to: tempDir.appendingPathComponent("Dockerfile"), options: .atomic)

        let contextDir: URL = tempDir.appendingPathComponent("context").absoluteURL
        try FileManager.default.createDirectory(at: contextDir, withIntermediateDirectories: true, attributes: nil)

        if let context {
            for entry in context {
                try createEntry(entry, contextDir)
            }
        }
    }

    @discardableResult
    func build(
        tag: String,
        tempDir: URL,
        buildArgs: [String] = [],
        otherArgs: [String] = []
    ) throws -> String {
        try buildWithPaths(
            tags: [tag],
            tempContext: tempDir,
            tempDockerfileContext: tempDir,
            buildArgs: buildArgs,
            otherArgs: otherArgs
        )
    }

    @discardableResult
    func build(
        tags: [String],
        tempDir: URL,
        buildArgs: [String] = [],
        otherArgs: [String] = []
    ) throws -> String {
        try buildWithPaths(
            tags: tags,
            tempContext: tempDir,
            tempDockerfileContext: tempDir,
            buildArgs: buildArgs,
            otherArgs: otherArgs
        )
    }

    // buildWithPaths is a helper function for calling build with different paths for the build context and
    // the dockerfile path. If both paths are the same, use `build` func above.
    @discardableResult
    func buildWithPaths(
        tags: [String],
        tempContext: URL,
        tempDockerfileContext: URL,
        buildArgs: [String] = [],
        otherArgs: [String] = []
    ) throws -> String {
        let contextDir: URL = tempContext.appendingPathComponent("context")
        let contextDirPath = contextDir.absoluteURL.path
        var args = [
            "build",
            "-f",
            tempDockerfileContext.appendingPathComponent("Dockerfile").path,
        ]
        for tag in tags {
            args.append("-t")
            args.append(tag)
        }
        for arg in buildArgs {
            args.append("--build-arg")
            args.append(arg)
        }
        args.append(contextDirPath)

        args.append(contentsOf: otherArgs)

        let response = try run(arguments: args)
        if response.status != 0 {
            throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
        }

        return response.output
    }

    @discardableResult
    func buildWithStdin(
        tags: [String],
        tempContext: URL,
        dockerfileContents: String,
        buildArgs: [String] = [],
        otherArgs: [String] = []
    ) throws -> String {
        let contextDir: URL = tempContext.appendingPathComponent("context")
        let contextDirPath = contextDir.absoluteURL.path
        var args = [
            "build",
            "-f",
            "-",
        ]
        for tag in tags {
            args.append("-t")
            args.append(tag)
        }
        for arg in buildArgs {
            args.append("--build-arg")
            args.append(arg)
        }
        args.append(contextDirPath)

        args.append(contentsOf: otherArgs)

        let stdinData = Data(dockerfileContents.utf8)
        let response = try run(arguments: args, stdin: stdinData)
        if response.status != 0 {
            throw CLIError.executionFailed("build failed: stdout=\(response.output) stderr=\(response.error)")
        }

        return response.output
    }

    enum FileSystemEntry {
        case file(
            _ path: String,
            content: FileEntryContent,
            permissions: FilePermissions = [.r, .w, .gr, .gw, .or, .ow],
            uid: uid_t = 0,
            gid: gid_t = 0
        )
        case directory(
            _ path: String,
            permissions: FilePermissions = [.r, .w, .x, .gr, .gw, .gx, .or, .ow, .ox],
            uid: uid_t = 0,
            gid: gid_t = 0
        )
        case symbolicLink(
            _ path: String,
            target: String,
            uid: uid_t = 0,
            gid: gid_t = 0
        )
    }

    func createEntry(_ entry: FileSystemEntry, _ contextDir: URL) throws {
        switch entry {
        // last 2 params are uid and gid
        case .file(let path, let content, let permissions, _, _):
            let fullPath = contextDir.appending(path: path)
            // not using .absoluteURL deletes the last component from fullPath
            let directory: URL = fullPath.absoluteURL.deletingLastPathComponent()
            let contentPath = fullPath.path

            try FileManager.default.createDirectory(
                atPath: directory.path,
                withIntermediateDirectories: true,
                attributes: nil
            )

            switch content {
            case .data(let data):
                try data.write(to: fullPath)
            case .zeroFilled(let size):
                let fd = open(contentPath, O_CREAT | O_WRONLY, permissions.rawValue)
                if fd == -1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                defer { close(fd) }
                ftruncate(fd, off_t(size))
            }

        // TODO: figure out why this block fails
        // try FileManager.default.setAttributes(
        //     [
        //         .posixPermissions: Int(permissions.rawValue),
        //         .ownerAccountID: uid,
        //         .groupOwnerAccountID: gid,
        //     ],
        //     ofItemAtPath: fullPath.absoluteURL.absoluteString
        // )

        case .directory(let path, let permissions, let uid, let gid):
            let fullPath = contextDir.appendingPathComponent(path).absoluteURL
            try FileManager.default.createDirectory(
                atPath: fullPath.path,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: Int(permissions.rawValue),
                    .ownerAccountID: uid,
                    .groupOwnerAccountID: gid,
                ]
            )

        case .symbolicLink(let path, let target, let uid, let gid):
            let fullPath = contextDir.appendingPathComponent(path).absoluteURL
            let directory: URL = fullPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                atPath: directory.path,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let targetURL = contextDir.appendingPathComponent(target)
            try FileManager.default.createSymbolicLink(
                atPath: fullPath.path,
                withDestinationPath: targetURL.relativePathFrom(from: fullPath)
            )
            lchown(fullPath.path, uid, gid)
        }
    }

    struct FilePermissions: OptionSet {
        let rawValue: UInt16

        static let r = FilePermissions(rawValue: 0o400)
        static let w = FilePermissions(rawValue: 0o200)
        static let x = FilePermissions(rawValue: 0o100)

        static let gr = FilePermissions(rawValue: 0o040)
        static let gw = FilePermissions(rawValue: 0o020)
        static let gx = FilePermissions(rawValue: 0o010)

        static let or = FilePermissions(rawValue: 0o004)
        static let ow = FilePermissions(rawValue: 0o002)
        static let ox = FilePermissions(rawValue: 0o001)
    }

    enum FileEntryContent {
        case zeroFilled(size: Int64)
        case data(Data)
    }

    func builderStart(cpus: Int64 = 2, memoryInGBs: Int64 = 2) throws {
        let (_, _, error, status) = try run(arguments: [
            "builder",
            "start",
            "-c",
            "\(cpus)",
            "-m",
            "\(memoryInGBs)GB",
        ])
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func builderStop() throws {
        let (_, _, error, status) = try run(arguments: [
            "builder",
            "stop",
        ])
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

    func builderDelete(force: Bool = false) throws {
        let (_, _, error, status) = try run(
            arguments: [
                "builder",
                "delete",
                force ? "--force" : nil,
            ].compactMap { $0 })
        if status != 0 {
            throw CLIError.executionFailed("command failed: \(error)")
        }
    }

}
