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

import ContainerXPC
import Foundation

public enum ClientHealthCheck {
    static let serviceIdentifier = "com.apple.container.apiserver"
}

extension ClientHealthCheck {
    private static func newClient() -> XPCClient {
        XPCClient(service: serviceIdentifier)
    }

    public static func ping(timeout: Duration? = .seconds(5)) async throws {
        let client = Self.newClient()
        let request = XPCMessage(route: .ping)
        try await client.send(request, responseTimeout: timeout)
    }
}
