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
import ContainerizationError
@testable import ContainerCompose

final class HealthCheckTests: XCTestCase {
    func testHealthCheckParsing() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: nginx:alpine
            healthcheck:
              test: ["CMD", "curl", "-f", "http://localhost"]
              interval: 30s
              timeout: 10s
              retries: 3
              start_period: 40s
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        XCTAssertNotNil(composeFile.services["web"]?.healthcheck)
        let healthcheck = composeFile.services["web"]!.healthcheck!
        
        XCTAssertEqual(healthcheck.test, .list(["CMD", "curl", "-f", "http://localhost"]))
        XCTAssertEqual(healthcheck.interval, "30s")
        XCTAssertEqual(healthcheck.timeout, "10s")
        XCTAssertEqual(healthcheck.retries, 3)
        XCTAssertEqual(healthcheck.startPeriod, "40s")
    }
    
    func testHealthCheckStringFormat() throws {
        let yaml = """
        version: '3'
        services:
          app:
            image: alpine
            healthcheck:
              test: "curl -f http://localhost || exit 1"
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let healthcheck = composeFile.services["app"]!.healthcheck!
        XCTAssertEqual(healthcheck.test, .string("curl -f http://localhost || exit 1"))
    }
    
    func testHealthCheckDisabled() throws {
        let yaml = """
        version: '3'
        services:
          db:
            image: postgres
            healthcheck:
              disable: true
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let healthcheck = composeFile.services["db"]!.healthcheck!
        XCTAssertTrue(healthcheck.disable ?? false)
    }
    
    func testProjectConverterHealthCheck() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: nginx
            healthcheck:
              test: ["CMD", "wget", "-q", "--spider", "http://localhost"]
              interval: 30s
              timeout: 5s
              retries: 3
              start_period: 10s
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let converter = ProjectConverter(log: .test)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "test",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        
        let service = project.services["web"]!
        XCTAssertNotNil(service.healthCheck)
        
        let healthCheck = service.healthCheck!
        XCTAssertEqual(healthCheck.test, ["CMD", "wget", "-q", "--spider", "http://localhost"])
        XCTAssertEqual(healthCheck.interval, 30)
        XCTAssertEqual(healthCheck.timeout, 5)
        XCTAssertEqual(healthCheck.retries, 3)
        XCTAssertEqual(healthCheck.startPeriod, 10)
    }
    
    func testHealthCheckWithShellFormat() throws {
        let yaml = """
        version: '3'
        services:
          api:
            image: node:alpine
            healthcheck:
              test: ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
              interval: 10s
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let converter = ProjectConverter(log: .test)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "test",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        
        let healthCheck = project.services["api"]!.healthCheck!
        // CMD-SHELL should be converted to shell command
        XCTAssertEqual(healthCheck.test, ["/bin/sh", "-c", "curl -f http://localhost:3000/health || exit 1"])
    }
    
    func testHealthCheckNoneDisabled() throws {
        let yaml = """
        version: '3'
        services:
          worker:
            image: busybox
            healthcheck:
              test: ["NONE"]
        """
        
        let parser = ComposeParser(log: .test)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        
        let converter = ProjectConverter(log: .test)
        let project = try converter.convert(
            composeFile: composeFile,
            projectName: "test",
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        
        // NONE should result in no health check
        XCTAssertNil(project.services["worker"]!.healthCheck)
    }
}