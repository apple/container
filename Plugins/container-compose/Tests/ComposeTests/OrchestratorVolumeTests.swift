//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors.
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import Logging
@testable import ComposeCore
import ContainerClient

private actor FakeVolumeClient: VolumeClient {
    struct Store { var vols: [String: ContainerClient.Volume] = [:] }
    private var store = Store()

    func create(name: String, driver: String, driverOpts: [String : String], labels: [String : String]) async throws -> ContainerClient.Volume {
        let v = ContainerClient.Volume(name: name, driver: driver, format: "ext4", source: "/vols/\(name)", labels: labels)
        store.vols[name] = v
        return v
    }
    func delete(name: String) async throws { store.vols.removeValue(forKey: name) }
    func list() async throws -> [ContainerClient.Volume] { Array(store.vols.values) }
    func inspect(name: String) async throws -> ContainerClient.Volume {
        if let v = store.vols[name] { return v }
        throw VolumeError.volumeNotFound(name)
    }
}

struct OrchestratorVolumeTests {
    let log = Logger(label: "test")

    @Test
    func testResolveComposeMounts_bind_named_anonymous() async throws {
        let fakeClient = FakeVolumeClient()
        let orch = Orchestrator(log: log, volumeClient: fakeClient)

        // Build a minimal project + service with three mounts
        let svcVolumes: [VolumeMount] = [
            // Bind mount
            VolumeMount(source: "/host/data", target: "/app/data", readOnly: true, type: .bind),
            // Named volume
            VolumeMount(source: "namedvol", target: "/var/lib/data", readOnly: false, type: .volume),
            // Anonymous volume (empty source, type volume)
            VolumeMount(source: "", target: "/cache", readOnly: false, type: .volume),
        ]

        let svc = Service(
            name: "app",
            image: "alpine:latest",
            build: nil,
            command: nil,
            entrypoint: nil,
            workingDir: nil,
            environment: [:],
            ports: [],
            volumes: svcVolumes,
            networks: [],
            dependsOn: [],
            dependsOnHealthy: [],
            dependsOnStarted: [],
            dependsOnCompletedSuccessfully: [],
            healthCheck: nil,
            deploy: nil,
            restart: nil,
            containerName: nil,
            profiles: [],
            labels: [:],
            cpus: nil,
            memory: nil,
            tty: false,
            stdinOpen: false
        )
        let project = Project(name: "proj", services: ["app": svc], networks: [:], volumes: ["namedvol": Volume(name: "namedvol")])

        let fs = try await orch.resolveComposeMounts(project: project, serviceName: "app", mounts: svcVolumes)
        #expect(fs.count == 3)

        // Bind -> virtiofs
        let bind = try #require(fs.first { $0.destination == "/app/data" })
        #expect(bind.isVirtiofs)
        #expect(bind.source == "/host/data")
        #expect(bind.options.contains("ro"))

        // Named volume -> block volume with real host path from fake client
        let named = try #require(fs.first { $0.destination == "/var/lib/data" })
        #expect(named.isVolume)
        #expect(named.source == "/vols/namedvol")

        // Anonymous -> created with generated name, but we mount by its host path
        let anon = try #require(fs.first { $0.destination == "/cache" })
        #expect(anon.isVolume)
        #expect(anon.source.hasPrefix("/vols/"))

        // Verify deterministic naming format
        let anonName = try await orch.resolveVolumeName(project: project, serviceName: "app", mount: VolumeMount(source: "", target: "/cache", type: .volume))
        #expect(anonName.hasPrefix("proj_app_anon_"))
    }
}
