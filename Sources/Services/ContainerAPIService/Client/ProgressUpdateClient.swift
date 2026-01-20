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

/// A client that can be used to receive progress updates from a service.
public actor ProgressUpdateClient {
    private var endpointConnection: xpc_connection_t?
    private var endpoint: xpc_endpoint_t?

    /// Creates a new client for receiving progress updates from a service.
    /// - Parameters:
    ///   - progressUpdate: The handler to invoke when progress updates are received.
    ///   - request: The XPC message to send the endpoint to connect to.
    public init(for progressUpdate: @escaping ProgressUpdateHandler, request: XPCMessage) async {
        createEndpoint(for: progressUpdate)
        setEndpoint(to: request)
    }

    /// Performs a connection setup for receiving progress updates.
    /// - Parameter progressUpdate: The handler to invoke when progress updates are received.
    private func createEndpoint(for progressUpdate: @escaping ProgressUpdateHandler) {
        let endpointConnection = xpc_connection_create(nil, nil)
        // Access to `reversedConnection` is protected by a lock
        nonisolated(unsafe) var reversedConnection: xpc_connection_t?
        let reversedConnectionLock = NSLock()
        xpc_connection_set_event_handler(endpointConnection) { connectionMessage in
            reversedConnectionLock.withLock {
                switch xpc_get_type(connectionMessage) {
                case XPC_TYPE_CONNECTION:
                    reversedConnection = connectionMessage
                    xpc_connection_set_event_handler(connectionMessage) { updateMessage in
                        Self.handleProgressUpdate(updateMessage, progressUpdate: progressUpdate)
                    }
                    xpc_connection_activate(connectionMessage)
                case XPC_TYPE_ERROR:
                    if let reversedConnectionUnwrapped = reversedConnection {
                        xpc_connection_cancel(reversedConnectionUnwrapped)
                        reversedConnection = nil
                    }
                default:
                    fatalError("unhandled xpc object type: \(xpc_get_type(connectionMessage))")
                }
            }
        }
        xpc_connection_activate(endpointConnection)

        self.endpointConnection = endpointConnection
        self.endpoint = xpc_endpoint_create(endpointConnection)
    }

    /// Performs a setup of the progress update endpoint.
    /// - Parameter request: The XPC message containing the endpoint to use.
    private func setEndpoint(to request: XPCMessage) {
        guard let endpoint else {
            return
        }
        request.set(key: .progressUpdateEndpoint, value: endpoint)
    }

    /// Performs cleanup of the created connection.
    public func finish() {
        if let endpointConnection {
            xpc_connection_cancel(endpointConnection)
            self.endpointConnection = nil
        }
    }

    private static func handleProgressUpdate(_ message: xpc_object_t, progressUpdate: @escaping ProgressUpdateHandler) {
        switch xpc_get_type(message) {
        case XPC_TYPE_DICTIONARY:
            let message = XPCMessage(object: message)
            handleProgressUpdate(message, progressUpdate: progressUpdate)
        case XPC_TYPE_ERROR:
            break
        default:
            fatalError("unhandled xpc object type: \(xpc_get_type(message))")
            break
        }
    }

    private static func handleProgressUpdate(_ message: XPCMessage, progressUpdate: @escaping ProgressUpdateHandler) {
        var events = [ProgressUpdateEvent]()

        if let description = message.string(key: .progressUpdateSetDescription) {
            events.append(.setDescription(description))
        }
        if let subDescription = message.string(key: .progressUpdateSetSubDescription) {
            events.append(.setSubDescription(subDescription))
        }
        if let itemsName = message.string(key: .progressUpdateSetItemsName) {
            events.append(.setItemsName(itemsName))
        }
        var tasks = message.int(key: .progressUpdateAddTasks)
        if tasks != 0 {
            events.append(.addTasks(tasks))
        }
        tasks = message.int(key: .progressUpdateSetTasks)
        if tasks != 0 {
            events.append(.setTasks(tasks))
        }
        var totalTasks = message.int(key: .progressUpdateAddTotalTasks)
        if totalTasks != 0 {
            events.append(.addTotalTasks(totalTasks))
        }
        totalTasks = message.int(key: .progressUpdateSetTotalTasks)
        if totalTasks != 0 {
            events.append(.setTotalTasks(totalTasks))
        }
        var items = message.int(key: .progressUpdateAddItems)
        if items != 0 {
            events.append(.addItems(items))
        }
        items = message.int(key: .progressUpdateSetItems)
        if items != 0 {
            events.append(.setItems(items))
        }
        var totalItems = message.int(key: .progressUpdateAddTotalItems)
        if totalItems != 0 {
            events.append(.addTotalItems(totalItems))
        }
        totalItems = message.int(key: .progressUpdateSetTotalItems)
        if totalItems != 0 {
            events.append(.setTotalItems(totalItems))
        }
        var size = message.int64(key: .progressUpdateAddSize)
        if size != 0 {
            events.append(.addSize(size))
        }
        size = message.int64(key: .progressUpdateSetSize)
        if size != 0 {
            events.append(.setSize(size))
        }
        var totalSize = message.int64(key: .progressUpdateAddTotalSize)
        if totalSize != 0 {
            events.append(.addTotalSize(totalSize))
        }
        totalSize = message.int64(key: .progressUpdateSetTotalSize)
        if totalSize != 0 {
            events.append(.setTotalSize(totalSize))
        }

        Task {
            await progressUpdate(events)
        }
    }
}
