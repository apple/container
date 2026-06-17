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
import Foundation
import Virtualization

/// Pre-flight checks for container machine settings that depend on host capabilities
/// or local filesystem state.
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

    /// Resolves the user-supplied kernel path to absolute and confirms it points to a
    /// readable, non-empty regular file. Returns the absolute path.
    static func validateKernelPath(_ path: String) throws -> String {
        let absolute = URL(fileURLWithPath: path).path
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: absolute, isDirectory: &isDirectory) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel binary not found at '\(absolute)'"
            )
        }
        guard !isDirectory.boolValue else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel path '\(absolute)' is a directory, expected a file"
            )
        }
        guard fm.isReadableFile(atPath: absolute) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel binary at '\(absolute)' is not readable"
            )
        }
        let attrs = try fm.attributesOfItem(atPath: absolute)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard size > 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel binary at '\(absolute)' is empty"
            )
        }
        return absolute
    }
}
