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

import Foundation
import Testing

@testable import ContainerCommands

struct ContainerCopyPathRefTests {
    private func parse(_ ref: String) throws -> Application.ContainerCopy.PathRef {
        try Application.ContainerCopy.parsePathRef(ref)
    }

    @Test("a path without a colon is a local path")
    func localNoColon() throws {
        #expect(try parse("/tmp/file.txt") == .local("/tmp/file.txt"))
    }

    @Test("an id followed by an absolute path is a container reference")
    func containerRef() throws {
        #expect(try parse("box:/tmp/file.txt") == .container(id: "box", path: "/tmp/file.txt"))
    }

    @Test("a container path containing colons is preserved")
    func containerPathWithColons() throws {
        // Regression: an ISO-8601 timestamp filename was rejected as an
        // "invalid path" because the reference was split on every colon
        // instead of only the first.
        #expect(
            try parse("box:/var/log/app-2026-07-20T10:30:00.log")
                == .container(id: "box", path: "/var/log/app-2026-07-20T10:30:00.log")
        )
    }

    @Test("a local path containing colons is a local path")
    func localPathWithColons() throws {
        #expect(
            try parse("/home/user/2026-07-20T10:30:00.log")
                == .local("/home/user/2026-07-20T10:30:00.log")
        )
    }

    @Test("an empty container id is rejected")
    func emptyId() {
        #expect(throws: (any Error).self) { try parse(":/tmp/x") }
    }

    @Test("a non-absolute container path is rejected")
    func relativeContainerPath() {
        #expect(throws: (any Error).self) { try parse("box:relative/path") }
    }
}
