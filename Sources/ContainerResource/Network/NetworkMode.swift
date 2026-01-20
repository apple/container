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

/// Networking mode that applies to client containers.
public enum NetworkMode: String, Codable, Sendable {
    /// NAT networking mode.
    /// Containers do not have routable IPs, and the host performs network
    /// address translation to allow containers to reach external services.
    case nat = "nat"

    /// Host only networking mode
    /// Containers can talk with each other in the same subnet only.
    case hostOnly = "hostOnly"
}

extension NetworkMode {
    public init() {
        self = .nat
    }

    public init?(_ value: String) {
        switch value.lowercased() {
        case "nat": self = .nat
        case "hostOnly": self = .hostOnly
        default: return nil
        }
    }
}
