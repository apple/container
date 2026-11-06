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

import Darwin
import Foundation
import Testing

@testable import ContainerCommands

struct ContainerLogsTests {
    @Test
    func followsInitiallyEmptyLog() async throws {
        // An exit test isolates stdout and its buffering from the other unit tests.
        try await #require(processExitsWith: .success) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let logURL = directory.appendingPathComponent("container.log")
            let outputURL = directory.appendingPathComponent("stdout.log")
            try Data().write(to: logURL)
            try Data().write(to: outputURL)
            let reader = try FileHandle(forReadingFrom: logURL)
            let writer = try FileHandle(forWritingTo: logURL)
            let output = try FileHandle(forWritingTo: outputURL)
            defer {
                reader.readabilityHandler = nil
                try? reader.close()
                try? writer.close()
                try? output.close()
            }
            try #require(dup2(output.fileDescriptor, STDOUT_FILENO) == STDOUT_FILENO)

            let follower = Task {
                try await Application.ContainerLogs.tail(fh: reader, n: nil, follow: true)
            }
            defer { follower.cancel() }

            let deadline = ContinuousClock.now + .seconds(10)
            while reader.readabilityHandler == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(reader.readabilityHandler != nil, "following an empty log must not return early")

            let expected = Data("hello\n".utf8)
            try writer.write(contentsOf: expected)
            while try Data(contentsOf: outputURL) != expected && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(try Data(contentsOf: outputURL) == expected, "follow must print output appended to the empty log")

            follower.cancel()
            try await follower.value
        }
    }
}
