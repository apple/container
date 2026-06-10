//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import Darwin
import Foundation
import SystemPackage

extension Bundle {
    /// Retrieves the application bundle for a path that refers to a macOS executable.
    ///
    /// Resolves symlinks in `executablePath`, then walks up the standard macOS bundle layout
    /// (`MacOS/` → `Contents/` → `Foo.app/`) and verifies the `.app` extension.
    ///
    /// - Parameter executablePath: The path to a macOS executable inside a bundle.
    /// - Returns: The ``Bundle`` at the resolved `.app` directory, or `nil` if the executable
    ///   is not inside a valid macOS application bundle.
    public static func appBundle(executablePath: FilePath) -> Bundle? {
        let resolvedPath =
            executablePath.withPlatformString { cPath in
                Darwin.realpath(cPath, nil).map { ptr -> FilePath in
                    defer { free(ptr) }
                    return FilePath(platformString: ptr)
                }
            } ?? executablePath
        let bundlePath =
            resolvedPath
            .removingLastComponent()  // MacOS/
            .removingLastComponent()  // Contents/
            .removingLastComponent()  // Foo.app/
        guard bundlePath.lastComponent?.extension == "app" else { return nil }
        return Bundle(url: URL(fileURLWithPath: bundlePath.string))
    }
}
