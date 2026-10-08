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

import ContainerizationError
import Logging
import Testing

@testable import ContainerXPC

struct RouteHandlerLogLevelTests {
    @Test func notFoundIsLoggedAtDebug() {
        // A missing image snapshot is an expected, recoverable outcome and must
        // not be surfaced as an error in the logs (see issue #589).
        let error = ContainerizationError(
            .notFound,
            message: "image snapshot for docker.io/library/ubuntu:24.04 with platform linux/amd64"
        )
        #expect(error.routeHandlerLogLevel == .debug)
    }

    @Test func otherErrorsAreLoggedAtError() {
        for code in [
            ContainerizationError.Code.invalidArgument,
            .invalidState,
            .internalError,
            .unknown,
        ] {
            let error = ContainerizationError(code, message: "boom")
            #expect(error.routeHandlerLogLevel == .error)
        }
    }
}
