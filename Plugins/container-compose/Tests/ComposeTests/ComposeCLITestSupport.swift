//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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

struct ComposeCLITestSupport {
    struct CommandResult {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func composeBinaryURL() throws -> URL {
        let buildRoot = packageRoot.appendingPathComponent(".build")
        let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var candidates: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "compose", !url.path.contains(".dSYM") else {
                continue
            }
            candidates.append(url)
        }

        if let debug = candidates.first(where: { $0.path.contains("/debug/compose") }) {
            return debug
        }

        if let release = candidates.first(where: { $0.path.contains("/release/compose") }) {
            return release
        }

        if let candidate = candidates.first {
            return candidate
        }

        throw NSError(domain: "ComposeCLITestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "compose binary not found under \(buildRoot.path)"])
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func run(arguments: [String], currentDirectory: URL) throws -> CommandResult {
        let process = Process()
        process.executableURL = try composeBinaryURL()
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}
