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

import Foundation
import Testing

@testable import ContainerBuildReporting

@Suite("Simple New Tests")
struct SimpleNewTests {

    @Test("BuildStatistics basic initialization")
    func testBuildStatisticsBasic() {
        let stats = BuildStatistics()
        #expect(stats.startTime == nil)
        #expect(stats.endTime == nil)
        #expect(stats.duration == nil)
        #expect(stats.totalOperations == 0)
    }

    @Test("StageStatistics basic initialization")
    func testStageStatisticsBasic() {
        let stageStats = StageStatistics(name: "test")
        #expect(stageStats.name == "test")
        #expect(stageStats.startTime == nil)
        #expect(stageStats.endTime == nil)
        #expect(stageStats.duration == nil)
        #expect(stageStats.operationCount == 0)
    }

    @Test("Basic JSON output functionality")
    func testBasicJSONOutput() async throws {
        let pipe = Pipe()
        let config = JSONProgressConsumer.Configuration(output: pipe.fileHandleForWriting, prettyPrint: false)
        let consumer = JSONProgressConsumer(configuration: config)

        let event = BuildEvent.buildStarted(totalOperations: 1, stages: 1, timestamp: Date())
        try await consumer.handle(event)

        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        #expect(output.contains("\"type\":\"build_started\""))
        #expect(output.contains("\"total_operations\":1"))
    }

    @Test("Basic plain output functionality")
    func testBasicPlainOutput() async throws {
        let pipe = Pipe()
        let config = PlainProgressConsumer.Configuration(output: pipe.fileHandleForWriting)
        let consumer = PlainProgressConsumer(configuration: config)

        let nodeId = UUID()
        let context = ReportContext(nodeId: nodeId, description: "Test operation")
        let event = BuildEvent.operationStarted(context: context)

        try await consumer.handle(event)

        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        #expect(output.contains("#1 [stage] Test operation"))
    }
}
