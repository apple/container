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

struct DefaultPlatformTests {

    // MARK: - fromEnvironment

    @Test
    func testFromEnvironmentWithLinuxAmd64() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/amd64"]
        let result = try DefaultPlatform.fromEnvironment(environment: env)
        #expect(result != nil)
        #expect(result?.os == "linux")
        #expect(result?.architecture == "amd64")
    }

    @Test
    func testFromEnvironmentWithLinuxArm64() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm64"]
        let result = try DefaultPlatform.fromEnvironment(environment: env)
        #expect(result != nil)
        #expect(result?.os == "linux")
        #expect(result?.architecture == "arm64")
    }

    @Test
    func testFromEnvironmentNotSet() throws {
        let env: [String: String] = [:]
        let result = try DefaultPlatform.fromEnvironment(environment: env)
        #expect(result == nil)
    }

    @Test
    func testFromEnvironmentEmptyString() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": ""]
        let result = try DefaultPlatform.fromEnvironment(environment: env)
        #expect(result == nil)
    }

    @Test
    func testFromEnvironmentInvalidPlatformThrows() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "not-a-valid-platform"]
        #expect {
            _ = try DefaultPlatform.fromEnvironment(environment: env)
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("CONTAINER_DEFAULT_PLATFORM")
                && error.description.contains("not-a-valid-platform")
        }
    }

    @Test
    func testFromEnvironmentIgnoresOtherVariables() throws {
        let env = ["SOME_OTHER_VAR": "linux/amd64"]
        let result = try DefaultPlatform.fromEnvironment(environment: env)
        #expect(result == nil)
    }

    @Test
    func testFromEnvironmentWithVariant() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm/v7"]
        let result = try DefaultPlatform.fromEnvironment(environment: env)
        #expect(result != nil)
        #expect(result?.os == "linux")
        #expect(result?.architecture == "arm")
        #expect(result?.variant == "v7")
    }

    // MARK: - resolve (optional os/arch, used by image pull/push/save)

    @Test
    func testResolveExplicitPlatformWins() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm64"]
        let result = try DefaultPlatform.resolve(
            platform: "linux/amd64", os: nil, arch: nil, environment: env
        )
        #expect(result != nil)
        #expect(result?.architecture == "amd64")
        #expect(result?.os == "linux")
    }

    @Test
    func testResolveExplicitArchWinsOverEnvVar() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm64"]
        let result = try DefaultPlatform.resolve(
            platform: nil, os: nil, arch: "amd64", environment: env
        )
        #expect(result != nil)
        #expect(result?.architecture == "amd64")
        #expect(result?.os == "linux")
    }

    @Test
    func testResolveExplicitOsAndArchWinOverEnvVar() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm64"]
        let result = try DefaultPlatform.resolve(
            platform: nil, os: "linux", arch: "amd64", environment: env
        )
        #expect(result != nil)
        #expect(result?.architecture == "amd64")
    }

    @Test
    func testResolveExplicitOsWinsOverEnvVar() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm64"]
        let result = try DefaultPlatform.resolve(
            platform: nil, os: "linux", arch: nil, environment: env
        )
        #expect(result != nil)
        #expect(result?.os == "linux")
    }

    @Test
    func testResolveFallsBackToEnvVar() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/amd64"]
        let result = try DefaultPlatform.resolve(
            platform: nil, os: nil, arch: nil, environment: env
        )
        #expect(result != nil)
        #expect(result?.os == "linux")
        #expect(result?.architecture == "amd64")
    }

    @Test
    func testResolveReturnsNilWithNoFlagsOrEnvVar() throws {
        let env: [String: String] = [:]
        let result = try DefaultPlatform.resolve(
            platform: nil, os: nil, arch: nil, environment: env
        )
        #expect(result == nil)
    }

    @Test
    func testResolveExplicitPlatformOverridesEverything() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm64"]
        let result = try DefaultPlatform.resolve(
            platform: "linux/amd64", os: "linux", arch: "arm64", environment: env
        )
        #expect(result?.architecture == "amd64")
    }

    @Test
    func testResolveExplicitPlatformIgnoresInvalidEnvVar() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "garbage"]
        let result = try DefaultPlatform.resolve(
            platform: "linux/amd64", os: nil, arch: nil, environment: env
        )
        #expect(result?.architecture == "amd64")
        #expect(result?.os == "linux")
    }

    // MARK: - resolveWithDefaults (required os/arch, used by run/create)

    @Test
    func testResolveWithDefaultsExplicitPlatformWins() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm64"]
        let result = try DefaultPlatform.resolveWithDefaults(
            platform: "linux/amd64", os: "linux", arch: "arm64", environment: env
        )
        #expect(result.architecture == "amd64")
    }

    @Test
    func testResolveWithDefaultsEnvVarOverridesDefaults() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/amd64"]
        let result = try DefaultPlatform.resolveWithDefaults(
            platform: nil, os: "linux", arch: "arm64", environment: env
        )
        #expect(result.architecture == "amd64")
        #expect(result.os == "linux")
    }

    @Test
    func testResolveWithDefaultsFallsBackToOsArch() throws {
        let env: [String: String] = [:]
        let result = try DefaultPlatform.resolveWithDefaults(
            platform: nil, os: "linux", arch: "arm64", environment: env
        )
        #expect(result.os == "linux")
        #expect(result.architecture == "arm64")
    }

    @Test
    func testResolveWithDefaultsEnvVarWithDifferentOs() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "linux/amd64"]
        let result = try DefaultPlatform.resolveWithDefaults(
            platform: nil, os: "linux", arch: Arch.hostArchitecture().rawValue, environment: env
        )
        #expect(result.architecture == "amd64")
    }

    @Test
    func testResolveWithDefaultsInvalidEnvVarThrows() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "garbage"]
        #expect {
            _ = try DefaultPlatform.resolveWithDefaults(
                platform: nil, os: "linux", arch: "arm64", environment: env
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("CONTAINER_DEFAULT_PLATFORM")
        }
    }

    @Test
    func testResolveWithDefaultsExplicitPlatformIgnoresInvalidEnvVar() throws {
        let env = ["CONTAINER_DEFAULT_PLATFORM": "garbage"]
        let result = try DefaultPlatform.resolveWithDefaults(
            platform: "linux/amd64", os: "linux", arch: "arm64", environment: env
        )
        #expect(result.architecture == "amd64")
    }

    // MARK: - Environment variable name

    @Test
    func testEnvironmentVariableName() {
        #expect(DefaultPlatform.environmentVariable == "CONTAINER_DEFAULT_PLATFORM")
    }
}
