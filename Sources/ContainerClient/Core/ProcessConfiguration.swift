//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

/// Configuration data for an executable Process.
public struct ProcessConfiguration: Sendable, Codable {
    /// The on disk path to the executable binary.
    public var executable: String
    /// Arguments passed to the Process.
    public var arguments: [String]
    /// Environment variables for the Process.
    public var environment: [String]
    /// The current working directory (cwd) for the Process.
    public var workingDirectory: String
    /// A boolean value indicating if a Terminal or PTY device should
    /// be attached to the Process's Standard I/O.
    public var terminal: Bool
    /// The User a Process should execute under.
    public var user: User
    /// Supplemental groups for the Process.
    public var supplementalGroups: [UInt32]
    /// Rlimits for the Process.
    public var rlimits: [Rlimit]

    /// Rlimits for Processes.
    public struct Rlimit: Sendable, Codable {
        /// The Rlimit type of the Process.
        ///
        /// Values include standard Rlimit resource types, i.e. RLIMIT_NPROC, RLIMIT_NOFILE, ...
        public let limit: String
        /// The soft limit of the Process
        public let soft: UInt64
        /// The hard or max limit of the Process.
        public let hard: UInt64

        public init(limit: String, soft: UInt64, hard: UInt64) {
            self.limit = limit
            self.soft = soft
            self.hard = hard
        }
    }

    /// The User information for a Process.
    public enum User: Sendable, Codable, CustomStringConvertible {
        /// Given the raw user string  of the form <uid:gid> or <user:group> or <user> lookup the uid/gid within
        /// the container before setting it for the Process.
        case raw(userString: String)
        /// Set the provided uid/gid for the Process.
        case id(uid: UInt32, gid: UInt32)

        public var description: String {
            switch self {
            case .id(let uid, let gid):
                return "\(uid):\(gid)"
            case .raw(let name):
                return name
            }
        }
    }

    public init(
        executable: String,
        arguments: [String],
        environment: [String],
        workingDirectory: String = "/",
        terminal: Bool = false,
        user: User = .id(uid: 0, gid: 0),
        supplementalGroups: [UInt32] = [],
        rlimits: [Rlimit] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        self.supplementalGroups = supplementalGroups
        self.rlimits = rlimits
    }
}
