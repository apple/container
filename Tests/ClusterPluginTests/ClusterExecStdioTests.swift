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

@testable import ContainerCluster

struct ClusterExecStdioTests {
    @Test func duplicatesCanBeClosedWithoutClosingTheOriginal() throws {
        let pipe = Pipe()
        let stdout = try ClusterHelper.stdioDuplicate(of: pipe.fileHandleForWriting)
        let stderr = try ClusterHelper.stdioDuplicate(of: pipe.fileHandleForWriting)
        #expect(stdout.fileDescriptor != pipe.fileHandleForWriting.fileDescriptor)
        #expect(stderr.fileDescriptor != stdout.fileDescriptor)

        // Sending a handle over XPC closes its descriptor. Do the same to both duplicates.
        #expect(close(stdout.fileDescriptor) == 0)
        #expect(close(stderr.fileDescriptor) == 0)

        // The original is still open, and closing it is the only remaining close.
        pipe.fileHandleForWriting.write(Data("ok".utf8))
        try pipe.fileHandleForWriting.close()
        #expect(pipe.fileHandleForReading.readDataToEndOfFile() == Data("ok".utf8))
    }
}
