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

import SystemPackage

extension FilePath {
    /// Resolves a pathname string relative to this path.
    ///
    /// The result is lexically normalized — `.` components are removed and `..` components
    /// collapse the preceding component. Absolute pathnames are returned normalized as-is;
    /// relative pathnames are appended to `self` before normalizing.
    ///
    /// - Parameter pathname: The pathname to resolve.
    /// - Returns: The resolved ``FilePath``, or `nil` if `pathname` is `nil` or empty.
    package func resolve(_ pathname: String?) -> FilePath? {
        guard let pathname, !pathname.isEmpty else { return nil }
        let path = FilePath(pathname)
        guard !path.isAbsolute else { return path.lexicallyNormalized() }
        return self.appending(path.components).lexicallyNormalized()
    }

    /// Resolves a pathname string relative to this path, falling back to a default.
    ///
    /// The result is lexically normalized — `.` components are removed and `..` components
    /// collapse the preceding component. Absolute pathnames are returned normalized as-is;
    /// relative pathnames are appended to `self` before normalizing.
    ///
    /// - Parameters:
    ///   - pathname: The pathname to resolve.
    ///   - defaultPath: The path returned when `pathname` is `nil` or empty.
    /// - Returns: The resolved ``FilePath``, or `defaultPath` lexically normalized if `pathname` is `nil` or empty.
    package func resolve(_ pathname: String?, defaultPath: FilePath) -> FilePath {
        resolve(pathname) ?? defaultPath.lexicallyNormalized()
    }
}
