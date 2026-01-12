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

import Testing

@testable import ContainerAPIClient

struct ArchTests {

    @Test func testAmd64Initialization() throws {
        let arch = Arch(rawValue: "amd64")
        #expect(arch != nil)
        #expect(arch == .amd64)
    }

    @Test func testX86_64Alias() throws {
        let arch = Arch(rawValue: "x86_64")
        #expect(arch != nil)
        #expect(arch == .amd64)
    }

    @Test func testX86_64WithDashAlias() throws {
        let arch = Arch(rawValue: "x86-64")
        #expect(arch != nil)
        #expect(arch == .amd64)
    }

    @Test func testArm64Initialization() throws {
        let arch = Arch(rawValue: "arm64")
        #expect(arch != nil)
        #expect(arch == .arm64)
    }

    @Test func testAarch64Alias() throws {
        let arch = Arch(rawValue: "aarch64")
        #expect(arch != nil)
        #expect(arch == .arm64)
    }

    @Test func testCaseInsensitive() throws {
        #expect(Arch(rawValue: "AMD64") == .amd64)
        #expect(Arch(rawValue: "X86_64") == .amd64)
        #expect(Arch(rawValue: "ARM64") == .arm64)
        #expect(Arch(rawValue: "AARCH64") == .arm64)
        #expect(Arch(rawValue: "Amd64") == .amd64)
    }

    @Test func testInvalidArchitecture() throws {
        #expect(Arch(rawValue: "invalid") == nil)
        #expect(Arch(rawValue: "i386") == nil)
        #expect(Arch(rawValue: "powerpc") == nil)
        #expect(Arch(rawValue: "") == nil)
    }

    @Test func testRawValueRoundTrip() throws {
        #expect(Arch.amd64.rawValue == "amd64")
        #expect(Arch.arm64.rawValue == "arm64")
    }
}
