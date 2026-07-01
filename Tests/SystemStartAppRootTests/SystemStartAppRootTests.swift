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

import ContainerPersistence
import Foundation
import SystemPackage
import Testing

// Unit tests for the app-root mismatch guard added to `SystemStart`.
//
// The guard canonicalizes both the daemon-reported `appRoot` (a URL rebuilt
// from the XPC reply string) and the requested `--app-root` (a `FilePath`)
// via realpath(3) before comparing them. This pins that comparison for the
// cases the guard must distinguish: identical paths, paths that differ only
// in ways realpath normalizes away (e.g. /var vs /private/var, trailing
// slash), and genuinely different roots.
struct SystemStartAppRootTests {
    // Mirrors the predicate added to SystemStart.run(): after canonicalizing
    // both sides through realpath(3) (via FilePath.resolvingSymlinks()), the
    // paths must be equal.
    private func matches(replyAppRoot: URL, requestedAppRoot: FilePath) throws -> Bool {
        let resolvedRequest = try requestedAppRoot.resolvingSymlinks()
        let resolvedReply = try FilePath(replyAppRoot.path).resolvingSymlinks()
        return resolvedReply == resolvedRequest
    }

    @Test
    func identicalAppRootsMatch() throws {
        let dir = makeTempDir()
        try #expect(matches(replyAppRoot: dir, requestedAppRoot: FilePath(dir.path)))
    }

    @Test
    func trailingSlashIsCanonicalizedEqual() throws {
        let dir = makeTempDir()
        // The XPC reply reconstructs the URL from a string and can carry a
        // trailing slash; the guard must still treat it as equal.
        let withSlash = URL(fileURLWithPath: dir.path + "/")
        try #expect(matches(replyAppRoot: withSlash, requestedAppRoot: FilePath(dir.path)))
    }

    @Test
    func symlinkedPrefixIsCanonicalizedEqual() throws {
        // /var is a symlink to /private/var on macOS. realpath() resolves it,
        // so a reply URL whose path is anchored at /private/... must match a
        // request path anchored at /var/... when they refer to the same dir.
        let dir = makeTempDir()
        let resolved = dir.resolvingSymlinksInPath()
        guard resolved.path != dir.path else {
            // Sandbox doesn't expose the /var symlink; skip rather than mask.
            return
        }
        try #expect(matches(replyAppRoot: resolved, requestedAppRoot: FilePath(dir.path)))
    }

    @Test
    func differentAppRootsDoNotMatch() throws {
        let a = makeTempDir()
        let b = makeTempDir()
        try #expect(!matches(replyAppRoot: a, requestedAppRoot: FilePath(b.path)))
    }

    @Test
    func dotDotSegmentIsResolvedBeforeCompare() throws {
        let parent = makeTempDir()
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        // "parent/child/.." canonicalizes back to parent, which must NOT match
        // child's own appRoot.
        let obfuscated = FilePath(parent.path).appending("child").appending("..")
        try #expect(!matches(replyAppRoot: child, requestedAppRoot: obfuscated))
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
