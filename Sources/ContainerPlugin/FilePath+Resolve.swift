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
    func resolve(_ pathname: String?) -> FilePath? {
        guard let pathname, !pathname.isEmpty else { return nil }
        let path = FilePath(pathname)
        guard !path.isAbsolute else { return path }
        return self.appending(path.components)
    }

    func resolve(_ pathname: String?, defaultPath: FilePath) -> FilePath {
        resolve(pathname) ?? defaultPath
    }
}
