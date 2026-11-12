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

import Testing

@testable import ContainerBuild

@Suite struct BuilderTransportConfigTests {
    /// The builder connection wraps an already-connected socket, so grpc-swift derives no
    /// `:authority` for it. gRPC-Go v1.84.0 and later reject requests without one, so the
    /// configuration must set it explicitly.
    @Test func transportConfigSetsAuthority() {
        let authority = Builder.transportConfig().http2.authority
        #expect(authority == Builder.grpcAuthority)
        #expect(authority?.isEmpty == false)
    }
}
