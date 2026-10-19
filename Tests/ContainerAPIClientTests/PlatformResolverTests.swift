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

import ContainerizationError
import ContainerizationOCI
import Testing

@testable import ContainerAPIClient

struct PlatformResolverTests {
    private static let linuxArm = Platform(arch: "arm64", os: "linux", variant: "v8")
    private static let linuxAmd = Platform(arch: "amd64", os: "linux")
    private static let windows = Platform(arch: "arm64", os: "windows")
    private static let reference = "example.com/img:latest"
    private static let invalidEnvironment = [DefaultPlatform.environmentVariable: "garbage"]

    struct TestCase: Sendable, CustomTestStringConvertible {
        let name: String
        var platform: Platform? = nil
        var os: String? = nil
        var arch: String? = nil
        let candidates: [Platform]
        let fallback: Platform
        let expected: Platform?

        var testDescription: String { name }
    }

    static let cases: [TestCase] = [
        .init(name: "single candidate wins over default", candidates: [windows], fallback: linuxArm, expected: windows),
        .init(name: "explicit os filters", os: "windows", candidates: [linuxArm, windows], fallback: linuxArm, expected: windows),
        .init(name: "explicit arch normalized", arch: "aarch64", candidates: [linuxAmd, linuxArm], fallback: linuxAmd, expected: linuxArm),
        .init(name: "explicit platform", platform: linuxAmd, candidates: [linuxArm, linuxAmd], fallback: linuxArm, expected: linuxAmd),
        .init(name: "platform wins over os/arch", platform: linuxAmd, os: "windows", arch: "arm64", candidates: [linuxAmd, windows], fallback: windows, expected: linuxAmd),
        .init(name: "several, default present", candidates: [linuxAmd, linuxArm], fallback: linuxArm, expected: linuxArm),
        .init(name: "several, default absent", candidates: [linuxAmd, linuxArm], fallback: windows, expected: nil),
        .init(name: "explicit os unsupported", os: "linux", candidates: [windows], fallback: linuxArm, expected: nil),
        .init(name: "no candidates", candidates: [], fallback: linuxArm, expected: nil),
    ]

    @Test(arguments: cases)
    func resolve(_ testCase: TestCase) throws {
        let environment = [DefaultPlatform.environmentVariable: testCase.fallback.description]
        let resolve = {
            try PlatformResolver.resolve(
                platform: testCase.platform, os: testCase.os, arch: testCase.arch,
                candidates: testCase.candidates, reference: Self.reference, environment: environment)
        }

        guard let expected = testCase.expected else {
            #expect(throws: ContainerizationError.self) {
                try resolve()
            }
            return
        }

        #expect(try resolve() == expected)
    }

    @Test func fallbackNotEvaluatedWhenExplicit() throws {
        let result = try PlatformResolver.resolve(
            platform: Self.linuxAmd,
            os: nil,
            arch: nil,
            candidates: [Self.linuxArm, Self.linuxAmd],
            reference: Self.reference,
            environment: Self.invalidEnvironment
        )
        #expect(result == Self.linuxAmd)
    }

    @Test func fallbackEvaluatedWhenSeveral() throws {
        #expect(throws: ContainerizationError.self) {
            try PlatformResolver.resolve(
                platform: nil,
                os: nil,
                arch: nil,
                candidates: [Self.linuxArm, Self.linuxAmd],
                reference: Self.reference,
                environment: Self.invalidEnvironment
            )
        }
    }
}
