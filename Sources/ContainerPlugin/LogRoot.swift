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

/// Provides the application data root path.
public struct LogRoot {
    /// The environment variable that if set, determines the root directory for log files.
    /// Otherwise, the application uses the macOS log facility.
    public static let environmentName = "CONTAINER_LOG_ROOT"

    /// The path object for the root directory
    public static let path = resolve(
        ProcessInfo.processInfo.environment[environmentName],
        currentDirectory: FilePath(FileManager.default.currentDirectoryPath)
    )

    /// The pathname to the root directory
    public static let pathname = path?.string

    static func resolve(_ rawValue: String?, currentDirectory: FilePath) -> FilePath? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let p = FilePath(rawValue)
        guard !p.isAbsolute else { return p }
        return currentDirectory.appending(p.components)
    }
}
