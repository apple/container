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
import ContainerizationOCI
import Foundation
import Logging

/// Picks the platform to run from the platforms an image provides.
///
/// Order: explicit flags filter candidates; one match wins; several fall back to the default.
enum PlatformResolver {
    private static let wildcard = "*"

    static func resolve(
        platform: Platform?,
        os: String?,
        arch: String?,
        candidates: [Platform],
        reference: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: Logger? = nil
    ) throws -> Platform {
        // Check if any of the images matches the provided platform OR os/arch
        let matches = candidates.filter { isMatch($0, platform: platform, os: os, arch: arch) }

        guard !matches.isEmpty else {
            let requested = platform?.description ?? "\(os ?? wildcard)/\(arch ?? wildcard)"
            throw ContainerizationError(.unsupported, message: "image \(reference) does not support \(requested); available: \(candidates)")
        }

        if matches.count == 1 {
            return matches[0]
        }

        // If there are multiple partial matches, in the case of no provided platform AND EITHER os and arch are present
        // then we refer to the fallback platform.
        let defaultPlatform = try DefaultPlatform.fallback(environment: environment, log: log)
        guard let chosen = matches.first(where: { $0 == defaultPlatform }) else {
            throw ContainerizationError(
                .invalidArgument, message: "image \(reference) has multiple platforms (\(matches)); pass --os/--arch or set a default")
        }
        return chosen
    }

    /// Check if a given `candidate` is compatible with the platform OR os/arch
    ///
    /// It has the logic:
    /// * If `platform` is provided, utilize that for equality
    /// * Else utilize os/arch for equality IF present, if not present treat as a match
    private static func isMatch(_ candidate: Platform, platform: Platform?, os: String?, arch: String?) -> Bool {
        if let platform {
            return candidate == platform
        }

        let osMatches = os.map { $0 == candidate.os } ?? true

        // Normalizes aliases such as aarch64 → arm64.
        let archMatches = arch.map { Platform(arch: $0, os: candidate.os).architecture == candidate.architecture } ?? true

        return osMatches && archMatches
    }
}
