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

import Darwin
import SystemPackage

extension FilePath {
    /// Returns a new `FilePath` with all symlinks resolved and `.`/`..`
    /// components normalized, by calling `realpath(3)`.
    ///
    /// Unlike ``lexicallyNormalized()``, this method accesses the file system.
    /// It throws ``Errno/noSuchFileOrDirectory`` if any component of the path
    /// does not exist.
    ///
    /// The returned path is always absolute. If the receiver is a relative path,
    /// it is resolved against the process's current working directory.
    public func resolvingSymlinks() throws -> FilePath {
        try withPlatformString { cPath in
            guard let resolved = Darwin.realpath(cPath, nil) else {
                throw Errno(rawValue: Darwin.errno)
            }
            defer { free(resolved) }
            return FilePath(platformString: resolved)
        }
    }
}
