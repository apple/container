//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import SystemPackage

/// Represents a socket that should be published from container to host.
public struct PublishSocket: Sendable, Codable {
    /// The path to the socket in the container.
    public var containerPath: URL

    /// The path where the socket should appear on the host.
    public var hostPath: URL

    /// File permissions for the socket on the host.
    public var permissions: FilePermissions?

    public init(
        containerPath: URL,
        hostPath: URL,
        permissions: FilePermissions? = nil
    ) {
        self.containerPath = containerPath
        self.hostPath = hostPath
        self.permissions = permissions
    }
}
