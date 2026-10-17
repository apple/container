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

import Foundation
import Testing

@testable import ContainerResource

struct ExitRecordTests {
    private let exitedAt = Date(timeIntervalSinceReferenceDate: 812_571_436)

    private func withBundle(_ body: (ContainerResource.Bundle) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("test-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(ContainerResource.Bundle(path: directory))
    }

    @Test
    func roundTripsThroughJSON() throws {
        let record = ExitRecord(exitCode: 7, exitedAt: exitedAt)
        let decoded = try JSONDecoder().decode(ExitRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }

    @Test
    func bundleWithoutARecordHasNoExitStatus() throws {
        try withBundle { bundle in
            #expect(bundle.exitStatus == nil)
        }
    }

    @Test
    func bundleReturnsTheRecordedExit() throws {
        try withBundle { bundle in
            try bundle.setExitStatus(ExitRecord(exitCode: 137, exitedAt: exitedAt))
            #expect(bundle.exitStatus == ExitRecord(exitCode: 137, exitedAt: exitedAt))
            #expect(FileManager.default.fileExists(atPath: bundle.filePath(for: "exit.json").path))
        }
    }

    @Test
    func aLaterExitReplacesAnEarlierOne() throws {
        try withBundle { bundle in
            try bundle.setExitStatus(ExitRecord(exitCode: 1, exitedAt: exitedAt))
            try bundle.setExitStatus(ExitRecord(exitCode: 0, exitedAt: exitedAt.addingTimeInterval(60)))
            #expect(bundle.exitStatus == ExitRecord(exitCode: 0, exitedAt: exitedAt.addingTimeInterval(60)))
        }
    }

    @Test
    func anUnreadableRecordCountsAsMissing() throws {
        try withBundle { bundle in
            try Data("not json".utf8).write(to: bundle.filePath(for: "exit.json"))
            #expect(bundle.exitStatus == nil)
        }
    }
}
