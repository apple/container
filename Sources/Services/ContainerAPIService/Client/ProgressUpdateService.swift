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

import ContainerXPC
import ContainerizationExtras
import Foundation
import TerminalProgress

/// A service that sends progress updates to the client.
public actor ProgressUpdateService {
    private let endpointConnection: xpc_connection_t

    /// Creates a new instance for sending progress updates to the client.
    /// - Parameter message: The XPC message that contains the endpoint to connect to.
    public init?(message: XPCMessage) {
        guard let progressUpdateEndpoint = message.endpoint(key: .progressUpdateEndpoint) else {
            return nil
        }
        endpointConnection = xpc_connection_create_from_endpoint(progressUpdateEndpoint)
        xpc_connection_set_event_handler(endpointConnection) { _ in }
        // This connection will be closed by the client.
        xpc_connection_activate(endpointConnection)
    }

    /// Performs a progress update.
    /// - Parameter events: The events that represent the update.
    public func handler(_ events: [ProgressUpdateEvent]) async {
        let object = xpc_dictionary_create(nil, nil, 0)
        let replyMessage = XPCMessage(object: object)
        for event in events {
            switch event {
            case .setDescription(let description):
                replyMessage.set(key: .progressUpdateSetDescription, value: description)
            case .setSubDescription(let subDescription):
                replyMessage.set(key: .progressUpdateSetSubDescription, value: subDescription)
            case .setItemsName(let itemsName):
                replyMessage.set(key: .progressUpdateSetItemsName, value: itemsName)
            case .addTasks(let tasks):
                replyMessage.set(key: .progressUpdateAddTasks, value: tasks)
            case .setTasks(let tasks):
                replyMessage.set(key: .progressUpdateSetTasks, value: tasks)
            case .addTotalTasks(let totalTasks):
                replyMessage.set(key: .progressUpdateAddTotalTasks, value: totalTasks)
            case .setTotalTasks(let totalTasks):
                replyMessage.set(key: .progressUpdateSetTotalTasks, value: totalTasks)
            case .addSize(let size):
                replyMessage.set(key: .progressUpdateAddSize, value: size)
            case .setSize(let size):
                replyMessage.set(key: .progressUpdateSetSize, value: size)
            case .addTotalSize(let totalSize):
                replyMessage.set(key: .progressUpdateAddTotalSize, value: totalSize)
            case .setTotalSize(let totalSize):
                replyMessage.set(key: .progressUpdateSetTotalSize, value: totalSize)
            case .addItems(let items):
                replyMessage.set(key: .progressUpdateAddItems, value: items)
            case .setItems(let items):
                replyMessage.set(key: .progressUpdateSetItems, value: items)
            case .addTotalItems(let totalItems):
                replyMessage.set(key: .progressUpdateAddTotalItems, value: totalItems)
            case .setTotalItems(let totalItems):
                replyMessage.set(key: .progressUpdateSetTotalItems, value: totalItems)
            case .custom(_):
                // Unsupported progress update event in XPC communication.
                break
            }
        }
        xpc_connection_send_message(endpointConnection, replyMessage.underlying)
    }
}
