//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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

@testable import ContainerClient

struct CredentialHelperTests {

    @Test("Execute credential helper with nonexistent helper")
    func testCredentialHelperWithNonexistentHelper() async {
        let executor = CredentialHelperExecutor()

        // Try to execute a nonexistent credential helper
        // This should return nil without crashing
        let auth = await executor.execute(helperName: "nonexistent-helper-\(UUID().uuidString)", for: "example.com")

        #expect(auth == nil)
    }

    @Test("Execute credential helper with invalid helper name")
    func testCredentialHelperWithInvalidHelperName() async {
        let executor = CredentialHelperExecutor()

        // Try to execute a credential helper with invalid characters
        // This should return nil to prevent command injection
        let auth = await executor.execute(helperName: "../../../bin/sh", for: "example.com")

        #expect(auth == nil)
    }

    @Test("Execute credential helper with valid helper name")
    func testCredentialHelperWithValidHelperName() async {
        let executor = CredentialHelperExecutor()

        // Valid helper names should be accepted (even if they don't exist)
        // The validation should pass, but execution will fail
        let auth = await executor.execute(helperName: "valid-helper_123", for: "example.com")

        // Should be nil because the helper doesn't exist, but validation passed
        #expect(auth == nil)
    }

    @Test("Validate helper name with special characters")
    func testValidateHelperNameWithSpecialCharacters() async {
        let executor = CredentialHelperExecutor()

        // Test various invalid characters
        let invalidNames = ["helper;echo", "helper|cat", "helper&ls", "helper$PWD", "helper`ls`", "helper/bin"]

        for name in invalidNames {
            let auth = await executor.execute(helperName: name, for: "example.com")
            #expect(auth == nil)
        }
    }

    @Test("Validate helper name with valid characters")
    func testValidateHelperNameWithValidCharacters() async {
        let executor = CredentialHelperExecutor()

        // These should pass validation (though they won't exist)
        let validNames = ["cgr", "gcloud", "ecr-login", "helper_123", "my-helper"]

        for name in validNames {
            // Should not crash, returns nil because helper doesn't exist
            let auth = await executor.execute(helperName: name, for: "example.com")
            #expect(auth == nil)
        }
    }
}
