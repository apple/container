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

@testable import ContainerPlugin

struct ServiceManagerTests {
    @Test
    func testInterpretPrintStatusSuccessMeansRegistered() throws {
        #expect(try ServiceManager.interpretPrintStatus(0))
    }

    @Test
    func testInterpretPrintStatusNoSuchServiceMeansUnregistered() throws {
        #expect(try !ServiceManager.interpretPrintStatus(ServiceManager.LaunchctlStatus.noSuchService))
    }

    @Test
    func testInterpretPrintStatusUnexpectedStatusThrows() throws {
        let statuses: [Int32] = [1, 3, 64, 112]
        for status in statuses {
            #expect {
                _ = try ServiceManager.interpretPrintStatus(
                    status,
                    target: "gui/501/com.apple.container.apiserver",
                    standardError: "marker"
                )
            } throws: { error in
                "\(error)".contains("status \(status), message: marker")
            }
        }
    }

    @Test
    func testIsRegisteredUnknownLabel() throws {
        let domain = try ServiceManager.getDomainString()
        let label = "\(domain)/com.apple.container.bogus-\(UUID().uuidString)"
        #expect(try !ServiceManager.isRegistered(fullServiceLabel: label))
    }
}
