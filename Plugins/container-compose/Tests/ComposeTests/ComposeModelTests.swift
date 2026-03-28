//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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

import ComposeCore
import Foundation
import Testing

struct ComposeModelTests {
    @Test
    func testComposeIncludeShortAndLongFormsRoundTrip() throws {
        let shortData = Data(#""./vendor/compose.yaml""#.utf8)
        let shortInclude = try JSONDecoder().decode(ComposeInclude.self, from: shortData)
        #expect(shortInclude.path == .string("./vendor/compose.yaml"))
        #expect(shortInclude.projectDirectory == nil)
        #expect(shortInclude.envFile == nil)

        let shortEncoded = try JSONEncoder().encode(shortInclude)
        let shortRoundTrip = try JSONDecoder().decode(StringOrList.self, from: shortEncoded)
        #expect(shortRoundTrip == .string("./vendor/compose.yaml"))

        let longData = Data(#"{"path":["vendor/compose.yaml","vendor/override.yaml"],"project_directory":"vendor","env_file":["vendor/.env","vendor/dev.env"]}"#.utf8)
        let longInclude = try JSONDecoder().decode(ComposeInclude.self, from: longData)
        #expect(longInclude.path == .list(["vendor/compose.yaml", "vendor/override.yaml"]))
        #expect(longInclude.projectDirectory == "vendor")
        #expect(longInclude.envFile == .list(["vendor/.env", "vendor/dev.env"]))
    }

    @Test
    func testComposeNetworkAndVolumeDecodeExternalVariants() throws {
        let externalBool = try JSONDecoder().decode(
            ComposeNetwork.self,
            from: Data(#"{"driver":"bridge","external":true,"name":"shared"}"#.utf8)
        )
        #expect(externalBool.driver == "bridge")
        #expect(externalBool.name == "shared")
        if case .bool(let value)? = externalBool.external {
            #expect(value)
        } else {
            Issue.record("Expected external bool network")
        }

        let externalConfig = try JSONDecoder().decode(
            ComposeVolume.self,
            from: Data(#"{"external":{"name":"shared-data"},"name":"data"}"#.utf8)
        )
        #expect(externalConfig.name == "data")
        if case .config(let config)? = externalConfig.external {
            #expect(config.name == "shared-data")
        } else {
            Issue.record("Expected external config volume")
        }

        let emptyVolume = try JSONDecoder().decode(ComposeVolume.self, from: Data("true".utf8))
        #expect(emptyVolume.driver == nil)
        #expect(emptyVolume.external == nil)
        #expect(emptyVolume.name == nil)
    }

    @Test
    func testServiceVolumeStringAndObjectFormsDecode() throws {
        let stringVolume = try JSONDecoder().decode(ServiceVolume.self, from: Data(#""cache:/cache:ro""#.utf8))
        #expect(stringVolume == .string("cache:/cache:ro"))

        let objectVolume = try JSONDecoder().decode(
            ServiceVolume.self,
            from: Data(#"{"type":"bind","source":"./src","target":"/app/src","read_only":true,"bind":{"propagation":"rshared"}}"#.utf8)
        )

        guard case .object(let object) = objectVolume else {
            Issue.record("Expected object service volume")
            return
        }
        #expect(object.type == "bind")
        #expect(object.source == "./src")
        #expect(object.target == "/app/src")
        #expect(object.readOnly == true)
        #expect(object.bind?.propagation == "rshared")
    }

    @Test
    func testEnvironmentLabelsDependsOnAndNetworkConversions() throws {
        let environment = try JSONDecoder().decode(
            Environment.self,
            from: Data(#"["FOO=bar","'QUOTED_KEY'=value # trailing comment","EMPTY"]"#.utf8)
        )
        #expect(environment.asDictionary == [
            "FOO": "bar",
            "QUOTED_KEY": "value",
        ])

        let labels = try JSONDecoder().decode(
            Labels.self,
            from: Data(#"["com.example.role=api","com.example.empty"]"#.utf8)
        )
        #expect(labels.asDictionary == [
            "com.example.role": "api",
            "com.example.empty": "",
        ])

        let dependsOn = try JSONDecoder().decode(
            DependsOn.self,
            from: Data(#"{"db":{"condition":"service_healthy"},"cache":{"condition":"service_started"}}"#.utf8)
        )
        #expect(Set(dependsOn.asList) == ["db", "cache"])

        let networkList = try JSONDecoder().decode(NetworkConfig.self, from: Data(#"["front","back"]"#.utf8))
        if case .list(let names) = networkList {
            #expect(names == ["front", "back"])
        } else {
            Issue.record("Expected list network config")
        }

        let networkDict = try JSONDecoder().decode(
            NetworkConfig.self,
            from: Data(#"{"front":{"aliases":["web","api"]}}"#.utf8)
        )
        if case .dict(let networks) = networkDict {
            #expect(networks["front"]?.aliases == ["web", "api"])
        } else {
            Issue.record("Expected dict network config")
        }
    }

    @Test
    func testStringOrListArrayConversion() throws {
        let stringValue = try JSONDecoder().decode(StringOrList.self, from: Data(#""one""#.utf8))
        let listValue = try JSONDecoder().decode(StringOrList.self, from: Data(#"["one","two"]"#.utf8))

        #expect(stringValue.asArray == ["one"])
        #expect(listValue.asArray == ["one", "two"])
    }
}
