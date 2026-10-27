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
import Virtualization

/// Pre-flight checks for container machine settings that depend on host capabilities.
enum MachineCapabilities {
    /// Throws when the host can't run a VM with `isNestedVirtualizationEnabled = true`.
    /// Apple Silicon M3+ with macOS 15+ is required.
    static func requireNestedVirtualizationSupported() throws {
        guard VZGenericPlatformConfiguration.isNestedVirtualizationSupported else {
            throw ContainerizationError(
                .unsupported,
                message: "nested virtualization is not supported on this host (requires Apple Silicon M3+ and macOS 15+)"
            )
        }
    }
}
