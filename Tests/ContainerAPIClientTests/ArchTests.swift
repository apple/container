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

import XCTest
@testable import ContainerAPIClient

final class ArchTests: XCTestCase {

    func testAmd64Initialization() throws {
        let arch = Arch(rawValue: "amd64")
        XCTAssertNotNil(arch)
        XCTAssertEqual(arch, .amd64)
    }

    func testX86_64Alias() throws {
        let arch = Arch(rawValue: "x86_64")
        XCTAssertNotNil(arch)
        XCTAssertEqual(arch, .amd64)
    }

    func testX86_64WithDashAlias() throws {
        let arch = Arch(rawValue: "x86-64")
        XCTAssertNotNil(arch)
        XCTAssertEqual(arch, .amd64)
    }

    func testArm64Initialization() throws {
        let arch = Arch(rawValue: "arm64")
        XCTAssertNotNil(arch)
        XCTAssertEqual(arch, .arm64)
    }

    func testCaseInsensitive() throws {
        XCTAssertEqual(Arch(rawValue: "AMD64"), .amd64)
        XCTAssertEqual(Arch(rawValue: "X86_64"), .amd64)
        XCTAssertEqual(Arch(rawValue: "ARM64"), .arm64)
        XCTAssertEqual(Arch(rawValue: "Amd64"), .amd64)
    }

    func testInvalidArchitecture() throws {
        XCTAssertNil(Arch(rawValue: "invalid"))
        XCTAssertNil(Arch(rawValue: "i386"))
        XCTAssertNil(Arch(rawValue: "powerpc"))
        XCTAssertNil(Arch(rawValue: ""))
    }

    func testRawValueRoundTrip() throws {
        XCTAssertEqual(Arch.amd64.rawValue, "amd64")
        XCTAssertEqual(Arch.arm64.rawValue, "arm64")
    }
}
