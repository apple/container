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

import XCTest
@testable import ContainerCLI
import Foundation
import ContainerClient

class TestCLIComposeHealth: CLITest {
    
    func testComposeHealthCheck() async throws {
        // Create compose file with health check
        let composeContent = """
        version: '3'
        services:
          healthy:
            image: busybox
            command: ["sh", "-c", "echo 'healthy' && sleep 3600"]
            healthcheck:
              test: ["CMD", "echo", "ok"]
              interval: 5s
              timeout: 3s
              start_period: 2s
          
          unhealthy:
            image: busybox
            command: ["sh", "-c", "echo 'unhealthy' && sleep 3600"]
            healthcheck:
              test: ["CMD", "sh", "-c", "exit 1"]
              interval: 5s
              timeout: 3s
        """
        
        let composeFile = tempDir.appendingPathComponent("docker-compose.yml")
        try composeContent.write(to: composeFile, atomically: true, encoding: .utf8)
        
        // Start services
        try await runCommand(["compose", "up", "-d"])
        
        // Wait for health checks to initialize
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        
        // Check health status
        let output = try await runCommand(["compose", "health"])
        
        // Verify output shows correct health status
        XCTAssertTrue(output.contains("✓ healthy: healthy"))
        XCTAssertTrue(output.contains("✗ unhealthy: unhealthy"))
        
        // Cleanup
        try await runCommand(["compose", "down"])
    }
    
    func testComposeHealthQuietMode() async throws {
        // Create compose file with failing health check
        let composeContent = """
        version: '3'
        services:
          failing:
            image: busybox
            command: ["sleep", "3600"]
            healthcheck:
              test: ["CMD", "false"]
              interval: 1s
        """
        
        let composeFile = tempDir.appendingPathComponent("docker-compose.yml")
        try composeContent.write(to: composeFile, atomically: true, encoding: .utf8)
        
        // Start service
        try await runCommand(["compose", "up", "-d"])
        
        // Wait for health check
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        // Check health in quiet mode - should fail
        do {
            _ = try await runCommand(["compose", "health", "--quiet"])
            XCTFail("Expected health check to fail")
        } catch {
            // Expected to fail
        }
        
        // Cleanup
        try await runCommand(["compose", "down"])
    }
    
    func testComposeHealthSpecificService() async throws {
        // Create compose file with multiple services
        let composeContent = """
        version: '3'
        services:
          web:
            image: busybox
            command: ["sleep", "3600"]
            healthcheck:
              test: ["CMD", "true"]
          
          db:
            image: busybox
            command: ["sleep", "3600"]
            healthcheck:
              test: ["CMD", "true"]
        """
        
        let composeFile = tempDir.appendingPathComponent("docker-compose.yml")
        try composeContent.write(to: composeFile, atomically: true, encoding: .utf8)
        
        // Start services
        try await runCommand(["compose", "up", "-d"])
        
        // Check health of specific service
        let output = try await runCommand(["compose", "health", "web"])
        
        // Should only show web service
        XCTAssertTrue(output.contains("✓ web: healthy"))
        XCTAssertFalse(output.contains("db"))
        
        // Cleanup
        try await runCommand(["compose", "down"])
    }
    
    func testComposeHealthNoHealthCheck() async throws {
        // Create compose file without health checks
        let composeContent = """
        version: '3'
        services:
          app:
            image: busybox
            command: ["sleep", "3600"]
        """
        
        let composeFile = tempDir.appendingPathComponent("docker-compose.yml")
        try composeContent.write(to: composeFile, atomically: true, encoding: .utf8)
        
        // Start service
        try await runCommand(["compose", "up", "-d"])
        
        // Check health
        let output = try await runCommand(["compose", "health"])
        
        // Should indicate no health checks
        XCTAssertTrue(output.contains("No services with health checks found"))
        
        // Cleanup
        try await runCommand(["compose", "down"])
    }
}
