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

import ContainerizationExtras
import Darwin
import Foundation
import SystemPackage
import Testing

// MARK: - Build context types

extension ContainerFixture {
    /// A file-system entry to materialize inside a build context directory.
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
        case symbolicLink(_ path: String, target: String, uid: uid_t = 0, gid: gid_t = 0)
    }

    enum FileEntryContent {
        case zeroFilled(size: Int64)
        case data(Data)
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
}

// MARK: - Builder lifecycle helpers

extension ContainerFixture {

    /// Starts the buildkit builder container.
    func builderStart(cpus: Int64 = 2, memoryInGBs: Int64 = 2) throws {
        try run(["builder", "start", "-c", "\(cpus)", "-m", "\(memoryInGBs)GB"]).check()
    }

    /// Stops the buildkit builder container.
    func builderStop() throws {
        try run(["builder", "stop"]).check()
    }

    /// Deletes the buildkit builder container.
    func builderDelete(force: Bool = false) throws {
        var args = ["builder", "delete"]
        if force { args.append("--force") }
        try run(args).check()
    }

    /// Polls until the buildkit container is running and the builder shim is ready.
    func waitForBuilderRunning() async throws {
        try waitForContainerRunning("buildkit", attempts: 10)
        for _ in 0..<3 {
            let response = try? doExec("buildkit", cmd: ["pidof", "-s", "container-builder-shim"])
            if let r = response, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw CommandError.executionFailed("timed out waiting for container-builder-shim on buildkit")
    }

    /// Deletes any existing builder, starts a fresh one, runs `body`, then deletes the builder.
    ///
    /// Each build test gets an isolated builder to avoid inter-test contamination.
    /// Acquires a process-wide lock so only one test holds the buildkit singleton at a time,
    /// regardless of how many suites run concurrently in the global pass.
    func withBuilder(
        cpus: Int64 = 2,
        memoryInGBs: Int64 = 2,
        _ body: @Sendable (ContainerFixture) async throws -> Void
    ) async throws {
        try await withoutActuallyEscaping(body) { escapingBody in
            try await Self.builderLock.withLock { _ in
                _ = try? self.run(["builder", "delete", "--force"])
                try self.builderStart(cpus: cpus, memoryInGBs: memoryInGBs)
                defer { _ = try? self.run(["builder", "delete", "--force"]) }
                try await self.waitForBuilderRunning()
                try await escapingBody(self)
            }
        }
    }

    /// Acquires the process-wide builder lock without starting a builder.
    ///
    /// Use this in tests that manually manage the builder lifecycle (e.g. lifecycle
    /// tests that call ``builderStart()``/``builderStop()`` directly) so they
    /// serialise correctly with tests that use ``withBuilder(_:)``.
    func withBuilderLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await withoutActuallyEscaping(body) { escapingBody in
            try await Self.builderLock.withLock { _ in
                try await escapingBody()
            }
        }
    }

    private static let builderLock = AsyncLock()
}

// MARK: - Build context helpers

extension ContainerFixture {

