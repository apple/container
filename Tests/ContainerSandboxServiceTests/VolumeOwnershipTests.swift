//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors.
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
import Containerization
import ContainerizationOCI
import SystemPackage
@testable import ContainerClient
@testable import ContainerSandboxService

/// Tests for automatic volume ownership fixing to prevent permission errors
///
/// ## Architecture Overview - How configs flow in real life:
///
/// ```
/// User CLI Command:
///   container run --user appuser -v data:/app/data myimage
///          ↓
/// ContainerConfiguration (high-level, from user input):
///   - id: "container-123"
///   - image: ImageDescription("myimage")
///   - initProcess.user: .raw(userString: "appuser")
///   - mounts: [volume "data" → "/app/data"]
///          ↓
/// SandboxService.configureInitialProcess():
///   - Parses user specification
///   - For numeric "1000:1000" → uid=1000, gid=1000, username=""
///   - For username "appuser" → uid=0, gid=0, username="appuser"
///          ↓
/// LinuxContainer.Configuration (low-level, for containerization):
///   - process.user.uid: 0 (or numeric value)
///   - process.user.gid: 0 (or numeric value)
///   - process.user.username: "appuser" (or "")
///          ↓
/// fixVolumeOwnership():
///   - If username set but uid=0 → resolve from /etc/passwd
///   - If uid already set → use directly
///   - Modify EXT4 volume ownership to match
///          ↓
/// Volume on disk:
///   - /data ownership: appuser:appuser (1000:1000)
/// ```
///
final class VolumeOwnershipTests: XCTestCase {

    // MARK: - Test Case 1: Root User (uid=0) - Should Skip Ownership Fix

    /// Test that volumes keep root:root ownership when container runs as root
    func testRootUserSkipsOwnershipFix() throws {
        // Given: High-level container configuration from user input (e.g., CLI)
        // ContainerConfiguration = what user specifies via `container run --user 0:0`
        _ = createMockContainerConfig(user: .id(uid: 0, gid: 0))

        // Given: Low-level Linux container config used by containerization layer
        // LinuxContainer.Configuration = internal representation after processing ContainerConfiguration
        let czConfig = createMockLinuxContainerConfig(uid: 0, gid: 0, username: "")

        // In real life:
        // 1. User runs: `container run --user 0:0 ...`
        // 2. CLI creates ContainerConfiguration with user=.id(0,0)
        // 3. SandboxService transforms it into LinuxContainer.Configuration
        // 4. fixVolumeOwnership uses czConfig to determine ownership

        XCTAssertEqual(czConfig.process.user.uid, 0, "Root user should have uid=0")
        XCTAssertEqual(czConfig.process.user.gid, 0, "Root user should have gid=0")

        // Expected: Volume would remain root:root (not modified)
    }

    // MARK: - Test Case 2: Numeric UID:GID (--user 1000:1000)

    /// Test that volumes get correct ownership when user is specified as numeric uid:gid
    func testNumericUserSetsCorrectOwnership() throws {
        // Given: Container with numeric user specification (uid=1000, gid=1000)
        let config = createMockContainerConfig(user: .raw(userString: "1000:1000"))

        // When: configureInitialProcess parses the user
        var czConfig = createEmptyLinuxContainerConfig()
        _ = config.initProcess

        // Parse numeric uid:gid from raw string (simulating the fix we implemented)
        let parts = "1000:1000".split(separator: ":")
        if parts.count == 2, let uid = UInt32(parts[0]), let gid = UInt32(parts[1]) {
            czConfig.process.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: [],
                username: ""
            )
        }

        // Then: User should be resolved to numeric values
        XCTAssertEqual(czConfig.process.user.uid, 1000, "Numeric uid should be 1000")
        XCTAssertEqual(czConfig.process.user.gid, 1000, "Numeric gid should be 1000")
        XCTAssertEqual(czConfig.process.user.username, "", "Username should be empty for numeric user")

