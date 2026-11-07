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

import ContainerCommands
import ContainerResource
import Testing

// MARK: - ManagedContainer conformance tests

struct ManagedContainerDisplayTests {
    @Test
    func tableHeaderHasNineColumns() {
        #expect(ManagedContainer.tableHeader.count == 9)
        #expect(ManagedContainer.tableHeader[0] == "ID")
        #expect(ManagedContainer.tableHeader[4] == "STATE")
        #expect(ManagedContainer.tableHeader[8] == "STARTED")
    }
}

// MARK: - NetworkResource ListDisplayable conformance tests

struct NetworkResourceDisplayTests {
    @Test
    func tableHeaderHasTwoColumns() {
        #expect(NetworkResource.tableHeader.count == 2)
        #expect(NetworkResource.tableHeader == ["NETWORK", "SUBNET"])
    }
}

// MARK: - VolumeResource ListDisplayable conformance tests

struct VolumeResourceDisplayTests {
    @Test
    func tableRowRedactsPasswordOption() {
        let config = VolumeConfiguration(
            name: "myshare",
            driver: "smb",
            format: "cifs",
            source: "//server/share",
            labels: [:],
            options: [
                "share": "//server/share",
                "username": "user",
                "password": "supersecretpassword",
            ],
            sizeInBytes: nil
        )
        let resource = VolumeResource(configuration: config)
        let row = resource.tableRow

        #expect(row == ["myshare", "named", "smb", "password=***,share=//server/share,username=user"])
        #expect(!row[3].contains("supersecretpassword"))
    }
}
