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

import ContainerResource
import Testing

@testable import ContainerCommands

struct BuilderStartTests {
    @Test
    func dnsConfigurationChangedTreatsMissingAndEmptyAsEquivalent() {
        let desired = ContainerConfiguration.DNSConfiguration()

        #expect(!Application.BuilderStart.dnsConfigurationChanged(existing: nil, desired: desired))
    }

    @Test
    func dnsConfigurationChangedDetectsRemovedConfiguration() {
        let existing = ContainerConfiguration.DNSConfiguration(
            nameservers: ["1.1.1.1"],
            domain: "corp.local",
            searchDomains: ["corp.local"],
            options: ["ndots:2"]
        )
        let desired = ContainerConfiguration.DNSConfiguration()

        #expect(Application.BuilderStart.dnsConfigurationChanged(existing: existing, desired: desired))
    }

    @Test
    func dnsConfigurationChangedDetectsAddedConfiguration() {
        let desired = ContainerConfiguration.DNSConfiguration(
            nameservers: ["8.8.8.8"],
            domain: "lab.local",
            searchDomains: ["lab.local"],
            options: ["timeout:1"]
        )

        #expect(Application.BuilderStart.dnsConfigurationChanged(existing: nil, desired: desired))
    }
}
