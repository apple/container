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

@testable import ContainerAPIClient

struct ProcessIOTests {
    @Test("Host tty does not translate guest newlines")
    func hostOutputProcessing() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw POSIXError.fromErrno()
        }
        defer {
            _ = close(master)
            _ = close(slave)
        }

        var attributes = termios()
        guard tcgetattr(slave, &attributes) == 0 else {
            throw POSIXError.fromErrno()
        }
        attributes.c_oflag |= tcflag_t(OPOST | ONLCR)
        guard tcsetattr(slave, TCSANOW, &attributes) == 0 else {
            throw POSIXError.fromErrno()
        }

        try ProcessIO.disableHostOutputProcessing(descriptor: slave)

        guard tcgetattr(slave, &attributes) == 0 else {
            throw POSIXError.fromErrno()
        }
        #expect(attributes.c_oflag & tcflag_t(OPOST) == 0)

        let output = Array("9\nX".utf8)
        let count = output.withUnsafeBytes { write(slave, $0.baseAddress, $0.count) }
        #expect(count == output.count)
        var received = [UInt8](repeating: 0, count: output.count)
        let receivedCount = received.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
        #expect(receivedCount == output.count)
        #expect(received == output)
    }
}
