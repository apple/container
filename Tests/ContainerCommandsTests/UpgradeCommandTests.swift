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

import Foundation
import Testing

@testable import ContainerCommands

struct UpgradeCommandTests {
    private func asset(_ name: String) -> GitHubReleaseAsset {
        GitHubReleaseAsset(
            name: name,
            browserDownloadURL: URL(string: "https://example.com/\(name)")!
        )
    }

    @Test
    func endpointForLatestRelease() {
        let url = GitHubRelease.endpoint(forVersion: nil)
        #expect(url.absoluteString == "https://api.github.com/repos/apple/container/releases/latest")
    }

    @Test
    func endpointForPinnedRelease() {
        let url = GitHubRelease.endpoint(forVersion: "0.6.0")
        #expect(url.absoluteString == "https://api.github.com/repos/apple/container/releases/tags/0.6.0")
    }

    @Test
    func decodesReleaseJSON() throws {
        let json = """
            {
                "tag_name": "0.6.0",
                "assets": [
                    {
                        "name": "container-installer-signed.pkg",
                        "browser_download_url": "https://example.com/container-installer-signed.pkg"
                    }
                ]
            }
            """
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "0.6.0")
        #expect(release.assets.count == 1)
        #expect(release.assets[0].name == "container-installer-signed.pkg")
        #expect(release.assets[0].browserDownloadURL.absoluteString == "https://example.com/container-installer-signed.pkg")
    }

    @Test
    func prefersSignedPrimaryPackage() {
        let release = GitHubRelease(
            tagName: "0.6.0",
            assets: [
                asset("container-installer-unsigned.pkg"),
                asset("container-0.6.0-installer-signed.pkg"),
                asset("container-installer-signed.pkg"),
            ]
        )
        let package = release.installerPackage()
        #expect(package == InstallerPackage(url: URL(string: "https://example.com/container-installer-signed.pkg")!, isSigned: true))
    }

    @Test
    func fallsBackToVersionedSignedPackage() {
        let release = GitHubRelease(
            tagName: "0.6.0",
            assets: [
                asset("container-installer-unsigned.pkg"),
                asset("container-0.6.0-installer-signed.pkg"),
            ]
        )
        let package = release.installerPackage()
        #expect(package == InstallerPackage(url: URL(string: "https://example.com/container-0.6.0-installer-signed.pkg")!, isSigned: true))
    }

    @Test
    func fallsBackToUnsignedPackages() {
        let primary = GitHubRelease(
            tagName: "0.6.0",
            assets: [asset("container-installer-unsigned.pkg")]
        )
        #expect(
            primary.installerPackage()
                == InstallerPackage(url: URL(string: "https://example.com/container-installer-unsigned.pkg")!, isSigned: false))

        let fallback = GitHubRelease(
            tagName: "0.6.0",
            assets: [asset("container-0.6.0-installer-unsigned.pkg")]
        )
        #expect(
            fallback.installerPackage()
                == InstallerPackage(url: URL(string: "https://example.com/container-0.6.0-installer-unsigned.pkg")!, isSigned: false))
    }

    @Test
    func returnsNilWhenNoInstallerPackageExists() {
        let release = GitHubRelease(
            tagName: "0.6.0",
            assets: [asset("checksums.txt"), asset("container-0.6.0.tar.gz")]
        )
        #expect(release.installerPackage() == nil)
    }

    @Test
    func upgradePolicyDecisionTable() {
        // Same version, no force: do not upgrade.
        #expect(!UpgradePolicy.shouldUpgrade(target: "0.6.0", installed: "0.6.0", force: false))
        // Same version, force: upgrade.
        #expect(UpgradePolicy.shouldUpgrade(target: "0.6.0", installed: "0.6.0", force: true))
        // Different version: upgrade (string comparison only, matching the script).
        #expect(UpgradePolicy.shouldUpgrade(target: "0.7.0", installed: "0.6.0", force: false))
        // "Downgrade" is just a different string: upgrade.
        #expect(UpgradePolicy.shouldUpgrade(target: "0.5.0", installed: "0.6.0", force: false))
    }
}
