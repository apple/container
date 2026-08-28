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

import ContainerizationOCI
import Foundation

/// Linux-specific runtime data passed through the opaque runtimeData field
/// in RuntimeConfiguration. Encoded by the CLI, decoded by the Linux runtime.
public struct LinuxRuntimeData: Codable, Sendable {
    public let variant: String?
    /// Block I/O cgroup tuning (Linux-specific, carried opaquely through
    /// `RuntimeConfiguration.runtimeData`).
    public let blockIO: ContainerizationOCI.LinuxBlockIO?

    public init(variant: String? = nil, blockIO: ContainerizationOCI.LinuxBlockIO? = nil) {
        self.variant = variant
        self.blockIO = blockIO
    }
}
