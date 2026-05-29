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

import Foundation

/// Linux-specific runtime data passed through the opaque runtimeData field
/// in RuntimeConfiguration. Encoded by the CLI, decoded by the Linux runtime.
public struct LinuxRuntimeData: Codable, Sendable {
    /// Runtime variant identifier.
    public let variant: String?
    /// Path to the kernel binary on the host.
    public let kernelPath: String
    /// Reference to the init image (resolved from local cache at bootstrap).
    public let initImageRef: String
    /// Reference to the container root image (resolved from local cache at bootstrap).
    /// Nil when using rootFsOverride.
    public let imageRef: String?

    public init(
        variant: String? = nil,
        kernelPath: String,
        initImageRef: String,
        imageRef: String?
    ) {
        self.variant = variant
        self.kernelPath = kernelPath
        self.initImageRef = initImageRef
        self.imageRef = imageRef
    }

    /// Encode Linux-specific runtime data into an opaque blob to pass through the API server.
    public static func encodeData(
        kernelPath: String,
        initImageRef: String,
        imageRef: String?,
        variant: String? = nil
    ) throws -> Data {
        let data = LinuxRuntimeData(
            variant: variant,
            kernelPath: kernelPath,
            initImageRef: initImageRef,
            imageRef: imageRef
        )
        return try JSONEncoder().encode(data)
    }

    /// Decode Linux-specific runtime data from the opaque blob.
    public static func decodeData(_ data: Data) throws -> LinuxRuntimeData {
        try JSONDecoder().decode(LinuxRuntimeData.self, from: data)
    }
}
