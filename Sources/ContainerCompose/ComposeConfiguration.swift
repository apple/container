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

import ContainerPersistence
import ContainerizationOCI
import Foundation

/// Configuration scoped to the Compose plugin.
struct ComposeConfiguration: LoadablePluginConfiguration {
    static let pluginId = "compose"
    static let defaultImage = "container-compose-machine:local"

    static func isValidImage(_ image: String) -> Bool {
        guard !image.isEmpty else { return false }
        return (try? Reference.parse(image)) != nil
    }

    var cpus: Int
    var memory: MemorySize
    var idleShutdownSeconds: Int

    init() {
        self.cpus = 4
        self.memory = try! MemorySize("4gb")
        self.idleShutdownSeconds = 0
    }

    init(
        cpus: Int = 4,
        memory: MemorySize = try! MemorySize("4gb"),
        idleShutdownSeconds: Int = 0
    ) {
        self.cpus = cpus
        self.memory = memory
        self.idleShutdownSeconds = idleShutdownSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case cpus
        case memory
        case idleShutdownSeconds = "idle-shutdown-seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cpus = try container.decodeIfPresent(Int.self, forKey: .cpus) ?? 4
        self.memory = try container.decodeIfPresent(MemorySize.self, forKey: .memory) ?? (try MemorySize("4gb"))
        self.idleShutdownSeconds = try container.decodeIfPresent(Int.self, forKey: .idleShutdownSeconds) ?? 0
        if idleShutdownSeconds < 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .idleShutdownSeconds,
                in: container,
                debugDescription: "idle-shutdown-seconds must not be negative"
            )
        }
    }
}
