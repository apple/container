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

import ContainerImagesServiceClient
import ContainerXPC
import ContainerizationOCI
import Testing

@testable import ContainerImagesService

/// Regression coverage for reading registry credentials in the CLI and forwarding
/// them to the images helper over XPC (commit "Read registry credentials in the
/// CLI, not the images helper").
///
/// The bug was that the `container-core-images` helper read the keychain itself
/// and failed with errSecInteractionNotAllowed (-25308), because its code identity
/// differs from the CLI that wrote the item. The fix forwards the resolved
/// `Authorization` header over XPC. These tests pin that the helper consumes the
/// forwarded credential rather than touching the keychain.
@Suite
struct RegistryAuthForwardingTests {
    private let authorization = "Basic dXNlcjpwYXNz"  // base64("user:pass")

    /// The wrapper must hand back the forwarded `Authorization` value unchanged,
    /// including its scheme prefix, so the registry handshake sees what the CLI read.
    @Test func resolvedAuthenticationReturnsAuthorizationVerbatim() async throws {
        let auth = ResolvedAuthentication(authorization: authorization)
        #expect(try await auth.token() == authorization)
    }

    /// A request carrying the credential must decode into an `Authentication`
    /// whose token matches it — the helper consumes it instead of reading the keychain.
    @Test func harnessDecodesForwardedAuthorization() async throws {
        let message = XPCMessage(route: ImagesServiceXPCRoute.imagePull.rawValue)
        message.set(key: .registryAuthorization, value: authorization)

        let auth = try #require(ImagesServiceHarness.authentication(from: message))
        #expect(try await auth.token() == authorization)
    }

    /// No forwarded credential means anonymous access (e.g. public image pulls),
    /// so no `Authentication` is produced.
    @Test func harnessReturnsNilWithoutForwardedAuthorization() {
        let message = XPCMessage(route: ImagesServiceXPCRoute.imagePull.rawValue)
        #expect(ImagesServiceHarness.authentication(from: message) == nil)
    }
}
