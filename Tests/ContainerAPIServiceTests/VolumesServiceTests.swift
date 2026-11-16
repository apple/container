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

import ContainerAPIClient
import ContainerAPIService
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerTestSupport
import ContainerizationError
import Foundation
import Logging
import SystemPackage
import Testing

struct VolumesServiceTests {
    private let log = Logger(label: "test")

    private func makeServices(
        appRoot: FilePath,
        credentialStore: VolumeCredentialStore = InMemoryVolumeCredentialStore()
    ) async throws -> (VolumesService, ContainersService) {
        let appRootURL = URL(fileURLWithPath: appRoot.string)
        let pluginLoader = try PluginLoader(
            appRoot: appRootURL,
            installRoot: appRootURL,
            logRoot: nil,
            pluginDirectories: [],
            pluginFactories: []
        )
        let containersService = try await ContainersService(
            appRoot: appRootURL,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log,
            credentialStore: credentialStore
        )
        let volumesService = try await VolumesService(
            resourceRoot: appRoot.appending("volumes"),
            containersService: containersService,
            log: log,
            credentialStore: credentialStore
        )
        return (volumesService, containersService)
    }

    private func makeVolumesService(
        appRoot: FilePath,
        credentialStore: VolumeCredentialStore = InMemoryVolumeCredentialStore()
    ) async throws -> VolumesService {
        try await makeServices(appRoot: appRoot, credentialStore: credentialStore).0
    }

    @Test("VolumesService creates, inspects, and deletes an SMB volume without a disk image")
    func testCreateInspectDeleteSMBVolume() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            let created = try await service.create(
                name: "myshare",
                driver: "smb",
                driverOpts: ["share": "//server/share", "username": "user", "password": "secret"],
                labels: ["env": "test"]
            )

            #expect(created.name == "myshare")
            #expect(created.driver == "smb")
            #expect(created.format == "cifs")
            #expect(created.source == "//server/share")
            #expect(created.sizeInBytes == nil)
            #expect(created.options["username"] == "user")
            #expect(created.labels["env"] == "test")

            let blockImagePath = appRoot.appending("volumes/myshare/volume.img").string
            #expect(!FileManager.default.fileExists(atPath: blockImagePath))

            let inspected = try await service.inspect("myshare")
            #expect(inspected.name == "myshare")
            #expect(inspected.driver == "smb")
            #expect(inspected.source == "//server/share")

