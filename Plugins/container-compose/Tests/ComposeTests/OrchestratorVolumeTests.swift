//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors.
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import Logging
@testable import ComposeCore
import ContainerAPIClient
import ContainerResource

private actor FakeVolumeClient: VolumeClient {
    struct Store { var vols: [String: ContainerResource.Volume] = [:] }
    private var store = Store()

    func create(name: String, driver: String, driverOpts: [String : String], labels: [String : String]) async throws -> ContainerResource.Volume {
        let v = ContainerResource.Volume(name: name, driver: driver, format: "ext4", source: "/vols/\(name)", labels: labels)
        store.vols[name] = v
        return v
    }
    func delete(name: String) async throws { store.vols.removeValue(forKey: name) }
    func list() async throws -> [ContainerResource.Volume] { Array(store.vols.values) }
    func inspect(name: String) async throws -> ContainerResource.Volume {
        if let v = store.vols[name] { return v }
        throw VolumeError.volumeNotFound(name)
    }
}

private actor FakeVolumePopulator: VolumePopulator {
    private(set) var calls: [(volume: String, target: String, imageName: String)] = []

    func populateIfNeeded(
        volume: ContainerResource.Volume,
        mount: VolumeMount,
        imageName: String,
        project: Project,
        serviceName: String,
        log: Logger
    ) async throws {
        _ = project
        _ = serviceName
        _ = log
        calls.append((volume.name, mount.target, imageName))
    }

    func snapshotCalls() -> [(volume: String, target: String, imageName: String)] {
        calls
    }
}

struct OrchestratorVolumeTests {
    let log = Logger(label: "test")

    @Test
    func testResolveComposeMounts_bind_named_anonymous() async throws {
        let fakeClient = FakeVolumeClient()
        let fakePopulator = FakeVolumePopulator()
        let orch = Orchestrator(log: log, volumeClient: fakeClient, volumePopulator: fakePopulator)

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

        let fs = try await orch.resolveComposeMounts(
            project: project,
            serviceName: "app",
            imageName: "alpine:latest",
            mounts: svcVolumes
        )
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

        let calls = await fakePopulator.snapshotCalls()
        #expect(calls.count == 2)
        #expect(calls.contains { $0.volume == "namedvol" && $0.target == "/var/lib/data" && $0.imageName == "alpine:latest" })
        #expect(calls.contains { $0.target == "/cache" && $0.imageName == "alpine:latest" })
    }

    @Test
    func testResolveComposeMountsCreatesMissingBindSourcesWhenRequested() async throws {
        let fakeClient = FakeVolumeClient()
        let fakePopulator = FakeVolumePopulator()
        let orch = Orchestrator(log: log, volumeClient: fakeClient, volumePopulator: fakePopulator)
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tempDir) }

        let missingSource = tempDir.appendingPathComponent("localstack").path
        let mounts = [
            VolumeMount(
                source: missingSource,
                target: "/var/lib/localstack",
                type: .bind,
                createHostPath: true
            )
        ]
        let service = Service(name: "localstack", image: "localstack/localstack:latest", volumes: mounts)
        let project = Project(name: "proj", services: ["localstack": service], networks: [:], volumes: [:])

        _ = try await orch.resolveComposeMounts(
            project: project,
            serviceName: "localstack",
            imageName: "localstack/localstack:latest",
            mounts: mounts
        )

        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: missingSource, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
        #expect(await fakePopulator.snapshotCalls().isEmpty)
    }

    @Test
    func testResolveComposeMountsSkipsCopyUpForExistingVolume() async throws {
        let fakeClient = FakeVolumeClient()
        let fakePopulator = FakeVolumePopulator()
        _ = try await fakeClient.create(name: "namedvol", driver: "local", driverOpts: [:], labels: [:])

        let orch = Orchestrator(log: log, volumeClient: fakeClient, volumePopulator: fakePopulator)
        let mounts = [
            VolumeMount(source: "namedvol", target: "/var/lib/data", type: .volume)
        ]
        let service = Service(name: "app", image: "alpine:latest", volumes: mounts)
        let project = Project(name: "proj", services: ["app": service], networks: [:], volumes: ["namedvol": Volume(name: "namedvol")])

        _ = try await orch.resolveComposeMounts(
            project: project,
            serviceName: "app",
            imageName: "alpine:latest",
            mounts: mounts
        )

        #expect(await fakePopulator.snapshotCalls().isEmpty)
    }
}
