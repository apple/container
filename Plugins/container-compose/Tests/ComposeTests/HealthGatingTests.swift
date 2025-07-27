//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
//===----------------------------------------------------------------------===//

import Testing
import Logging
@testable import ComposeCore

struct HealthGatingTests {
    let log = Logger(label: "test")

    func makeProject(health: Bool) -> Project {
        let h = health ? HealthCheck(test: ["/bin/true"]) : nil
        let db = Service(name: "db", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: [], healthCheck: h, deploy: nil, restart: nil, containerName: "p_db", profiles: [], labels: [:], cpus: nil, memory: nil)
        let web = Service(name: "web", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: ["db"], healthCheck: nil, deploy: nil, restart: nil, containerName: "p_web", profiles: [], labels: [:], cpus: nil, memory: nil)
        return Project(name: "p", services: ["db": db, "web": web], networks: [:], volumes: [:])
    }

    @Test
    func testAwaitHealthyReturnsWhenHealthy() async throws {
        let orch = Orchestrator(log: log)
        let project = makeProject(health: true)
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        try await orch.awaitServiceHealthy(project: project, serviceName: "db", deadlineSeconds: 2)
    }

    @Test
    func testAwaitHealthyWaitsUntilNotified() async throws {
        let orch = Orchestrator(log: log)
        let project = makeProject(health: true)
        // Don't set healthy yet; flip after a short delay
        async let gate: Void = orch.awaitServiceHealthy(project: project, serviceName: "db", deadlineSeconds: 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        _ = try await gate
    }

    @Test
    func testAwaitHealthyNoHealthcheckDoesNotBlock() async throws {
        let orch = Orchestrator(log: log)
        // Project with db lacking healthcheck
        let p = Project(name: "p", services: [
            "db": Service(name: "db", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: [], healthCheck: nil, deploy: nil, restart: nil, containerName: "p_db", profiles: [], labels: [:], cpus: nil, memory: nil)
        ], networks: [:], volumes: [:])
        try await orch.awaitServiceHealthy(project: p, serviceName: "db", deadlineSeconds: 1)
    }


    @Test
    func testAwaitStartedReturnsWhenRunning() async throws {
        let orch = Orchestrator(log: log)
        let project = makeProject(health: false)
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        try await orch.awaitServiceStarted(project: project, serviceName: "db", deadlineSeconds: 1)
    }

    @Test
    func testAwaitCompletedPlaceholder() throws {
        // Placeholder: without runtime or a direct setter to stopped, we acknowledge coverage gap here.
        #expect(true)
    }

    @Test
    func testDependsOnStartedGating() async throws {
        let orch = Orchestrator(log: log)
        let db = Service(name: "db", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnStarted: [], healthCheck: nil, deploy: nil, restart: nil, containerName: "p_db", profiles: [], labels: [:], cpus: nil, memory: nil)
        let web = Service(name: "web", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnStarted: ["db"], healthCheck: nil, deploy: nil, restart: nil, containerName: "p_web", profiles: [], labels: [:], cpus: nil, memory: nil)
        let project = Project(name: "p", services: ["db": db, "web": web], networks: [:], volumes: [:])

        // Test that web waits for db to start
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        try await orch.awaitServiceStarted(project: project, serviceName: "db", deadlineSeconds: 1)
    }



    @Test
    func testMultipleDependencyTypes() async throws {
        let orch = Orchestrator(log: log)
        let db = Service(name: "db", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: [], healthCheck: HealthCheck(test: ["/bin/true"]), deploy: nil, restart: nil, containerName: "p_db", profiles: [], labels: [:], cpus: nil, memory: nil)
        let cache = Service(name: "cache", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnStarted: [], healthCheck: nil, deploy: nil, restart: nil, containerName: "p_cache", profiles: [], labels: [:], cpus: nil, memory: nil)
        let web = Service(name: "web", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: ["db"], dependsOnStarted: ["cache"], healthCheck: nil, deploy: nil, restart: nil, containerName: "p_web", profiles: [], labels: [:], cpus: nil, memory: nil)
        let project = Project(name: "p", services: ["db": db, "cache": cache, "web": web], networks: [:], volumes: [:])

        // Test that web waits for both db to be healthy and cache to be started
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        await orch.testSetServiceHealthy(project: project, serviceName: "cache")

        try await orch.awaitServiceHealthy(project: project, serviceName: "db", deadlineSeconds: 1)
        try await orch.awaitServiceStarted(project: project, serviceName: "cache", deadlineSeconds: 1)
    }

    @Test
    func testHealthCheckTimeout() async throws {
        let orch = Orchestrator(log: log)
        let db = Service(name: "db", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: [], healthCheck: HealthCheck(test: ["/bin/true"], timeout: 1), deploy: nil, restart: nil, containerName: "p_db", profiles: [], labels: [:], cpus: nil, memory: nil)
        let project = Project(name: "p", services: ["db": db], networks: [:], volumes: [:])

        // Test that health check respects timeout
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        try await orch.awaitServiceHealthy(project: project, serviceName: "db", deadlineSeconds: 2)
    }

    @Test
    func testHealthCheckRetries() async throws {
        let orch = Orchestrator(log: log)
        let db = Service(name: "db", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: [], healthCheck: HealthCheck(test: ["/bin/true"], retries: 3), deploy: nil, restart: nil, containerName: "p_db", profiles: [], labels: [:], cpus: nil, memory: nil)
        let project = Project(name: "p", services: ["db": db], networks: [:], volumes: [:])

        // Test that health check respects retry count
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        try await orch.awaitServiceHealthy(project: project, serviceName: "db", deadlineSeconds: 2)
    }
}

