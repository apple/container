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
@testable import ContainerizationOS

struct RegistryResourceTests {

    func createRegistryInfo(
        hostname: String = "docker.io",
        username: String = "testuser"
    ) -> RegistryInfo {
        RegistryInfo(
            hostname: hostname,
            username: username,
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000),
            createdDate: Date(timeIntervalSince1970: 1_690_000_000)
        )
    }

    @Test("RegistryResource id and name are both hostname")
    func testRegistryResourceIdAndName() {
        let hostname = "ghcr.io"
        let registryInfo = createRegistryInfo(hostname: hostname, username: "myuser")
        let resource = RegistryResource(from: registryInfo)

        #expect(resource.id == hostname, "id should be the hostname")
        #expect(resource.name == hostname, "name should be the hostname")
        #expect(resource.id == resource.name, "id and name should be identical")
    }

    @Test("RegistryResource maps RegistryInfo correctly")
    func testRegistryResourceMapping() {
        let hostname = "registry.example.com:5000"
        let username = "developer"
        let registryInfo = createRegistryInfo(hostname: hostname, username: username)

        let resource = RegistryResource(from: registryInfo)

        #expect(resource.id == hostname)
        #expect(resource.name == hostname)
        #expect(resource.username == username)
        #expect(resource.creationDate == registryInfo.createdDate)
        #expect(resource.modificationDate == registryInfo.modifiedDate)
        #expect(resource.labels.isEmpty, "default labels should be empty")
    }

    @Test("RegistryResource implements ManagedResource")
    func testManagedResourceConformance() {
        let registryInfo = createRegistryInfo()
        let resource = RegistryResource(from: registryInfo)

        // Test that it conforms to ManagedResource protocol
        let managedResource: any ManagedResource = resource
        #expect(managedResource.id == "docker.io")
        #expect(managedResource.name == "docker.io")
        #expect(managedResource.creationDate == registryInfo.createdDate)
        #expect(managedResource.labels.isEmpty)
    }

    @Test("RegistryResource is Codable - JSON encoding")
    func testRegistryResourceJSONEncoding() throws {
        let hostname = "docker.io"
        let username = "testuser"
        let registryInfo = createRegistryInfo(hostname: hostname, username: username)
        let resource = RegistryResource(from: registryInfo)

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let jsonData = try encoder.encode(resource)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Verify JSON contains expected fields
        #expect(jsonString.contains("\"id\""), "JSON should contain id field")
        #expect(jsonString.contains("\"name\""), "JSON should contain name field")
        #expect(jsonString.contains("\"username\""), "JSON should contain username field")
        #expect(jsonString.contains("\"creationDate\""), "JSON should contain creationDate field")
        #expect(jsonString.contains("\"modifiedDate\""), "JSON should contain modifiedDate field")
        #expect(jsonString.contains(hostname), "JSON should contain the hostname")
        #expect(jsonString.contains(username), "JSON should contain the username")
    }

    @Test("RegistryResource is Codable - round trip")
    func testRegistryResourceRoundTrip() throws {
        let hostname = "ghcr.io"
        let username = "developer"
        let registryInfo = createRegistryInfo(hostname: hostname, username: username)
        let original = RegistryResource(from: registryInfo)

        // Encode
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(original)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RegistryResource.self, from: jsonData)

        // Verify
        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.username == original.username)
        #expect(decoded.creationDate.timeIntervalSince1970 == original.creationDate.timeIntervalSince1970)
        #expect(decoded.modificationDate.timeIntervalSince1970 == original.modificationDate.timeIntervalSince1970)
        #expect(decoded.labels == original.labels)
    }

    @Test("RegistryResource nameValid validates hostnames")
    func testRegistryResourceNameValidation() {
        // Valid hostnames
        #expect(RegistryResource.nameValid("docker.io"), "docker.io should be valid")
        #expect(RegistryResource.nameValid("ghcr.io"), "ghcr.io should be valid")
        #expect(RegistryResource.nameValid("registry.example.com"), "registry.example.com should be valid")
        #expect(RegistryResource.nameValid("localhost:5000"), "localhost:5000 should be valid")
        #expect(RegistryResource.nameValid("registry.k8s.io"), "registry.k8s.io should be valid")

        // Invalid hostnames
        #expect(!RegistryResource.nameValid(""), "empty string should be invalid")
        #expect(!RegistryResource.nameValid("-invalid.com"), "hostname starting with hyphen should be invalid")
        #expect(!RegistryResource.nameValid("invalid-.com"), "hostname ending with hyphen should be invalid")
    }

    @Test("RegistryResource can have labels")
    func testRegistryResourceWithLabels() {
        let hostname = "docker.io"
        let username = "testuser"
        let labels = [
            "environment": "production",
            ResourceLabelKeys.role: "primary",
        ]

        let resource = RegistryResource(
            hostname: hostname,
            username: username,
            creationDate: Date(),
            modifiedDate: Date(),
            labels: labels
        )

        #expect(resource.labels.count == 2)
        #expect(resource.labels["environment"] == "production")
        #expect(resource.labels[ResourceLabelKeys.role] == "primary")
    }

    @Test("RegistryResource handles hostname with port")
    func testRegistryResourceWithPort() {
        let hostname = "localhost:5000"
        let registryInfo = createRegistryInfo(hostname: hostname, username: "admin")
        let resource = RegistryResource(from: registryInfo)

        #expect(resource.id == hostname)
        #expect(resource.name == hostname)
        #expect(RegistryResource.nameValid(hostname))
    }

    @Test("Multiple RegistryResources can be encoded as array")
    func testMultipleRegistryResourcesJSONEncoding() throws {
        let registries = [
            RegistryResource(from: createRegistryInfo(hostname: "docker.io", username: "user1")),
            RegistryResource(from: createRegistryInfo(hostname: "ghcr.io", username: "user2")),
            RegistryResource(from: createRegistryInfo(hostname: "quay.io", username: "user3")),
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let jsonData = try encoder.encode(registries)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Verify all hostnames are present
        #expect(jsonString.contains("docker.io"))
        #expect(jsonString.contains("ghcr.io"))
        #expect(jsonString.contains("quay.io"))

        // Verify all usernames are present
        #expect(jsonString.contains("user1"))
        #expect(jsonString.contains("user2"))
        #expect(jsonString.contains("user3"))

        // Print for manual verification
        print("Encoded JSON:")
        print(jsonString)
    }
}
