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

#if os(macOS)
import ContainerizationError
import Foundation
import Testing

@testable import ContainerXPC

@Suite
struct XPCMessageTests {
    @Test
    func errorRejectsUnknownPeerCodeWithoutTrapping() throws {
        let message = XPCMessage(route: "unknown-error-code")
        message.set(
            key: XPCMessage.errorKey,
            value: Data(#"{"code":"newerPeerCode","message":"from a newer peer"}"#.utf8)
        )

        let error = try #require(
            #expect(throws: ContainerizationError.self) {
                try message.error()
            }
        )
        #expect(error.code == .internalError)
        #expect(error.message == "received a malformed error payload from the XPC peer")
    }

    @Test(
        arguments: [
            ContainerizationError.Code.unknown,
            .invalidArgument,
            .internalError,
            .exists,
            .notFound,
            .cancelled,
            .invalidState,
            .empty,
            .timeout,
            .unsupported,
            .interrupted,
        ]
    )
    func errorPreservesKnownPeerCodeAndMessage(code: ContainerizationError.Code) throws {
        let message = XPCMessage(route: "known-error-code")
        message.set(error: ContainerizationError(code, message: "message"))

        let error = try #require(
            #expect(throws: ContainerizationError.self) {
                try message.error()
            }
        )
        #expect(error.code == code)
        #expect(error.message == "message")
    }
}
#endif
