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

import SystemPackage
import Testing

@testable import ContainerPlugin

private let cwd = FilePath("/current/dir")

struct FilePathResolveTests {
    @Test func nilWhenPathnameIsNil() {
        #expect(cwd.resolve(nil) == nil)
    }

    @Test func nilWhenPathnameIsEmpty() {
        #expect(cwd.resolve("") == nil)
    }

    @Test func absolutePathnameReturnedAsIs() {
        #expect(cwd.resolve("/custom/root") == FilePath("/custom/root"))
    }

    @Test func relativePathnamePrependsCurrentDirectory() {
        #expect(cwd.resolve("data") == FilePath("/current/dir/data"))
    }

    @Test func relativePathnameWithDotDotIsLexicallyNormalized() {
        #expect(cwd.resolve("../sibling") == FilePath("/current/sibling"))
    }

    @Test func relativePathnameWithDotIsLexicallyNormalized() {
        #expect(cwd.resolve("./data") == FilePath("/current/dir/data"))
    }

    @Test func absolutePathnameWithDotDotIsLexicallyNormalized() {
        #expect(cwd.resolve("/custom/../root") == FilePath("/root"))
    }

    @Test func absolutePathnameWithDotIsLexicallyNormalized() {
        #expect(cwd.resolve("/custom/./root") == FilePath("/custom/root"))
    }

    @Test func defaultPathUsedWhenPathnameIsNil() {
        let fallback = FilePath("/fallback")
        #expect(cwd.resolve(nil, defaultPath: fallback) == fallback)
    }

    @Test func defaultPathUsedWhenPathnameIsEmpty() {
        let fallback = FilePath("/fallback")
        #expect(cwd.resolve("", defaultPath: fallback) == fallback)
    }

    @Test func defaultPathIsLexicallyNormalized() {
        #expect(cwd.resolve(nil, defaultPath: FilePath("/fallback/../normalized")) == FilePath("/normalized"))
    }

    @Test func absolutePathnameOverridesDefaultPath() {
        #expect(cwd.resolve("/custom", defaultPath: FilePath("/fallback")) == FilePath("/custom"))
    }
}
