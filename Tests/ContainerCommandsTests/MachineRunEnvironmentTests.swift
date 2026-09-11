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

import ContainerResource
import ContainerizationOCI
import Foundation
import MachineAPIClient
import Testing

@testable import ContainerCommands

@Suite("MachineRun base environment")
struct MachineRunEnvironmentTests {
    private static func configuration(username: String, uid: UInt32 = 501, gid: UInt32 = 20) throws -> MachineConfiguration {
        try MachineConfiguration(
            id: "test-machine",
            image: ImageDescription(
                reference: "ghcr.io/apple/container/machine:latest",
                descriptor: Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:0", size: 0)
            ),
            platform: Platform(arch: "arm64", os: "linux"),
            userSetup: UserSetup(username: username, uid: uid, gid: gid)
        )
    }

    /// The guest resolves the login shell from CONTAINER_USER. It cannot recover the
    /// name from the UID alone, because the image may already use that UID under a
    /// different name and `id -un` reports whichever name comes first in /etc/passwd.
    @Test func passesUsernameWhenRunningAsTheMachineUser() throws {
        let config = try Self.configuration(username: "alice")
        let env = Application.MachineRun.baseEnvironment(configuration: config, user: config.user)

        #expect(env.contains("CONTAINER_USER=alice"))
        #expect(env.contains(Application.MachineRun.defaultPath))
    }

    @Test func omitsUsernameWhenRunningAsRoot() throws {
        let config = try Self.configuration(username: "alice")
        let env = Application.MachineRun.baseEnvironment(configuration: config, user: .id(uid: 0, gid: 0))

        #expect(!env.contains { $0.hasPrefix("CONTAINER_USER=") })
        #expect(env == [Application.MachineRun.defaultPath])
    }

    @Test func omitsUsernameWhenRunningAsAnotherUser() throws {
        let config = try Self.configuration(username: "alice")
        let env = Application.MachineRun.baseEnvironment(configuration: config, user: .raw(userString: "bob"))

        #expect(!env.contains { $0.hasPrefix("CONTAINER_USER=") })
    }

    /// Machines provisioned before usernames were recorded fall back to numeric
    /// credentials, and have no name to pass through.
    @Test func omitsUsernameWhenTheConfigurationHasNone() throws {
        let config = try Self.configuration(username: "")
        let env = Application.MachineRun.baseEnvironment(configuration: config, user: config.user)

        #expect(config.user == .id(uid: 501, gid: 20))
        #expect(env == [Application.MachineRun.defaultPath])
    }
}
