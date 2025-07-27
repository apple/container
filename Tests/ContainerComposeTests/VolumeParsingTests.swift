//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import XCTest
import ContainerCompose
@testable import ContainerCompose

final class VolumeParsingTests: XCTestCase {
    
    func testEmptyVolumeDefinition() throws {
        // Test case for volumes defined with empty values (e.g., "postgres-data:")
        let yaml = """
        version: '3'
        services:
          db:
            image: postgres
            volumes:
              - postgres-data:/var/lib/postgresql/data
        volumes:
          postgres-data:
          redis-data:
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        XCTAssertNotNil(composeFile.volumes)
        XCTAssertEqual(composeFile.volumes?.count, 2)
        
        // Check that empty volume definitions are parsed correctly
        let postgresVolume = composeFile.volumes?["postgres-data"]
        XCTAssertNotNil(postgresVolume)
        XCTAssertNil(postgresVolume?.driver)
        XCTAssertNil(postgresVolume?.external)
        XCTAssertNil(postgresVolume?.name)
        
        let redisVolume = composeFile.volumes?["redis-data"]
        XCTAssertNotNil(redisVolume)
        XCTAssertNil(redisVolume?.driver)
        XCTAssertNil(redisVolume?.external)
        XCTAssertNil(redisVolume?.name)
    }
    
    func testVolumeWithProperties() throws {
        let yaml = """
        version: '3'
        services:
          db:
            image: postgres
            volumes:
              - data:/var/lib/postgresql/data
        volumes:
          data:
            driver: local
            name: my-data-volume
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        XCTAssertNotNil(composeFile.volumes)
        XCTAssertEqual(composeFile.volumes?.count, 1)
        
        let dataVolume = composeFile.volumes?["data"]
        XCTAssertNotNil(dataVolume)
        XCTAssertEqual(dataVolume?.driver, "local")
        XCTAssertEqual(dataVolume?.name, "my-data-volume")
        XCTAssertNil(dataVolume?.external)
    }
    
    func testExternalVolume() throws {
        let yaml = """
        version: '3'
        services:
          app:
            image: myapp
            volumes:
              - external-vol:/data
        volumes:
          external-vol:
            external: true
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let externalVolume = composeFile.volumes?["external-vol"]
        XCTAssertNotNil(externalVolume)
        XCTAssertNotNil(externalVolume?.external)
    }
}