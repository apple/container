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

import ContainerizationOCI
import Foundation
import Testing

@testable import Application

struct ImageSaveTests {
    @Test
    func testResolvePlatformFallsBackToHost() throws {
        // Empty environment should cause DefaultPlatform.resolve to return nil,
        // so our helper falls back to Platform.current
        let platform = try Application.ImageSave.resolvePlatform(platform: nil, os: nil, arch: nil, environment: [:], log: nil)
        #expect(platform == Platform.current)
    }

    @Test
    func testResolvePlatformUsesEnvironmentOverride() throws {
        let env: [String: String] = ["CONTAINER_DEFAULT_PLATFORM": "linux/arm64/v8"]
        let platform = try Application.ImageSave.resolvePlatform(platform: nil, os: nil, arch: nil, environment: env, log: nil)
        #expect(platform.description == "linux/arm64/v8")
    }

    @Test
    func testResolvePlatformPrefersExplicitFlags() throws {
        let platform = try Application.ImageSave.resolvePlatform(platform: "linux/amd64", os: nil, arch: nil, environment: [:], log: nil)
        #expect(platform.description == "linux/amd64")
    }
}
