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

public enum PathUtils {
    public enum BaseConfigPath {
        case home
        case appRoot

        public func basePath(env: [String: String] = ProcessInfo.processInfo.environment) -> FilePath {
            switch self {
            case .home:
                let configHome: String
                if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
                    configHome = xdg
                } else {
                    configHome = NSHomeDirectory() + "/.config"
                }
                return FilePath(configHome).appending("container")
            case .appRoot:
                if let envPath = env["CONTAINER_APP_ROOT"], !envPath.isEmpty {
                    return FilePath(envPath)
                }
                let appSupportURL = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first!.appendingPathComponent("com.apple.container")
                return FilePath(appSupportURL.path(percentEncoded: false))
            }
        }
    }
}