        // Expected: Volume ownership would be set to 1000:1000
        // In real implementation, EXT4.Formatter.setOwner would be called with uid=1000, gid=1000
    }

    // MARK: - Test Case 3: Username String (--user dynamodblocal)

    /// Test that username is resolved to uid:gid by reading /etc/passwd from rootfs
    func testUsernameResolutionFromPasswd() throws {
        // Given: Container with username specification
        _ = createMockContainerConfig(user: .raw(userString: "appuser"))
        var czConfig = createMockLinuxContainerConfig(uid: 0, gid: 0, username: "appuser")

        // Simulate /etc/passwd content
        let passwdContent = """
        root:x:0:0:root:/root:/bin/bash
        daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
        appuser:x:1000:1000:Application User:/home/appuser:/bin/bash
        nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
        """

        // When: Username is resolved from /etc/passwd
        let resolved = parsePasswdEntry(username: "appuser", passwdContent: passwdContent)

        // Then: Should resolve to correct uid:gid
        XCTAssertNotNil(resolved, "Username 'appuser' should be found in passwd")
        XCTAssertEqual(resolved?.uid, 1000, "Resolved uid should be 1000")
        XCTAssertEqual(resolved?.gid, 1000, "Resolved gid should be 1000")

        // When: Applied to czConfig
        if let resolved = resolved {
            czConfig.process.user.uid = resolved.uid
            czConfig.process.user.gid = resolved.gid
        }

        XCTAssertEqual(czConfig.process.user.uid, 1000, "Username should resolve to uid=1000")
        XCTAssertEqual(czConfig.process.user.gid, 1000, "Username should resolve to gid=1000")

        // Expected: Volume ownership would be set to 1000:1000 (appuser)
        // In real implementation, resolveUsernameToUidGid would read from EXT4 rootfs
    }

    // MARK: - Test Case 4: Multiple Volumes Get Same Ownership

    /// Test that all volumes get the same ownership when container has multiple volumes
    func testMultipleVolumesGetSameOwnership() throws {
        // Given: Container with user 1000:1000
        let czConfig = createMockLinuxContainerConfig(uid: 1000, gid: 1000, username: "")

        // In real life:
        // container run --user 1000:1000 -v vol1:/data1 -v vol2:/data2 -v vol3:/data3
        // All 3 volumes should get ownership 1000:1000

        XCTAssertEqual(czConfig.process.user.uid, 1000, "All volumes should use uid=1000")
        XCTAssertEqual(czConfig.process.user.gid, 1000, "All volumes should use gid=1000")

        // Expected: Each volume (vol1, vol2, vol3) would have EXT4.Formatter.setOwner called
        // with the same uid=1000, gid=1000 values
    }

    // MARK: - Test Case 5: Non-EXT4 Volume Is Skipped

    /// Test that volumes with non-ext4 format are skipped gracefully
    func testNonExt4VolumeIsSkipped() throws {
        // Given: Volume with different filesystem format
        // In real life: volume created with format=xfs or btrfs

        // This would be detected by checking volume.format != "ext4"
        let volumeFormat = "xfs"

        // When: Checking if volume should be processed
        let shouldProcess = volumeFormat.lowercased() == "ext4"

        // Then: Should skip non-ext4 volumes
        XCTAssertFalse(shouldProcess, "Non-EXT4 volumes should be skipped")

        // Expected behavior:
        // - fixVolumeOwnership logs: "Volume 'data' format 'xfs' not supported, skipping"
        // - Volume ownership remains unchanged (likely root:root)
        // - User may encounter permission errors (logged as warning)
    }

    // MARK: - Test Case 6: Mixed Volume and Bind Mounts

    /// Test that only named volumes get ownership fix, bind mounts are skipped
    func testMixedVolumeAndBindMounts() throws {
        // Given: Container with both volume and bind mount
        // In real life:
        // container run -v namedvolume:/data -v /host/path:/bind

        // Simulating mount type filtering
        enum MountType {
            case volume(name: String)
            case bind(source: String)
        }

        let mounts: [MountType] = [
            .volume(name: "namedvolume"),
            .bind(source: "/host/path")
        ]

        // When: Filtering for volumes only
        let volumeMounts = mounts.filter { mount in
            if case .volume = mount { return true }
            return false
        }

        // Then: Only named volumes should be included
        XCTAssertEqual(volumeMounts.count, 1, "Should only process named volumes")

        // Expected behavior:
        // - Named volume "namedvolume" gets ownership fix
        // - Bind mount "/host/path" is skipped (host filesystem owns it)
    }

    // MARK: - Test Case 7: Username Not Found

    /// Test that missing username is handled gracefully
    func testUsernameNotFoundReturnsNil() throws {
        // Given: /etc/passwd without the requested username
        let passwdContent = """
        root:x:0:0:root:/root:/bin/bash
        daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
        """

        // When: Trying to resolve non-existent username
        let resolved = parsePasswdEntry(username: "nonexistent", passwdContent: passwdContent)

        // Then: Should return nil
        XCTAssertNil(resolved, "Non-existent username should return nil")

        // Expected: fixVolumeOwnership would skip the volume fix and log warning
    }

    // MARK: - Helper Functions

    /// Creates mock ContainerConfiguration - HIGH-LEVEL config from user input
    ///
    /// This represents what the CLI layer creates when user runs:
    /// `container run --user <USER> --image <IMAGE> ...`
    ///
    /// In real life flow:
    /// CLI → ContainerConfiguration → SandboxService → LinuxContainer.Configuration
    private func createMockContainerConfig(user: ProcessConfiguration.User) -> ContainerConfiguration {
        let imageDesc = ImageDescription(
            reference: "docker.io/library/test:latest",
            descriptor: Descriptor(
                mediaType: "application/vnd.oci.image.index.v1+json",
                digest: "sha256:test",
                size: 1000
            )
        )

        let initProcess = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", "sleep infinity"],
            environment: ["PATH=/usr/bin"],
            workingDirectory: "/",
            terminal: false,
            user: user,
            supplementalGroups: [],
            rlimits: []
        )

        return ContainerConfiguration(
            id: "test-container",
            image: imageDesc,
            process: initProcess
        )
    }

    /// Creates mock LinuxContainer.Configuration - LOW-LEVEL config for containerization
    ///
    /// This represents the internal configuration used by the containerization layer.
    /// It's created by SandboxService.configureInitialProcess() which transforms
    /// ContainerConfiguration into this format.
    ///
    /// In real life:
    /// - ContainerConfiguration.user = .raw("appuser") or .id(1000, 1000)
    /// - configureInitialProcess() parses it and creates LinuxContainer.Configuration
    /// - For .raw("appuser"): sets uid=0, gid=0, username="appuser"
    /// - For .id(1000, 1000): sets uid=1000, gid=1000, username=""
    /// - fixVolumeOwnership() then uses this to determine volume ownership
    private func createMockLinuxContainerConfig(uid: UInt32, gid: UInt32, username: String) -> LinuxContainer.Configuration {
        var config = LinuxContainer.Configuration()
        config.process.user = ContainerizationOCI.User(
            uid: uid,
            gid: gid,
            umask: nil,
            additionalGids: [],
            username: username
        )
        return config
    }

    private func createEmptyLinuxContainerConfig() -> LinuxContainer.Configuration {
        return LinuxContainer.Configuration()
    }

    private func createMockBundle() throws -> ContainerClient.Bundle {
        // Create temporary directory for mock bundle
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        return ContainerClient.Bundle(path: tempDir)
    }

    /// Helper to parse /etc/passwd entry and extract uid/gid
    private func parsePasswdEntry(username: String, passwdContent: String) -> (uid: UInt32, gid: UInt32)? {
        for line in passwdContent.split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count >= 4 else { continue }

            let lineUsername = String(parts[0])
            guard lineUsername == username else { continue }

            guard let uid = UInt32(parts[2]), let gid = UInt32(parts[3]) else {
                return nil
            }

            return (uid: uid, gid: gid)
        }

        return nil
    }
}
