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

//

import ContainerizationOS
import Foundation
import Testing

class TestCLIRunBase: CLITest {
    var terminal: Terminal!
    var containerName: String = UUID().uuidString

    var ContainerImage: String {
        fatalError("Subclasses must override this property")
    }

    var Interactive: Bool {
        false
    }

    var Tty: Bool {
        false
    }

    var Entrypoint: String? {
        nil
    }

    var Command: [String]? {
        nil
    }

    var DisableProgressUpdates: Bool {
        false
    }

    override init() throws {
        try super.init()
        do {
            terminal = try containerStart(self.containerName)
            try waitForContainerRunning(self.containerName)
        } catch {
            throw CLIError.containerRunFailed("failed to setup container \(error)")
        }
    }

    func containerRun(stdin: [String], findMessage: String) async throws -> Bool {
        let stdout = FileHandle(fileDescriptor: terminal.handle.fileDescriptor, closeOnDealloc: false)
        let stdoutListenTask = Task {
            for try await line in stdout.bytes.lines {
                if line.contains(findMessage) && !line.contains("echo") {
                    return true
                }
            }
            return false
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            stdoutListenTask.cancel()
        }

        do {
            try self.exec(commands: stdin)
            let found = try await stdoutListenTask.value
            timeoutTask.cancel()
            return found
        } catch is CancellationError {
            throw CLIError.executionFailed("timeout hit")
        } catch {
            throw error
        }
    }

    func exec(commands: [String]) throws {
        let stdin = FileHandle(fileDescriptor: terminal.handle.fileDescriptor, closeOnDealloc: false)
        try commands.forEach { cmd in
            let cmdLine = cmd.appending("\n")
            guard let cmdNormalized = cmdLine.data(using: .ascii) else {
                throw CLIError.invalidInput("shell command \(cmd) is invalid")
            }
            try stdin.write(contentsOf: cmdNormalized)
        }
        try stdin.synchronize()
    }

    func containerStart(_ name: String) throws -> Terminal {
        if name.count == 0 {
            throw CLIError.invalidInput("container name cannot be empty")
        }

        var arguments = [
            "run",
            "--rm",
            "--name",
            name,
        ]

        if Interactive && Tty {
            arguments.append("-it")
        } else {
            if Interactive { arguments.append("-i") }
            if Tty { arguments.append("-t") }
        }

        if DisableProgressUpdates {
            arguments.append("--disable-progress-updates")
        }

        if let entrypoint = Entrypoint {
            arguments += ["--entrypoint", entrypoint]
        }

        arguments.append(ContainerImage)

        if let command = Command {
            arguments += command
        }
        return try runInteractive(arguments: arguments)
    }
}
