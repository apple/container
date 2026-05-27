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

import ContainerResource

/// Plugin info passed from the API server in the sandbox bootstrap message so the
/// runtime can connect to the correct network helper and configure the interface.
public struct NetworkBootstrapInfo: Codable, Sendable {
    /// Plugin info identifying which network helper to contact and which interface
    /// strategy the runtime should use.
    public let pluginInfo: NetworkPluginInfo

    public init(pluginInfo: NetworkPluginInfo) {
        self.pluginInfo = pluginInfo
    }
}
