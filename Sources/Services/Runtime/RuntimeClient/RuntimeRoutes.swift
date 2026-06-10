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

/// XPC routes exposed by the runtime service.
public enum RuntimeRoutes: String {
    // MARK: - Service lifecycle

    /// Create an XPC endpoint for communicating with the runtime service.
    case createEndpoint = "com.apple.container.runtime/createEndpoint"
    /// Shut down the runtime service process. Requires the sandbox to be stopped first.
    case shutdown = "com.apple.container.runtime/shutdown"

    // MARK: - Sandbox lifecycle

    /// Bootstrap the sandbox: create the VM, configure networks, and boot the guest.
    case bootstrap = "com.apple.container.runtime/bootstrap"
    /// Stop the sandbox and all processes running inside it.
    case stop = "com.apple.container.runtime/stop"
    /// Return the current state of the sandbox.
    case state = "com.apple.container.runtime/state"
    /// Get resource usage statistics for the sandbox.
    case statistics = "com.apple.container.runtime/statistics"
    /// Open a vsock connection to a port inside the sandbox.
    case dial = "com.apple.container.runtime/dial"

    // MARK: - Process management

    /// Register a new process inside the sandbox (used by exec).
    case createProcess = "com.apple.container.runtime/createProcess"
    /// Start a registered process inside the sandbox.
    case start = "com.apple.container.runtime/start"
    /// Send a signal to a process inside the sandbox.
    case kill = "com.apple.container.runtime/kill"
    /// Resize the PTY of a process inside the sandbox.
    case resize = "com.apple.container.runtime/resize"
    /// Wait for a process inside the sandbox to exit.
    case wait = "com.apple.container.runtime/wait"
    /// Execute a new process in the sandbox.
    case exec = "com.apple.container.runtime/exec"

    // MARK: - File Management
    /// Copy a file or directory into the container.
    case copyIn = "com.apple.container.runtime/copyIn"
    /// Copy a file or directory out of the container.
    case copyOut = "com.apple.container.runtime/copyOut"
}
