//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani
//===----------------------------------------------------------------------===//

import Testing
import Logging
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
@testable import ComposeCore

struct OrchestratorNetworkTests {
    let log = Logger(label: "test")

    @Test
    func testMapServiceNetworkIds_projectScoped() throws {
        let orch = Orchestrator(log: log)
        let nets: [String: Network] = [
            "appnet": Network(name: "appnet", driver: "bridge", external: false)
        ]
        let svc = Service(name: "web", image: "alpine", build: nil, command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["appnet"], dependsOn: [], dependsOnHealthy: [], dependsOnStarted: [], dependsOnCompletedSuccessfully: [], healthCheck: nil, deploy: nil, restart: nil, containerName: nil, profiles: [], labels: [:], cpus: nil, memory: nil, tty: false, stdinOpen: false)
        let proj = Project(name: "demo", services: ["web": svc], networks: nets, volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids == ["demo_appnet"])
    }

    @Test
    func testMapServiceNetworkIds_external() throws {
        let orch = Orchestrator(log: log)
        let nets: [String: Network] = [
            "extnet": Network(name: "extnet", driver: "bridge", external: true, externalName: "corp-net")
        ]
        let svc = Service(name: "api", image: "alpine", build: nil, command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["extnet"], dependsOn: [], dependsOnHealthy: [], dependsOnStarted: [], dependsOnCompletedSuccessfully: [], healthCheck: nil, deploy: nil, restart: nil, containerName: nil, profiles: [], labels: [:], cpus: nil, memory: nil, tty: false, stdinOpen: false)
        let proj = Project(name: "demo", services: ["api": svc], networks: nets, volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids == ["corp-net"]) // external uses literal name
    }

    @Test
    func testMapServiceNetworkIds_defaultWhenNone() throws {
        let orch = Orchestrator(log: log)
        let svc = Service(name: "api", image: "alpine", build: nil, command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: [], dependsOn: [], dependsOnHealthy: [], dependsOnStarted: [], dependsOnCompletedSuccessfully: [], healthCheck: nil, deploy: nil, restart: nil, containerName: nil, profiles: [], labels: [:], cpus: nil, memory: nil, tty: false, stdinOpen: false)
        let proj = Project(name: "demo", services: ["api": svc], networks: [:], volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids.isEmpty)
    }

    @Test
    func testMapServiceNetworkIds_bridgeNetworkModeUsesRuntimeDefault() throws {
        let orch = Orchestrator(log: log)
        let svc = Service(name: "api", image: "alpine", networks: ["default"], networkMode: "bridge")
        let proj = Project(name: "demo", services: ["api": svc], networks: ["default": Network(name: "default", driver: "bridge", external: false)], volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids.isEmpty)
    }

    @Test
    func testMapServiceNetworkIdsRejectsUnsupportedNetworkMode() {
        let orch = Orchestrator(log: log)
        let svc = Service(name: "api", image: "alpine", networkMode: "host")
        let proj = Project(name: "demo", services: ["api": svc], networks: [:], volumes: [:])

        #expect(throws: ContainerizationError.self) {
            _ = try orch.mapServiceNetworkIds(project: proj, service: svc)
        }
    }

    @Test
    func testResolvedAttachmentNetworkIdsAddsDefaultForHostGatewayServices() throws {
        let orch = Orchestrator(log: log)
        let svc = Service(
            name: "api",
            image: "alpine",
            networks: ["appnet"],
            extraHosts: [ExtraHost(hostname: "host.docker.internal", address: "host-gateway")]
        )
        let proj = Project(
            name: "demo",
            services: ["api": svc],
            networks: ["appnet": Network(name: "appnet", driver: "bridge", external: false)],
            volumes: [:]
        )

        let ids = try orch.resolvedAttachmentNetworkIds(project: proj, service: svc)
        #expect(ids == ["default", "demo_appnet"])
    }

    @Test
    func testComposePeerHostsIncludesServiceNameAndAliases() throws {
        let orch = Orchestrator(log: log)
        let backend = Service(
            name: "backend",
            image: "demo:dev",
            networks: ["resq-network"],
            extraHosts: [ExtraHost(hostname: "host.docker.internal", address: "host-gateway")]
        )
        let localstack = Service(
            name: "aws",
            image: "localstack/localstack:latest",
            networks: ["resq-network"],
            networkAliases: ["resq-network": ["localstack"]]
        )
        let project = Project(
            name: "resq-fullstack",
            services: ["backend": backend, "aws": localstack],
            networks: ["resq-network": Network(name: "resq-network", driver: "bridge", external: false)],
            volumes: [:]
        )

        let localstackConfig = ContainerConfiguration(
            id: "resq-localstack",
            image: ImageDescription(
                reference: "docker.io/localstack/localstack:4.2",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        var labeledConfig = localstackConfig
        labeledConfig.labels = [
            "com.apple.compose.project": "resq-fullstack",
            "com.apple.compose.service": "aws",
        ]

        let localstackSnapshot = ContainerSnapshot(
            configuration: labeledConfig,
            status: .running,
            networks: [
                Attachment(
                    network: "resq-fullstack_resq-network",
                    hostname: "resq-localstack",
                    ipv4Address: try CIDRv4("192.168.66.27/24"),
                    ipv4Gateway: try IPv4Address("192.168.66.1"),
                    ipv6Address: nil,
                    macAddress: nil
                )
            ]
        )

        let hosts = try orch.composePeerHosts(
            project: project,
            serviceName: "backend",
            service: backend,
            containers: [localstackSnapshot]
        )

        #expect(hosts == [
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.66.27",
                hostnames: ["aws", "localstack"]
            )
        ])
    }

    @Test
    func testComposePeerHostsIncludesRunningSharedServiceOutsideCurrentProjectModel() throws {
        let orch = Orchestrator(log: log)
        let backend = Service(
            name: "backend",
            image: "demo:dev",
            networks: ["resq-network"]
        )
        let project = Project(
            name: "resq-fullstack",
            services: ["backend": backend],
            networks: ["resq-network": Network(name: "resq-network", driver: "bridge", external: false)],
            volumes: [:]
        )

        let postgresConfig = ContainerConfiguration(
            id: "resq-postgres",
            image: ImageDescription(
                reference: "docker.io/kartoza/postgis:17-3.5",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        var labeledConfig = postgresConfig
        labeledConfig.labels = [
            "com.apple.compose.project": "resq-fullstack",
            "com.apple.compose.service": "postgres",
        ]

        let postgresSnapshot = ContainerSnapshot(
            configuration: labeledConfig,
            status: .running,
            networks: [
                Attachment(
                    network: "resq-fullstack_resq-network",
                    hostname: "resq-postgres",
                    ipv4Address: try CIDRv4("192.168.66.39/24"),
                    ipv4Gateway: try IPv4Address("192.168.66.1"),
                    ipv6Address: nil,
                    macAddress: nil
                )
            ]
        )

        let hosts = try orch.composePeerHosts(
            project: project,
            serviceName: "backend",
            service: backend,
            containers: [postgresSnapshot]
        )

        #expect(hosts == [
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.66.39",
                hostnames: ["postgres"]
            )
        ])
    }
}
