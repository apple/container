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
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

/// User configuration created during first boot provisioning.
/// Stores the mapping between host user and container machine user.
public struct UserSetup: Sendable, Codable, Equatable {
    public var username: String
    public var uid: UInt32
    public var gid: UInt32

    public var home: String {
        "/home/\(username)"
    }

    public var user: ProcessConfiguration.User {
        .id(uid: uid, gid: gid)
    }

    public init(username: String, uid: UInt32, gid: UInt32) {
        self.username = username
        self.uid = uid
        self.gid = gid
    }
}

public struct MachineConfiguration: Sendable, Codable {
    public static let containerUUIDLength = 6

    public static let defaultDNSDomain = "machine"

    /// Identifier for the container machine.
    public var id: String
    /// Image used to create the container machine.
    public var image: ImageDescription
    /// Platform for the container machine
    public var platform: ContainerizationOCI.Platform
    /// User setup from first boot. Nil means provisioning has not run yet.
    public var userSetup: UserSetup

    public var user: ProcessConfiguration.User {
        userSetup.user
    }

    public var home: String {
        userSetup.home
    }

    public var processEnvironment: [String] {
        [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",

            "CONTAINER_MACHINE_ID=\(id)",
            "CONTAINER_USER=\(userSetup.username)",
            "CONTAINER_HOME=\(userSetup.home)",
            "CONTAINER_UID=\(userSetup.uid)",
            "CONTAINER_GID=\(userSetup.gid)",
        ]
    }

    public var dnsName: String {
        "\(id.lowercased()).\(Self.defaultDNSDomain)"
    }

    public var dnsHostname: String {
        "\(dnsName)."
    }

    public init(
        id: String,
        image: ImageDescription,
        platform: ContainerizationOCI.Platform,
        userSetup: UserSetup
    ) throws {
        self.id = id
        self.image = image
        self.platform = platform
        self.userSetup = userSetup

        try self.validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(String.self, forKey: .id)
        self.image = try container.decode(ImageDescription.self, forKey: .image)
        self.platform = try container.decode(ContainerizationOCI.Platform.self, forKey: .platform)
        // DEPRECATED 0.11.0.0 - `decodeIfPresent` used for down-revision compatibility, remove in 0.13.0.0
        self.userSetup = try container.decodeIfPresent(UserSetup.self, forKey: .userSetup) ?? UserSetup(username: NSUserName(), uid: getuid(), gid: getgid())

        try self.validate()
    }

    private func validate() throws {
        let maxNameLength = LinuxContainer.maxIDLength - Self.containerUUIDLength - 1
        guard self.id.count <= maxNameLength else {
            throw ContainerizationError(.invalidArgument, message: "machine name cannot be longer than \(maxNameLength)")
        }

        let pattern = #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"#
        let regex = try Regex(pattern)
        guard try regex.firstMatch(in: id.lowercased()) != nil else {
            throw ContainerizationError(
                .invalidArgument,
                message: "machine name '\(id)' must start and end with a lowercase letter or digit, and contain only lowercase letters, digits, and hyphens"
            )
        }
    }
}
