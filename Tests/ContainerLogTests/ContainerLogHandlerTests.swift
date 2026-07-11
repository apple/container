//===----------------------------------------------------------------------===//
// Copyright 2026 Apple Inc. and the container project authors.
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

import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerLog

@Suite
struct ContainerLogHandlerTests {
    @Test
    func handlersAcceptPrimaryLogEvent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-log-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("events.log")
        var fileHandler = try FileLogHandler(
            label: "container-log-tests",
            category: "events",
            path: FilePath(url.path)
        )
        fileHandler.metadata = ["scope": "handler"]

        let event = LogEvent(
            level: .warning,
            message: "primary event",
            metadata: ["scope": "event", "request": "123"],
            source: "ContainerLogTests",
            file: #fileID,
            function: #function,
            line: #line
        )

        fileHandler.log(event: event)
        StderrLogHandler().log(event: event)
        OSLogHandler(label: "container-log-tests", category: "events").log(event: event)

        let output = try String(contentsOf: url, encoding: .utf8)
        #expect(output.contains("[warning] container-log-tests events"))
        #expect(output.contains("primary event"))
        #expect(output.contains("event"))
        #expect(output.contains("123"))
        #expect(!output.contains("handler"))
    }
}
