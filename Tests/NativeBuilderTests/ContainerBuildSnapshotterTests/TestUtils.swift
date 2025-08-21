//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

// Simple temp-directory helper for tests
enum TestUtils {
    static func withTempDir<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cb-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    static func withTempDirAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cb-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    @discardableResult
    static func write(_ path: URL, contents: Data, permissions: UInt16? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: path.path, contents: contents)
        if let mode = permissions {
            try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path.path)
        }
        return path
    }

    @discardableResult
    static func writeString(_ path: URL, _ string: String, permissions: UInt16? = nil) throws -> URL {
        try write(path, contents: Data(string.utf8), permissions: permissions)
    }

    static func readString(_ path: URL) throws -> String {
        String(decoding: try Data(contentsOf: path), as: UTF8.self)
    }

    static func makeSymlink(at: URL, to relativeTarget: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: at.path, withDestinationPath: relativeTarget)
    }

    static func chmod(_ path: URL, mode: UInt16) throws {
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path.path)
    }

    static func fileExists(_ path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    static func mkdir(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }

    static func listAll(relativeTo root: URL) throws -> [String] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        while let u = en.nextObject() as? URL {
            let rel = u.path.replacingOccurrences(of: root.path + "/", with: "")
            out.append(rel)
        }
        return out.sorted()
    }
}
