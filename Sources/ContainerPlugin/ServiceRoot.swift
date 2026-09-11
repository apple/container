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
import SystemPackage

/// Provides the root path for launchd service registration files (plists).
///
/// This root is intentionally separate from ``ApplicationRoot`` so that service
/// registration succeeds even when the application data directory is on an
/// external or removable volume. launchd cannot register Mach services from
/// plists on such volumes, so registration files must always reside on the
/// internal system volume.
///
/// The default path resolves to a `com.apple.container` subdirectory under the
/// per-user temporary directory, which macOS always places on the internal
/// system volume regardless of where the user's home directory lives.
public struct ServiceRoot {
    /// The environment variable that, if set, determines the root directory for
    /// launchd service registration files.
    public static let environmentName = "CONTAINER_SERVICE_ROOT"

    /// The default root directory used when ``environmentName`` is not set:
    /// a `com.apple.container` subdirectory under the user's temporary directory.
    ///
    /// `NSTemporaryDirectory()` is guaranteed by macOS to reside on the internal
    /// system volume (typically `/private/var/folders/…`), making it safe for
    /// launchd plist registration even when ``ApplicationRoot`` is on an external
    /// or removable volume.
    public static let defaultPath: FilePath = {
        let tmpPath = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        precondition(
            !tmpPath.isEmpty,
            "NSTemporaryDirectory() returned an empty path; cannot determine a safe location for launchd plists"
        )
        return FilePath(tmpPath).appending(FilePath.Component("com.apple.container"))
    }()

    /// The resolved root directory path, always lexically normalized.
    ///
    /// If the environment variable is set to an absolute path, that path is used directly.
    /// If it is set to a relative path, the path is resolved against the working directory.
    /// Otherwise, ``defaultPath`` is used.
    public static let path = FilePath(FileManager.default.currentDirectoryPath).resolve(
        ProcessInfo.processInfo.environment[environmentName],
        defaultPath: defaultPath
    )

    /// The pathname to the root directory.
    public static let pathname = path.string
}