            try await service.delete(name: "myshare")
            await #expect(throws: VolumeError.self) {
                _ = try await service.inspect("myshare")
            }
        }
    }

    @Test("VolumesService creates, inspects, and deletes an NFS volume without a disk image")
    func testCreateInspectDeleteNFSVolume() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            let created = try await service.create(
                name: "myexport",
                driver: "nfs",
                driverOpts: ["share": "nas.local:/exports/data", "vers": "4", "nolock": ""],
                labels: ["env": "test"]
            )

            #expect(created.name == "myexport")
            #expect(created.driver == "nfs")
            #expect(created.format == "nfs")
            #expect(created.source == "nas.local:/exports/data")
            #expect(created.sizeInBytes == nil)
            #expect(created.options["vers"] == "4")
            #expect(created.options["nolock"] == "")
            #expect(created.labels["env"] == "test")

            let blockImagePath = appRoot.appending("volumes/myexport/volume.img").string
            #expect(!FileManager.default.fileExists(atPath: blockImagePath))

            let inspected = try await service.inspect("myexport")
            #expect(inspected.name == "myexport")
            #expect(inspected.driver == "nfs")
            #expect(inspected.source == "nas.local:/exports/data")

            try await service.delete(name: "myexport")
            await #expect(throws: VolumeError.self) {
                _ = try await service.inspect("myexport")
            }
        }
    }

    @Test(
        "VolumesService rejects SMB and NFS volumes with missing or empty share option",
        arguments: ["smb", "nfs"]
    )
    func testRejectsMissingOrEmptyShare(_ driver: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol1", driver: driver, driverOpts: [:])
            }

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol2", driver: driver, driverOpts: ["share": ""])
            }
        }
    }

    @Test(
        "VolumesService rejects unsupported size option for SMB and NFS volumes",
        arguments: [
            ("smb", "//server/share"),
            ("nfs", "nas.local:/exports/data"),
        ]
    )
    func testRejectsSizeOption(_ driver: String, _ share: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(
                    name: "vol1",
                    driver: driver,
                    driverOpts: ["share": share, "size": "10G"]
                )
            }
        }
    }

    @Test(
        "VolumesService rejects SMB and NFS volumes with syntactically invalid options",
        arguments: [
            ("smb", "//server/share"),
            ("nfs", "nas.local:/exports/data"),
        ]
    )
    func testRejectsInvalidMountOptions(_ driver: String, _ share: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            // A comma in a value could inject additional mount options.
            await #expect(throws: VolumeError.self) {
                _ = try await service.create(
                    name: "vol1",
                    driver: driver,
                    driverOpts: ["share": share, "username": "user,uid=0"]
                )
            }

            // A key that does not start with a letter.
            await #expect(throws: VolumeError.self) {
                _ = try await service.create(
                    name: "vol2",
                    driver: driver,
                    driverOpts: ["share": share, "1bad": "value"]
                )
            }

            // A control character in the share.
            await #expect(throws: VolumeError.self) {
                _ = try await service.create(
                    name: "vol3",
                    driver: driver,
                    driverOpts: ["share": share + "\n"]
                )
            }

            // Nothing was persisted.
            let volumes = try await service.list()
            #expect(volumes.isEmpty)
        }
    }

    @Test(
        "VolumesService accepts shares that contain spaces",
        arguments: [
            ("smb", "//server/My Share"),
            ("nfs", "nas.local:/exports/my data"),
        ]
    )
    func testAcceptsShareWithSpaces(_ driver: String, _ share: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            let created = try await service.create(name: "vol1", driver: driver, driverOpts: ["share": share])
            #expect(created.source == share)
            #expect(created.options["share"] == share)
        }
    }

    @Test("VolumesService rejects unsupported volume driver")
    func testRejectsUnsupportedDriver() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol1", driver: "ceph", driverOpts: [:])
            }
        }
    }

    // MARK: - SMB credentials

    @Test("VolumesService keeps the SMB password in the credential store, not in the volume")
    func testSMBPasswordIsStoredInCredentialStore() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore()
            let service = try await makeVolumesService(appRoot: appRoot, credentialStore: credentialStore)

            let created = try await service.create(
                name: "myshare",
                driver: "smb",
                driverOpts: [
                    "share": "//server/share",
                    "username": "alice",
                    "password": "hunter2",
                    "domain": "CORP",
                ]
            )

            // The returned, persisted, and inspected configurations all omit the password.
            #expect(created.options["password"] == nil)
            #expect(created.options["username"] == "alice")
            #expect(created.options["domain"] == "CORP")
            let inspected = try await service.inspect("myshare")
            #expect(inspected.options["password"] == nil)
            let onDisk = try String(contentsOfFile: appRoot.appending("volumes/myshare/entity.json").string, encoding: .utf8)
            #expect(!onDisk.contains("hunter2"))

            // The credential store holds it, keyed by volume name.
            #expect(try credentialStore.lookup(volume: "myshare") == VolumeCredential(username: "alice", password: "hunter2"))

            // Deleting the volume removes the credential.
            try await service.delete(name: "myshare")
            #expect(try credentialStore.lookup(volume: "myshare") == nil)
            #expect(credentialStore.count == 0)
        }
    }

    @Test("VolumesService does not store a credential for an SMB volume without a password")
    func testSMBWithoutPasswordStoresNoCredential() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore()
            let service = try await makeVolumesService(appRoot: appRoot, credentialStore: credentialStore)

            _ = try await service.create(name: "guest", driver: "smb", driverOpts: ["share": "//server/public", "guest": ""])
            #expect(credentialStore.count == 0)

            // Deleting is still fine when there is nothing to remove.
            try await service.delete(name: "guest")
        }
    }

    @Test("VolumesService removes any pre-existing credential when creating an SMB volume without a password")
    func testSMBWithoutPasswordRemovesStaleCredential() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore()
            try credentialStore.save(volume: "guest", credential: VolumeCredential(username: "old", password: "stale"))
            #expect(credentialStore.count == 1)

            let service = try await makeVolumesService(appRoot: appRoot, credentialStore: credentialStore)
            _ = try await service.create(name: "guest", driver: "smb", driverOpts: ["share": "//server/public", "guest": ""])

            #expect(try credentialStore.lookup(volume: "guest") == nil)
            #expect(credentialStore.count == 0)
        }
    }

    @Test("VolumesService rejects an SMB password without a username")
    func testSMBPasswordRequiresUsername() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore()
            let service = try await makeVolumesService(appRoot: appRoot, credentialStore: credentialStore)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol1", driver: "smb", driverOpts: ["share": "//server/share", "password": "hunter2"])
            }
            #expect(credentialStore.count == 0)
            #expect(try await service.list().isEmpty)
        }
    }

    @Test(
        "VolumesService rejects SMB secret keys other than password and non-allowlisted keys",
        arguments: ["pass", "password2", "pass2", "credentials", "cred", "ip", "addr", "source", "unc"]
    )
    func testSMBRejectsOtherSecretKeys(_ key: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore()
            let service = try await makeVolumesService(appRoot: appRoot, credentialStore: credentialStore)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol1", driver: "smb", driverOpts: ["share": "//server/share", "username": "u", key: "x"])
            }
            #expect(credentialStore.count == 0)
            #expect(try await service.list().isEmpty)
        }
    }

    @Test(
        "VolumesService rejects secret keys for NFS volumes, which have no password option",
        arguments: ["password", "pass", "password2", "pass2", "credentials", "cred"]
    )
    func testNFSRejectsSecretKeys(_ key: String) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore()
            let service = try await makeVolumesService(appRoot: appRoot, credentialStore: credentialStore)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "vol1", driver: "nfs", driverOpts: ["share": "nas.local:/exports/data", key: "x"])
            }
            #expect(credentialStore.count == 0)
            #expect(try await service.list().isEmpty)
        }
    }

    @Test("VolumesService does not create the volume if the credential cannot be stored")
    func testSMBCreateFailsClosedWhenCredentialStoreFails() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore(failSave: true)
            let service = try await makeVolumesService(appRoot: appRoot, credentialStore: credentialStore)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(
                    name: "vol1",
                    driver: "smb",
                    driverOpts: ["share": "//server/share", "username": "alice", "password": "hunter2"]
                )
            }
            #expect(try await service.list().isEmpty)
        }
    }

    // MARK: - ContainersService SMB volume & credential verification

    @Test("ContainersService.validateMounts verifies named SMB mounts against stored volumes")
    func testValidateMountsChecksNamedSMBVolume() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore()
            let (volumesService, containersService) = try await makeServices(appRoot: appRoot, credentialStore: credentialStore)

            let vol = try await volumesService.create(
                name: "corp",
                driver: "smb",
                driverOpts: ["share": "//corp.local/files", "username": "alice", "password": "secret", "domain": "CORP"]
            )
            _ = try await volumesService.create(
                name: "nfsvol",
                driver: "nfs",
                driverOpts: ["share": "nas.local:/exports/data"]
            )

            // Valid named mount matching stored volume source and options, with ro/rw.
            let validMount = Filesystem.smb(
                name: "corp",
                share: vol.source,
                mountOptions: vol.options,
                destination: "/mnt/corp",
                options: ["ro"]
            )
            try await containersService.validateMounts([validMount])

            // 1. Unknown volume or non-smb volume is rejected.
            let unknownVolMount = Filesystem.smb(
                name: "missing",
                share: "//corp.local/files",
                mountOptions: vol.options,
                destination: "/mnt/corp",
                options: []
            )
            await #expect(throws: ContainerizationError.self) {
                try await containersService.validateMounts([unknownVolMount])
            }

            let nonSMBVolMount = Filesystem.smb(
                name: "nfsvol",
                share: "nas.local:/exports/data",
                mountOptions: ["share": "nas.local:/exports/data"],
                destination: "/mnt/corp",
                options: []
            )
            await #expect(throws: ContainerizationError.self) {
                try await containersService.validateMounts([nonSMBVolMount])
            }

            // 2. Mismatched share or mountOptions is rejected, naming destination and field, never the value.
            let wrongShareMount = Filesystem.smb(
                name: "corp",
                share: "//evil.example.com/capture",
                mountOptions: vol.options,
                destination: "/mnt/corp",
                options: []
            )
            do {
                try await containersService.validateMounts([wrongShareMount])
                Issue.record("Expected wrong share to be rejected")
            } catch let error as ContainerizationError {
                #expect(error.message.contains("/mnt/corp"))
                #expect(error.message.contains("share"))
                #expect(!error.message.contains("evil.example.com"))
            }

            let wrongOptionsMount = Filesystem.smb(
                name: "corp",
                share: vol.source,
                mountOptions: ["share": vol.source, "username": "mallory"],
                destination: "/mnt/corp",
                options: []
            )
            do {
                try await containersService.validateMounts([wrongOptionsMount])
                Issue.record("Expected wrong mountOptions to be rejected")
            } catch let error as ContainerizationError {
                #expect(error.message.contains("/mnt/corp"))
                #expect(error.message.contains("mountOptions"))
                #expect(!error.message.contains("mallory"))
            }

            // 3. Per-mount options other than exact "ro" and "rw" are rejected.
            for badPerMount in ["pass=leaked", "password=leaked", "password2=leaked", "pass2=leaked", "ip=1.2.3.4", "addr=1.2.3.4", "source=//evil/share", "username=mallory", ""] {
                let badPerMountFS = Filesystem.smb(
                    name: "corp",
                    share: vol.source,
                    mountOptions: vol.options,
                    destination: "/mnt/corp",
                    options: [badPerMount]
                )
                do {
                    try await containersService.validateMounts([badPerMountFS])
                    Issue.record("Expected per-mount option '\(badPerMount)' to be rejected")
                } catch let error as ContainerizationError {
                    #expect(!error.message.contains("leaked"))
                }
            }

            // 4. Unnamed direct SMB mount is allowed without a password and rejected with one.
            let directMount = Filesystem.smb(
                name: nil,
                share: "//public.local/share",
                mountOptions: ["guest": ""],
                destination: "/mnt/public",
                options: ["ro"]
            )
            try await containersService.validateMounts([directMount])

            let directMountWithPassword = Filesystem.smb(
                name: nil,
                share: "//public.local/share",
                mountOptions: ["username": "alice", "password": "secret"],
                destination: "/mnt/public",
                options: []
            )
            await #expect(throws: ContainerizationError.self) {
                try await containersService.validateMounts([directMountWithPassword])
            }
        }
    }

    @Test("ContainersService.prepareBootstrapMounts rebuilds named SMB mounts from volume and enforces credential rules")
    func testPrepareBootstrapMountsRebuildsAndResolvesCredentials() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let credentialStore = InMemoryVolumeCredentialStore()
            let (volumesService, containersService) = try await makeServices(appRoot: appRoot, credentialStore: credentialStore)

            let authVol = try await volumesService.create(
                name: "corp",
                driver: "smb",
                driverOpts: ["share": "//corp.local/files", "username": "alice", "password": "hunter2", "domain": "CORP"]
            )
            let guestVol = try await volumesService.create(
                name: "public",
                driver: "smb",
                driverOpts: ["share": "//corp.local/public", "guest": ""]
            )

            let image = ImageDescription(reference: "alpine:latest", descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:00", size: 1))
            let process = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))

            // Even if the stored container config has tampered share/mountOptions on a named SMB mount,
            // prepareBootstrapMounts rebuilds it from the authoritative volume before releasing the credential.
            var config = ContainerConfiguration(id: "c1", image: image, process: process)
            config.mounts = [
                Filesystem.smb(
                    name: "corp",
                    share: "//attacker.example.com/steal",
                    mountOptions: ["share": "//attacker.example.com/steal", "username": "attacker"],
                    destination: "/mnt/corp",
                    options: ["ro"]
                ),
                Filesystem.smb(
                    name: "public",
                    share: guestVol.source,
                    mountOptions: guestVol.options,
                    destination: "/mnt/public",
                    options: ["rw"]
                ),
                Filesystem.smb(
                    name: nil,
                    share: "//direct.local/share",
                    mountOptions: ["guest": ""],
                    destination: "/mnt/direct",
                    options: ["ro"]
                ),
            ]

            let creds = try await containersService.prepareBootstrapMounts(for: &config)
            #expect(creds == ["corp": "hunter2"])

            guard case .smb(let name, let rebuiltShare, let rebuiltOpts) = config.mounts[0].type else {
                Issue.record("Expected rebuilt .smb mount")
                return
            }
            #expect(name == "corp")
            #expect(rebuiltShare == authVol.source)
            #expect(config.mounts[0].source == authVol.source)
            #expect(rebuiltOpts == authVol.options)
            #expect(config.mounts[0].destination == "/mnt/corp")
            #expect(config.mounts[0].options == ["ro"])

            // If the keychain item for a volume with a username is lost, bootstrap fails instead of mounting anonymously.
            try credentialStore.delete(volume: "corp")
            await #expect(throws: ContainerizationError.self) {
                _ = try await containersService.prepareBootstrapMounts(for: &config)
            }

            // If a named volume is missing, bootstrap fails.
            var missingVolConfig = ContainerConfiguration(id: "c2", image: image, process: process)
            missingVolConfig.mounts = [
                Filesystem.smb(
                    name: "nonexistent",
                    share: "//corp.local/files",
                    mountOptions: ["share": "//corp.local/files"],
                    destination: "/mnt/missing",
                    options: []
                )
            ]
            await #expect(throws: ContainerizationError.self) {
                _ = try await containersService.prepareBootstrapMounts(for: &missingVolConfig)
            }
        }
    }
    @Test("ContainersService.prepareBootstrapMounts fails when the keychain would need to ask the user")
    func testPrepareBootstrapMountsFailsWhenCredentialLookupFails() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            // A locked keychain, or an access list that no longer trusts the API server, surfaces as
            // a lookup error because the store never shows a dialog.
            let credentialStore = InMemoryVolumeCredentialStore(
                lookupError: KeychainVolumeCredentialStoreError.interactionRequired(status: -25293)
            )
            let (volumesService, containersService) = try await makeServices(appRoot: appRoot, credentialStore: credentialStore)

            let volume = try await volumesService.create(
                name: "corp",
                driver: "smb",
                driverOpts: ["share": "//corp.local/files", "username": "alice", "password": "hunter2"]
            )

            let image = ImageDescription(reference: "alpine:latest", descriptor: .init(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:00", size: 1))
            let process = ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
            var config = ContainerConfiguration(id: "c1", image: image, process: process)
            config.mounts = [
                Filesystem.smb(
                    name: "corp",
                    share: volume.source,
                    mountOptions: volume.options,
                    destination: "/mnt/corp",
                    options: []
                )
            ]

            let error = await #expect(throws: ContainerizationError.self) {
                _ = try await containersService.prepareBootstrapMounts(for: &config)
            }
            #expect(error?.code == .internalError)
            #expect(error?.message.contains("corp") == true)
            #expect(error?.cause as? KeychainVolumeCredentialStoreError == .interactionRequired(status: -25293))
        }
    }
}
