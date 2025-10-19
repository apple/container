//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

public protocol ProgressAdapter {
    associatedtype T
    static func handler(from progressUpdate: ProgressUpdateHandler?) -> (@Sendable ([T]) async -> Void)?
}
