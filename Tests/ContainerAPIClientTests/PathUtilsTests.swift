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

struct PathUtilsTests {
    private static let homeFallback = FilePath(NSHomeDirectory() + "/.config").appending("container")
    private static let appRootFallback: FilePath = {
        let url = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("com.apple.container")
        return FilePath(url.path(percentEncoded: false))
    }()

    @Test func testHomeUsesXdgConfigHomeWhenSet() {
        let path = PathUtils.BaseConfigPath.home.basePath(env: ["XDG_CONFIG_HOME": "/tmp/xdg-test"])
        #expect(path == FilePath("/tmp/xdg-test/container"))
    }

    @Test func testHomeFallsBackToHomeDirectoryWhenXdgUnset() {
        let path = PathUtils.BaseConfigPath.home.basePath(env: [:])
        #expect(path == Self.homeFallback)
    }

    @Test func testHomeTreatsEmptyXdgAsUnset() {
        let path = PathUtils.BaseConfigPath.home.basePath(env: ["XDG_CONFIG_HOME": ""])
        #expect(path == Self.homeFallback)
    }

    @Test func testAppRootUsesContainerAppRootWhenSet() {
        let path = PathUtils.BaseConfigPath.appRoot.basePath(env: ["CONTAINER_APP_ROOT": "/tmp/foo"])
        #expect(path == FilePath("/tmp/foo"))
    }

    @Test func testAppRootFallsBackToApplicationSupportWhenUnset() {
        let path = PathUtils.BaseConfigPath.appRoot.basePath(env: [:])
        #expect(path == Self.appRootFallback)
    }

    @Test func testAppRootTreatsEmptyEnvAsUnset() {
        let path = PathUtils.BaseConfigPath.appRoot.basePath(env: ["CONTAINER_APP_ROOT": ""])
        #expect(path == Self.appRootFallback)
    }

    @Test func testAppRootIgnoresXdgConfigHome() {
        let path = PathUtils.BaseConfigPath.appRoot.basePath(env: ["XDG_CONFIG_HOME": "/tmp/xdg-test"])
        #expect(path == Self.appRootFallback)
    }

    @Test func testHomeIgnoresContainerAppRoot() {
        let path = PathUtils.BaseConfigPath.home.basePath(env: ["CONTAINER_APP_ROOT": "/tmp/foo"])
        #expect(path == Self.homeFallback)
    }
}
