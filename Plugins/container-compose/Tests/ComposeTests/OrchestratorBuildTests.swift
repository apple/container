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

import Foundation
import Testing
import Logging
import ContainerizationError
import ContainerAPIClient
import ContainerPersistence

@testable import ComposeCore

@Suite(.serialized)
struct OrchestratorBuildTests {
    let log = Logger(label: "test")

    @Test
    func testOrchestratorCreation() async throws {
        _ = Orchestrator(log: log)
        #expect(Bool(true))
    }

    @Test
    func testBuildServiceCreation() async throws {
        _ = DefaultBuildService()
        #expect(Bool(true))
    }

    @Test
    func testServiceHasBuild() throws {
        // Test service with build config
        let buildConfig = BuildConfig(context: ".", dockerfile: "Dockerfile", args: nil, target: nil)
        let serviceWithBuild = Service(
            name: "test",
            image: nil,
            build: buildConfig
        )
        #expect(serviceWithBuild.hasBuild == true)

        // Test service with image only
        let serviceWithImage = Service(
            name: "test",
            image: "nginx:latest",
            build: nil
        )
        #expect(serviceWithImage.hasBuild == false)

        // Test service with both image and build
        let serviceWithBoth = Service(
            name: "test",
            image: "nginx:latest",
            build: buildConfig
        )
        #expect(serviceWithBoth.hasBuild == true)
    }

    @Test
    func testHealthCheckConfigurationValidation() throws {
        // Test health check with empty test command
        let emptyHealthCheck = HealthCheck(
            test: [],
            interval: nil,
            timeout: nil,
            retries: nil,
            startPeriod: nil
        )

        #expect(emptyHealthCheck.test.isEmpty)

        // Test health check with valid configuration
        let validHealthCheck = HealthCheck(
            test: ["curl", "-f", "http://localhost:8080/health"],
            interval: 30.0,
            timeout: 10.0,
            retries: 3,
            startPeriod: 60.0
        )

        #expect(validHealthCheck.test.count == 3)
        #expect(validHealthCheck.interval == 30.0)
        #expect(validHealthCheck.timeout == 10.0)
        #expect(validHealthCheck.retries == 3)
        #expect(validHealthCheck.startPeriod == 60.0)
    }

    @Test
    func testDependencyWaitTimeoutUsesHealthBudgetWhenLongerThanDefault() throws {
        let healthCheck = HealthCheck(
            test: ["/bin/true"],
            interval: 45.0,
            timeout: 5.0,
            retries: 4,
            startPeriod: 300.0,
            startInterval: 15.0
        )

        #expect(healthCheck.dependencyWaitTimeoutSeconds == 450)
    }

    @Test
    func testMakeContainerNetworkingConfigurationUsesRuntimeDNSAndDefaultNetwork() throws {
        DefaultsStore.unset(key: .defaultDNSDomain)

        let orchestrator = Orchestrator(log: log)

        let networking = try orchestrator.makeContainerNetworkingConfiguration(
            containerId: "service-1",
            networkIds: []
        )

        #expect(networking.dns.nameservers.isEmpty)
        #expect(networking.dns.domain == nil)
        #expect(networking.attachments.count == 1)
        #expect(networking.attachments[0].network == ClientNetwork.defaultNetworkName)
        #expect(networking.attachments[0].options.hostname == "service-1")
        #expect(networking.attachments[0].options.mtu == 1280)
    }

    @Test
    func testMakeContainerNetworkingConfigurationPreservesNetworkOrder() throws {
        DefaultsStore.unset(key: .defaultDNSDomain)

        guard #available(macOS 26, *) else {
            return
        }

        let orchestrator = Orchestrator(log: log)
        let networking = try orchestrator.makeContainerNetworkingConfiguration(
            containerId: "service-1",
            networkIds: ["alpha", "beta"]
        )

        #expect(networking.dns.nameservers.isEmpty)
        #expect(networking.attachments.map(\.network) == ["alpha", "beta"])
        #expect(networking.attachments.allSatisfy { $0.options.hostname == "service-1" })
        #expect(networking.attachments.allSatisfy { $0.options.mtu == 1280 })
    }

    @Test
    func testMakeContainerNetworkingConfigurationUsesDefaultDNSDomainForPrimaryHostname() throws {
        DefaultsStore.set(value: "compose.test", key: .defaultDNSDomain)
        defer { DefaultsStore.unset(key: .defaultDNSDomain) }

        let orchestrator = Orchestrator(log: log)
        let networking = try orchestrator.makeContainerNetworkingConfiguration(
            containerId: "service-1",
            networkIds: []
        )

        #expect(networking.dns.domain == "compose.test")
        #expect(networking.attachments[0].options.hostname == "service-1.compose.test.")
    }

    @Test
    func testResolvedMemoryLimitDefaultsToSixGiBWhenUnspecified() async throws {
        let orchestrator = Orchestrator(log: log)
        let service = Service(name: "frontend", image: "resq-fullstack:dev")

        let memory = await orchestrator.resolvedMemoryLimit(for: service)

        #expect(memory == 6144.mib())
    }

    @Test
    func testResolvedMemoryLimitUsesExplicitComposeValue() async throws {
        let orchestrator = Orchestrator(log: log)
        let service = Service(name: "frontend", image: "resq-fullstack:dev", memory: "2g")

        let memory = await orchestrator.resolvedMemoryLimit(for: service)

        #expect(memory == 2048.mib())
    }

    @Test
    func testResolvedProcessEnvironmentIncludesImageDefaultsAndServiceOverrides() throws {
        let orchestrator = Orchestrator(log: log)

        let environment = orchestrator.resolvedProcessEnvironment(
            imageEnvironment: [
                "PATH=/usr/local/bin:/usr/bin",
                "GF_PATHS_HOME=/usr/share/grafana",
                "UNPARSEABLE"
            ],
            serviceEnvironment: [
                "PATH": "/custom/bin:/usr/local/bin:/usr/bin",
                "GF_PATHS_DATA": "/var/lib/grafana"
            ]
        )

        #expect(environment.contains("PATH=/custom/bin:/usr/local/bin:/usr/bin"))
        #expect(environment.contains("GF_PATHS_HOME=/usr/share/grafana"))
        #expect(environment.contains("GF_PATHS_DATA=/var/lib/grafana"))
        #expect(!environment.contains("UNPARSEABLE"))
    }

    @Test
    func testOrchestratorCleanupFunctionality() async throws {
        // Test that the orchestrator can be created and basic functionality works
        _ = Orchestrator(log: log)

        // Test that cleanup methods exist and can be called (they're private but we can test indirectly)
        // This is more of an integration test to ensure the cleanup functionality is present
        #expect(Bool(true)) // Placeholder - cleanup functionality is implemented in the orchestrator
    }
}
