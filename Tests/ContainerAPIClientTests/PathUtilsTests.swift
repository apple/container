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
    @Test func testHomeBasePathDefault() {
        let path = PathUtils.BaseConfigPath.home.basePath()
        let expectedBase: String
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            expectedBase = xdg
        } else {
            expectedBase = NSHomeDirectory() + "/.config"
        }
        let expected = FilePath(expectedBase).appending("container")
        #expect(path == expected)
    }

    @Test func testAppRootBasePathDefault() {
        let path = PathUtils.BaseConfigPath.appRoot.basePath()
        if let envPath = ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"], !envPath.isEmpty {
            #expect(path == FilePath(envPath))
        } else {
            let appSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!.appendingPathComponent("com.apple.container")
            let expected = FilePath(appSupportURL.path(percentEncoded: false))
            #expect(path == expected)
        }
    }
}
