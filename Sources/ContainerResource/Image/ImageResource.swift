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


/// NOTE: This is just a basic representation of the ImageResource and will be stripped out and/or updated before merge.
/// This was needed in order to use the ManagedResourceError and ManagedResourcePartialError types

import Foundation

/// A named or anonymous volume that can be mounted in containers.
public struct ImageResource: ManagedResource {
    // Associated error codes with the image
    public typealias ErrorCode = ImageErrorCode
    // Id of the image.
    public var id: String { name }
    // Name of the image.
    public let name: String
    // Timestamp when the volume was created.
    public var creationDate: Date
    // User-defined key/value metadata.
    public var labels: [String: String]

    public init(
        name: String?,
        creationDate: Date,
        labels: [String: String] = [:],
    ) {
        self.name = name ?? ""
        self.creationDate = creationDate
        self.labels = labels
    }

    public static func nameValid(_ name: String) -> Bool {
        // TODO
        true
    }
}

/// Error codes for volume operations.
public enum ImageErrorCode: ManagedResourceErrorCode {
    case imageNotFound
}
