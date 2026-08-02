//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

@testable import ContainerPlugin

struct ServiceManagerTests {
    @Test
    func domainStringAquaUsesGuiDomain() throws {
        #expect(try ServiceManager.domainString(sessionType: "Aqua", uid: 501, euid: 501) == "gui/501")
    }

    @Test
    func domainStringBackgroundUsesUserDomain() throws {
        #expect(try ServiceManager.domainString(sessionType: "Background", uid: 501, euid: 501) == "user/501")
    }

    @Test
    func domainStringSystemSessionUsesSystemDomain() throws {
        #expect(try ServiceManager.domainString(sessionType: "System", uid: 0, euid: 0) == "system")
    }

    @Test
    func domainStringRootOutsideAquaUsesSystemDomain() throws {
        #expect(try ServiceManager.domainString(sessionType: "Background", uid: 0, euid: 0) == "system")
        #expect(try ServiceManager.domainString(sessionType: "System", uid: 0, euid: 0) == "system")
    }

    @Test
    func domainStringRootInAquaKeepsGuiDomain() throws {
        // Preserve existing Aqua behavior for interactive sudo sessions.
        #expect(try ServiceManager.domainString(sessionType: "Aqua", uid: 0, euid: 0) == "gui/0")
    }

    @Test
    func domainStringUnsupportedSessionThrows() {
        #expect(throws: (any Error).self) {
            try ServiceManager.domainString(sessionType: "LoginWindow", uid: 501, euid: 501)
        }
    }

    @Test
    func registerSurfacesLaunchctlBootstrapFailure() throws {
        let missingPlist = "/tmp/container-issue-2008-missing-\(UUID().uuidString).plist"
        do {
            try ServiceManager.register(plistPath: missingPlist)
            Issue.record("expected register to throw for missing plist")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("launchctl bootstrap"))
            #expect(message.contains(missingPlist))
            #expect(message.contains("failed with status"))
        }
    }
}
