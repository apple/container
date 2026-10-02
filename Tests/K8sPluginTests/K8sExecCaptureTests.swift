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

import ContainerResource
import Darwin
import Foundation
import Testing

@testable import ContainerK8s

@Suite("K8sHelper.execCapture")
struct K8sExecCaptureTests {
    @Test func transfersRegularFileInputAndExplicitEnvironment() async throws {
        let contents = Data(
            "\(String(repeating: "a", count: 132_000))\nEOF\ncontent-after-eof\n".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".yaml")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let factory = CapturingProcessFactory(output: "stdout\nstderr\n")
        let result = try await K8sHelper.execCapture(
            executable: K8sHelper.kubectlPath,
            arguments: ["apply", "-f", "-"],
            environment: [K8sHelper.kubeconfigEnv],
            standardInput: .file(url)
        ) { configuration, stdio in
            try await factory.create(configuration: configuration, stdio: stdio)
        }

        let invocation = await factory.invocation
        #expect(result.code == 0)
        #expect(result.output == "stdout\nstderr\n")
        #expect(invocation?.executable == K8sHelper.kubectlPath)
        #expect(invocation?.arguments == ["apply", "-f", "-"])
        #expect(invocation?.environment == [K8sHelper.kubeconfigEnv])
        #expect(invocation?.input == contents)
        #expect(invocation?.transferredDescriptorsWereClosed == true)
    }

    @Test func preservesEmptyEnvironmentByDefault() async throws {
        let factory = CapturingProcessFactory(output: "")
        let result = try await K8sHelper.execCapture(
            executable: "/bin/true",
            arguments: [],
            processCreator: { configuration, stdio in
                try await factory.create(configuration: configuration, stdio: stdio)
            })

        let invocation = await factory.invocation
        #expect(result.code == 0)
        #expect(invocation?.environment == [])
        #expect(invocation?.input == nil)
    }

    @Test func transfersInMemoryInputWhileDrainingLargeOutput() async throws {
        let input = Data(repeating: 0x61, count: 256_000)
        let output = Data(repeating: 0x62, count: 256_000)
        let factory = CapturingProcessFactory(output: output)

        let result = try await K8sHelper.execCapture(
            executable: "/bin/cat",
            arguments: [],
            standardInput: .data(input),
            processCreator: { configuration, stdio in
                try await factory.create(configuration: configuration, stdio: stdio)
            })

        let invocation = await factory.invocation
        #expect(result.code == 0)
        #expect(Data(result.output.utf8) == output)
        #expect(invocation?.input == input)
        #expect(invocation?.transferredDescriptorsWereClosed == true)
    }
}

private actor CapturingProcessFactory {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String]
        let input: Data?
        let transferredDescriptorsWereClosed: Bool
    }

    private(set) var invocation: Invocation?
    private let output: Data

    init(output: String) {
        self.output = Data(output.utf8)
    }

    init(output: Data) {
        self.output = output
    }

    func create(configuration: ProcessConfiguration, stdio: [FileHandle?]) throws -> K8sHelper.ExecProcess {
        #expect(stdio.count == 3)
        guard stdio.count == 3, let stdout = stdio[1], let stderr = stdio[2] else {
            throw POSIXError(.EINVAL)
        }

        let inputCopy = stdio[0].map { dup($0.fileDescriptor) }
        let stdoutCopy = dup(stdout.fileDescriptor)
        let stderrCopy = dup(stderr.fileDescriptor)
        let devNull = open("/dev/null", O_RDONLY)
        guard (inputCopy ?? 0) >= 0, stdoutCopy >= 0, stderrCopy >= 0, devNull >= 0 else {
            if let inputCopy, inputCopy >= 0 { close(inputCopy) }
            if stdoutCopy >= 0 { close(stdoutCopy) }
            if stderrCopy >= 0 { close(stderrCopy) }
            if devNull >= 0 { close(devNull) }
            throw POSIXError(.EIO)
        }

        let transferredDescriptors = stdio.compactMap { $0?.fileDescriptor }
        for handle in stdio.compactMap({ $0 }) {
            guard close(handle.fileDescriptor) == 0 else {
                if let inputCopy { close(inputCopy) }
                close(stdoutCopy)
                close(stderrCopy)
                close(devNull)
                throw POSIXError(.EIO)
            }
        }
        let descriptorsWereClosed = transferredDescriptors.allSatisfy {
            fcntl($0, F_GETFD) == -1 && errno == EBADF
        }
        var sentinelDescriptors: [Int32] = []
        for descriptor in transferredDescriptors {
            guard dup2(devNull, descriptor) == descriptor else {
                for sentinel in sentinelDescriptors { close(sentinel) }
                if let inputCopy { close(inputCopy) }
                close(stdoutCopy)
                close(stderrCopy)
                close(devNull)
                throw POSIXError(.EIO)
            }
            sentinelDescriptors.append(descriptor)
        }
        close(devNull)

        let output = self.output
        let executable = configuration.executable
        let arguments = configuration.arguments
        let environment = configuration.environment
        return K8sHelper.ExecProcess(
            start: {
                let descriptorsRemainOpen = transferredDescriptors.allSatisfy {
                    fcntl($0, F_GETFD) >= 0
                }
                for descriptor in transferredDescriptors {
                    close(descriptor)
                }
                guard descriptorsRemainOpen else {
                    if let inputCopy { close(inputCopy) }
                    close(stdoutCopy)
                    close(stderrCopy)
                    throw POSIXError(.EBADF)
                }
            },
            wait: {
                let input = inputCopy.map {
                    FileHandle(fileDescriptor: $0, closeOnDealloc: true).readDataToEndOfFile()
                }
                let stdoutHandle = FileHandle(fileDescriptor: stdoutCopy, closeOnDealloc: true)
                let stderrHandle = FileHandle(fileDescriptor: stderrCopy, closeOnDealloc: true)
                try stdoutHandle.write(contentsOf: output)
                try stdoutHandle.close()
                try stderrHandle.close()
                await self.record(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    input: input,
                    transferredDescriptorsWereClosed: descriptorsWereClosed)
                return 0
            })
    }

    private func record(
        executable: String,
        arguments: [String],
        environment: [String],
        input: Data?,
        transferredDescriptorsWereClosed: Bool
    ) {
        invocation = Invocation(
            executable: executable,
            arguments: arguments,
            environment: environment,
            input: input,
            transferredDescriptorsWereClosed: transferredDescriptorsWereClosed)
    }
}
