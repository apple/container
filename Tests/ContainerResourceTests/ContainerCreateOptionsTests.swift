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

struct ContainerCreateOptionsTests {
    @Test(arguments: [
        ("no", RestartPolicy.no),
        ("always", .always),
        ("on-failure", .onFailure(maximumRetryCount: 0)),
        ("on-failure:0", .onFailure(maximumRetryCount: 0)),
        ("on-failure:3", .onFailure(maximumRetryCount: 3)),
        ("on-failure:010", .onFailure(maximumRetryCount: 10)),
    ])
    func parsesDockerSpellings(value: String, expected: RestartPolicy) throws {
        #expect(try RestartPolicy(parsing: value) == expected)
    }

    @Test(arguments: [
        "onFailure", "unless-stopped", "unlessStopped", "on-failure:", "on-failure:-1", "on-failure:+1",
        "on-failure:abc", "on-failure: 1", "on-failure:1.5", "on-failure:99999999999999999999", "always:3", "no:1", "", "sometimes",
    ])
    func rejectsOtherSpellings(value: String) {
        #expect(throws: Error.self) { try RestartPolicy(parsing: value) }
    }

    @Test func cliValueRoundTrips() throws {
        for setting in [RestartPolicy.no, .always, .onFailure(maximumRetryCount: 0), .onFailure(maximumRetryCount: 5)] {
            #expect(try RestartPolicy(parsing: setting.cliValue) == setting)
        }
    }

    @Test func zeroRetriesMeansUnlimitedAndNormalizes() throws {
        #expect(try RestartPolicy(parsing: "on-failure:0").cliValue == "on-failure")
    }

    @Test func decodesLegacyOptionsWithoutRestartPolicy() throws {
        let json = #"{"autoRemove": true}"#.data(using: .utf8)!
        let options = try JSONDecoder().decode(ContainerCreateOptions.self, from: json)
        #expect(options.autoRemove)
        #expect(options.restartPolicy == .no)
    }

    @Test func roundTripsRestartPolicy() throws {
        let options = ContainerCreateOptions(autoRemove: false, restartPolicy: .always)
        let decoded = try JSONDecoder().decode(ContainerCreateOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.restartPolicy == .always)
    }

    @Test(arguments: [RestartPolicy.always, .onFailure(maximumRetryCount: 0), .onFailure(maximumRetryCount: 2)])
    func rejectsAutoRemoveWithRestartPolicy(policy: RestartPolicy) {
        #expect(throws: Error.self) {
            try ContainerCreateOptions(autoRemove: true, restartPolicy: policy).validate()
        }
    }

    @Test func roundTripsMaximumRetryCount() throws {
        let options = ContainerCreateOptions(autoRemove: false, restartPolicy: .onFailure(maximumRetryCount: 4))
        let decoded = try JSONDecoder().decode(ContainerCreateOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.restartPolicy == .onFailure(maximumRetryCount: 4))
    }

    @Test func rejectsNegativeRetryCount() {
        #expect(throws: Error.self) { try ContainerCreateOptions(autoRemove: false, restartPolicy: .onFailure(maximumRetryCount: -1)).validate() }
    }

    @Test func allowsValidCombinations() throws {
        try ContainerCreateOptions(autoRemove: true, restartPolicy: .no).validate()
        try ContainerCreateOptions(autoRemove: false, restartPolicy: .always).validate()
        try ContainerCreateOptions(autoRemove: false, restartPolicy: .onFailure(maximumRetryCount: 3)).validate()
    }
}
