//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

extension ProgressBar {
    /// A handler function to update the progress bar.
    /// - Parameter events: The events to handle.
    public func handler(_ events: [ProgressUpdateEvent]) {
        for event in events {
            switch event {
            case .setDescription(let description):
                set(description: description)
            case .setSubDescription(let subDescription):
                set(subDescription: subDescription)
            case .setItemsName(let itemsName):
                set(itemsName: itemsName)
            case .addTasks(let tasks):
                add(tasks: tasks)
            case .setTasks(let tasks):
                set(tasks: tasks)
            case .addTotalTasks(let totalTasks):
                add(totalTasks: totalTasks)
            case .setTotalTasks(let totalTasks):
                set(totalTasks: totalTasks)
            case .addSize(let size):
                add(size: size)
            case .setSize(let size):
                set(size: size)
            case .addTotalSize(let totalSize):
                add(totalSize: totalSize)
            case .setTotalSize(let totalSize):
                set(totalSize: totalSize)
            case .addItems(let items):
                add(items: items)
            case .setItems(let items):
                set(items: items)
            case .addTotalItems(let totalItems):
                add(totalItems: totalItems)
            case .setTotalItems(let totalItems):
                set(totalItems: totalItems)
            case .custom:
                // Custom events are handled by the client.
                break
            }
        }
    }

    /// Performs a check to see if the progress bar should be finished.
    public func checkIfFinished() {
        var finished = true
        var defined = false
        if let totalTasks = state.totalTasks, totalTasks > 0 {
            // For tasks, we're showing the current task rather than the number of completed tasks.
            finished = finished && state.tasks == totalTasks
            defined = true
        }
        if let totalItems = state.totalItems, totalItems > 0 {
            finished = finished && state.items == totalItems
            defined = true
        }
        if let totalSize = state.totalSize, totalSize > 0 {
            finished = finished && state.size == totalSize
            defined = true
        }
        if defined && finished {
            finish()
        }
    }

    /// Sets the current tasks.
    /// - Parameter newTasks: The current tasks to set.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func set(tasks newTasks: Int, render: Bool = true) {
        state.tasks = newTasks
        if render {
            self.render()
        }
        checkIfFinished()
    }

    /// Performs an addition to the current tasks.
    /// - Parameter delta: The tasks to add to the current tasks.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func add(tasks delta: Int, render: Bool = true) {
        _state.withLock {
            let newTasks = $0.tasks + delta
            $0.tasks = newTasks
        }
        if render {
            self.render()
        }
    }

    /// Sets the total tasks.
    /// - Parameter newTotalTasks: The total tasks to set.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func set(totalTasks newTotalTasks: Int, render: Bool = true) {
        state.totalTasks = newTotalTasks
        if render {
            self.render()
        }
    }

    /// Performs an addition to the total tasks.
    /// - Parameter delta: The tasks to add to the total tasks.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func add(totalTasks delta: Int, render: Bool = true) {
        _state.withLock {
            let totalTasks = $0.totalTasks ?? 0
            let newTotalTasks = totalTasks + delta
            $0.totalTasks = newTotalTasks
        }
        if render {
            self.render()
        }
    }

    /// Sets the items name.
    /// - Parameter newItemsName: The current items to set.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func set(itemsName newItemsName: String, render: Bool = true) {
        state.itemsName = newItemsName
        if render {
            self.render()
        }
    }

    /// Sets the current items.
    /// - Parameter newItems: The current items to set.
    public func set(items newItems: Int, render: Bool = true) {
        state.items = newItems
        if render {
            self.render()
        }
    }

    /// Performs an addition to the current items.
    /// - Parameter delta: The items to add to the current items.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func add(items delta: Int, render: Bool = true) {
        _state.withLock {
            let newItems = $0.items + delta
            $0.items = newItems
        }
        if render {
            self.render()
        }
    }

    /// Sets the total items.
    /// - Parameter newTotalItems: The total items to set.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func set(totalItems newTotalItems: Int, render: Bool = true) {
        state.totalItems = newTotalItems
        if render {
            self.render()
        }
    }

    /// Performs an addition to the total items.
    /// - Parameter delta: The items to add to the total items.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func add(totalItems delta: Int, render: Bool = true) {
        _state.withLock {
            let totalItems = $0.totalItems ?? 0
            let newTotalItems = totalItems + delta
            $0.totalItems = newTotalItems
        }
        if render {
            self.render()
        }
    }

    /// Sets the current size.
    /// - Parameter newSize: The current size to set.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func set(size newSize: Int64, render: Bool = true) {
        state.size = newSize
        if render {
            self.render()
        }
    }

    /// Performs an addition to the current size.
    /// - Parameter delta: The size to add to the current size.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func add(size delta: Int64, render: Bool = true) {
        _state.withLock {
            let newSize = $0.size + delta
            $0.size = newSize
        }
        if render {
            self.render()
        }
    }

    /// Sets the total size.
    /// - Parameter newTotalSize: The total size to set.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func set(totalSize newTotalSize: Int64, render: Bool = true) {
        state.totalSize = newTotalSize
        if render {
            self.render()
        }
    }

    /// Performs an addition to the total size.
    /// - Parameter delta: The size to add to the total size.
    /// - Parameter render: The flag indicating whether the progress bar has to render after the update.
    public func add(totalSize delta: Int64, render: Bool = true) {
        _state.withLock {
            let totalSize = $0.totalSize ?? 0
            let newTotalSize = totalSize + delta
            $0.totalSize = newTotalSize
        }
        if render {
            self.render()
        }
    }
}
