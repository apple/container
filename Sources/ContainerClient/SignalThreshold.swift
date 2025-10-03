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

import ContainerizationOS

// For a lot of programs, they don't install their own signal handlers for
// SIGINT/SIGTERM which poses a somewhat fun problem for containers. Because
// they're pid 1 (doesn't matter that it isn't in the "root" pid namespace)
// the default actions for SIGINT and SIGTERM now are nops. So this type gives
// us an opportunity to set a threshold for a certain number of signals received
// so we can have an escape hatch for users to escape their horrific mistake
// of cat'ing /dev/urandom by exit(1)'ing :)
public struct SignalThreshold {
    private let threshold: Int
    private let signals: [Int32]
    private var t: Task<(), Never>?

    public init(
        threshold: Int,
        signals: [Int32],
    ) {
        self.threshold = threshold
        self.signals = signals
    }

    // Start kicks off the signal watching. The passed in handler will
    // run only once upon passing the threshold number passed in the constructor.
    mutating public func start(handler: @Sendable @escaping () -> Void) {
        let signals = self.signals
        let threshold = self.threshold
        self.t = Task {
            var received = 0
            let signalHandler = AsyncSignalHandler.create(notify: signals)
            for await _ in signalHandler.signals {
                received += 1
                if received == threshold {
                    handler()
                    signalHandler.cancel()
                    return
                }
            }
        }
    }

    public func stop() {
        self.t?.cancel()
    }
}
