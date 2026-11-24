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

#if os(macOS)
import ContainerXPC
import Foundation

public enum ClusterServiceXPCKeys: String {
    case configuration
    case name
    case cluster
    case clusters
}

extension XPCMessage {
    public func set(key: ClusterServiceXPCKeys, value: String) { self.set(key: key.rawValue, value: value) }
    public func set(key: ClusterServiceXPCKeys, value: Data) { self.set(key: key.rawValue, value: value) }
    public func string(key: ClusterServiceXPCKeys) -> String? { self.string(key: key.rawValue) }
    public func data(key: ClusterServiceXPCKeys) -> Data? { self.data(key: key.rawValue) }
    public func dataNoCopy(key: ClusterServiceXPCKeys) -> Data? { self.dataNoCopy(key: key.rawValue) }
}
#endif
