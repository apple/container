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

#if os(macOS)
import ContainerizationError
import Foundation

/// A message that can be pass across application boundaries via XPC.
public struct XPCMessage: Sendable {
    /// Defined message key storing the route value.
    public static let routeKey = "com.apple.container.xpc.route"
    /// Defined message key storing the error value.
    public static let errorKey = "com.apple.container.xpc.error"

    // Access to `object` is protected by a lock
    private nonisolated(unsafe) let object: xpc_object_t
    private let lock = NSLock()
    private let isErr: Bool

    /// The underlying xpc object that the message wraps.
    public var underlying: xpc_object_t {
        lock.withLock {
            object
        }
    }
    public var isErrorType: Bool { isErr }

    public init(object: xpc_object_t) {
        self.object = object
        self.isErr = xpc_get_type(self.object) == XPC_TYPE_ERROR
    }

    public init(route: String) {
        self.object = xpc_dictionary_create_empty()
        self.isErr = false
        xpc_dictionary_set_string(self.object, Self.routeKey, route)
    }
}

extension XPCMessage {
    public static func == (lhs: XPCMessage, rhs: xpc_object_t) -> Bool {
        xpc_equal(lhs.underlying, rhs)
    }

    public func reply() -> XPCMessage {
        lock.withLock {
            XPCMessage(object: xpc_dictionary_create_reply(object)!)
        }
    }

    public func errorKeyDescription() -> String? {
        guard self.isErr,
            let xpcErr = lock.withLock({
                xpc_dictionary_get_string(
                    self.object,
                    XPC_ERROR_KEY_DESCRIPTION
                )
            })
        else {
            return nil
        }
        return String(cString: xpcErr)
    }

    public func error() throws {
        let data = data(key: Self.errorKey)
        if let data {
            let item = try? JSONDecoder().decode(ContainerXPCError.self, from: data)
            precondition(item != nil, "expected to receive a ContainerXPCXPCError")

            throw ContainerizationError(item!.code, message: item!.message)
        }
    }

    public func set(error: ContainerizationError) {
        let serializableError = ContainerXPCError(code: error.code.description, message: error.message)
        let data = try? JSONEncoder().encode(serializableError)
        precondition(data != nil)

        set(key: Self.errorKey, value: data!)
    }
}

struct ContainerXPCError: Codable {
    let code: String
    let message: String
}

extension XPCMessage {
    public func data(key: String) -> Data? {
        var length: Int = 0
        let bytes = lock.withLock {
            xpc_dictionary_get_data(self.object, key, &length)
        }

        guard let bytes else {
            return nil
        }

        return Data(bytes: bytes, count: length)
    }

    /// dataNoCopy is similar to data, except the data is not copied
    /// to a new buffer. What this means in practice is the second the
    /// underlying xpc_object_t gets released by ARC the data will be
    /// released as well. This variant should be used when you know the
    /// data will be used before the object has no more references.
    public func dataNoCopy(key: String) -> Data? {
        var length: Int = 0
        let bytes = lock.withLock {
            xpc_dictionary_get_data(self.object, key, &length)
        }

        guard let bytes else {
            return nil
        }

        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes),
            count: length,
            deallocator: .none
        )
    }

    public func set(key: String, value: Data) {
        value.withUnsafeBytes { ptr in
            if let addr = ptr.baseAddress {
                lock.withLock {
                    xpc_dictionary_set_data(self.object, key, addr, value.count)
                }
            }
        }
    }

    public func string(key: String) -> String? {
        let _id = lock.withLock {
            xpc_dictionary_get_string(self.object, key)
        }
        if let _id {
            return String(cString: _id)
        }
        return nil
    }

    public func set(key: String, value: String) {
        lock.withLock {
            xpc_dictionary_set_string(self.object, key, value)
        }
    }

    public func bool(key: String) -> Bool {
        lock.withLock {
            xpc_dictionary_get_bool(self.object, key)
        }
    }

    public func set(key: String, value: Bool) {
        lock.withLock {
            xpc_dictionary_set_bool(self.object, key, value)
        }
    }

    public func uint64(key: String) -> UInt64 {
        lock.withLock {
            xpc_dictionary_get_uint64(self.object, key)
        }
    }

    public func set(key: String, value: UInt64) {
        lock.withLock {
            xpc_dictionary_set_uint64(self.object, key, value)
        }
    }

    public func int64(key: String) -> Int64 {
        lock.withLock {
            xpc_dictionary_get_int64(self.object, key)
        }
    }

    public func set(key: String, value: Int64) {
        lock.withLock {
            xpc_dictionary_set_int64(self.object, key, value)
        }
    }

    public func fileHandle(key: String) -> FileHandle? {
        let fd = lock.withLock {
            xpc_dictionary_get_value(self.object, key)
        }
        if let fd {
            let fd2 = xpc_fd_dup(fd)
            return FileHandle(fileDescriptor: fd2, closeOnDealloc: false)
        }
        return nil
    }

    public func set(key: String, value: FileHandle) {
        let fd = xpc_fd_create(value.fileDescriptor)
        close(value.fileDescriptor)
        lock.withLock {
            xpc_dictionary_set_value(self.object, key, fd)
        }
    }

    public func fileHandles(key: String) -> [FileHandle]? {
        let fds = lock.withLock {
            xpc_dictionary_get_value(self.object, key)
        }
        if let fds {
            let fd1 = xpc_array_dup_fd(fds, 0)
            let fd2 = xpc_array_dup_fd(fds, 1)
            if fd1 == -1 || fd2 == -1 {
                return nil
            }
            return [
                FileHandle(fileDescriptor: fd1, closeOnDealloc: false),
                FileHandle(fileDescriptor: fd2, closeOnDealloc: false),
            ]
        }
        return nil
    }

    public func set(key: String, value: [FileHandle]) throws {
        let fdArray = xpc_array_create(nil, 0)
        for fh in value {
            guard let xpcFd = xpc_fd_create(fh.fileDescriptor) else {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to create xpc fd for \(fh.fileDescriptor)"
                )
            }
            xpc_array_append_value(fdArray, xpcFd)
            close(fh.fileDescriptor)
        }
        lock.withLock {
            xpc_dictionary_set_value(self.object, key, fdArray)
        }
    }

    public func endpoint(key: String) -> xpc_endpoint_t? {
        lock.withLock {
            xpc_dictionary_get_value(self.object, key)
        }
    }

    public func set(key: String, value: xpc_endpoint_t) {
        lock.withLock {
            xpc_dictionary_set_value(self.object, key, value)
        }
    }
}

#endif