    /// Creates a new scratch directory under ``testDir`` and returns its path.
    ///
    /// The directory is removed automatically when the fixture scope exits.
    func createTempDir() throws -> FilePath {
        let dir = testDir.appending(UUID().uuidString)
        try FileManager.default.createDirectory(
            atPath: dir.string, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    /// Writes `contents` to a new file under ``testDir`` with the given suffix.
    func createTempFile(suffix: String, contents: Data) throws -> FilePath {
        let file = testDir.appending(UUID().uuidString + suffix)
        try contents.write(to: URL(filePath: file.string), options: .atomic)
        return file
    }

    /// Writes a Dockerfile and optional context entries into `dir`.
    ///
    /// Creates `dir/Dockerfile` (if `dockerfile` is non-empty) and
    /// `dir/context/` populated with `context` entries.
    func createContext(dir: FilePath, dockerfile: String, context: [FileSystemEntry]? = nil) throws {
        if !dockerfile.isEmpty {
            try Data(dockerfile.utf8).write(to: URL(filePath: dir.appending("Dockerfile").string), options: .atomic)
        }
        let contextDir = dir.appending("context")
        try FileManager.default.createDirectory(
            atPath: contextDir.string, withIntermediateDirectories: true, attributes: nil)
        for entry in context ?? [] {
            try createEntry(entry, contextDir: contextDir)
        }
    }

    /// Materializes a ``FileSystemEntry`` inside `contextDir`.
    func createEntry(_ entry: FileSystemEntry, contextDir: FilePath) throws {
        switch entry {
        case .file(let path, let content, let permissions, let uid, let gid):
            let fullPath = appendingRelative(contextDir, path)
            let parentDir = fullPath.string.components(separatedBy: "/").dropLast().joined(separator: "/")
            try FileManager.default.createDirectory(
                atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
            switch content {
            case .data(let data):
                try data.write(to: URL(filePath: fullPath.string), options: .atomic)
            case .zeroFilled(let size):
                let zeros = Data(count: Int(size))
                try zeros.write(to: URL(filePath: fullPath.string), options: .atomic)
            }
            // Set permissions explicitly so they match the requested mode regardless of umask.
            try FileManager.default.setAttributes(
                [.posixPermissions: Int(permissions.rawValue)],
                ofItemAtPath: fullPath.string)
            // Ownership change silently ignored when not running as root.
            _ = lchown(fullPath.string, uid, gid)

        case .directory(let path, let permissions, let uid, let gid):
            let fullPath = appendingRelative(contextDir, path)
            try FileManager.default.createDirectory(
                atPath: fullPath.string,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: Int(permissions.rawValue),
                    .ownerAccountID: uid,
                    .groupOwnerAccountID: gid,
                ])

        case .symbolicLink(let path, let target, let uid, let gid):
            let fullPath = appendingRelative(contextDir, path)
            let parentDir = fullPath.string.components(separatedBy: "/").dropLast().joined(separator: "/")
            try FileManager.default.createDirectory(
                atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
            let targetPath = appendingRelative(contextDir, target)
            let relativeDest = relativePathFrom(targetPath, from: fullPath)
            try FileManager.default.createSymbolicLink(
                atPath: fullPath.string, withDestinationPath: relativeDest)
            lchown(fullPath.string, uid, gid)
        }
    }

    /// Appends a multi-component relative path (e.g. `"a/b/c"`) to a `FilePath` base.
    private func appendingRelative(_ base: FilePath, _ relative: String) -> FilePath {
        relative.split(separator: "/", omittingEmptySubsequences: true)
            .reduce(base) { $0.appending(String($1)) }
    }

    /// Computes the relative path from `base` to `dest`.
    ///
    /// - FIXME: This duplicates logic in `ContainerBuild/URL+Extensions.swift`.
    ///   Both copies should be extracted to `ContainerizationOS/FilePathOps`
    ///   in the containerization package.
    private func relativePathFrom(_ dest: FilePath, from base: FilePath) -> String {
        let destParts = dest.string.components(separatedBy: "/").filter { !$0.isEmpty }
        let baseParts = base.string.components(separatedBy: "/").filter { !$0.isEmpty }
        let common = zip(destParts, baseParts).prefix { $0.0 == $0.1 }.count
        guard common > 0 else { return dest.string }
        let ups = Array(repeating: "..", count: baseParts.count - common)
        let remainder = Array(destParts.dropFirst(common))
        return (ups + remainder).joined(separator: "/")
    }
}

// MARK: - Build invocation helpers

extension ContainerFixture {

    /// Builds an image from `contextDir/Dockerfile` with context `contextDir/context/`.
    @discardableResult
    func build(
        tag: String,
        contextDir: FilePath = FilePath("."),
        buildArgs: [String] = [],
        otherArgs: [String] = []
    ) throws -> String {
        try buildWithPaths(tags: [tag], contextDir: contextDir, buildArgs: buildArgs, otherArgs: otherArgs)
    }

    /// Builds using a context directory and an optional explicit Dockerfile path.
    ///
    /// Mirrors `container build [-f dockerfilePath] [contextDir]`:
    /// - `tags` defaults to `[]`; when empty the runtime auto-generates a UUID tag
    ///   and prints it to stdout (call `.trimmingCharacters(in: .whitespacesAndNewlines)`
    ///   on the return value to obtain it)
    /// - `contextDir` defaults to the current directory (`.`)
    /// - `dockerfilePath` defaults to `nil`, resolved to `contextDir/Dockerfile` at call time
    @discardableResult
    func buildWithPaths(
        tags: [String] = [],
        contextDir: FilePath = FilePath("."),
        dockerfilePath: FilePath? = nil,
        buildArgs: [String] = [],
        otherArgs: [String] = []
    ) throws -> String {
        let contextPath = contextDir.appending("context")
        let resolvedDockerfile = dockerfilePath ?? contextDir.appending("Dockerfile")
        var args = ["build", "-f", resolvedDockerfile.string]
        for tag in tags { args += ["-t", tag] }
        for arg in buildArgs { args += ["--build-arg", arg] }
        args.append(contextPath.string)
        args.append(contentsOf: otherArgs)
        let result = try run(args)
        guard result.status == 0 else {
            throw CommandError.executionFailed(
                "build failed: stdout=\(result.output) stderr=\(result.error)")
        }
        return result.output
    }

    /// Builds with a Dockerfile read from stdin.
    @discardableResult
    func buildWithStdin(
        tags: [String],
        contextDir: FilePath,
        dockerfileContents: String,
        buildArgs: [String] = [],
        otherArgs: [String] = []
    ) throws -> String {
        let contextPath = contextDir.appending("context")
        var args = ["build", "-f", "-"]
        for tag in tags { args += ["-t", tag] }
        for arg in buildArgs { args += ["--build-arg", arg] }
        args.append(contextPath.string)
        args.append(contentsOf: otherArgs)
        let result = try run(args, stdin: Data(dockerfileContents.utf8))
        guard result.status == 0 else {
            throw CommandError.executionFailed(
                "build failed: stdout=\(result.output) stderr=\(result.error)")
        }
        return result.output
    }

    /// Builds with `--output type=local,dest=<outputDir>`.
    @discardableResult
    func buildWithPathsAndLocalOutput(
        tag: String,
        contextDir: FilePath = FilePath("."),
        dockerfilePath: FilePath? = nil,
        outputDir: FilePath,
        buildArgs: [String] = []
    ) throws -> String {
        let contextPath = contextDir.appending("context")
        let resolvedDockerfile = dockerfilePath ?? contextDir.appending("Dockerfile")
        var args = [
            "build",
            "-f", resolvedDockerfile.string,
            "-t", tag,
            "--output", "type=local,dest=\(outputDir.string)",
        ]
        for arg in buildArgs { args += ["--build-arg", arg] }
        args.append(contextPath.string)
        let result = try run(args)
        guard result.status == 0 else {
            throw CommandError.executionFailed(
                "build failed: stdout=\(result.output) stderr=\(result.error)")
        }
        return result.output
    }
}

// MARK: - Container exec helpers

extension ContainerFixture {
    /// Returns true if `path` exists as a regular file inside `container`.
    func containerHasFile(_ container: String, at path: String) throws -> Bool {
        try run(["exec", container, "test", "-f", path]).status == 0
    }

    /// Asserts that `path` exists as a regular file inside `container`.
    func assertContainerHasFile(_ container: String, at path: String, _ comment: String? = nil) throws {
        let exists = try containerHasFile(container, at: path)
        #expect(exists, "\(comment ?? path) should exist in container")
    }

    /// Asserts that `path` does NOT exist inside `container`.
    func assertContainerMissingFile(_ container: String, at path: String, _ comment: String? = nil) throws {
        let exists = try containerHasFile(container, at: path)
        #expect(!exists, "\(comment ?? path) should NOT exist in container")
    }
}
