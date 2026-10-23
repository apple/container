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

@testable import ContainerCommands

struct ImagePullPlatformTests {
    @Test func noFlagsFetchesAllAndUnpacksHost() throws {
        let selection = try Application.ImagePull.resolvePlatforms(
            platform: nil,
            os: nil,
            arch: nil,
            environment: [:]
        )
        #expect(selection.fetch == nil)
        #expect(selection.unpack?.os == Platform.current.os)
        #expect(selection.unpack?.architecture == Platform.current.architecture)
    }

    @Test func allFetchesAndUnpacksEveryPlatform() throws {
        let selection = try Application.ImagePull.resolvePlatforms(
            platform: "all",
            os: nil,
            arch: nil,
            environment: [:]
        )
        #expect(selection.fetch == nil)
        #expect(selection.unpack == nil)
    }

    @Test func allIsCaseInsensitive() throws {
        let selection = try Application.ImagePull.resolvePlatforms(
            platform: "ALL",
            os: nil,
            arch: nil,
            environment: [:]
        )
        #expect(selection.fetch == nil)
        #expect(selection.unpack == nil)
    }

    @Test func allRejectsOSOrArchOverrides() {
        #expect {
            _ = try Application.ImagePull.resolvePlatforms(
                platform: "all",
                os: "linux",
                arch: nil,
                environment: [:]
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("--platform all")
        }
        #expect {
            _ = try Application.ImagePull.resolvePlatforms(
                platform: "all",
                os: nil,
                arch: "arm64",
                environment: [:]
            )
        } throws: { error in
            guard let error = error as? ContainerizationError else {
                return false
            }
            return error.description.contains("--platform all")
        }
    }

    @Test func explicitPlatformIsUsedForFetchAndUnpack() throws {
        let selection = try Application.ImagePull.resolvePlatforms(
            platform: "linux/amd64",
            os: nil,
            arch: nil,
            environment: [:]
        )
        #expect(selection.fetch?.os == "linux")
        #expect(selection.fetch?.architecture == "amd64")
        #expect(selection.unpack?.os == "linux")
        #expect(selection.unpack?.architecture == "amd64")
    }

    @Test func environmentPlatformIsUsedForFetchAndUnpack() throws {
        let selection = try Application.ImagePull.resolvePlatforms(
            platform: nil,
            os: nil,
            arch: nil,
            environment: ["CONTAINER_DEFAULT_PLATFORM": "linux/amd64"]
        )
        #expect(selection.fetch?.architecture == "amd64")
        #expect(selection.unpack?.architecture == "amd64")
    }

    @Test func osAndArchFlagsAreUsedForFetchAndUnpack() throws {
        let selection = try Application.ImagePull.resolvePlatforms(
            platform: nil,
            os: "linux",
            arch: "arm64",
            environment: [:]
        )
        #expect(selection.fetch?.os == "linux")
        #expect(selection.fetch?.architecture == "arm64")
        #expect(selection.unpack?.os == "linux")
        #expect(selection.unpack?.architecture == "arm64")
    }
}
