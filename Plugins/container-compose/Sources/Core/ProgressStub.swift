//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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

// Temporary stub for ProgressBar to allow plugin to build independently
// TODO: Extract TerminalProgress as a separate package

public struct ProgressConfig {
    public let description: String
    public let showTasks: Bool
    public let showItems: Bool
    
    public init(description: String, showTasks: Bool = true, showItems: Bool = false) throws {
        self.description = description
        self.showTasks = showTasks
        self.showItems = showItems
    }
}

public enum ProgressUpdateEvent: Sendable {
    case setDescription(String)
    case setSubDescription(String)
    case setItemsName(String)
    case addTasks(Int)
    case setTasks(Int)
    case addTotalTasks(Int)
    case setTotalTasks(Int)
    case addItems(Int)
    case setItems(Int)
    case addTotalItems(Int)
    case setTotalItems(Int)
    case addSize(Int64)
    case setSize(Int64)
    case addTotalSize(Int64)
    case setTotalSize(Int64)
    case custom(String)
}

public typealias ProgressUpdateHandler = @Sendable (_ events: [ProgressUpdateEvent]) async -> Void

public class ProgressBar {
    private let config: ProgressConfig
    public var handler: ProgressUpdateHandler = { _ in }
    
    public init(config: ProgressConfig) {
        self.config = config
        print("[\(config.description)]")
    }
    
    public func start() {
        // No-op for now
    }
    
    public func finish() {
        print("✓ \(config.description) complete")
    }
}
