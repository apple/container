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

import Logging
import Dispatch

// Global logger instance used across commands; matches ContainerCommands bootstrap behavior.
nonisolated(unsafe) var log: Logger = {
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    var logger = Logger(label: "com.apple.containercompose")
    logger.logLevel = .info
    return logger
}()

// MARK: - Signal Handling Helpers

#if os(macOS)
import Darwin
#else
import Glibc
#endif

@MainActor
final class GlobalSignalKeeper {
    static let shared = GlobalSignalKeeper()
    private var sources: [DispatchSourceSignal] = []
    func retain(_ s: DispatchSourceSignal) { sources.append(s) }
}

/// Install SIGINT/SIGTERM handlers for a command. If `onSignal` is provided, it is invoked on signal; otherwise the process exits 130.
func installDefaultTerminationHandlers(onSignal: (@Sendable () -> Void)? = nil) {
    func install(_ signo: Int32) {
        signal(signo, SIG_IGN)
        DispatchQueue.main.async {
            let src = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            src.setEventHandler {
                if let onSignal { onSignal() } else { Darwin.exit(130) }
            }
            src.resume()
            Task { @MainActor in GlobalSignalKeeper.shared.retain(src) }
        }
    }
    install(SIGINT)
    install(SIGTERM)
}
