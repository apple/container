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

/// The policy applied when a container's init process exits.
///
/// The command-line spelling is Docker-compatible: `no`, `always`, `on-failure` and
/// `on-failure:<max-retries>`. Swift spellings such as `onFailure` are rejected.
public enum RestartPolicy: Sendable, Equatable, Codable {
    /// Never restart the container.
    case no
    /// Restart only when the container exits with a non-zero exit code, at most
    /// `maximumRetryCount` times. 0 means unlimited retries, matching Docker/Moby
    /// (`MaximumRetryCount == 0`).
    case onFailure(maximumRetryCount: Int)
    /// Always restart the container, unless it was manually stopped.
    case always

    public init(parsing value: String) throws {
        switch value {
        case "no": self = .no
        case "always": self = .always
        case "on-failure": self = .onFailure(maximumRetryCount: 0)
        default:
            let prefix = "on-failure:"
            guard value.hasPrefix(prefix) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "invalid restart policy '\(value)': expected one of no, always, on-failure, on-failure:<max-retries>"
                )
            }
            let count = value.dropFirst(prefix.count)
            // Only plain decimal digits: reject signs, whitespace, and empty strings.
            guard !count.isEmpty, count.allSatisfy({ $0 >= "0" && $0 <= "9" }), let max = Int(count) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "invalid restart policy '\(value)': max-retries must be a non-negative integer"
                )
            }
            self = .onFailure(maximumRetryCount: max)
        }
    }

    /// The Docker-compatible command-line spelling.
    public var cliValue: String {
        switch self {
        case .no: "no"
        case .always: "always"
        case .onFailure(let max): max > 0 ? "on-failure:\(max)" : "on-failure"
        }
    }
}

public struct ContainerCreateOptions: Codable, Sendable {
    /// Remove the container and wipe out its data on container stop
    public let autoRemove: Bool
    /// Override the rootFs with this one other than the image-cloned version
    public let rootFsOverride: Filesystem?
    public let restartPolicy: RestartPolicy

    public init(autoRemove: Bool, restartPolicy: RestartPolicy = .no, rootFsOverride: Filesystem? = nil) {
        self.autoRemove = autoRemove
        self.restartPolicy = restartPolicy
        self.rootFsOverride = rootFsOverride
    }

    /// Validates option combinations that must be rejected before a container is created.
    public func validate() throws {
        if case .onFailure(let max) = restartPolicy, max < 0 {
            throw ContainerizationError(
                .invalidArgument,
                message: "invalid restart policy: max-retries must be non-negative"
            )
        }
        if autoRemove && restartPolicy != .no {
            throw ContainerizationError(
                .invalidArgument,
                message: "conflicting options: --rm cannot be used with --restart \(restartPolicy.cliValue)"
            )
        }
    }

    public static let `default` = ContainerCreateOptions(autoRemove: false, restartPolicy: .no)

    enum CodingKeys: String, CodingKey {
        case autoRemove
        case restartPolicy
        case rootFsOverride
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        autoRemove = try container.decode(Bool.self, forKey: .autoRemove)
        restartPolicy = try container.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy) ?? .no
        rootFsOverride = try container.decodeIfPresent(Filesystem.self, forKey: .rootFsOverride)
    }
}
