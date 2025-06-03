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
        if let totalTasks = state.totalTasks {
            // For tasks, we're showing the current task rather then the number of completed tasks.
            guard state.tasks > totalTasks else {
                return
            }
        }
        if let totalItems = state.totalItems {
            guard state.items == totalItems else {
                return
            }
        }
        if let totalSize = state.totalSize {
            guard state.size == totalSize else {
                return
            }
        }
        finish()
    }

    /// Sets the current tasks.
    /// - Parameter tasks: The current tasks to set.
    public func set(tasks newTasks: Int, render: Bool = true) {
        state.tasks = newTasks
        if render {
            self.render()
        }
        checkIfFinished()
    }

    /// Performs an addition to the current tasks.
    /// - Parameter tasks: The tasks to add to the current tasks.
    public func add(tasks toAdd: Int, render: Bool = true) {
        let newTasks = state.tasks + toAdd
        set(tasks: newTasks, render: render)
    }

    /// Sets the total tasks.
    /// - Parameter totalTasks: The total tasks to set.
    public func set(totalTasks newTotalTasks: Int, render: Bool = true) {
        state.totalTasks = newTotalTasks
        if render {
            self.render()
        }
    }

    /// Performs an addition to the total tasks.
    /// - Parameter totalTasks: The tasks to add to the total tasks.
    public func add(totalTasks toAdd: Int, render: Bool = true) {
        let totalTasks = state.totalTasks ?? 0
        let newTotalTasks = totalTasks + toAdd
        set(totalTasks: newTotalTasks, render: render)
    }

    /// Sets the items name.
    /// - Parameter items: The current items to set.
    public func set(itemsName newItemsName: String, render: Bool = true) {
        state.itemsName = newItemsName
        if render {
            self.render()
        }
    }

    /// Sets the current items.
    /// - Parameter items: The current items to set.
    public func set(items newItems: Int, render: Bool = true) {
        state.items = newItems
        if render {
            self.render()
        }
    }

    /// Performs an addition to the current items.
    /// - Parameter items: The items to add to the current items.
    public func add(items toAdd: Int, render: Bool = true) {
        let newItems = state.items + toAdd
        set(items: newItems, render: render)
    }

    /// Sets the total items.
    /// - Parameter totalItems: The total items to set.
    public func set(totalItems newTotalItems: Int, render: Bool = true) {
        state.totalItems = newTotalItems
        if render {
            self.render()
        }
    }

    /// Performs an addition to the total items.
    /// - Parameter totalItems: The items to add to the total items.
    public func add(totalItems toAdd: Int, render: Bool = true) {
        let totalItems = state.totalItems ?? 0
        let newTotalItems = totalItems + toAdd
        set(totalItems: newTotalItems, render: render)
    }

    /// Sets the current size.
    /// - Parameter size: The current size to set.
    public func set(size newSize: Int64, render: Bool = true) {
        state.size = newSize
        if render {
            self.render()
        }
    }

    /// Performs an addition to the current size.
    /// - Parameter size: The size to add to the current size.
    public func add(size toAdd: Int64, render: Bool = true) {
        let newSize = state.size + toAdd
        set(size: newSize, render: render)
    }

    /// Sets the total size.
    /// - Parameter totalSize: The total size to set.
    public func set(totalSize newTotalSize: Int64, render: Bool = true) {
        state.totalSize = newTotalSize
        if render {
            self.render()
        }
    }

    /// Performs an addition to the total size.
    /// - Parameter totalSize: The size to add to the total size.
    public func add(totalSize toAdd: Int64, render: Bool = true) {
        let totalSize = state.totalSize ?? 0
        let newTotalSize = totalSize + toAdd
        set(totalSize: newTotalSize, render: render)
    }
}
