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

import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation

extension ImageResource: ListDisplayable {
    public static var tableHeader: [String] {
        ["NAME", "TAG", "DIGEST", "DISK USAGE"]
    }

    public var tableRow: [String] {
        // `displayReference` is already denormalized by the caller.
        let reference = try? ContainerizationOCI.Reference.parse(displayReference)
        return [
            reference?.name ?? displayReference,
            reference?.tag ?? "<none>",
            Utility.trimDigest(digest: configuration.descriptor.digest),
            formattedDiskUsage,
        ]
    }

    public var quietValue: String {
        name
    }

    private var diskUsage: Int64 {
        variants
            // Skip attestation manifests, which use the `unknown/unknown` platform.
            .filter { !($0.platform.os == "unknown" && $0.platform.architecture == "unknown") }
            .reduce(0) { $0 + $1.size }
    }

    private var formattedDiskUsage: String {
        let formatter = ByteCountFormatter()
        return formatter.string(fromByteCount: diskUsage)
    }
}
