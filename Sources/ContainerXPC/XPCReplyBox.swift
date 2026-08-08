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
import Foundation

/// Resume-once bridge between a `CheckedContinuation` and the XPC reply handler.
///
/// The XPC reply handler is not cancellation-aware, so a request can outlive a
/// client-side timeout. This box lets either the reply handler or the task's
/// cancellation handler resume the continuation, whichever fires first, while
/// guaranteeing it is resumed exactly once. A continuation resumed twice traps.
final class XPCReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<XPCMessage, Error>?
    private var resumed = false
    private var pending: Result<XPCMessage, Error>?

    /// Store the continuation. If a resume already raced ahead (cancellation
    /// before the continuation was installed), honor it immediately.
    func store(_ cont: CheckedContinuation<XPCMessage, Error>) {
        lock.lock()
        if let pending, !resumed {
            resumed = true
            lock.unlock()
            cont.resume(with: pending)
            return
        }
        self.cont = cont
        lock.unlock()
    }

    /// Resume the continuation with the result of `body`, at most once. A later
    /// call is a no-op, so the reply handler and the cancellation handler can
    /// both call it safely.
    func resume(_ body: () throws -> XPCMessage) {
        let result = Result { try body() }
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        guard let cont else {
            pending = result
            lock.unlock()
            return
        }
        resumed = true
        self.cont = nil
        lock.unlock()
        cont.resume(with: result)
    }
}

#endif
