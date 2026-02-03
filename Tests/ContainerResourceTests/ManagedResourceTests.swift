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

struct ManagedResourceTests {

    // Mock implementation to test the randomId function
    struct MockManagedResource: ManagedResource {
        var id: String
        var name: String
        var creationDate: Date
        var labels: [String: String]

        static func nameValid(_ name: String) -> Bool {
            true
        }
    }

    @Test("randomId generates valid hex string SHA256 hash format")
    func testRandomIdFormat() {
        let id = MockManagedResource.generateId()

        // SHA256 hash is 64 hex characters (256 bits / 4 bits per hex char)
        #expect(id.count == 64, "randomId should generate 64 character string")

        // Should only contain valid hexadecimal characters (0-9, a-f)
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        let idCharacterSet = CharacterSet(charactersIn: id)
        #expect(
            hexCharacterSet.isSuperset(of: idCharacterSet),
            "randomId should only contain hexadecimal characters (0-9, a-f)")
    }

    @Test("randomId generates unique values")
    func testRandomIdUniqueness() {
        // Generate multiple IDs and verify they're all different
        let ids = (0..<100).map { _ in MockManagedResource.generateId() }
        let uniqueIds = Set(ids)

        #expect(uniqueIds.count == 100, "All generated IDs should be unique")
    }

    @Test("randomId uses lowercase hexadecimal")
    func testRandomIdLowercase() {
        let id = MockManagedResource.generateId()

        // Should not contain uppercase letters
        let uppercaseLetters = CharacterSet.uppercaseLetters
        let idCharacterSet = CharacterSet(charactersIn: id)
        #expect(
            uppercaseLetters.isDisjoint(with: idCharacterSet),
            "randomId should use lowercase hexadecimal characters")
    }
}
